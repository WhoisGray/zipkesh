#!/bin/bash
# CI-safe install checks: never write into the real login user's Library.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { printf 'Run this check on macOS.\n' >&2; exit 1; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/work"
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/zipkesh-check.XXXXXX")
trap 'rm -rf -- "$TEST_HOME"' EXIT
BREW=$(command -v brew)
export HOMEBREW_NO_AUTO_UPDATE=1

# Keep Homebrew's real login HOME; redirect HOME only for Zipkesh's file paths.
# The wrapper makes its identity explicit rather than installing Homebrew again.
mkdir -p "$TEST_HOME/bin"
{
    printf '#!/bin/bash\n'
    printf 'export HOME=%q\nexec %q "$@"\n' "$HOME" "$BREW"
} > "$TEST_HOME/bin/brew"
chmod 700 "$TEST_HOME/bin/brew"
(
    export HOME="$TEST_HOME" PATH="$TEST_HOME/bin:$PATH"
    bash "$ROOT/install.sh"
    HELPER="$HOME/Library/Application Support/Zipkesh/current/zipkesh-ui"
    "$HELPER" --smoke-test
    /usr/bin/plutil -lint "$HOME/Library/Services/Zipkesh.workflow/Contents/Info.plist" \
        "$HOME/Library/Services/Zipkesh.workflow/Contents/document.wflow"
    # Repeat installation to cover service replacement and current symlink updates.
    bash "$ROOT/install.sh"
    test -L "$HOME/Library/Application Support/Zipkesh/current"
    test -x "$HOME/Library/Application Support/Zipkesh/current/zipkesh-ui"
    bash "$HOME/Library/Application Support/Zipkesh/current/uninstall.sh"
    test ! -e "$HOME/Library/Services/Zipkesh.workflow"
    test ! -e "$HOME/Library/Application Support/Zipkesh"
) 2>&1 | tee "$ROOT/work/macos-check.log"
printf 'Build, AppKit construction, workflow, reinstall and uninstall checks passed.\n'
