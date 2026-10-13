# Screenshots

The README images are rendered by the app's debug snapshot mode using a separate
bundle identifier ending in `.snapshots`. It has separate settings, state, and
Keychain access. Snapshot mode never starts a backup. Do not grant this fixture
Photos or Messages access, and do not provide real account credentials.

From the repository root:

```sh
scripts/build-app.sh --identity -
SNAPSHOT_UI_ONLY=1 scripts/snapshots.sh /tmp/photos-backup-screenshots
```

Inspect every image before copying `home.png`, `settings.png`, and `activity.png`
into `docs/`. Publish only the disconnected, empty-library UI. Do not publish
sign-in screenshots, account addresses, real logs, attachment names, or desktop
captures. UI-only mode skips the sign-in flow and ignores any snapshot auth input.
Without this flag the script also exercises sign-in with a fake cookie; those
outputs are not README assets.
