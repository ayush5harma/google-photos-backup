"""gpmc 0.9.0's schema-less decode against a media key that parses as protobuf.

Measured 2026-10-26: about one random "AF1Qip..." key in 14,000 has bytes that
blackboxprotobuf reads as a nested message, so gpmc 0.9.0 returned a dict for
it. The item's line then failed to decode in the app ("The uploader stopped
unexpectedly (exit 0)") and the dict broke the album add for its batch. These
tests drive the real gpmc 0.9.0 methods with a Google-shaped reply carrying
such a key; they run when GPMC_SITE_PACKAGES points at a real gpmc install.
"""

import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import gpmc_bridge  # noqa: E402

# Found by search: its bytes decode as a message without a schema.
ODD_KEY = "AF1Qip34rQJYPppV1ZmOVvg5r3ULYJU8-hWPpeny98xi"
SITE = os.environ.get("GPMC_SITE_PACKAGES")


@unittest.skipUnless(SITE, "set GPMC_SITE_PACKAGES to a real gpmc install")
class MediaKeyTypeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, SITE)
        import blackboxprotobuf
        import gpmc.api

        cls.bbp = blackboxprotobuf
        cls.api_module = gpmc.api

    def reply(self, shape):
        typedef = gpmc_bridge.KEY_RESPONSE_TYPES[shape]
        bodies = {
            "find_remote_media_by_hash": {"1": {"2": {"2": {"1": ODD_KEY}}}},
            "commit_upload": {"1": {"3": {"1": ODD_KEY}}},
            "create_album": {"1": {"1": ODD_KEY}},
        }
        return bytes(self.bbp.encode_message(bodies[shape], typedef))

    def api(self, content):
        class Response:
            def raise_for_status(self):
                pass

        Response.content = content

        class Session:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def post(self, *args, **kwargs):
                return Response()

        class OfflineApi(self.api_module.Api):
            bearer_token = "token"

            def _new_session(self):
                return Session()

        api = OfflineApi.__new__(OfflineApi)
        api.language, api.user_agent, api.timeout = "en_US", "ua", 5
        api.make, api.model, api.android_api_version = "Google", "Pixel XL", 28
        return api

    def call(self, shape, api):
        if shape == "find_remote_media_by_hash":
            return api.find_remote_media_by_hash(b"\x00" * 20)
        if shape == "commit_upload":
            return api.commit_upload({"1": 1}, "a.jpg", b"\x00" * 20)
        return api.create_album("Trip", ["key"])

    def test_the_schema_less_decode_returns_a_dict_for_this_key(self):
        decoded, _ = self.bbp.decode_message(self.reply("commit_upload"))
        self.assertIsInstance(decoded["1"]["3"]["1"], dict)

    def test_pinned_calls_return_the_key_as_a_string(self):
        gpmc_bridge.pin_media_key_types(self.api_module)
        for shape in gpmc_bridge.KEY_RESPONSE_TYPES:
            with self.subTest(shape):
                self.assertEqual(self.call(shape, self.api(self.reply(shape))), ODD_KEY)

    def test_pinning_twice_wraps_once(self):
        gpmc_bridge.pin_media_key_types(self.api_module)
        gpmc_bridge.pin_media_key_types(self.api_module)
        wrapped = self.api_module.Api.commit_upload
        self.assertFalse(hasattr(getattr(wrapped, "__wrapped__", None), "__wrapped__"))


if __name__ == "__main__":
    unittest.main()
