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

`windows-overview.png` and `windows-overview-dark.png` are rendered by the native WinUI app on the Windows CI runner with `--smoke-test <report.json> --screenshot <image.png>`. It uses synthetic folders and an example account, never signs in or uploads, and substitutes an opaque theme background for Mica during capture. The normal app retains Mica. The image was inspected from successful run [38631859751](https://github.com/ayush5harma/google-photos-backup/actions/runs/38631859751).

The Photos-inspired glass icon has matching light and dark assets. See [icon source and appearance behavior](ICON.md).
