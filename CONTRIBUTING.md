# Contributing

Keep Zipkesh a small Finder action. Prefer standard library code over packages.
Open an issue before adding formats or changing encryption defaults.

On macOS, install 7zip and Python 3.13 with Homebrew. Run:

```sh
python3 -m unittest discover -s tests -v
bash scripts/check-macos.sh
```

Use `ZIPKESH_7ZZ=/absolute/path/to/7zz` to select the test binary. A release needs
all integration tests to run; skipped integration tests are not release evidence.
The macOS check installs into a temporary home and removes it afterwards.
Interactive Finder and permission checks are described in [TESTING.md](docs/TESTING.md).

English and Persian documentation should describe the same behavior. Label
mockups as mockups. Never include real secrets, personal paths, or a passing CI
claim without a corresponding run.
