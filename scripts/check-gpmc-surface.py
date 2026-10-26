"""Fail a build whose bundled gpmc lacks a call the bridge makes.

    check-gpmc-surface.py <site-packages> <bridge-dir>

Measured 2026-10-26: Photos Backup 0.2.0 to 0.5.1 appended to existing albums with
Client.add_to_existing_album, which exists only on gpmc's main branch; the
pinned 0.9.0 release lacks it, the test fakes had it, and the shipped app added
only each album's first batch. GPMC_SURFACE in the bridge lists every call.
"""

import sys

site_packages, bridge = sys.argv[1], sys.argv[2]
sys.path[:0] = [site_packages, bridge]

import gpmc_bridge  # noqa: E402
from gpmc import Client  # noqa: E402
from gpmc.api import Api  # noqa: E402

missing = gpmc_bridge.missing_gpmc_surface(Client, Api)
if missing:
    sys.exit("the bundled gpmc lacks " + ", ".join(missing))

# The media-key schemas the bridge pins onto gpmc 0.9.0 must still apply, and
# another gpmc must not ship until someone has decided whether it still needs
# them: the bridge applies them to 0.9.0 only, so a quiet bump would drop them.
version = gpmc_bridge._gpmc_version()
if version != "0.9.0":
    sys.exit(f"the bundled gpmc is {version}: review pin_media_key_types in the bridge (written for 0.9.0) and this check")
import gpmc.api  # noqa: E402

try:
    gpmc_bridge.pin_media_key_types(gpmc.api)
except AttributeError as error:
    sys.exit(f"the bundled gpmc cannot take the media-key schemas: {error}")
