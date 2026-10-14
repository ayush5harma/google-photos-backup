# Photos Backup technical reference

[Back to the quick start](../README.md)

A native macOS app that backs up selected Apple Photos albums to Google Photos,
optionally uploads the photos and videos from Messages, and optionally keeps a
readable archive of your Messages on this Mac. A menu bar panel keeps backups
visible and running after the window is closed.

The uploading is done by [gpmc](https://github.com/xob0t/gpmc) (xob0t, MIT),
a client for Google Photos' reverse-engineered mobile API. The default upload
mode uses a Pixel XL profile; Google determines storage accounting, which may
change. The app also offers Storage saver and quota-counted original quality.

<p align="center">
  <img src="menu-bar-panel-light.png" width="32%" alt="The menu bar panel: everything backed up, Photos and Messages archive status, Back Up Now">
  <img src="menu-bar-panel-backing-up-dark.png" width="32%" alt="The menu bar panel in dark mode while a backup runs">
  <img src="welcome-guide-light.png" width="32%" alt="The first page of the welcome guide">
</p>

## Read this first

- **The API is unofficial.** gpmc talks to an API Google never published. Google
  can change it or its Pixel XL storage behavior at any time. Uploads may fail
  or count against your storage. Photos on the Mac is never changed either way:
  the app only reads it.
- **`auth_data` is a password.** It contains a long-lived Google master token
  (`Token=aas_et/...`). The app stores it in your login keychain and gives it
  to the uploader over a pipe, never in argv or the environment, where other
  processes of yours could read it. Treat it like a password: never paste it
  into an issue or a log.
- **One way, upload only.** Deleting a photo on the Mac does not delete it from
  Google Photos, and nothing comes back down from Google.

## How it works

```
Apple Photos ──PhotoKit──▶ Photos Backup.app ──JSON over a pipe──▶ gpmc_bridge.py ──▶ gpmc ──▶ Google Photos
 (albums you pick)          plan, export a batch,                   (bundled Python)      mobile API,
                            record media keys                                             "Pixel XL"
```

1. **Plan.** The app reads the selected albums through PhotoKit. Each asset
   Google has not confirmed yet is uploaded once, even if it sits in several
   albums. Your own albums go first, so a photo lands straight in its Google
   album; then smart albums; then everything else in All Photos.
2. **Export.** For each batch (20 by default), the app writes the version Photos
   shows into a staging folder: the edited rendition if there is one,
   otherwise the original. Originals still in iCloud ("Optimize Mac Storage")
   are downloaded first. Each file's modification date is set to its capture
   date, because gpmc sends that as the timestamp.
3. **Upload.** `Bridge/gpmc_bridge.py` hands the batch to gpmc one file at a
   time. gpmc hashes each file and asks Google whether it already has those
   bytes ("Already backed up"), uploads the rest, and returns a media key for
   every item. The app records each key as soon as Google confirms it. That
   hash check is also why resetting the history never uploads anything twice.
4. **Albums.** If "Recreate my albums" is on, each of your own albums gets a
   Google Photos album of the same name. It is created by its first batch, and
   later batches and later runs append to it. Smart albums and All Photos only
   upload their items.
5. **Record.** Media keys and album links go to
   `~/Library/Application Support/io.github.ayush5harma.PhotosBackup/state.json`
   after every batch, and the staging copies are deleted.

With **Back up automatically** on, a run starts at launch, 30 seconds after the
Mac wakes, every 30 minutes, when Photos reports a change (after it settles for
20 seconds) and when a blocking condition clears. Nothing runs by itself until
the welcome guide has been finished or skipped. **Pause** finishes the current
batch first. **Stop** abandons the files still uploading and keeps every one
already confirmed. Anything Google committed in the last instant is found by the
hash check on the next run. An album that is being created is always allowed to
finish first, so a stop cannot leave a duplicate album behind. Quitting the app
mid-batch stops the same way before it exits. While a run is uploading, the app
holds off idle sleep; it lets the Mac sleep again while a run waits.

## Retries, rate limits and conditions

These rules follow the iOS app and apply to every run.

**Retries.** A failed item is classified from Google's answer. HTTP 408 and 5xx
and network failures are retryable; other 4xx answers and anything unrecognised
are permanent. A retryable item is sent again within the same run: three
attempts in all, after 1 s, then 2 s, capped at 30 s. After the last attempt the
item stays failed for the run and the next run releases it again. A permanent
failure is not retried. **Retry Failed** and the per-item **Retry** give an item
fresh attempts.

**Google's 429.** An HTTP 429 holds every upload, not only the item that hit it,
and does not use up an attempt. The hold is 60 s, doubles while Google keeps
refusing, and is at most 600 s; it returns to 60 s after a batch gets through.
A run sits through at most five holds with nothing getting through in between
(1, 2, 4, 8 and 10 minutes); the next 429 ends the run as failed, so a run cannot
hold forever and keep automatic runs from starting.

**Conditions.** Four settings pause uploads (see Backup settings). They apply to
automatic runs only: launch, timer, library change, wake, a cleared condition,
turning an album on and signing in. Back Up Now, chosen photos, Retry and
`photosbackup://` links go ahead on a metered network, in Low Data Mode, on
battery and in Low Power Mode. No network at all holds every run. A run someone
started gives up after two minutes without a network; an automatic run waits as
long as it takes. When several conditions apply, one reason is shown, in this
order: offline, metered network, Low Data Mode, Low Power Mode, battery.

**Edited photos.** Each upload records an edit stamp: the asset's modification
date, whether the uploaded version was the edited one, and, for an edited
version, a SHA-256 of Photos' adjustment data. With **Back up edits again** on,
a photo whose edit changed since its backup is uploaded again as edited. A
favourite, keyword or re-render does not change the stamp's edit identity and
sends nothing; items backed up before stamps existed only get a stamp.

## Connect your Google account

Use the welcome guide's account page, or open **Settings > Account > Sign In with Google** (or **Sign In** on the Overview banner).
Google's own sign-in page opens inside the app. Sign in, then choose
**I agree**. The page may keep loading after that; the app has already
noticed the sign-in and closes the window once Google Photos accepts the
account.

What happens underneath follows [gotohp](https://github.com/xob0t/gotohp)
(xob0t's GUI client, MIT):

1. The page is Google's Embedded Setup, the one Android's setup wizard shows.
   After "I agree", Google leaves a single-use `oauth_token` cookie.
2. The app posts that cookie to Google's Android auth endpoint, as Google Play
   services would, for a newly generated Android device ID. Google returns a
   master token for that device.
3. The app builds the request Google Photos for Android would make with that
   token; that is gpmc's `auth_data`. It checks it with Google Photos before
   storing it.

The sign-in page runs in a web view with a throwaway session; the web view
identifies itself as Safari, whose engine it is, because Google turns away
sign-ins from web views it takes for embedded browsers. Only the resulting
`auth_data` is kept, in your login keychain. Signing in to a different Google
account resets the backup history, because media keys and albums belong to
the account that holds them.

If the in-app page will not work, **Other ways to connect** accepts the
`oauth_token` cookie copied from Safari's Web Inspector, or a whole `auth_data`
line from gpmc's own methods: [ReVanced (no root)](https://github.com/xob0t/gpmc#option-1---revanced-no-root-required)
or [the official app on a rooted phone or emulator, via HTTP Toolkit](https://github.com/xob0t/gpmc#option-2---official-apk-root-required).

## Build and run

For most users, download the macOS arm64 or x86_64 ZIP from the
[latest release](https://github.com/ayush5harma/google-photos-backup/releases/latest).
The prebuilt app requires macOS 14 or later and needs no developer tools.
Unzip it, move **Photos Backup.app** to Applications, and open it. Version 0.2.0
is signed ad hoc and is not notarized. If macOS blocks it, use **System Settings
> Privacy & Security > Open Anyway** after checking that you trust the download.

Building from source requires macOS 14 or later, Xcode 26 or later (Xcode or
Command Line Tools), and [uv](https://docs.astral.sh/uv/).

```sh
scripts/build-app.sh             # -> build/Photos Backup.app
scripts/build-app.sh --install   # ...and copy it to /Applications
open "build/Photos Backup.app"
```

The script compiles the app and copies a relocatable CPython 3.13 into the
bundle. That CPython is the python-build-standalone build uv installs. The
script then installs gpmc beside the bridge, precompiles the Python, draws
the icon, and signs everything from the inside out. The bundle is about 76 MB
and needs nothing else installed on the Mac.

Signing uses the first Apple Development / iPhone Developer / Developer ID
identity in your keychain; `--identity -` (or `CODESIGN_IDENTITY`) overrides
it. A real identity matters because macOS ties both the Photos permission and
the keychain item to the signature. With ad hoc signing, every rebuild asks
for both again.

On first launch the seven-page welcome guide walks through Photos access, Google
sign-in, choosing albums (All Photos starts selected), Messages, and menu bar and
startup choices. **Settings > General > Show Welcome Guide** reopens it.

## Settings

Settings are stored as one JSON value under the key `settings` in the app's
preferences. The names below are the UI labels, then the stored key. A value
outside its range is clamped when settings load.

### General

| Setting (UI) | Key | Default | Notes |
|---|---|---|---|
| Open at login | none (macOS Login Items) | off | Needs the app installed as an app. |
| Show in Dock | `showInDock` | on | Off gives menu-bar-only mode; the app always stays in the menu bar. |
| Show progress in the menu bar | `menuBarShowsProgress` | on | |
| Back up automatically | `automatic` | on | Triggers are listed under How it works. |
| When an automatic backup finishes | `notifyWhenFinished` | on | Turning it on asks macOS for permission once. |
| About problems that need you | `notifyAboutProblems` | on | At most one notification per category per hour. |
| Show Welcome Guide | `onboardingCompleted` | false on a fresh install | Settings saved before the guide existed count as completed. |

### Backup

| Setting (UI) | Key | Default | Range |
|---|---|---|---|
| Upload quality | `quality` | Pixel XL original quality (`original`) | `original`, `saver` (Storage saver), `quota` (Original, counts against storage). Google controls actual storage accounting. |
| Parallel uploads | `threads` | 2 | 1 to 8 |
| Items per batch | `batchSize` | 20 | 5 to 100, in steps of 5 |
| Recreate my albums in Google Photos | `mirrorAlbums` | on | |
| Back up edits again | `reuploadEdits` | on | |
| On a metered network, like an iPhone hotspot | `pauseOnExpensiveNetwork` | on | |
| In Low Data Mode | `pauseInLowDataMode` | on | |
| On battery power | `pauseOnBattery` | off | |
| In Low Power Mode | `pauseInLowPowerMode` | on | |

Google controls upload availability and storage accounting; no free or unlimited
storage is guaranteed. The tab also shows the conditions right now, such as
"Wi-Fi, on power".

### Messages

| Setting (UI) | Key | Default | Range |
|---|---|---|---|
| Back up photos and videos from Messages | `messagesMedia` | off | |
| Keep an archive of my messages | `messagesArchive` | off | |
| Folder | `archiveFolder` | `~/Messages Archive` (stored as none) | An existing archive at the former `~/Documents/Messages Archive` default stays there. Choose a new folder in Settings to move future output. |
| Archive automatically every day | `archiveAutomatically` | on | |
| Include attachments | `archiveAttachments` | on | |
| Show contact names | `archiveContactNames` | on | Names appear only after you allow Contacts access. |
| Database copies to keep | `archiveSnapshotsToKeep` | 7 | 0 to 30; 0 keeps none |

The cursor of the last bounded Messages media scan is kept as `messagesCursor`.

### Account

No stored settings. Sign in, check or disconnect the Google account; the other
connection methods; the backup history counts; **Forget Album Links** makes the
next run create fresh Google albums (use it after deleting the mirrored albums
in Google Photos); **Re-check Backups** forgets which items are backed up but
keeps the album links, and the next run re-checks every item by hash.

### Advanced

No stored settings. Storage use (upload copies, logs, backup history, run history
and timeline) with **Clean Up**, which removes staging leftovers when no run is
active, rotated logs and an oversized gpmc failure log. **Export Report** and
**Copy Report** produce the diagnostic report, **Show Logs in Finder** and
**View Timeline** open the logs and the Activity timeline, and About shows the
version and the uploader.

## Messages media

With Messages media on, locally available image and video attachments are
staged and uploaded like any other item. Each pass reads attachment metadata from
a temporary database snapshot, checks that local files stay inside the
attachment directory, and identifies media by SHA-256. Messages needs Full Disk
Access for Photos Backup. Back Up Messages Media Now and
`photosbackup://backup/messages-media` run only this source.

## Messages archive

The archive is a private, readable copy of every conversation. The first run
writes everything; later runs touch only conversations that changed, because
`archive.json` records a signature per chat. It runs automatically once a day
(an automatic run that failed is not retried for six hours) and on demand with
**Archive Now**, Shift-Command-A in the Messages section, the Backup menu or
`photosbackup://archive`. It reads a temporary copy of Messages' database, so
Messages itself is never changed.

```text
<archive folder>/
  index.html                 every conversation with its last message date
  style.css
  archive.json               manifest: per-chat signature, last message id, snapshot names
  Conversations/
    <name>-<hash>/           from the chat identifier and a hash of the chat guid
      index.html             the conversation styled like Messages
      messages.json          the same messages as data
      Attachments/           <hash>-<file name>, only when Include attachments is on
  Database/
    chat-YYYY-MM-DD.db       dated copies of Messages' database
```

- A conversation's folder name derives from its guid, so renaming a group or a
  contact never moves it.
- Messages deleted from Messages stay in the archive. If the database goes
  backwards (a restored Mac), every conversation is rewritten.
- On a later run, the current edited text replaces the displayed text, and an
  unsend marks the message as unsent. The archive can also retain text it saw
  before either change; it cannot recover earlier versions or unsent text it
  never read.
- Folders the archive creates are 0700 and every file is 0600; files are written
  whole and only when their bytes changed.
- The default folder is outside Documents to avoid common cloud sync setups.
  A folder you choose may sync to iCloud Drive or another provider; in that
  case the archive is stored with that provider too. Settings shows a sync note
  when the app detects one.
- Attachments are copied only when they are on this Mac. Attachments that
  Messages keeps in iCloud only are counted as not on this Mac.
- Message text is read from the attributed body when the plain text column is
  empty, so newer messages are not blank.
- Contact names come from Contacts only after you allow access, using the
  button in the Messages section; a background run never raises that prompt and
  falls back to phone numbers and addresses.
- The Database copies setting keeps the newest N dated copies, one per day.

The app mirrors the last archive result in `messages-archive.json` in
Application Support so the menu bar and Settings can show it without reading the
folder.

## History, timeline and report

| File (Application Support) | Holds | Limit |
|---|---|---|
| `state.json` | media keys, album links, edit stamps | none |
| `history.json` | run history: trigger, counts, bytes, outcome, conditions | 40 runs |
| `events.json` | event timeline | 400 events, none older than 14 days |
| `messages-archive.json` | summary of the last archive run | one |
| `Logs/` | `bridge.log`, rotated | cleaned by Clean Up |

- When history passes 40 runs, the oldest run that found nothing to do goes
  first, then the oldest run a person started, then the oldest. The newest run
  always stays.
- When the timeline passes 400 events, ordinary events go before problems. Each
  message is redacted when recorded and cut to 500 characters.
- A history or timeline file that cannot be read is moved aside as
  `<name>.unreadable` and the value starts empty.
- Redaction removes tokens, email addresses (including percent-encoded ones),
  phone numbers, staging paths and the home folder's name.
- The diagnostic report starts with "What stands out", then lists app, macOS and
  uploader versions, account and permissions (the address masked), settings,
  backup counts, storage, the last 20 runs and the last 30 problems. The findings
  cover a refused account, a full Google account, limited or denied Photos access,
  a Messages feature without Full Disk Access, no completed run in 24 hours,
  three of the last five runs with failures, Google slowing the app down in the
  last day, an hour-long hold, five or more failures with one cause, and staging
  leftovers.

## Links

See the table in the README. A link runs the same code as the matching button.
`photosbackup://open/home` still works and means `overview`. Backing up needs a
signed-in account; `backup/photos` also needs Photos access; `archive` needs the
archive turned on. A link that cannot run is recorded in the timeline. Every run
a link starts is recorded with the trigger "Shortcut or link". The table lives in
`Sources/PhotosBackupCore/AutomationCommand.swift` and the actions in
`Sources/PhotosBackup/Automation.swift`.

## Keyboard shortcuts

| Shortcut | Action | Where |
|---|---|---|
| Command-B | Back Up Now | Backup menu, menu bar panel |
| Shift-Command-P | Pause after current uploads, or Resume | Backup menu |
| Command-. | Stop | Backup menu |
| Shift-Command-A | Archive Messages now | Messages section |
| Command-, | Settings | menu bar panel, app menu |
| Command-Q | Quit | menu bar panel |

Retry Failed Items and Archive Messages Now are also in the Backup menu, without
shortcuts.

## Not done yet

- Live Photos upload as their still image; the motion part is not sent, because
  gpmc cannot attach it.
- Google storage-full detection: gpmc 0.9.0 drops the response that tells a
  full account from any other refusal, so the bridge cannot report
  `storage_full`. The app has the wording and an Overview banner ready for it; for
  now a full account shows up as failed items.
- Shared albums and other people's items are skipped, since PhotoKit does not
  hand out their originals.
- No App Intents or Shortcuts actions: a SwiftPM build cannot emit their
  metadata, so `photosbackup://` links are the automation surface.
- Messages attachments that exist only in iCloud cannot be archived or uploaded
  until Messages has downloaded them to this Mac.
- Google caps an album at 20,000 items. gpmc splits a larger new album into
  "Name 1", "Name 2" and so on, but the app only remembers the first.
- Release builds are signed ad hoc and are not notarized. Version 0.2.0 has
  separate Apple silicon and Intel macOS ZIPs. Windows WinUI 3 is in
  development and has no release yet.
- If the response to creating a Google album is lost (a timeout, a crash, or
  a quit that outlasts the 15-second stop), the album exists but the app never
  learned its id, and the next run creates another. gpmc cannot list albums,
  so the orphan cannot be found again automatically.
- Deleting an item from Google Photos does not send it again;
  Re-check Backups does. Edits are sent again only while Back up edits again is on.
- Each batch is a new uploader process that signs in again, so the default
  batch size means one sign-in per 20 items. For very large libraries the
  next step is a long-lived uploader that reuses its token.
- Messages deleted from the Mac stay in the archive, and there is no restore
  tool: the dated database copies are for a manual restore.
- The in-app conversation preview reads a conversation's whole `messages.json`
  before showing its last 200 messages. Very large conversations may use
  substantial memory; the browser page remains available for the full archive.
- A real sign-in and a real upload are not covered by automated tests; the
  end-to-end run uses a fake Google.

## Development

```sh
swift test                                                # Swift Testing
python3 -B -m unittest discover -s Bridge/tests           # bridge tests against a fake gpmc
SNAPSHOT_FIXTURE=1 scripts/snapshots.sh /tmp/shots        # fixture screenshots
scripts/e2e.py --app "build/Photos Backup.app"            # end-to-end run
```

See [CONTRIBUTING.md](../CONTRIBUTING.md) for what each layer covers and what the
end-to-end run needs.

- `Sources/PhotosBackupCore`: everything that needs neither PhotoKit nor a
  process: the bridge protocol, persisted state, the planner, retry, rate-limit
  and conditions rules, history, timeline and report, the links, and the Messages
  archive.
- `Sources/PhotosBackup`: the app: PhotoKit library and exporter, the bridge
  runner, the engine, Keychain, SwiftUI views, the menu bar panel and the
  Settings tabs.
- `Bridge/gpmc_bridge.py`: the line protocol. Its docstring is the
  specification: one JSON request on stdin, NDJSON events on stdout, logs on
  stderr. The pinned gpmc version is in `Bridge/requirements.txt`.
- The bridge log is `~/Library/Application Support/io.github.ayush5harma.PhotosBackup/Logs/bridge.log`
  (Settings > Advanced > Show Logs in Finder).

## Credits

[gpmc](https://github.com/xob0t/gpmc) by xob0t does the actual talking to
Google, under the MIT license. This app is MIT too; see [LICENSE](../LICENSE).
