# Screenshots

The images in `docs/` are rendered by the app's fixture mode from made-up data:
a pretend library of about 48,000 items, an example account, and five invented
conversations. They never come from a real library, account or Messages
database. The renderer runs the plain debug build with `PHOTOS_BACKUP_SANDBOX`
in a temporary folder, so it has its own settings, state and Keychain item,
reads nothing private and never starts a backup.

From the repository root:

```sh
SNAPSHOT_FIXTURE=1 scripts/snapshots.sh /tmp/photos-backup-screenshots
SNAPSHOT_FIXTURE=1 scripts/snapshots.sh /tmp/photos-backup-screenshots menubar,onboarding
```

The optional second argument limits the groups: `sections`, `settings`,
`onboarding`, `menubar` and `links`. Every Overview state, section, Settings tab,
welcome page and menu bar panel state is written in light and dark.

## Choosing images

Look at every image before using it. Skip any with rendering artefacts: a window
rendered while inactive shows greyed toggles, buttons and progress bars, and the
published set leaves those out. Do not publish sign-in screens, real account
addresses, real logs, attachment names or desktop captures, and never grant the
fixture Photos, Messages or Contacts access.

Downscale each image to at most 1400 px wide and keep it as PNG:

```sh
sips --resampleWidth 1400 docs/<name>.png
```

Images narrower than that, such as the menu bar panel, are used as rendered.

## Published set

| File | Shows |
| --- | --- |
| `menu-bar-panel-light.png` | The panel when everything is backed up |
| `menu-bar-panel-dark.png` | The same, in dark mode |
| `menu-bar-panel-backing-up-dark.png` | The panel during a run |
| `welcome-guide-light.png` | The first page of the welcome guide |

## Windows preview

`windows-overview.png` and `windows-overview-dark.png` are rendered by the native WinUI app on the Windows CI runner with `--smoke-test <report.json> --screenshot <image.png>`. It uses synthetic folders and an example account, never signs in or uploads, and substitutes an opaque theme background for Mica during capture. The normal app retains Mica. The image was inspected from successful run [38805480000](https://github.com/ayush5harma/google-photos-backup/actions/runs/38805480000).

`windows-navigation-collapsed.png` captures the same fixture after collapsing the pane. The smoke test checks that rendered icons remain visible, labels are hidden, and reopening restores them.

The finalized F aperture-and-infinity icon uses translucent mint and violet blades with matching light and dark assets. macOS screenshots were regenerated from fixtures on 2026-10-16. See [icon source and appearance behavior](ICON.md).

The `icloud-setup-light.png` and `icloud-setup-dark.png` images show the signed-out iCloud form with synthetic state. Generate them through the fixture `sections` group; the form-only render forces active control styling without activating the application.

## v0.5.0 refresh — 2026-10-17

The README and GitHub Pages site share the current macOS menu-bar and Windows
connected-device images. macOS menu-bar and welcome images were rendered from
`3d1b3c6` (v0.5.0 main) with the `menubar,onboarding` fixture groups above.

The Windows light and dark connected-device images are `ui-smoke.png` and
`ui-smoke-dark.png` from `verification/installed` in the
`Windows-x64-verification` artifact of successful
[run 38890780067](https://github.com/ayush5harma/google-photos-backup/actions/runs/38890780067),
also built from `3d1b3c6`. Despite their generic output names, these captures
show Connected devices, not Overview. The website no longer uses the older
Parallels overview capture.

The Android image is retained from the v0.5.0 device validation in `0f7fd37`;
it already shows the current release's full-width backup action.
