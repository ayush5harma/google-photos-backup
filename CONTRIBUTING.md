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
python3 -m unittest discover -s Bridge/tests
swift build
scripts/build-app.sh --identity -
```

The last command builds an ad-hoc-signed app under `build/`; it does not install
it. Do not run an installer or a real backup merely to verify a documentation
change. The automated tests use fixture data, not a real Google account.

## Code and review

Keep changes focused and explain the problem, resulting behavior, and checks in
your pull request. Add meaningful regression tests for backup-state, deduplication,
permissions, or uploader changes. Update docs and provide synthetic screenshots
for visible UI changes. State which real-device or account checks you did not run.

- `Sources/PhotosBackupCore`: source planning, persisted state, bridge protocol.
- `Sources/PhotosBackup`: SwiftUI app, media sources, export, and upload execution.
- `Bridge`: uploader protocol and Python tests.
- `Tests`: Swift tests using synthetic data.

Preserve upload confirmation before recording success, account-bound history,
and source files. Avoid logging tokens, message text, attachment paths, or
personal identifiers. Check changed shell scripts with `bash -n` and
`shellcheck -S warning -x`.

Contributions are distributed under the repository's [MIT license](LICENSE).
