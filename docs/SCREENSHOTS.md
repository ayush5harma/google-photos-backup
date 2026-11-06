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
`accounts`, `onboarding`, `menubar` and `links`. Every Overview state, section,
Settings tab, welcome page and menu bar panel state is written in light and dark.
The `accounts` group adds four made-up accounts at example.com: idle, at a
storage check, left out of backups, and three of them backing up at once.

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

| File | Shows | Fixture render |
| --- | --- | --- |
| `menu-bar-panel-light.png` | The panel when everything is backed up | `menubar-up-to-date-light` |
| `menu-bar-panel-dark.png` | The same, in dark mode | `menubar-up-to-date-dark` |
| `menu-bar-panel-backing-up-dark.png` | The panel during a run to three accounts at once | `menubar-accounts-running-dark` |
| `accounts-menubar-light.png` | The panel with several accounts, ready to back up, and its accounts button | `menubar-accounts-light` |
| `accounts-overview-light.png` | The Overview during a run to three accounts at once, each with its own count, and a fourth left out | `overview-accounts-running-light` |
| `accounts-overview-dark.png` | The same, in dark mode | `overview-accounts-running-dark` |
| `accounts-activity-light.png` | Activity during that run: each account's progress and uploads at a time | `activity-accounts-running-light` |
| `accounts-activity-dark.png` | The same, in dark mode | `activity-accounts-running-dark` |
| `accounts-settings-light.png` | Settings > Account, backing up only the chosen accounts | `settings-accounts-light` |
| `accounts-settings-dark.png` | The same, in dark mode | `settings-accounts-dark` |
| `accounts-storage-check-light.png` | An added account's storage check with Start Backing Up | `settings-accounts-storage-light` |
| `backup-settings-light.png` | Settings > Backup with parallel uploads chosen automatically, up to 32 | `settings-backup-light` |
| `backup-settings-dark.png` | The same, in dark mode | `settings-backup-dark` |
| `backup-settings-fixed-light.png` | Settings > Backup with 16 uploads at once chosen | `settings-backup-fixed-light` |
| `welcome-guide-light.png` | The first page of the welcome guide | `onboarding-1-welcome-light` |
| `icloud-setup-light.png` | The signed-out iCloud Photos form | `icloud-setup-light` |
| `icloud-setup-dark.png` | The same, in dark mode | `icloud-setup-dark` |
| `macos-connected-device-light.png` | Connected device with a made-up iPhone and two files | `section-devices-light` |
| `macos-connected-device-dark.png` | The same, in dark mode | `section-devices-dark` |

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

## v0.6.4 refresh — 2026-11-07

Every macOS image in the published set above was re-rendered from the fixture
at `9c0511b` (v0.6.4 main) plus the fixture commit `ad47aa2`, with all six
groups, and looked at before it was kept. The 2026-11-05 accounts images and the
2026-10-17 menu bar and welcome images showed greyed switches, bars and
prominent buttons from an inactive window; the accounts renders now draw in a
key window like the others. The connected-device images of 2026-10-16 were blank below the toolbar;
the iCloud setup images still had the retired "Copies only" card. The made-up
accounts moved from gmail.com to example.com. Images wider than 1400 px were
downscaled with `sips --resampleWidth 1400`.
