# Detailed setup

For downloads and a quick start, see the [README](../README.md).

## Set up on macOS

1. Open **Photos Backup.app** and follow the welcome guide. Grant Photos access so the app can read the library and albums you want to back up.
2. Choose **Sign In with Google**. Sign in on Google's page inside the app and complete the consent step. Photos Backup stores the resulting credential in your macOS login Keychain.
3. Choose **All Photos** for the whole library, or select albums in **Albums**. You can change the selection later. Photos kept only in iCloud are downloaded by Photos when the app exports them.
4. Choose **Back Up Now** in the window or menu bar panel. The menu bar shows progress, and **Activity** shows recent runs and failed items. Leave the app running for automatic backups; **Settings > General > Open at login** can start it when you sign in to your Mac.

Automatic backups are on by default after the welcome guide. They run when the library changes, at launch, after wake, and periodically. You can pause, stop, or retry failed items. The app reads Apple Photos and uploads copies; it never deletes media from your Mac or Google Photos. Edited photos can be uploaded again, so Google Photos may contain both versions.

## iCloud Photos backup

The macOS app and Windows preview include an iCloud Photos source. You do not need to be signed in to iCloud in macOS System Settings or have iCloud for Windows installed.

1. Connect your destination Google account in the app.
2. Open **iCloud Photos**, enter your Apple Account, and follow the sign-in prompts. Enter your password in the app and complete Apple's verification code prompt when requested. Use a trusted-device code, or select a masked trusted phone number and choose **Send Text Message** for SMS verification.
3. Once connected, start the iCloud backup. Keep the app open while it downloads originals and uploads them to Google Photos. Use the source's pause/resume controls to continue an interrupted transfer. iCloud backups are started manually; the existing automatic Photos Library schedule does not run this source.
4. If the session expires, return to **iCloud Photos** and sign in again. A previous desktop iCloud or `icloudpd` sign-in does not guarantee that this app has a usable session.

The sign-in flow supports Apple two-factor authentication. Legacy two-step verification accounts are not supported; the app explains this instead of repeatedly asking for a code.

Direct iCloud access depends on Apple's web access being available. Accounts with Advanced Data Protection may not support this provider. The app does not change your account's protection settings. If web access is unavailable, use the macOS Photos Library source or download originals using Apple's tools and back up a local folder on Windows.

The macOS menu bar has a separate **iCloud Photos** card with progress and start/pause/resume controls. **Back Up Mac** remains the action for local Mac sources.

Apple session material is stored in macOS Keychain or encrypted with Windows DPAPI. Passwords and verification codes are passed to the bundled helper through a pipe and are not saved by the form. The helper uses a private temporary cookie directory while running; a forced termination can leave it until the next helper launch cleans it up.

This integration currently copies media and retains the iCloud originals. Upload completion alone is not a safe basis for reclaiming iCloud storage.

### Upcoming v0.5.0: verified iCloud reclaim preview

The upcoming v0.5.0 preview keeps iCloud backup copy-only by default. Reclaim is a separate, opt-in action: review a manual preview, or explicitly confirm an automatic run of no more than 100 assets. Before an asset is moved, the app freshly downloads every original component from iCloud, reads the uploaded original back from Google Photos, and compares SHA-256 hashes and byte counts. A changed source, failed verification, or uncertain deletion leaves the source retained.

A successful reclaim moves the item to **Recently Deleted**; it does not permanently purge it, guarantee immediate iCloud storage recovery, or avoid propagation to devices sharing that iCloud Photos library. Review the preview and Recently Deleted consequence carefully. Validation of synthetic iCloud reclaim synchronization is still pending.

### Upcoming v0.5.0: connected devices

On macOS, an unlocked and trusted iPhone or camera can supply selected originals through Image Capture/DCIM. This imports files that the connected device exposes; it does not browse PhotoKit albums or cloud-only items. The import path copies originals and retains the device source. Connected-iPhone end-to-end validation remains pending.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="icloud-setup-dark.png">
  <img src="icloud-setup-light.png" alt="iCloud Photos setup with Apple Account sign-in and backup-only guidance, using synthetic data">
</picture>

The shared provider replaces the earlier iCloud-to-Google-Photos pipeline, using [iCloud Photos Downloader](https://github.com/icloud-photos-downloader/icloud_photos_downloader) for iCloud access and this app's existing Google uploader.


## More help

- [Windows setup](../Windows/README.md#set-up-and-back-up)
- [Android setup and builds](../Android/README.md)
- [Messages, automation and settings](REFERENCE.md)
- [Project credits](../ACKNOWLEDGEMENTS.md)
