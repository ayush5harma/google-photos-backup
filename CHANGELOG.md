# Changelog

What changed in each release, newest first. Downloads and full notes are on the [releases page](https://github.com/ayush5harma/google-photos-backup/releases). Numbers like #49 are GitHub issues.

## 0.6.4 (2026-11-06)

- Mac: uploads are confirmed with Google up to 20 at a time instead of one by one. One account went from about 1.1 to 2.2 photos a second (#72).
- Mac: if Google refuses a batch, its photos are confirmed one at a time, as before.
- Android: a new signed APK, the first since 0.5.0. It installs over 0.5.0 and brings parallel uploads (see 0.6.2) and the uploader fixes from 0.5.2 and 0.5.3.
- Windows and Android still confirm uploads one at a time.

## 0.6.3 (2026-11-05)

- Mac: each Google account uploads at its own pace. A fast account no longer waits for a slow one at the end of each batch (#70).
- Mac: each account row shows its own progress while it backs up.
- Mac: picks, Messages media and device imports go to the first account without holding the others back.

## 0.6.2 (2026-11-05)

- Mac: several Google accounts back up at the same time instead of one after another. Each photo is exported once and sent to every account that needs it (#66).
- Mac: every album safeguard still holds for each account.
- Mac: when Google has trouble keeping up, parallel uploads step down in proportion to how much of a batch failed, and try higher again after a long clean stretch.
- Windows: one uploader for the whole run, up to 32 parallel uploads (automatic or a number you choose), and the speed and time left (#58).
- iCloud backups on Mac and Windows: one Google sign-in per run, up to 8 iCloud downloads and 32 uploads at once (#60).
- Android: one Google sign-in per run and parallel uploads, up to 8 on Wi-Fi and 2 on a metered network (#59). Released in the 0.6.4 APK.

## 0.6.1-preview.2 (2026-11-05, Windows test build)

- A Windows-only test build: 0.6.1 plus the Windows upload and iCloud speed work that shipped in 0.6.2. It was never run on a Windows PC.

## 0.6.1-preview.1 (2026-11-05, Windows test build)

- A Windows-only test build: 0.6.1 plus the Windows upload speed work that shipped in 0.6.2. It was never run on a Windows PC.

## 0.6.1 (2026-11-05)

- Mac: with automatic parallel uploads off, the number you choose is used from the first batch. Before, runs started at 4 and crept up.
- Mac: up to 32 uploads can run at once, up from 16.
- Mac: automatic mode climbs in bigger steps, no longer stops after one slow batch, and tries a higher level again later in a long run.

## 0.6.0 (2026-11-05)

- Mac: back up the same albums to several Google accounts. Each account has its own sign-in and its own record (#49).
- Mac: send backups to all accounts or only the ones you tick, or back up once to a single account.
- Mac: faster uploads. The next batch is prepared while one uploads, one uploader serves the whole run, and parallel uploads adapt to your connection (#50).
- Mac: album safeguards. Hidden photos never go into an album or to any account but the first. More than 25 photos for an existing album wait for you. Photos you removed from a Google album are not put back.
- Upgrading: macOS may ask once whether the app may use its keychain item. Choose Always Allow.

## 0.5.7 (2026-10-27)

- Mac: photos chosen with Choose Photos from the Hidden album now back up. macOS keeps hidden photos from apps, so the app uploads the file the photo picker hands over (#46).
- Mac: such photos keep their capture date, read from the file itself.

## 0.5.6 (2026-10-27)

- Mac: a first fix for photos picked from the Hidden album failing as "No longer in the Photos library" (#46). It did not cover every case; 0.5.7 finished it.

## 0.5.5 (2026-10-27)

- Adding photos to an album no longer gives up on a passing "500" or "503" error from Google. The app waits a few seconds and tries again (#44).
- On Windows this covers adding to existing albums; creating a new album there is unchanged.

## 0.5.4 (2026-10-27)

- Mac: albums no longer stop filling with "404 Not Found" when one photo in a batch has gone from Google Photos. The other photos are added and the missing ones uploaded again (#42).
- Mac: burst photos added to an album one by one now back up.
- Mac: a photo deleted in Google Photos but still in a backed-up album is uploaded again the next time that album is updated.

## 0.5.3 (2026-10-26)

- Large backups no longer stall with "The uploader stopped unexpectedly (exit 0)". About one Google media key in 14,000 was misread (#40). Use Retry Failed for items that failed this way.
- Uploader output the app cannot read is now written to the log instead of being dropped.

## 0.5.2 (2026-10-26)

- Albums fill completely. Since 0.2.0, an existing Google album only ever got its first batch of photos (#38).
- Photos that were backed up but left out of their album are added on the next backup.

## 0.5.1 (2026-10-25)

- Mac: opening the Connected device page no longer leaves the window blank (#36).

## 0.5.0 (2026-10-16)

- Mac: import photos from a connected iPhone or camera.
- Windows: import from connected phones and cameras, and optionally from an Android phone over wireless ADB.
- Android: choose device folders and mirror their names as Google albums.
- Experimental iCloud clean-up: after checking the Google copy byte for byte, move iCloud items to Recently Deleted. Off by default.
- Fixes for Android layout and large text, and for Windows folders it could not read, repeated devices and long paths.

## 0.4.0 (2026-10-15)

- The first Android app: back up the photos and videos you select.
- Windows installers for ARM64 and x64, a fix for the collapsed navigation bar on Windows, and a new icon on every platform.
- A live test on all three platforms showed Original quality without using account storage, and the downloaded originals matched.

## 0.3.0 (2026-10-14)

- Back up straight from iCloud Photos, with two-factor sign-in and its own menu bar controls on the Mac.
- The first Windows preview, as an x64 ZIP.

## 0.2.0 (2026-10-14)

- The first release, for the Mac: back up Apple Photos albums to Google Photos, recreate the albums, resume interrupted uploads, and control it all from the menu bar or Shortcuts links.
- Optional backup of Messages photos and videos, and a readable local archive of your conversations.
