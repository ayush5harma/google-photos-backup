# Photos Backup

<p align="center"><picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/app-icon-dark.png">
  <img src="docs/app-icon.png" width="112" height="112" alt="Aperture and infinity app icon">
</picture></p>

Back up photos and videos to Google Photos with native apps for **macOS, Windows and Android**. Choose what to upload, follow progress, and keep your originals. Includes a **currently working unlimited original-quality upload mode** through the unofficial gpmc Pixel XL profile; see the [validation and limits](#does-it-use-google-storage) below.

[Website](https://ayush5harma.github.io/google-photos-backup/) · [Download](https://github.com/ayush5harma/google-photos-backup/releases/latest) · [Setup](docs/SETUP.md) · [Credits](ACKNOWLEDGEMENTS.md) · [Contribute](CONTRIBUTING.md)

## Choose your app

| Platform | What you can back up | v0.4.0 download |
| --- | --- | --- |
| macOS 14+ | Apple Photos albums/library; optional Messages media; iCloud Photos | [Apple silicon DMG](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/Photos-Backup-0.4.0-macOS-arm64.dmg) · [Intel DMG](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/Photos-Backup-0.4.0-macOS-x86_64.dmg) |
| Windows 10 1809+ (x64) / Windows 11 (ARM64) | Selected photo/video folders; iCloud Photos | [ARM64 installer](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/Google-Photos-Backup-0.4.0-Windows-arm64-Setup.exe) · [Intel/AMD x64 installer](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/Google-Photos-Backup-0.4.0-Windows-x64-Setup.exe) |
| Android 8+ | Individually selected on-device photos/videos | [APK — ARM64 and x86_64](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/Photos-Backup-0.4.0-Android.apk) |

These are early releases. No Python or developer tools are needed to use them. [SHA256SUMS.txt](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/SHA256SUMS.txt) covers all five downloads.

## Get started

1. **Install.** On Mac, open the DMG and drag the app to Applications. On Windows, run the installer matching your system architecture. On Android, install the APK, allowing installation from your browser when prompted.
2. **Choose your sources.** On Mac, review album selection and automatic backup settings before connecting: automatic backups are enabled by default. Start with a small test album or folder.
3. **Connect Google Photos** in the app, select your photos/albums/folders, and start a backup. Android uploads only files you explicitly select.
4. **Check the result** in Google Photos, including the item's quality and storage information.

The macOS release is ad-hoc signed and not notarized; if blocked, use **System Settings → Privacy & Security → Open Anyway** only if you trust the download. Windows installers are unsigned previews. See the [Windows requirements](Windows/README.md) and [detailed setup](docs/SETUP.md) for help.

## Does it use Google storage?

Uploads use [xob0t's gpmc](https://github.com/xob0t/gpmc), an **unofficial** Google Photos client. Its unlimited Original / Pixel XL mode currently works in our live tests: Google attributes no account-storage use to those uploads. This is not a guaranteed entitlement for every file, account, or future upload.

In our 16 October 2026 test, Google Photos marked a photo and video uploaded from **each platform** as **Original quality** and **not taking up account storage**. All six downloaded originals matched their source SHA-256 hashes. The Mac album and Windows folder appeared with the same names and exactly the expected files. [Read the validation report](https://github.com/ayush5harma/google-photos-backup/releases/download/v0.4.0/live-validation.md).

Those results apply to the tested files and account. Google can change sign-in, uploads or storage charging. This project is not affiliated with Google or Apple.

## Screenshots

Screenshots use synthetic data; they are not live-upload evidence.

| macOS | Windows |
| --- | --- |
| ![macOS menu bar](docs/menu-bar-panel-light.png) | ![Windows app in Parallels](docs/windows-parallels.png) |

<details><summary>Android and dark mode</summary>

<img src="docs/android-overview-dark.png" width="280" alt="Android backup screen in dark mode">

![macOS dark mode](docs/menu-bar-panel-backing-up-dark.png)

</details>

## Know before backing up

- **Copies, not offloading:** the apps retain your source media. iCloud automatic deletion and storage reclaim are not implemented.
- **Albums:** macOS can recreate selected Apple Photos albums; Windows can mirror folder names. Android currently selects individual files, not albums.
- **Live Photos:** the macOS Photos-library source currently uploads the still image. Edited versions may create additional uploads.
- **Privacy:** selected media and associated metadata go to your Google account. Credentials are protected by macOS Keychain, Windows DPAPI or Android Keystore. Local history stays on your device. Optional Mac Messages archiving stays in the folder you choose; a cloud-synced folder also shares it with that provider.

[Settings and limitations](docs/REFERENCE.md) · [Windows guide](Windows/README.md) · [Android guide](Android/README.md) · [Security](SECURITY.md)

## Build and contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for macOS development, and the [Windows](Windows/README.md#build-on-windows) / [Android](Android/README.md#build) guides for those platforms. [Dependency monitoring](docs/dependency-updates.md) checks the core uploader daily.

## Credits

Made possible by [gpmc](https://github.com/xob0t/gpmc) and [gotohp](https://github.com/xob0t/gotohp) by **xob0t**, [iCloud Photos Downloader](https://github.com/icloud-photos-downloader/icloud_photos_downloader), and the platform/runtime projects listed in [Acknowledgements](ACKNOWLEDGEMENTS.md). This app is [MIT licensed](LICENSE); upstream projects retain their own licenses.
