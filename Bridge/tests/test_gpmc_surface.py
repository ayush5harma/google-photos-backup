"""The bridge's view of gpmc against the fakes and the real package.

Measured 2026-10-26: the bridge appended to an existing album with
Client.add_to_existing_album, which exists only on gpmc's main branch, not in
the 0.9.0 release the app pins and bundles. Both test fakes had the method, so
every test passed while the shipped app added only an album's first batch.
GPMC_SURFACE is the declaration these tests hold the code and the fakes to;
scripts/build-app.sh checks it against the gpmc it bundles.
"""

import importlib
import os
import re
import sys
import unittest
from pathlib import Path

BRIDGE = Path(__file__).resolve().parents[1]
ROOT = BRIDGE.parent
sys.path.insert(0, str(BRIDGE))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import gpmc_bridge  # noqa: E402
import test_bridge  # noqa: E402


def _called_names():
    source = (BRIDGE / "gpmc_bridge.py").read_text()
    names = {"Client": set(), "Api": set()}
    for api, name in re.findall(r"\bclient\.(api\.)?([A-Za-z_]\w*)", source):
        if api:
            names["Api"].add(name)
        elif name != "api":
            names["Client"].add(name)
    return names


class GpmcSurfaceTests(unittest.TestCase):
    def test_every_gpmc_call_in_the_bridge_is_declared(self):
        for owner, names in _called_names().items():
            self.assertLessEqual(names, set(gpmc_bridge.GPMC_SURFACE[owner]), owner)

    def test_unit_fake_provides_the_declared_surface(self):
        client = test_bridge.FakeClient()
        for name in gpmc_bridge.GPMC_SURFACE["Client"]:
            self.assertTrue(hasattr(client, name), f"FakeClient.{name}")
        for name in gpmc_bridge.GPMC_SURFACE["Api"]:
            if name not in ("get_download_urls", "_new_session"):  # verify-original tests stub these per case
                self.assertTrue(hasattr(type(client.api), name), f"FakeApi.{name}")

    def test_end_to_end_fake_provides_the_declared_surface(self):
        sys.path.insert(0, str(ROOT / "Tests" / "E2E" / "fake_gpmc"))
        try:
            fake = importlib.import_module("gpmc")
            missing = gpmc_bridge.missing_gpmc_surface(fake.Client, fake.Api)
        finally:
            sys.path.pop(0)
            sys.modules.pop("gpmc", None)
        # The end-to-end fake never runs verify-original.
        self.assertEqual([m for m in missing if m not in ("Api.get_download_urls", "Api._new_session")], [])

    @unittest.skipUnless(os.environ.get("GPMC_SITE_PACKAGES"), "set GPMC_SITE_PACKAGES to a real gpmc install")
    def test_real_gpmc_has_the_declared_surface(self):
        sys.path.insert(0, os.environ["GPMC_SITE_PACKAGES"])
        try:
            from gpmc import Client
            from gpmc.api import Api
        finally:
            sys.path.pop(0)
        self.assertEqual(gpmc_bridge.missing_gpmc_surface(Client, Api), [])


if __name__ == "__main__":
    unittest.main()
