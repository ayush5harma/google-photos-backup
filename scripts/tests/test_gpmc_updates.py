import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "watch-gpmc-updates.py"
spec = importlib.util.spec_from_file_location("gpmc_monitor", SCRIPT)
monitor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def test_numeric_order_and_post_releases(self):
        self.assertGreater(monitor.stable_version("0.10.0"), monitor.stable_version("0.9.0"))
        self.assertGreater(monitor.stable_version("0.10.0.post0"), monitor.stable_version("0.10.0"))
        self.assertEqual(monitor.canonical_version("v0.10.0"), "0.10.0")
        self.assertEqual(monitor.canonical_version("0.10.0.post0"), "0.10.0.post0")
        for tag in ["0.10.0rc1", "v0.10.0-beta", "0.10.0.dev1", "main", "$(echo danger)"]:
            self.assertIsNone(monitor.stable_version(tag))

    def test_metadata_union_skips_yanked_empty_draft_and_prerelease(self):
        versions = monitor.discover_versions(
            {"releases": {"0.10.0": [{"yanked": False}], "0.11.0": [{"yanked": True}], "0.12.0": [], "1.0.0rc1": [{}]}},
            [{"tag_name": "v0.10.0"}, {"tag_name": "v0.11.0"}, {"tag_name": "1.0.0", "draft": True}, {"tag_name": "1.1.0", "prerelease": True}],
        )
        self.assertEqual(versions, {"0.10.0": {"PyPI", "GitHub"}, "0.11.0": {"GitHub"}})

    def test_closed_issue_acknowledges_version_but_pr_does_not(self):
        issues = [
            {"state": "closed", "body": "<!-- gpmc-upstream-version:0.10.0 -->"},
            {"body": "<!-- gpmc-upstream-version:0.11.0 -->", "pull_request": {}},
            {"body": None},
        ]
        self.assertEqual(monitor.pending_versions({"0.10.0": set(), "0.11.0": set()}, {"pin": "0.9.0"}, issues), ["0.11.0"])

    def test_oldest_platform_pin_keeps_android_updates_visible(self):
        pins = {"Bridge": "0.10.0", "Android": "0.9.0"}
        self.assertEqual(monitor.pending_versions({"0.9.0": set(), "0.10.0": set()}, pins, []), ["0.10.0"])
        self.assertEqual(monitor.pending_versions({"0.10.0": set()}, {"Bridge": "0.10.0", "Android": "0.10.0"}, []), [])

    def test_read_real_platform_pins_and_fail_on_missing_guard(self):
        pins = monitor.read_pins(SCRIPT.parents[1])
        self.assertEqual(len(pins), 4)
        self.assertIn("Android/app/src/main/python/android_bridge.py", pins)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in monitor.PIN_PATTERNS:
                dest = root / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_text((SCRIPT.parents[1] / relative).read_text())
            (root / "Android/app/src/main/python/android_bridge.py").write_text("# Guard changed; monitor must be reviewed")
            with self.assertRaisesRegex(ValueError, "exactly one"):
                monitor.read_pins(root)

    def test_pagination_dedup_includes_later_pages_and_closed(self):
        client = monitor.MetadataClient("synthetic")
        pages = [[{"body": None}] * 100, [{"body": "<!-- gpmc-upstream-version:0.10.0 -->", "state": "closed"}]]
        with patch.object(client, "request", side_effect=pages) as request:
            issues = client.pages("/repos/owner/repo/issues?state=all")
        self.assertEqual(len(issues), 101)
        self.assertIn("state=all&per_page=100&page=2", request.call_args.args[0])
        self.assertEqual(monitor.pending_versions({"0.10.0": set()}, {"pin": "0.9.0"}, issues), [])

    def test_tokens_never_go_to_pypi_and_redirects_are_refused(self):
        class Opener:
            def __init__(self): self.requests = []
            def open(self, request, timeout):
                self.requests.append(request)
                return io.BytesIO(b'{}')
        client = monitor.MetadataClient("synthetic-test-token")
        client.opener = Opener()
        client.request("https://pypi.org/pypi/gpmc/json")
        client.request("https://api.github.com/repos/xob0t/gpmc/releases")
        self.assertFalse(client.opener.requests[0].has_header("Authorization"))
        self.assertEqual(client.opener.requests[1].get_header("Authorization"), "Bearer synthetic-test-token")
        self.assertIsNone(monitor.NoRedirect().redirect_request(None, None, 302, "", {}, "https://evil.example"))
        for bad in ["https://api.github.com.evil.example/", "http://api.github.com/repos/a/b", "https://pypi.org@evil.example/"]:
            with self.assertRaises(ValueError): client.request(bad)
        with self.assertRaises(ValueError): client.request("https://pypi.org/pypi/gpmc/json", {"body": "no"})

    def test_dry_run_fetches_metadata_without_writing(self):
        def request(url, payload=None):
            self.assertIsNone(payload)
            self.assertEqual(url, "https://pypi.org/pypi/gpmc/json")
            return {"releases": {"0.10.0": [{"yanked": False}]}}
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "DRY_RUN": "false"}), patch.object(monitor, "read_pins", return_value={"pin": "0.9.0"}), patch.object(monitor.MetadataClient, "request", side_effect=request), patch.object(monitor.MetadataClient, "pages", return_value=[]), patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(monitor.main(["--dry-run"]), 0)
        self.assertIn("Would open issue: gpmc 0.10.0", output.getvalue())

    def test_issue_creation_is_deduplicated_and_only_uses_fixed_fields(self):
        calls = []
        def request(url, payload=None):
            calls.append((url, payload))
            if payload is None: return {"releases": {"0.10.0": [{}], "0.11.0": [{}]}}
            return {"number": 42}
        def pages(path):
            if "issues" in path: return [{"body": "<!-- gpmc-upstream-version:0.10.0 -->"}]
            return []
        with patch.dict(os.environ, {"GITHUB_TOKEN": "synthetic", "GITHUB_REPOSITORY": "owner/repo", "DRY_RUN": "false"}), patch.object(monitor, "read_pins", return_value={"pin": "0.9.0"}), patch.object(monitor.MetadataClient, "request", side_effect=request), patch.object(monitor.MetadataClient, "pages", side_effect=pages), patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(monitor.main([]), 0)
        writes = [(url, payload) for url, payload in calls if payload is not None]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][0], "https://api.github.com/repos/owner/repo/issues")
        self.assertEqual(writes[0][1]["title"], "Review upstream gpmc 0.11.0")
        self.assertIn("<!-- gpmc-upstream-version:0.11.0 -->", writes[0][1]["body"])
        self.assertNotIn("synthetic", writes[0][1]["body"])


if __name__ == "__main__":
    unittest.main()
