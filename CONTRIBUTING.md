# Contributing

Start with a focused issue for substantial changes. Include your macOS version,
app commit, reproduction steps using sample media, and expected behavior. Never
attach credentials, personal photos, Messages databases, or unredacted logs.
Report vulnerabilities through [SECURITY.md](SECURITY.md).

## Development

Use macOS 14+ and a Swift 6 toolchain. Building a complete app also requires
[uv](https://docs.astral.sh/uv/); the Python dependencies are pinned in
`Bridge/requirements.txt`.

```sh
swift test
python3 -B -m unittest discover -s Bridge/tests
swift build
scripts/build-app.sh --identity -
```

The last command builds an ad-hoc-signed app under `build/`; it does not install
it. Do not run an installer or a real backup merely to verify a documentation
change. The automated tests use fixture data, not a real Google account.

## Test layers

| Layer | Command | What it covers |
| --- | --- | --- |
| Swift tests | `swift test` (187 tests) | Core rules: retry, rate limit, conditions, edit detection, history, timeline, report, links, status line, the Messages archive writer and decoding, the planner, the bridge protocol |
| Bridge tests | `python3 -B -m unittest discover -s Bridge/tests` (38) | The line protocol against a fake gpmc client, and real bridge runs against `Tests/E2E/fake_gpmc` |
| Fixture screenshots | `SNAPSHOT_FIXTURE=1 scripts/snapshots.sh <out> [groups]` | Renders every screen from made-up data; groups are `sections`, `settings`, `onboarding`, `menubar` and `links` |
| End-to-end | `scripts/e2e.py --app <bundle>` | The real app and the real bridge against a fake Google |

### The end-to-end run

```sh
scripts/build-app.sh --identity "Apple Development: ..."   # the identity you use for the real app
scripts/e2e.py --app "build/Photos Backup.app" [--only launch,photos] [--keep]
```

What it needs:

- A bundle built by `scripts/build-app.sh`. The run copies it, swaps in a debug
  binary and signs the copy with the same identity, so the copy keeps the
  bundle identifier and the Photos permission the real app has. Ad hoc signing
  works but loses that grant.
- The real app quit. A second copy with the same bundle identifier would receive
  the `photosbackup://` links, and the script refuses to start otherwise.
- Photos access already granted to the app, and a small user album (3 to 25
  items) in your Photos library for the upload scenario. The library is only read.
- For the Messages scenarios, the terminal you run it from needs Full Disk
  Access, because those scenarios start the binary from the shell so it inherits
  that access. Without it, only the no-access scenario is meaningful.

How it stays safe: everything the app writes goes under `<work>/sandbox`
(`PHOTOS_BACKUP_SANDBOX`, default work folder `~/.cache/photos-backup-e2e`), so the
real app's history, settings and Keychain item are untouched. Google is a fake
(`Tests/E2E/fake_gpmc`), so no byte leaves the Mac. The Messages archive it
writes holds private text, lands in `<work>/archive` and is deleted at the end
unless you pass `--keep`. The report, `<work>/report.md`, lists pass or fail per
check and contains no album title, file name, message text or contact detail.
Read the docstring at the top of `scripts/e2e.py` before changing it.

## Screenshots

Published screenshots come from fixture mode only. They show made-up data and
never a real library, account, conversation or contact. Render them with
`SNAPSHOT_FIXTURE=1 scripts/snapshots.sh <out>` and look at every image before
copying it into `docs/`: skip any with rendering artefacts, such as greyed
controls from an inactive window. Do not capture your own desktop, do not grant
the fixture Photos, Messages or Contacts access, and never publish sign-in
screens, account addresses, real logs or attachment names. Downscale to at most
1400 px wide (`sips --resampleWidth 1400`). See [docs/SCREENSHOTS.md](docs/SCREENSHOTS.md).

## Code and review

Keep changes focused and explain the problem, resulting behavior, and checks in
your pull request. Add meaningful regression tests for backup-state, deduplication,
permissions, or uploader changes. Update docs and provide synthetic screenshots
for visible UI changes. State which real-device or account checks you did not run.

- `Sources/PhotosBackupCore`: planning, persisted state, bridge protocol, retry,
  rate-limit and conditions rules, history, report, links, Messages archive.
- `Sources/PhotosBackup`: SwiftUI app, menu bar, Settings, media sources, export,
  and upload execution.
- `Bridge`: uploader protocol and Python tests.
- `Tests`: Swift tests using synthetic data, and the fake gpmc for the end-to-end run.

Preserve upload confirmation before recording success, account-bound history,
and source files. Avoid logging tokens, message text, attachment paths, or
personal identifiers; anything that reaches the timeline goes through `Redactor`.
Keep Messages archive files 0600 and its folders 0700. Check changed shell scripts with `bash -n` and
`shellcheck -S warning -x`.

Contributions are distributed under the repository's [MIT license](LICENSE).
