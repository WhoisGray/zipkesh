# Security

Use ZIP AES-256 or 7z for private content. Legacy ZipCrypto has known attacks.
ZIP filenames, sizes and timestamps are visible. 7z encrypts the file listing.

Passwords enter the Python worker through an anonymous pipe, then reach 7-Zip
through an echo-disabled pseudo-terminal. They are not passed in arguments,
environment variables, config files or logs. Passwords exist in process memory;
Zipkesh does not promise memory zeroization or protection from local malware.

Copy is explicit. Zipkesh clears its clipboard item after 30 seconds, on normal
close or successful completion, only if the clipboard has not changed. Clipboard
history managers and other devices may retain copies. Force-quitting the helper
bypasses normal cleanup. No password recovery, telemetry or network calls occur
during archive creation. Installation uses GitHub, Apple and Homebrew services.

Temporary archives live in a private directory on the destination volume. An
archive is tested with 7-Zip before atomic publication without overwriting an
existing path. Cancellation removes unfinished output; a cancellation arriving
after publication can leave a complete archive. Abrupt power loss or SIGKILL may
leave a `.zipkesh-*` directory; inspect it before deleting it. Source files are
never intentionally changed. Concurrent source changes are not snapshotted.

ZIP passwords must be ASCII because of 7-Zip's ZIP implementation. 7z supports
Unicode passwords. Generated passwords use Python's cryptographic `secrets`
module: strong is 24 characters, long is 48; easy uses 16 unambiguous random
letters/digits in four groups. Easy is easier to type, not a dictionary password.

Symbolic links are stored as links. Extract only archives you trust, into a fresh
folder; links in untrusted archives may point elsewhere. The tool does not
preserve macOS resource forks, extended attributes, ACLs or Finder tags.

To report a vulnerability, use GitHub's private vulnerability reporting if the
repository owner has enabled it. Do not publish passwords or private files in
an issue. There is no formal security audit or guaranteed response SLA.
