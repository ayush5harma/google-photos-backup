#!/usr/bin/env python3
"""End-to-end run of a debug build: the real app, the real Photos library, a
fake Google.

    scripts/e2e.py --app <Photos Backup.app built by scripts/build-app.sh> [--work <dir>] [--only s1,s2]

Several Google accounts (#49): --only launch,connect,photos,migrate,accounts,choice

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
own privacy client (its current Photos and Full Disk Access grants). "exec" starts the
binary from this shell, so it inherits the terminal's Full Disk Access; the
Messages scenarios use it. "denied" additionally blocks reads of Library/Messages
with sandbox-exec, independently of existing privacy grants. The Messages archive it writes holds private
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
from urllib.parse import urlencode

REPO = Path(__file__).resolve().parents[1]
BUNDLE_ID = "io.github.ayush5harma.PhotosBackup"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
FAKE_AUTH = ("androidId=0123456789abcdef&app=com.google.android.apps.photos&client_sig=0&"
             "Email=e2e.tester%40example.com&service=oauth2&Token=aas_et/E2E-FAKE-TOKEN-NOT-A-SECRET")
# A second made-up account, for the several-accounts scenarios.
FAKE_AUTH_2 = FAKE_AUTH.replace("e2e.tester%40example.com", "e2e.second%40example.com")
FIRST_ACCOUNT, SECOND_ACCOUNT = "e2e.tester@example.com", "e2e.second@example.com"
SANDBOX_KEYCHAIN = BUNDLE_ID + ".auth-data.sandbox"


def clear_sandbox_keychain() -> None:
    """Every item of the sandbox keychain service: one per account since #49,
    and the "gpmc" item from before. Never the app's own service."""
    for _ in range(20):
        if subprocess.run(["security", "delete-generic-password", "-s", SANDBOX_KEYCHAIN], capture_output=True).returncode != 0:
            break


def sandbox_keychain_has(account: str) -> bool:
    return subprocess.run(["security", "find-generic-password", "-s", SANDBOX_KEYCHAIN, "-a", account],
                          capture_output=True).returncode == 0


def quoted(auth: str) -> str:
    return auth.replace("&", "%26").replace("=", "%3D")


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
        self.mode = "open"
        self.sent = 0
        self.scenario_name = ""

    # MARK: setup

    def build(self) -> None:
        run(["swift", "build", "--product", "PhotosBackup"], cwd=REPO)
        binary = Path(run(["swift", "build", "--show-bin-path"], cwd=REPO).strip()) / "PhotosBackup"
        if self.app.exists():
            shutil.rmtree(self.app)
        run(["ditto", str(self.source_app), str(self.app)])
        shutil.copy2(binary, self.app / "Contents/MacOS/PhotosBackup")
        # The copy refuses to run without the sandbox (E2EHooks.refuseUnsandboxedCopy).
        run(["/usr/libexec/PlistBuddy", "-c", "Add :PhotosBackupE2ECopy bool true", str(self.app / "Contents/Info.plist")])
        identity = signing_identity(self.source_app)
        run(["codesign", "--force", "--sign", identity, "--identifier", BUNDLE_ID, str(self.app)])
        run([LSREGISTER, "-f", str(self.app)])
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
        clear_sandbox_keychain()
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
        self.mode = mode
        if mode == "open":
            env_args = [arg for key, value in self.environment().items() for arg in ("--env", f"{key}={value}")]
            run(["open", "-n", "-g", *env_args, "-a", str(self.app)])
        else:
            env = {**os.environ, **self.environment()}
            log_file = open(self.work / "exec.log", "ab")
            command = [str(self.app / "Contents/MacOS/PhotosBackup")]
            if mode == "denied":
                # 2026-10-15: LaunchServices inherited an existing FDA grant;
                # enforce the denial rather than assuming the owner lacks it.
                messages = str(Path.home() / "Library/Messages")
                profile = f"(version 1)(allow default)(deny file-read* (subpath {json.dumps(messages)}))"
                command = ["/usr/bin/sandbox-exec", "-p", profile, *command]
            self.process = subprocess.Popen(command, env=env,
                                            stdout=log_file, stderr=subprocess.STDOUT)
        self.wait("the app answers", lambda s: s.get("pid") is not None, timeout=60, poll=1.5)

    def link(self, path: str, attempts: int = 1) -> None:
        # Debug links always go through the inbox, which only a running,
        # sandboxed copy reads. A link through LaunchServices starts the app
        # when no copy is running, without the sandbox (it happened once,
        # 2026-10-14): public links are sent that way only to a running copy.
        if path.startswith("debug/") or self.mode in ("exec", "denied"):
            inbox = self.sandbox / "inbox"
            inbox.mkdir(exist_ok=True)
            self.sent += 1
            name = inbox / f"{time.time_ns():020d}-{self.sent:05d}"
            name.with_suffix(".tmp").write_text(f"photosbackup://{path}")
            name.with_suffix(".tmp").rename(name.with_suffix(".url"))
            return
        if not self.running_pid():
            raise RuntimeError(f"no test copy is running; not sending photosbackup://{path} through LaunchServices")
        for attempt in range(attempts):
            try:
                run(["open", "-g", "-a", str(self.app), f"photosbackup://{path}"])
                return
            except RuntimeError:
                if attempt == attempts - 1:
                    raise
                time.sleep(1.5)

    def state(self, timeout: float = 15, settle: bool = False) -> dict[str, Any]:
        before = self.state_file.stat().st_mtime_ns if self.state_file.exists() else 0
        self.link(f"debug/state?out={self.state_file}" + ("&settle=1" if settle else ""))
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
        query = urlencode({key: json.dumps(value) for key, value in values.items()})
        self.link(f"debug/settings?{query}", attempts=5)
        time.sleep(0.8)

    def quit(self) -> None:
        if self.running_pid():
            try:
                self.link("debug/quit", attempts=3)
            except RuntimeError:
                pass
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

def s_guard(h: Harness) -> None:
    """The copy has the real bundle id; started without the sandbox it must
    quit before it reads anything. CFFIXED_USER_HOME points it at an empty
    home, so even a broken guard could not reach the real data (and with no
    settings the welcome guide would hold any backup)."""
    home = h.work / "guard-home"
    shutil.rmtree(home, ignore_errors=True)
    home.mkdir(parents=True)
    env = {key: value for key, value in os.environ.items() if not key.startswith("PHOTOS_BACKUP_")}
    env["CFFIXED_USER_HOME"] = str(home)
    started = time.time()
    try:
        result = subprocess.run([str(h.app / "Contents/MacOS/PhotosBackup")], env=env, capture_output=True, text=True, timeout=20)
        quit_on_its_own = result.returncode == 0 and "without PHOTOS_BACKUP_SANDBOX" in result.stderr
    except subprocess.TimeoutExpired:
        quit_on_its_own = False
    h.check("an unsandboxed start of the test copy quits at once", quit_on_its_own, f"{time.time() - started:.1f} s")
    h.check("and writes nothing", not any((home / "Library").rglob("state.json")) if (home / "Library").exists() else True)
    shutil.rmtree(home, ignore_errors=True)


def s_launch(h: Harness) -> None:
    h.launch("open")
    s = h.wait("albums to load", lambda s: s["albumsLoaded"], timeout=180)
    h.check("app launches sandboxed", s["sandbox"] == str(h.sandbox))
    h.check("Photos access carries over to the build", s["photosAuthorized"])
    h.check("welcome guide pending on a fresh install", s["settings"]["onboardingCompleted"] is False)
    h.check("not signed in", s["hasAuthData"] is False)
    h.check("first launch selects All Photos", s["selectedAlbumIDs"] == ["all-photos"])
    h.check("conditions are read", s["conditions"] not in ("", "Unknown"), s["conditions"])
    h.check("backs up automatically by default", s["settings"]["automatic"] is True)


def s_connect(h: Harness) -> None:
    # Still inside the welcome guide, with All Photos selected and automatic
    # backups on: signing in must not start a whole-library upload.
    h.link(f"debug/connect?auth={FAKE_AUTH.replace('&', '%26').replace('=', '%3D')}")
    s = h.wait("the account to connect", lambda s: s["hasAuthData"] and "connected" in s["account"], timeout=60)
    h.check("pasted credential verified through the bridge", "e2e.tester@example.com" in s["account"], s["account"])
    h.check("connect is logged without the token", not any("aas_et" in e["message"] for e in s["events"]))
    time.sleep(8)
    s = h.state()
    started = s["phase"] != "idle" or any(r["kind"] == "photos" for r in s["runs"])
    if started:
        h.link("stop")
    h.check("signing in during the welcome guide starts no backup", not started, f"phase={s['phase']}")
    h.settings(onboardingCompleted=True, automatic=False)
    s = h.state()
    h.check("settings change through the model", s["settings"]["onboardingCompleted"] and not s["settings"]["automatic"])


def choose_small_album(h: Harness) -> dict[str, Any]:
    h.wait("albums to load", lambda s: s["albumsLoaded"], timeout=180)
    h.link("debug/select?smallest=3-25")
    s = h.wait("an album to be selected", lambda s: len(s["selectedAlbumIDs"]) == 1 and s["selectedAlbumIDs"] != ["all-photos"], timeout=20)
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
    # Pause acts after the current batch, so this needs several batches.
    h.launch("open")
    h.wait("albums to load", lambda s: s["albumsLoaded"], timeout=180)
    h.link("debug/select?smallest=6-400")
    s = h.wait("a larger album", lambda s: len(s["selectedAlbumIDs"]) == 1 and s["selectedAlbumIDs"] != ["all-photos"], timeout=20)
    album, count = s_recheck(h)
    h.scenario({"delay": 1.5})
    h.launch("open")
    # Serial on purpose: with automatic parallelism (on by default since #50)
    # threads=1 is ignored, four uploads finish the first batch at once and the
    # export-ahead batch starts before the Pause lands (6 of 6, 2026-11-05).
    h.settings(threads=1, threadsAutomatic=False, batchSize=5)
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
    h.settings(threads=2, threadsAutomatic=True, batchSize=20)


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
    # Every link here goes through LaunchServices, which makes the app a Dock
    # app again on delivery; settle=1 reads after the app has undone that.
    h.check("menu bar only hides the Dock icon", h.state(settle=True)["activationPolicy"] == "accessory")
    h.link("open/activity")
    time.sleep(1.5)
    h.check("still menu bar only after opening the window by link", h.state(settle=True)["activationPolicy"] == "accessory")
    h.launch("open")
    s = h.state(settle=True)
    h.check("a relaunch in menu bar only mode starts without a Dock icon", s["activationPolicy"] == "accessory", s["activationPolicy"])
    h.check("and without opening the main window", "Overview" not in s["windows"] and "Activity" not in s["windows"], str(s["windows"]))
    h.settings(showInDock=True)
    time.sleep(1.5)
    h.check("Show in Dock brings it back", h.state(settle=True)["activationPolicy"] == "regular")
    h.link("settings/backup")
    time.sleep(2)
    s = h.state()
    h.check("photosbackup://settings opens the Settings window", any(w for w in s["windows"] if w not in ("", "Photos Backup")), str(s["windows"]))
    h.link("open/activity")
    time.sleep(1.5)
    h.check("photosbackup://open shows the main window", len(h.state()["windows"]) >= 1, str(h.state()["windows"]))
    h.link("debug/login?on=1")
    s = h.wait("launch at login", lambda s: s["loginItem"] in ("enabled", "requiresApproval") or s.get("loginItemError"), timeout=20, poll=1)
    h.check("Launch at login registers the app", s["loginItem"] in ("enabled", "requiresApproval"), f"{s['loginItem']} {s.get('loginItemError') or ''}")
    h.link("debug/login?on=0")
    s = h.wait("launch at login off", lambda s: s["loginItem"] == "disabled" or s.get("loginItemError"), timeout=20, poll=1)
    h.check("and unregisters it", s["loginItem"] == "disabled", f"{s['loginItem']} {s.get('loginItemError') or ''}")
    h.link("bogus-command")
    time.sleep(1)
    h.check("unknown links are ignored and logged", any("does not know" in e["message"] for e in h.state()["events"]))


def s_messages_without_access(h: Harness) -> None:
    h.launch("denied")
    h.settings(automatic=False)
    if not h.state()["hasAuthData"]:
        h.link(f"debug/connect?auth={FAKE_AUTH.replace('&', '%26').replace('=', '%3D')}")
        h.wait("the fake account to connect", lambda s: s["hasAuthData"], timeout=60)
    h.settings(messagesArchive=True, archiveFolder=str(h.archive), archiveContactNames=False, messagesMedia=True)
    h.link("archive")
    s = h.wait("the archive to report missing access", lambda s: s["archiveStatus"] in ("needsFullDiskAccess",) or s["archiveStatus"].startswith("failed"), timeout=60, poll=1)
    h.check("the archive asks for Full Disk Access when it lacks it", s["archiveStatus"] == "needsFullDiskAccess", s["archiveStatus"])
    h.link("backup/messages-media")
    s = h.wait("Messages media to report", lambda s: "Full Disk Access" in s["messagesStatus"], timeout=60, poll=1)
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

    already = len(h.ledger()["uploads"])
    h.link("backup/messages-media")
    s = h.wait("Messages media to back up", lambda s: idle(s) and last_run(s, "messagesMedia") is not None, timeout=900)
    media = [i for i in s["uploadedIDs"] if i.startswith("messages:")]
    record = last_run(s, "messagesMedia")
    h.check("Messages media run completes", record["outcome"] == "completed", f"{len(media)} items, {record['failed']} failed")
    h.check("every confirmed attachment is recorded", len(media) == record["uploaded"] + record["existing"] or len(media) >= record["uploaded"],
            f"{len(media)} recorded, {record['uploaded']} uploaded, {record['existing']} existing")
    uploads = h.ledger()["uploads"][already:]
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


def account(state: dict[str, Any], email: str) -> dict[str, Any] | None:
    return next((a for a in state.get("accounts", []) if a.get("email") == email), None)


def newest_run(state: dict[str, Any]) -> str | None:
    """The newest run's id (the dump lists at most 20, newest first)."""
    return state["runs"][0].get("id") if state.get("runs") else None


def s_accounts(h: Harness) -> None:
    """A second Google account (#49): it waits for its storage check, then
    gets the same album in its own Google account, one account after the
    other, as Original quality; Remove and signing in again lose nothing and
    create no second album. Runs after connect and photos."""
    # migrate relaunches the app just before this; reading the album list
    # before it has loaded again found no album (StopIteration, 2026-11-05).
    s = h.wait("albums to load", lambda s: s["albumsLoaded"] and s.get("selectedAlbumIDs"), timeout=180)
    album_id = s["selectedAlbumIDs"][0]
    count = next(a["count"] for a in s["albums"] if a["id"] == album_id)
    first = account(s, FIRST_ACCOUNT)
    h.check("the first account holds the photos run", first is not None and first["uploadedCount"] >= count)
    first_album = first["mirrors"][album_id]["googleAlbumID"]
    # From here each account is a Google account of its own in the fake.
    h.scenario({"per_account": True})

    h.link(f"debug/connect?auth={quoted(FAKE_AUTH_2)}")
    s = h.wait("the second account", lambda s: account(s, SECOND_ACCOUNT) is not None, timeout=60)
    second = account(s, SECOND_ACCOUNT)
    h.check("a second account is added next to the first", [a["email"] for a in s["accounts"]] == [FIRST_ACCOUNT, SECOND_ACCOUNT])
    h.check("each account has its own keychain item", sandbox_keychain_has(FIRST_ACCOUNT) and sandbox_keychain_has(SECOND_ACCOUNT))
    h.check("the added account waits for its storage check", second["storageChecked"] is False and second["uploadedCount"] == 0)

    newest = newest_run(s)
    h.link("backup/photos")
    s = h.wait("a run that skips the unchecked account", lambda s: idle(s) and not s["passRunning"] and newest_run(s) != newest, timeout=300)
    h.check("no upload goes to an account before its storage check", account(s, SECOND_ACCOUNT)["uploadedCount"] == 0)

    h.link(f"debug/confirm-storage?account={SECOND_ACCOUNT}")
    s = h.wait("the second account's first backup",
               lambda s: idle(s) and not s["passRunning"] and account(s, SECOND_ACCOUNT)["summary"]["pending"] == 0, timeout=900)
    second = account(s, SECOND_ACCOUNT)
    first = account(s, FIRST_ACCOUNT)
    ledger = h.ledger()
    sent = [u for u in ledger["uploads"] if u.get("account") == SECOND_ACCOUNT and u["status"] == "uploaded"]
    h.check("the second account receives every item", second["summary"]["backedUp"] == count and len(sent) == count,
            f"{len(sent)} uploads for {count} items")
    h.check("the second account gets an album of its own", bool(second["mirrors"].get(album_id, {}).get("googleAlbumID"))
            and second["mirrors"][album_id]["googleAlbumID"] != first_album)
    h.check("the first account's album link is untouched", first["mirrors"][album_id]["googleAlbumID"] == first_album)
    h.check("every upload is Original quality on the Pixel XL path",
            all(u.get("saver") is False and u.get("use_quota") is False for u in ledger["uploads"] if "saver" in u))
    h.check("the run is recorded with its account", any(r.get("account") == SECOND_ACCOUNT for r in s["runs"]))
    h.check("the primary account is active again", s["activeAccount"] == FIRST_ACCOUNT)

    h.link(f"debug/remove?account={SECOND_ACCOUNT}")
    s = h.wait("the second account to be removed", lambda s: account(s, SECOND_ACCOUNT) is None, timeout=30)
    h.check("Remove leaves the first account alone", account(s, FIRST_ACCOUNT)["uploadedCount"] == first["uploadedCount"]
            and sandbox_keychain_has(FIRST_ACCOUNT) and not sandbox_keychain_has(SECOND_ACCOUNT))

    h.link(f"debug/connect?auth={quoted(FAKE_AUTH_2)}")
    s = h.wait("the second account again", lambda s: account(s, SECOND_ACCOUNT) is not None, timeout=60)
    again = account(s, SECOND_ACCOUNT)
    h.check("signing in again restores its record", again["uploadedCount"] == second["uploadedCount"] and again["storageChecked"])
    albums_before = len(h.ledger().get("accounts", {}).get(SECOND_ACCOUNT, {}).get("albums", {}))
    uploads_before = len(h.ledger()["uploads"])
    newest = newest_run(s)
    h.link("backup/photos")
    h.wait("another pass", lambda s: idle(s) and not s["passRunning"] and newest_run(s) != newest, timeout=300)
    after = h.ledger()
    h.check("no album is created twice", len(after.get("accounts", {}).get(SECOND_ACCOUNT, {}).get("albums", {})) == albums_before)
    h.check("nothing is uploaded twice", len([u for u in after["uploads"][uploads_before:] if u["status"] == "uploaded"]) == 0)
    h.scenario({})


def s_choice(h: Harness) -> None:
    """Back up to (#49, the owner's choice), with the real Photos library:
    with the primary left out, backup/photos goes to the chosen account
    only; ?account= sends a one-off to the account left out without
    changing the choice; an unknown address is logged and ignored. Runs
    after accounts (two accounts, both past their storage check)."""
    h.scenario({"per_account": True})
    s = h.state()
    h.check("two accounts to choose from", [a["email"] for a in s["accounts"]] == [FIRST_ACCOUNT, SECOND_ACCOUNT])
    h.check("backups go to all accounts by default", s.get("backUpTo") == "all")
    # Re-check both, so each has the whole album to back up again (the
    # fake answers "already there" for what its account holds).
    h.link(f"debug/recheck?account={FIRST_ACCOUNT}")
    h.link(f"debug/recheck?account={SECOND_ACCOUNT}")
    h.link(f"debug/include?account={FIRST_ACCOUNT}&on=0")
    s = h.wait("the primary left out", lambda s: s.get("backUpTo") == "chosen" and account(s, FIRST_ACCOUNT)["uploadedCount"] == 0
               and account(s, SECOND_ACCOUNT)["uploadedCount"] == 0, timeout=30)
    h.check("only the second account is included",
            account(s, FIRST_ACCOUNT)["included"] is False and account(s, SECOND_ACCOUNT)["included"] is True)

    newest = newest_run(s)
    h.link("backup/photos")
    s = h.wait("a backup to the chosen account", lambda s: idle(s) and not s["passRunning"] and newest_run(s) != newest
               and account(s, SECOND_ACCOUNT)["summary"]["pending"] == 0, timeout=600)
    h.check("the chosen account gets the album", account(s, SECOND_ACCOUNT)["summary"]["pending"] == 0)
    h.check("the account left out gets nothing", account(s, FIRST_ACCOUNT)["uploadedCount"] == 0)
    h.check("the run is the chosen account's", s["runs"][0].get("account") == SECOND_ACCOUNT)

    newest = newest_run(s)
    h.link(f"backup/photos?account={FIRST_ACCOUNT}")
    s = h.wait("a one-off to the account left out", lambda s: idle(s) and not s["passRunning"] and newest_run(s) != newest
               and account(s, FIRST_ACCOUNT)["summary"]["pending"] == 0, timeout=600)
    h.check("a link naming an account backs up to it", account(s, FIRST_ACCOUNT)["summary"]["pending"] == 0)
    h.check("and to no other", s["runs"][0].get("account") == FIRST_ACCOUNT
            and (len(s["runs"]) < 2 or s["runs"][1].get("account") == SECOND_ACCOUNT))
    h.check("the choice is unchanged", s["backUpTo"] == "chosen" and account(s, FIRST_ACCOUNT)["included"] is False)
    h.check("every upload is Original quality on the Pixel XL path",
            all(u.get("saver") is False and u.get("use_quota") is False for u in h.ledger()["uploads"] if "saver" in u))

    newest = newest_run(s)
    h.link("backup?account=nobody%40example.com")
    s = h.wait("the unknown account to be logged",
               lambda s: any("which is not an account signed in here" in e["message"] for e in s["events"]), timeout=30)
    time.sleep(2)
    s = h.state()
    h.check("an unknown account is ignored, never guessed", newest_run(s) == newest and not s["passRunning"])

    h.link("debug/back-up-to?choice=all")
    s = h.wait("all accounts again", lambda s: s.get("backUpTo") == "all", timeout=30)
    h.check("All accounts includes both", all(a["included"] for a in s["accounts"]))
    h.scenario({})


def s_migrate(h: Harness) -> None:
    """The upgrade from one account: state.json as the last single-account
    version left it and the "gpmc" keychain item. Runs after photos."""
    support = h.sandbox / "Support"
    state_path = support / "state.json"
    pre_accounts = support / "state.json.pre-accounts"
    h.quit()
    # The copy beside accounts.json too: left in place, the next launch
    # restores the list from it instead of migrating. And the one-time copy
    # of state.json, which is written only when none exists.
    for leftover in [support / "accounts.json", support / "accounts.json.bak", pre_accounts, *support.glob("state-*.json")]:
        leftover.unlink(missing_ok=True)
    before = state_path.read_bytes()
    clear_sandbox_keychain()
    # -A: the test copy reads it without a keychain prompt, as the app's own
    # item would be readable by the app that wrote it.
    run(["security", "add-generic-password", "-A", "-s", SANDBOX_KEYCHAIN, "-a", "gpmc", "-w", FAKE_AUTH])
    h.launch("open")
    s = h.wait("the account to load", lambda s: s.get("accounts"), timeout=60)
    first = account(s, FIRST_ACCOUNT)
    h.check("state.json becomes the first account's record", first is not None and first["stateFile"] == "state.json")
    h.check("the gpmc item moves to its account", sandbox_keychain_has(FIRST_ACCOUNT) and not sandbox_keychain_has("gpmc"))
    h.check("state.json is byte for byte what it was", state_path.read_bytes() == before)
    h.check("the album links survive", all(m.get("googleAlbumID") for m in first["mirrors"].values()) and bool(first["mirrors"]))
    h.check("accounts.json is written", (support / "accounts.json").exists())
    h.check("state.json.pre-accounts is the state.json from before the upgrade",
            pre_accounts.exists() and pre_accounts.read_bytes() == before)


SCENARIOS: dict[str, Callable[[Harness], None]] = {
    "guard": s_guard, "launch": s_launch, "connect": s_connect, "photos": s_photos, "retry": s_retry, "rate-limit": s_rate_limit,
    "controls": s_controls, "conditions": s_conditions, "shell": s_shell,
    "messages-no-access": s_messages_without_access, "messages": s_messages, "diagnostics": s_diagnostics,
    "migrate": s_migrate, "accounts": s_accounts, "choice": s_choice,
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
        if harness.running_pid():
            harness.link("debug/login?on=0")
            time.sleep(1)
        harness.quit()
        if not args.keep:
            # The sandbox holds conversation titles and handles (the archive
            # overview) and the copy has the real bundle id: neither stays.
            for path in (harness.archive, harness.sandbox, harness.runtime):
                shutil.rmtree(path, ignore_errors=True)
            # 2026-10-15: The state snapshot also contains library names and
            # archive summaries; keep only the deliberately redacted report.
            harness.state_file.unlink(missing_ok=True)
            (harness.work / "exec.log").unlink(missing_ok=True)
            subprocess.run([LSREGISTER, "-u", str(harness.app)], capture_output=True)
            shutil.rmtree(harness.app, ignore_errors=True)
            subprocess.run(["defaults", "delete", BUNDLE_ID + ".sandbox"], capture_output=True)
            clear_sandbox_keychain()
    return harness.report()


if __name__ == "__main__":
    sys.exit(main())
