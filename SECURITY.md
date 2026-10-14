# Security reports

Report suspected vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/ayush5harma/google-photos-backup/security/advisories/new).
Do not post tokens, account credentials, private page content, photographs,
Messages attachments, Messages archives, or unredacted logs in public issues.

Include the affected version or commit, the steps to reproduce with synthetic
data, and the expected impact. Share only the minimum information needed to
understand the issue. There is no guaranteed response time.

## What the app holds

- **The Google credential.** `auth_data` contains a long-lived Google master
  token. It is stored in the login Keychain (this device only, after first
  unlock) and handed to the uploader over a pipe, never in arguments or the
  environment. Treat a leaked token as a leaked password and sign out of the
  device in your Google account.
- **The Messages archive.** When you turn it on, the app writes private message
  text, attachments and dated copies of Messages' own database to a folder you
  choose (default `~/Documents/Messages Archive`). Folders are created 0700 and
  files 0600, but the folder is a normal folder: if you point it at a synced or
  shared location, whoever can read that location can read your messages. It is
  never uploaded by this app. The Messages features need Full Disk Access.
- **Logs and reports.** The timeline and the diagnostic report redact tokens,
  addresses, phone numbers, staging paths and your home folder's name, but read a
  report before you attach it.

The uploader is an unofficial Google Photos client; see the README.
