# Verification record and release checks

## Recorded for this source bundle

Verification was performed on **2026-11-17** in Linux with **Python
3.12.14** and the official **7-Zip 25.01 x64** executable. **24 tests passed with
zero skips**, including detached launching and the terminal password handoff.
This is worker/protocol evidence; it is not
evidence of macOS UI execution. See [VERIFICATION.txt](../VERIFICATION.txt) for the final bundled run.

Verified with real encrypted archives:

- ZIP AES-256, legacy ZipCrypto and 7z creation, integrity testing and extraction.
- Correct passwords succeed; wrong passwords fail; 7z hides the listing.
- Unicode filenames, spaces, quotes, newlines, leading `-`/`@`, hidden files,
  wildcard-like names, empty entries, symlinks and duplicate basenames in different parents.
- Unicode 7z passwords; clear rejection of unsupported Unicode ZIP passwords.
- Password generation, source deduplication, safe workflow shell quoting.
- Existing-path protection, an output creation race, cleanup on failure and cancellation,
  termination of the child process, and the JSON worker error protocol.

Not yet executed in the source-preparation environment:

- Swift compilation, the AppKit window, and macOS permissions.
- Installation on a clean Mac, Finder menu discovery and interaction.
- GitHub-hosted macOS jobs or release publication.

The repository includes CI checks for macOS compilation, AppKit construction,
workflow plist validation, install, reinstall and uninstall. Those are configured
checks, not already-passed checks. Publish only after they run successfully.

## Repeat automated checks

```sh
brew install 7zip python@3.13
python3 -m unittest discover -s tests -v
bash scripts/check-macos.sh
```

The Python suite works on Linux too. If 7-Zip is not on PATH, integration tests
are skipped; set `ZIPKESH_7ZZ=/absolute/path/to/7zz` to run them. A release needs
zero integration skips. `check-macos.sh` uses a temporary HOME for Zipkesh files,
keeps the real HOME for Homebrew, and removes the temporary install afterwards.

## Manual macOS release checklist

Use dummy files, not your only copy of something important. Record the macOS
version, CPU architecture and outcomes below after running these checks.

- [ ] Install locally with `bash install.sh`; check permission/CLT prompts on a clean Mac.
- [ ] Select one file, several files, a folder, and mixed files/folders in Finder.
- [ ] Confirm the service appears under Quick Actions or Services and receives every selection.
- [ ] Verify both light and dark appearance; labels and buttons fit the window.
- [ ] Generate all three password styles; toggle Show; edit your own password.
- [ ] Copy a password; confirm clearing after 30 seconds and on normal close.
- [ ] Copy other text after the password; confirm Zipkesh leaves the new clipboard intact.
- [ ] Save each format; open it in Keka/7-Zip, verify content, and reject a wrong password.
- [ ] Confirm the 7z listing requires the password; ZIP listings remain visible.
- [ ] Try Persian filenames and a Persian 7z password; ZIP rejects a non-ASCII password clearly.
- [ ] Cancel the save sheet; cancel a large archive in progress; close while it runs.
- [ ] Choose an existing filename and a path inside a selected folder; confirm safe refusal.
- [ ] Try a read-denied source, a full disk, cloud placeholders and a protected location.
- [ ] Test Show in Finder, reinstall, log out/in if service caching needs it, and uninstall.
- [ ] Confirm original files remain intact and no unfinished output remains after normal cancellation.

| macOS | CPU | Automated CI URL | Manual test date/result |
| --- | --- | --- | --- |
| Not recorded | Not recorded | Not run in source preparation | Pending |

The minimum target is macOS 13. A newer CI runner does not verify macOS 13;
include an older supported Mac in manual release testing when available.
