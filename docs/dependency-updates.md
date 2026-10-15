# gpmc dependency updates

`gpmc` is the shared, unofficial Google Photos client used by the desktop uploader and the Android app. It is pinned independently where each platform packages or validates it:

| Location | Purpose |
| --- | --- |
| `Bridge/requirements.txt` | Desktop uploader dependency |
| `Android/app/build.gradle.kts` | Android's embedded Python dependency |
| `Android/app/src/main/python/android_bridge.py` | Android compatibility guard |
| `scripts/verify-windows.ps1` | Windows package verification expectation |

Dependabot checks `Bridge/requirements.txt` daily and opens at most one `gpmc` pull request. It does not update the Android pin or compatibility checks automatically.

The `Monitor gpmc updates` workflow also runs daily. It reads only release metadata from PyPI and the upstream GitHub releases API. When a stable version is newer than the oldest platform pin, it creates one review issue marked with that version. Existing open or closed review issues suppress duplicates. The workflow has read-only repository access except for its issue-creation job; it never installs, imports, or executes a newly released package.

Use **Run workflow** with `dry_run` enabled to inspect what would be reported. When reviewing an update, keep every affected pin and compatibility check in sync, run the platform checks named in the issue, and validate sign-in and upload behaviour when the upstream change could affect it. Closing the review issue intentionally acknowledges that version, including when its update is deferred.
