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
        assert any(event.get("type") == "reclaim" and event.get("requires_preview") is True
                   and event.get("immediate_space_recovery") is False for event in events), \
            "iCloud reclaim must require preview and disclose delayed storage recovery"
        request.update(command="reclaim", auth_data="Email=fixture@example.invalid")
        result = subprocess.run([python, "-I", "-B", script], input=json.dumps(request) + "\n",
                                capture_output=True, text=True, timeout=30)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        assert result.returncode == 4 and any(e.get("type") == "fatal" and e.get("kind") == "request" for e in events), \
            "Reclaim without explicit confirmation must fail before network access"
    crypto_code = """
import os, sys, tempfile
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]).parent))
import icloud_bridge as bridge
if os.name == 'nt':
    with tempfile.TemporaryDirectory(prefix='icloud-vault-smoke-') as root:
        state = bridge.private_dir(root)
        account = 'fixture@example.invalid'
        with bridge.state_lock(state):
            with bridge.session_directory(state, account) as cookies:
                (cookies / 'fixture.session').write_bytes(b'synthetic-session')
            assert bridge.has_saved_session(state, account)
            assert not list(state.glob('session-tmp-*'))
            with bridge.session_directory(state, account) as cookies:
                assert (cookies / 'fixture.session').read_bytes() == b'synthetic-session'
            assert not list(state.glob('session-tmp-*'))
"""
    crypto = subprocess.run([python, "-I", "-B", "-c", crypto_code, script],
                            capture_output=True, text=True, timeout=30)
    assert crypto.returncode == 0, "Packaged iCloud credential protection failed"
    print("Packaged iCloud provider: signed-out guidance and reclaim guard passed")


if __name__ == "__main__":
    main()
