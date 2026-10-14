# Google Photos Backup for Windows

A native WinUI 3 desktop preview for backing up photo and video folders to Google Photos. It uses Windows App SDK 2.5.1, .NET 10, and the same pinned gpmc uploader as the macOS app.

This is a development preview, not a stable Windows release. See implementation and verification in [PR #5](https://github.com/ayush5harma/google-photos-backup/pull/5). The released [macOS app](../README.md#download) is available for Intel and Apple silicon.

## Get a preview build

Open a successful **Windows x64** run associated with the PR, then download its **Google-Photos-Backup-Windows-x64** artifact while signed into GitHub. Artifacts expire after 14 days. Extract the artifact, then extract the enclosed application ZIP. Keep the entire **Google Photos Backup** folder together and run **GooglePhotosBackup.exe**.

The preview targets Windows 10 version 1809 or later on x64; Windows 11 is recommended for its native Mica appearance. ARM64 packages are not provided. The package includes .NET, Windows App SDK, Python, and the uploader. Google sign-in also requires Microsoft Edge WebView2 Runtime. Follow Microsoft’s [Windows App SDK prerequisites](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/deployment-architecture), including the current x64 Visual C++ Redistributable. A clean Windows installation without that redistributable has not been tested. The application is currently unsigned, so Windows may warn when opening it; inspect the source and build provenance before trusting a preview.

## A look at the preview

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../docs/windows-overview-dark.png">
  <img src="../docs/windows-overview.png" alt="Native WinUI 3 backup overview">
</picture>

This is the actual WinUI window rendered with synthetic data in [verified Windows CI run 38637885601](https://github.com/ayush5harma/google-photos-backup/actions/runs/38637885601). The fixture uses an opaque theme background so Mica transparency is readable in a PNG; the normal app retains its system backdrop.

## Set up and back up

1. Open **Settings** and choose **Sign in with Google**. Complete Google's sign-in in the embedded window. The app checks the resulting credential before saving it, encrypted with Windows DPAPI for your Windows account.
2. Open **Folders** and add the photo or video folders you want to back up. Subfolders are scanned too. Nested symbolic links and reparse points are skipped; select a real folder as the root. An unreadable source stops the scan rather than reporting a successful backup.
3. Choose your upload quality in **Settings**. Original quality uses gpmc's Pixel XL mode. Google determines storage accounting; verify your account after a small initial backup. Unlimited storage is not guaranteed.
4. Enable album mirroring if you want each selected root folder represented as an album in Google Photos.
5. Open **Overview** and start a backup. Keep the app open. You can pause between batches, resume, or stop the run. **Activity** shows completed runs and failure counts.

Only confirmed uploads enter the local resume state. A later run skips unchanged, confirmed files and retries pending files and album updates; edited files may upload again. Overlapping folder selections are deduplicated. The app uploads copies and does not delete source files or Google Photos media.

This preview does not yet provide automatic scheduling, a tray app, Windows Photos library integration, or the macOS Messages features. Google sign-in and real account uploads still need interactive Windows validation; automated tests use synthetic data and a fake Google service.

## Local data

Settings, history, and account-specific resume state are stored in `%LOCALAPPDATA%\GooglePhotosBackup`. Credentials are encrypted with DPAPI `CurrentUser` and sent to the uploader through standard input, not command-line arguments. Disconnecting removes the saved credential. Deleting resume state can cause files to be reconsidered on the next run.

Selected media and optional album names are sent to Google Photos using an unofficial API. Google may change authentication, upload behavior, and storage accounting. Read the repository's [privacy notes](../README.md#privacy).

## Build on Windows

Use a native Windows x64 host with PowerShell 7, .NET 10 SDK, the Windows SDK and C++ build tools required by WinUI 3, and uv. Visual Studio with the WinUI application development workload supplies the native build tools. Run from the repository root:

```powershell
git clone https://github.com/ayush5harma/google-photos-backup.git
cd google-photos-backup
./scripts/build-windows.ps1
```

The script publishes the self-contained app, bundles Python 3.13 and gpmc, verifies native binaries and imports, and tests the app after extracting the ZIP into a new location. Output is `build/windows/Google-Photos-Backup-Windows-x64.zip`, with a SHA-256 checksum and verification reports. The smoke test uses synthetic content, checks an encrypted credential round trip, and captures the actual WinUI window without signing in or uploading anything.

Run the core and bridge tests separately:

```powershell
dotnet test Windows/GooglePhotosBackup.Core.Tests/GooglePhotosBackup.Core.Tests.csproj -c Release
uv run --no-project --python 3.13 python -B -m unittest discover -s Bridge/tests
```

## iCloud Photos

Current source builds include an iCloud Photos source. Connect Google first, then open **iCloud Photos** and follow the Apple Account password and verification-code prompts. An iCloud for Windows installation or existing Windows iCloud sign-in is not required. Expired sessions return you to sign-in rather than silently reporting success.

See [iCloud setup and limitations](../README.md#icloud-photos-backup-source-builds). This version retains the iCloud originals; automatic source deletion is not enabled.
