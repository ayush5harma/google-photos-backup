#!/usr/bin/env python3
"""Verify packaged iCloud signed-out guidance without accounts or network access."""
import json
import subprocess
import sys
import tempfile


def main():
    python, script = sys.argv[1:3]
    with tempfile.TemporaryDirectory(prefix="icloud-package-check-") as temporary:
        request = {"command": "status", "account": "fixture@example.invalid", "state_dir": temporary}
        result = subprocess.run([python, "-I", "-B", script], input=json.dumps(request) + "\n",
                                capture_output=True, text=True, timeout=30)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        assert any(event.get("type") == "auth" and event.get("status") == "signed_out" for event in events), \
            "Packaged iCloud provider did not guide a fresh user to sign in"
        request["command"] = "reclaim-status"
        result = subprocess.run([python, "-I", "-B", script], input=json.dumps(request) + "\n",
                                capture_output=True, text=True, timeout=30)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        assert any(event.get("type") == "reclaim" and event.get("enabled") is False for event in events), \
            "Unverified iCloud deletion must stay disabled"
    print("Packaged iCloud provider: signed-out guidance and reclaim guard passed")


if __name__ == "__main__":
    main()
