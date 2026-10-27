# Photos Backup

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/app-icon-dark.png">
  <img src="docs/app-icon.png" width="112" height="112" alt="Aperture and infinity app icon">
</picture></p>

Back up selected photos and videos to Google Photos from **macOS, Windows, or Android**. The apps keep your originals by default and include a **currently working unlimited original-quality mode** through the unofficial gpmc client. [Validation and limits](#upload-mode-and-its-limits).

[Website](https://ayush5harma.github.io/google-photos-backup/) · [Download v0.5.6](https://github.com/ayush5harma/google-photos-backup/releases/latest) · [Setup](docs/SETUP.md) · [Reference](docs/REFERENCE.md) · [Credits](ACKNOWLEDGEMENTS.md)

## Start here

1. Install the current release for your platform below (v0.5.6 on Mac and Windows, v0.5.0 on Android).
2. Pick a small source and review automatic backup settings (on by default on Mac), then connect Google Photos and run a backup.
3. Check the uploaded item in Google Photos, including its quality and storage details, before trusting a larger backup.

| Platform | Download |
| --- | --- |
| macOS 14+ (v0.5.6) | [Apple silicon DMG](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.6/Photos-Backup-0.5.6-macOS-arm64.dmg) · [Intel DMG](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.6/Photos-Backup-0.5.6-macOS-x86_64.dmg) |
| Windows 10 1809+ (x64) / Windows 11 (ARM64) (v0.5.6) | [ARM64 installer](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.6/Google-Photos-Backup-0.5.6-Windows-arm64-Setup.exe) · [Intel/AMD x64 installer](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.6/Google-Photos-Backup-0.5.6-Windows-x64-Setup.exe) |
| Android 8+ (v0.5.0) | [APK — ARM64 and x86_64](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.0/Photos-Backup-0.5.0-Android.apk) |

`SHA256SUMS.txt` in the [v0.5.6](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.6/SHA256SUMS.txt) and [v0.5.0](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.5.0/SHA256SUMS.txt) releases cover their packages. The Mac app is ad-hoc signed and not notarized; Windows installers are unsigned previews.

## Upload mode and its limits

Photos Backup uses [xob0t's gpmc](https://github.com/xob0t/gpmc), an unofficial Google Photos client. Its Pixel XL profile currently produced **Original quality** uploads that did **not** count against Google account storage in our finite live tests. Google can change authentication, upload behavior, or storage accounting at any time, so this is neither a guarantee nor an entitlement for every account or file.

On 16 October 2026, a photo and video from each supported platform were read back from Google Photos with SHA-256 hashes matching the originals. The tested Mac albums and Windows folders also had their expected names and contents. See the [validation report](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/live-validation.md).

## What’s new in v0.5.6

On the Mac, photos chosen with Choose Photos from the unlocked Hidden album now back up instead of failing as "No longer in the Photos library" ([#46](https://github.com/ayush5harma/google-photos-backup/issues/46)). Hidden photos still go up only when you choose them; selected albums leave them out as before. The Android APK stays at 0.5.0 until a signed APK is published.

## What’s new in v0.5.5

Adding photos to an album no longer gives up on a passing "500 Server Error" or "503 Service Unavailable" from Google ([#44](https://github.com/ayush5harma/google-photos-backup/issues/44)). The call is tried again after a few seconds, so an album no longer waits for the next backup because of one bad moment on Google's side. On Windows this covers adding to existing albums; creating a new album there is unchanged. The Android APK stays at 0.5.0 until a signed APK is published.

## What’s new in v0.5.4

On the Mac, albums no longer stop filling with "404 Client Error: Not Found" ([#42](https://github.com/ayush5harma/google-photos-backup/issues/42)). Google refuses a whole album call when one photo in it is no longer in Google Photos; a day after one large backup, 1 of 72 sampled uploads had become such a photo. The app now adds every other photo, uploads the missing ones again and files them in their albums. Burst frames added to an album one by one now back up instead of failing as "No longer in the Photos library". A photo deleted in Google Photos while it is still in a backed-up Photos album is now uploaded again the next time that album is updated. Windows keeps the earlier album behaviour for now, and the Android APK stays at 0.5.0 until a signed APK is published.

## What’s new in v0.5.3

Large backups no longer stall on an item with "The uploader stopped unexpectedly (exit 0)": gpmc 0.9.0 occasionally decoded a Google media key as a nested message, which lost that item and broke the album add for its batch ([#40](https://github.com/ayush5harma/google-photos-backup/issues/40)). Use Retry Failed, or the next backup, for an item that failed this way. The Android APK stays at 0.5.0, which still has this and the v0.5.2 album problem, until a signed APK is published.

## What’s new in v0.5.2

Albums now fill completely: since v0.2.0, adding items to an existing Google Photos album, from its second batch on, failed with "'Client' object has no attribute 'add_to_existing_album'", so an album got only its first batch ([#38](https://github.com/ayush5harma/google-photos-backup/issues/38)). Items that were backed up but left out are added to their album on the next backup. The Android APK stays at 0.5.0, which still has this problem, until a signed 0.5.2 APK is published.

## What’s new in v0.5.1

On macOS, choosing **Connected device** (or launching with it as the saved section) no longer leaves the main window blank, with no sidebar and no page ([#36](https://github.com/ayush5harma/google-photos-backup/issues/36)). Mac and Windows packages are 0.5.1; the Android APK stays at 0.5.0, since it is signed with the release key outside CI and Android code did not change.

## What’s new in v0.5.0

Disposable files passed import and byte-for-byte Google original readback: iPhone on Mac, and iPhone and Pixel through Windows production components. Android folder backup and album creation passed the owner’s on-device check, and its responsive layout passed device tests and scrcpy inspection. Live iCloud reclaim validation remains pending. [Validation](docs/VALIDATION-v0.5.0.md).

- **Android:** select accessible MediaStore folders and mirror them as Google Photos albums. These are device folders, not logical Google albums. Android's partial-media permission means only media you granted the app can appear.
- **macOS:** import selected originals from a connected, unlocked and trusted iPhone or camera through DCIM/Image Capture. This is file import, not PhotoKit album access or cloud-only media.
- **Windows:** import selected media from devices exposed through Windows portable storage/DCIM. An optional, explicitly configured ADB source can import from a wireless Android connection.
- **iCloud reclaim (experimental):** iCloud backup remains copy-only by default. A manual preview, or an explicitly confirmed automatic run of at most 100 items, may move verified source assets to Recently Deleted only after fresh original readback and SHA-256 verification of every component. Recently Deleted changes propagate to iCloud devices; it does not promise immediate free space or purge the items.

## Know before backing up

- macOS can recreate selected Apple Photos albums. Windows mirrors selected folder names. Android selects individual files or accessible device folders.
- Live Photos and other paired components need special care. The Mac Photos-library source currently uploads the still image; connected-device reclaim requires every identified paired component.
- Selected media and associated metadata go to your Google account. Credentials stay in macOS Keychain, Windows DPAPI, or Android Keystore; local history stays on your device.

## Screenshots

Screenshots show v0.5.0 with synthetic data; they are not live-upload evidence.

| macOS | Windows |
| --- | --- |
| ![macOS menu bar](docs/menu-bar-panel-light.png) | ![Windows connected-device import](docs/windows-connected-device-light.png) |

<details><summary>Android and dark mode</summary>

<img src="docs/android-overview-dark.png" width="280" alt="Android app with full-width backup action and synthetic media">

Android image shows v0.5.0 with synthetic account and media data.

![macOS dark mode](docs/menu-bar-panel-backing-up-dark.png)

</details>

See [detailed setup](docs/SETUP.md), the [technical reference](docs/REFERENCE.md), [Windows guide](Windows/README.md), and [Android guide](Android/README.md). Developers can start with [CONTRIBUTING.md](CONTRIBUTING.md).

<details><summary>Connected iPhone import — v0.5.0</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/macos-connected-device-dark.png">
  <img src="docs/macos-connected-device-light.png" alt="Connected iPhone import preview with synthetic photo and video files">
</picture>

</details>

<details><summary>Connected-device import on Windows — v0.5.0</summary>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/windows-connected-device-dark.png">
  <img src="docs/windows-connected-device-light.png" alt="Windows Connected devices page with synthetic Android and portable-device media">
</picture>

The `--device-smoke` fixture supplies synthetic media and does not query connected devices.

</details>

## Credits

Made possible by [gpmc](https://github.com/xob0t/gpmc) and [gotohp](https://github.com/xob0t/gotohp) by **xob0t**, [iCloud Photos Downloader](https://github.com/icloud-photos-downloader/icloud_photos_downloader), and the projects listed in [Acknowledgements](ACKNOWLEDGEMENTS.md). Photos Backup is [MIT licensed](LICENSE); upstream projects retain their own licenses.
