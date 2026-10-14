#!/usr/bin/env python3
"""End-to-end run of a debug build: the real app, the real Photos library, a
fake Google.

    scripts/e2e.py --app <Photos Backup.app built by scripts/build-app.sh> [--work <dir>] [--only s1,s2]

What it does:
  1. Builds the debug binary and puts it in a copy of the given bundle (which
     carries the Python runtime), signed with the same identity, so the copy
     keeps the bundle id and therefore the Photos permission the real app has.
  2. Lays out the fake uploader (Tests/E2E/fake_gpmc) and drives each scenario
     with a scenario file, the public photosbackup:// links, and the debug-only
     photosbackup://debug/... links (E2EHooks.swift), reading the app's state
     back as JSON.
  3. Everything the app writes goes under <work>/sandbox (PHOTOS_BACKUP_SANDBOX):
     the real app's history, settings and keychain item are never touched. No
     byte leaves the Mac: the fake answers for Google.

Two launch modes. "open" launches through LaunchServices, so the app is its
own privacy client (Photos allowed, no Full Disk Access). "exec" starts the
binary from this shell, so it inherits the terminal's Full Disk Access; the
Messages scenarios use it. The Messages archive it writes holds private
message text: it lands in <work>/archive and is deleted at the end.

Output: <work>/report.md (pass/fail per check, timings) and exit status 0 only
if every check passed. No album title, file name, message text or contact
detail is printed or written to the report.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

REPO = Path(__file__).resolve().parents[1]
BUNDLE_ID = "io.github.ayush5harma.PhotosBackup"
FAKE_AUTH = ("androidId=0123456789abcdef&app=com.google.android.apps.photos&client_sig=0&"
             "Email=e2e.tester%40example.com&service=oauth2&Token=aas_et/E2E-FAKE-TOKEN-NOT-A-SECRET")


class Harness:
    def __init__(self, app: Path, work: Path) -> None:
        self.source_app = app
        self.work = work
        self.app = work / "Photos Backup.app"
        self.sandbox = work / "sandbox"
        self.runtime = work / "runtime"
        self.state_file = work / "state.json"
        self.archive = work / "archive"
        self.results: list[tuple[str, str, bool, str]] = []
        self.process: subprocess.Popen[bytes] | None = None
        self.scenario_name = ""

    # MARK: setup

    def build(self) -> None:
        run(["swift", "build", "--product", "PhotosBackup"], cwd=REPO)
        binary = Path(run(["swift", "build", "--show-bin-path"], cwd=REPO).strip()) / "PhotosBackup"
        if self.app.exists():
            shutil.rmtree(self.app)
        run(["ditto", str(self.source_app), str(self.app)])
        shutil.copy2(binary, self.app / "Contents/MacOS/PhotosBackup")
        identity = signing_identity(self.source_app)
        run(["codesign", "--force", "--sign", identity, "--identifier", BUNDLE_ID, str(self.app)])
        run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
             "-f", str(self.app)])
        log(f"bundle ready, signed with {identity!r}")

    def reset(self) -> None:
        self.quit()
        for path in (self.sandbox, self.runtime, self.archive, self.state_file):
            if path.is_dir():
                shutil.rmtree(path)
            elif path.exists():
                path.unlink()
        self.sandbox.mkdir(parents=True)
        run([str(REPO / "Tests/E2E/make_fake_runtime.sh"), str(self.runtime)])
        subprocess.run(["defaults", "delete", BUNDLE_ID + ".sandbox"], capture_output=True)
        subprocess.run(["security", "delete-generic-password", "-s", BUNDLE_ID + ".auth-data.sandbox", "-a", "gpmc"],
                       capture_output=True)
        self.scenario({})

    def scenario(self, values: dict[str, Any]) -> None:
        values = {"ledger": str(self.runtime / "fake_gpmc_ledger.json"), **values}
        (self.runtime / "fake_gpmc_scenario.json").write_text(json.dumps(values))

    def ledger(self) -> dict[str, Any]:
        path = self.runtime / "fake_gpmc_ledger.json"
        return json.loads(path.read_text()) if path.exists() else {"media": {}, "uploads": [], "albums": {}, "counters": {}}

    def environment(self) -> dict[str, str]:
        return {
            "PHOTOS_BACKUP_SANDBOX": str(self.sandbox),
            "PHOTOS_BACKUP_PYTHON": str(self.app / "Contents/Resources/python/bin/python3"),
            "PHOTOS_BACKUP_BRIDGE": str(self.runtime / "gpmc_bridge.py"),
        }

    # MARK: launching and talking

    def launch(self, mode: str = "open") -> None:
        self.quit()
        if mode == "open":
            env_args = [arg for key, value in self.environment().items() for arg in ("--env", f"{key}={value}")]
            run(["open", "-n", "-g", *env_args, "-a", str(self.app)])
        else:
            env = {**os.environ, **self.environment()}
            log_file = open(self.work / "exec.log", "ab")
            self.process = subprocess.Popen([str(self.app / "Contents/MacOS/PhotosBackup")], env=env,
                                            stdout=log_file, stderr=subprocess.STDOUT)
        self.wait("the app answers", lambda s: s.get("pid") is not None, timeout=60, poll=1.5)

    def link(self, path: str) -> None:
        run(["open", "-g", "-a", str(self.app), f"photosbackup://{path}"])

    def state(self, timeout: float = 15) -> dict[str, Any]:
        before = self.state_file.stat().st_mtime_ns if self.state_file.exists() else 0
        self.link(f"debug/state?out={self.state_file}")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.state_file.exists() and self.state_file.stat().st_mtime_ns != before:
                try:
                    return json.loads(self.state_file.read_text())
                except json.JSONDecodeError:
                    pass
            time.sleep(0.3)
        return {}

    def wait(self, what: str, condition: Callable[[dict[str, Any]], bool], timeout: float = 120, poll: float = 2) -> dict[str, Any]:
        deadline = time.time() + timeout
        state: dict[str, Any] = {}
        while time.time() < deadline:
            state = self.state(timeout=min(15, max(2, deadline - time.time())))
            try:
                if state and condition(state):
                    return state
            except (KeyError, IndexError, TypeError):
                pass
            time.sleep(poll)
        raise TimeoutError(f"timed out waiting for {what}; last phase={state.get('phase')} "
                           f"wait={state.get('waitReason')} error={state.get('lastError')}")

    def settings(self, **values: Any) -> None:
        query = "&".join(f"{key}={json.dumps(value)}" for key, value in values.items())
        self.link(f"debug/settings?{query}")
        time.sleep(0.8)

    def quit(self) -> None:
        if self.running_pid():
            self.link("debug/quit")
            deadline = time.time() + 20
            while self.running_pid() and time.time() < deadline:
                time.sleep(0.5)
        if self.process:
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.send_signal(signal.SIGTERM)
            self.process = None
        pid = self.running_pid()
        if pid:
            os.kill(pid, signal.SIGTERM)
            time.sleep(1)

    def running_pid(self) -> int | None:
        out = subprocess.run(["pgrep", "-f", str(self.app / "Contents/MacOS/PhotosBackup")], capture_output=True, text=True).stdout
        pids = [int(line) for line in out.split()]
        return pids[0] if pids else None

    # MARK: checks

    def check(self, name: str, passed: bool, detail: str = "") -> bool:
        self.results.append((self.scenario_name, name, bool(passed), detail))
        log(f"  {'PASS' if passed else 'FAIL'}  {name}{('  (' + detail + ')') if detail else ''}")
        return bool(passed)

    def report(self) -> int:
        failed = [r for r in self.results if not r[2]]
        lines = ["# Photos Backup end-to-end run", "",
                 f"{len(self.results) - len(failed)} of {len(self.results)} checks passed.", "",
                 "| Scenario | Check | Result | Detail |", "|---|---|---|---|"]
        lines += [f"| {s} | {n} | {'pass' if p else 'FAIL'} | {d} |" for s, n, p, d in self.results]
        (self.work / "report.md").write_text("\n".join(lines) + "\n")
        log(f"\n{len(self.results) - len(failed)} of {len(self.results)} checks passed; report: {self.work / 'report.md'}")
        return 0 if not failed else 1


def run(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {result.stderr.strip()[-2000:]}")
    return result.stdout


def signing_identity(app: Path) -> str:
    out = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True).stderr
    for line in out.splitlines():
        if line.startswith("Authority="):
            return line.split("=", 1)[1]
    return "-"


def log(message: str) -> None:
    print(message, flush=True)


def idle(state: dict[str, Any]) -> bool:
    return state.get("phase") in ("idle", "paused")


def last_run(state: dict[str, Any], kind: str) -> dict[str, Any] | None:
    return next((run for run in state.get("runs", []) if run["kind"] == kind and run["finished"]), None)


# MARK: scenarios

def s_launch(h: Harness) -> None:
    h.launch("open")
    s = h.wait("albums to load", lambda s: s["albumsLoaded"], timeout=180)
    h.check("app launches sandboxed", s["sandbox"] == str(h.sandbox))
    h.check("Photos access carries over to the build", s["photosAuthorized"])
    h.check("welcome guide pending on a fresh install", s["settings"]["onboardingCompleted"] is False)
    h.check("not signed in", s["hasAuthData"] is False)
    h.check("first launch selects All Photos", s["selectedAlbumIDs"] == ["all-photos"])
    h.check("conditions are read", s["conditions"] not in ("", "Unknown"), s["conditions"])
    h.settings(onboardingCompleted=True, automatic=False)
    s = h.state()
    h.check("settings change through the model", s["settings"]["onboardingCompleted"] and not s["settings"]["automatic"])


def s_connect(h: Harness) -> None:
    h.link(f"debug/connect?auth={FAKE_AUTH.replace('&', '%26').replace('=', '%3D')}")
    s = h.wait("the account to connect", lambda s: s["hasAuthData"] and "connected" in s["account"], timeout=60)
    h.check("pasted credential verified through the bridge", "e2e.tester@example.com" in s["account"], s["account"])
    h.check("connect is logged without the token", not any("aas_et" in e["message"] for e in s["events"]))


def choose_small_album(h: Harness) -> dict[str, Any]:
    h.link("debug/select?smallest=3-25")
    s = h.wait("an album to be selected", lambda s: len(s["selectedAlbumIDs"]) == 1, timeout=20)
    album = next(a for a in s["albums"] if a["id"] == s["selectedAlbumIDs"][0])
    return album


def s_photos(h: Harness) -> None:
    album = choose_small_album(h)
    h.check("a small user album exists to test with", album["kind"] == "user" and 3 <= album["count"] <= 25, f"{album['count']} items")
    started = time.time()
    h.link("backup/photos")
    s = h.wait("the photo run to finish", lambda s: idle(s) and last_run(s, "photos") is not None, timeout=600)
    run_record = last_run(s, "photos")
    ledger = h.ledger()
    uploaded = [u for u in ledger["uploads"] if u["status"] == "uploaded"]
    h.check("run completes", run_record["outcome"] == "completed", f"{time.time() - started:.0f} s")
    h.check("every item in the album recorded as backed up", s["summary"]["pending"] == 0 and s["summary"]["backedUp"] == album["count"],
            f"{s['summary']['backedUp']} of {album['count']}")
    h.check("the fake Google received each file once", len({u['sha1'] for u in uploaded}) == len(uploaded) and len(uploaded) >= 1,
            f"{len(uploaded)} uploads")
    h.check("run record counts the uploads", run_record["uploaded"] + run_record["existing"] == album["count"])
    mirror = s["mirrors"].get(album["id"], {})
    h.check("the album is recreated in Google Photos", bool(mirror.get("googleAlbumID")) and mirror.get("added") == album["count"])
    h.check("trigger recorded as a link", run_record["trigger"] == "automation")

    h.link("backup/photos")
    s = h.wait("a second run", lambda s: idle(s) and len([r for r in s["runs"] if r["kind"] == "photos"]) >= 2, timeout=300)
    again = h.ledger()
    h.check("a second run uploads nothing", len([u for u in again["uploads"] if u["status"] == "uploaded"]) == len(uploaded))


def s_recheck(h: Harness) -> tuple[dict[str, Any], int]:
    """Forget what was backed up, as Re-check Backups does, keeping the selection."""
    album = next(a for a in h.state()["albums"] if a["id"] == h.state()["selectedAlbumIDs"][0])
    h.quit()
    state_path = h.sandbox / "Support/state.json"
    data = json.loads(state_path.read_text())
    data["uploaded"] = {}
    state_path.write_text(json.dumps(data))
    ledger_path = h.runtime / "fake_gpmc_ledger.json"
    if ledger_path.exists():
        ledger_path.unlink()
    return album, album["count"]


def s_retry(h: Harness) -> None:
    album, count = s_recheck(h)
    h.scenario({"flaky_first": {"times": 2, "error": "503"}, "fail_first": 0})
    h.launch("open")
    h.link("backup/photos")
    s = h.wait("the run with flaky uploads", lambda s: idle(s) and last_run(s, "photos") is not None, timeout=600)
    run_record = last_run(s, "photos")
    h.check("retryable failures are retried in the same run", run_record["failed"] == 0 and s["summary"]["pending"] == 0,
            f"failed={run_record['failed']} pending={s['summary']['pending']}")
    attempts = [u for u in h.ledger()["uploads"] if u["status"] == "failed"]
    h.check("the fake saw the failed attempts", len(attempts) >= 1, f"{len(attempts)} failed attempts")

    album, count = s_recheck(h)
    h.scenario({"fail_first": 1})
    h.launch("open")
    h.link("backup/photos")
    s = h.wait("a run with a permanent failure", lambda s: idle(s) and last_run(s, "photos") is not None, timeout=600)
    h.check("a permanent failure is not retried", s["failedCount"] == 1 and last_run(s, "photos")["failed"] == 1,
            f"failedCount={s['failedCount']}")
    failed_rows = [a for a in s["activity"] if a["failed"]]
    h.check("the failed row carries Google's words", bool(failed_rows) and "400" in (failed_rows[0].get("detail") or ""))
    h.link("retry-failed")
    s = h.wait("Retry Failed to finish", lambda s: idle(s) and s["failedCount"] == 0 and s["summary"]["pending"] == 0, timeout=300)
    h.check("Retry Failed backs the item up", s["summary"]["pending"] == 0)


def s_rate_limit(h: Harness) -> None:
    album, count = s_recheck(h)
    h.scenario({"rate_limit_first": 1})
    h.launch("open")
    h.link("backup/photos")
    s = h.wait("the rate-limit hold", lambda s: s["phase"] == "waiting" and "slow down" in (s.get("waitReason") or ""), timeout=180, poll=1)
    h.check("a 429 holds the run", True, s["waitReason"])
    started = time.time()
    s = h.wait("the run to resume and finish", lambda s: idle(s) and s["summary"]["pending"] == 0, timeout=300)
    held = time.time() - started
    h.check("the run carries on by itself after the hold", s["summary"]["pending"] == 0, f"held about {held:.0f} s")
    h.check("the hold is in the timeline", any("slow down" in e["message"].lower() or "rate" in e["message"].lower() for e in s["events"]))


def s_controls(h: Harness) -> None:
    album, count = s_recheck(h)
    h.scenario({"delay": 1.5})
    h.settings(threads=1, batchSize=5)
    h.launch("open")
    h.link("backup/photos")
    h.wait("the run to start uploading", lambda s: s["phase"] == "running" and s["runDone"] >= 1, timeout=180, poll=1)
    h.link("pause")
    s = h.wait("pause", lambda s: s["phase"] == "paused", timeout=120, poll=1)
    done_at_pause = s["runDone"]
    h.check("Pause stops after the current batch", s["phase"] == "paused" and done_at_pause < count, f"{done_at_pause} of {count}")
    time.sleep(4)
    h.check("nothing uploads while paused", h.state()["runDone"] == done_at_pause)
    h.link("resume")
    h.wait("resume", lambda s: s["phase"] == "running", timeout=30, poll=1)
    h.check("Resume continues the run", True)
    h.link("stop")
    s = h.wait("stop", lambda s: s["phase"] == "idle", timeout=60, poll=1)
    stopped = next(r for r in s["runs"] if r["kind"] == "photos")
    h.check("Stop ends the run", stopped["outcome"] == "stopped", str(stopped["outcome"]))
    h.check("no uploader left running after Stop",
            subprocess.run(["pgrep", "-f", str(h.runtime / "gpmc_bridge.py")], capture_output=True).returncode != 0)
    h.scenario({})
    h.settings(threads=2, batchSize=20)


def s_conditions(h: Harness) -> None:
    album, count = s_recheck(h)
    h.launch("open")
    h.link("debug/conditions?network=expensive")
    time.sleep(1)
    s = h.state()
    h.check("a metered network blocks automatic runs", s["blocking"] == "Paused on a metered network", str(s["blocking"]))
    h.link("debug/conditions?network=offline")
    h.link("backup/photos")
    s = h.wait("the offline hold", lambda s: s["phase"] == "waiting" and "network" in (s.get("waitReason") or "").lower(), timeout=120, poll=1)
    h.check("a run holds while offline", True, s["waitReason"])
    h.link("debug/conditions?network=online&power=ac")
    s = h.wait("the run to finish once online", lambda s: idle(s) and s["summary"]["pending"] == 0, timeout=300)
    h.check("the run resumes when the network returns", s["summary"]["pending"] == 0)
    h.link("debug/conditions?network=real&power=real")


def s_shell(h: Harness) -> None:
    h.launch("open")
    h.settings(showInDock=False)
    time.sleep(1.5)
    h.check("menu bar only hides the Dock icon", h.state()["activationPolicy"] == "accessory")
    h.settings(showInDock=True)
    time.sleep(1.5)
    h.check("Show in Dock brings it back", h.state()["activationPolicy"] == "regular")
    h.link("settings/backup")
    time.sleep(2)
    s = h.state()
    h.check("photosbackup://settings opens the Settings window", any(w for w in s["windows"] if w not in ("", "Photos Backup")), str(s["windows"]))
    h.link("open/activity")
    time.sleep(1.5)
    h.check("photosbackup://open shows the main window", len(h.state()["windows"]) >= 1, str(h.state()["windows"]))
    h.link("bogus-command")
    time.sleep(1)
    h.check("unknown links are ignored and logged", any("does not know" in e["message"] for e in h.state()["events"]))


def s_messages_without_access(h: Harness) -> None:
    h.launch("open")
    h.settings(messagesArchive=True, archiveFolder=str(h.archive), archiveContactNames=False, messagesMedia=True)
    h.link("archive")
    s = h.wait("the archive to report missing access", lambda s: s["archiveStatus"] in ("needsFullDiskAccess",) or s["archiveStatus"].startswith("failed"), timeout=60, poll=1)
    h.check("the archive asks for Full Disk Access when it lacks it", s["archiveStatus"] == "needsFullDiskAccess", s["archiveStatus"])
    h.link("backup/messages-media")
    s = h.wait("Messages media to report", lambda s: "scanning" not in s["messagesStatus"], timeout=60, poll=1)
    h.check("Messages media says what it needs", "Full Disk Access" in s["messagesStatus"], s["messagesStatus"])
    h.settings(messagesArchive=False, messagesMedia=False)


def s_messages(h: Harness) -> None:
    h.launch("exec")
    h.settings(messagesArchive=True, archiveFolder=str(h.archive), archiveContactNames=False, archiveSnapshotsToKeep=2,
               messagesMedia=True, automatic=False)
    started = time.time()
    h.link("archive")
    s = h.wait("the archive to finish", lambda s: s["archiveStatus"].startswith("finished"), timeout=900, poll=2)
    first = time.time() - started
    overview = s.get("archiveOverview") or {}
    h.check("the archive reads every conversation", overview.get("conversations", 0) > 0 and overview.get("messages", 0) > 0,
            f"{overview.get('conversations')} conversations, {overview.get('messages')} messages, {first:.0f} s")
    h.check("the archive is browsable", (h.archive / "index.html").exists() and (h.archive / "style.css").exists())
    h.check("a database copy is kept", any((h.archive / "Database").glob("chat-*.db")))
    modes = {oct(p.stat().st_mode & 0o777) for p in [h.archive, *(h.archive / "Conversations").iterdir()]}
    h.check("archive folders are private (0700)", modes == {"0o700"}, str(modes))
    h.check("the archive run joins the history", last_run(s, "messagesArchive") is not None)
    before = {p: p.stat().st_mtime_ns for p in (h.archive / "Conversations").glob("*/index.html")}
    started = time.time()
    h.link("archive")
    s = h.wait("the second archive", lambda s: s["archiveStatus"].startswith("finished") and
               len([r for r in s["runs"] if r["kind"] == "messagesArchive"]) >= 2, timeout=600, poll=1)
    second = time.time() - started
    after = {p: p.stat().st_mtime_ns for p in before}
    h.check("a second archive with nothing new rewrites no conversation", before == after, f"{second:.1f} s")

    h.link("backup/messages-media")
    s = h.wait("Messages media to back up", lambda s: idle(s) and last_run(s, "messagesMedia") is not None, timeout=900)
    media = [i for i in s["uploadedIDs"] if i.startswith("messages:")]
    record = last_run(s, "messagesMedia")
    h.check("Messages media run completes", record["outcome"] == "completed", f"{len(media)} items, {record['failed']} failed")
    h.check("every confirmed attachment is recorded", len(media) == record["uploaded"] + record["existing"] or len(media) >= record["uploaded"],
            f"{len(media)} recorded, {record['uploaded']} uploaded, {record['existing']} existing")
    uploads = h.ledger()["uploads"]
    named = [u for u in uploads if u["filename"].startswith("Messages-")]
    h.check("uploads never carry the chat's file names", len(named) == len(uploads), f"{len(named)} of {len(uploads)} named Messages-<hash>")


def s_diagnostics(h: Harness) -> None:
    s = h.state()
    blob = json.dumps(s)
    h.check("the timeline never holds the token", "aas_et/E2E" not in blob)
    events = (h.sandbox / "Support/events.json").read_text() if (h.sandbox / "Support/events.json").exists() else ""
    history = (h.sandbox / "Support/history.json").read_text() if (h.sandbox / "Support/history.json").exists() else ""
    h.check("events and history are persisted", bool(events) and bool(history))
    h.check("persisted events are redacted", "aas_et/E2E" not in events and "e2e.tester@example.com" not in events)


SCENARIOS: dict[str, Callable[[Harness], None]] = {
    "launch": s_launch, "connect": s_connect, "photos": s_photos, "retry": s_retry, "rate-limit": s_rate_limit,
    "controls": s_controls, "conditions": s_conditions, "shell": s_shell,
    "messages-no-access": s_messages_without_access, "messages": s_messages, "diagnostics": s_diagnostics,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--work", type=Path, default=Path.home() / ".cache/photos-backup-e2e")
    parser.add_argument("--only", default="")
    parser.add_argument("--keep", action="store_true", help="keep the sandbox and the archive afterwards")
    args = parser.parse_args()
    if subprocess.run(["pgrep", "-x", "PhotosBackup"], capture_output=True).returncode == 0:
        log("Quit Photos Backup first: a second copy with the same bundle id would receive the links.")
        return 2
    harness = Harness(args.app.resolve(), args.work.resolve())
    harness.work.mkdir(parents=True, exist_ok=True)
    harness.build()
    harness.reset()
    names = [n for n in args.only.split(",") if n] or list(SCENARIOS)
    try:
        for name in names:
            harness.scenario_name = name
            log(f"\n== {name}")
            try:
                SCENARIOS[name](harness)
            except Exception as error:  # a scenario that cannot finish is a failed check, not a crash
                harness.check("scenario finished", False, f"{type(error).__name__}: {error}")
    finally:
        harness.quit()
        if not args.keep:
            shutil.rmtree(harness.archive, ignore_errors=True)
            subprocess.run(["defaults", "delete", BUNDLE_ID + ".sandbox"], capture_output=True)
            subprocess.run(["security", "delete-generic-password", "-s", BUNDLE_ID + ".auth-data.sandbox", "-a", "gpmc"],
                           capture_output=True)
    return harness.report()


if __name__ == "__main__":
    sys.exit(main())
