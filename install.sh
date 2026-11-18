#!/bin/bash
# Local or remote installer. bash 3.2 compatible; no sudo for Zipkesh files.
set -euo pipefail
umask 077

REPOSITORY=whoisGray/zipkesh
PREFIX="${HOME}/Library/Application Support/Zipkesh"
SERVICES="${HOME}/Library/Services"
SERVICE="${SERVICES}/Zipkesh.workflow"
TEMP_ROOT=""
STAGE=""

die() { printf 'Zipkesh: %s\n' "$*" >&2; exit 1; }
cleanup() {
    [ -z "$STAGE" ] || rm -rf -- "$STAGE"
    [ -z "$TEMP_ROOT" ] || rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

[ "$(uname -s)" = Darwin ] || die 'macOS 13 or newer is required.'
MAJOR=$(/usr/bin/sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 13 ] || die 'macOS 13 or newer is required.'

SOURCE=""
TAG=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ ! -f "$SOURCE/Sources/Zipkesh.swift" ] || [ ! -f "$SOURCE/zipkesh/engine.py" ]; then
    TEMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/zipkesh-download.XXXXXX")
    RELEASE_URL=$(/usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        --silent --show-error --output /dev/null --write-out '%{url_effective}' \
        "https://github.com/${REPOSITORY}/releases/latest") || die 'Could not resolve the latest published release.'
    TAG=${RELEASE_URL##*/}
    [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Latest release has an unsupported version tag.'
    printf 'Downloading Zipkesh %s…\n' "$TAG"
    /usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        "https://codeload.github.com/${REPOSITORY}/tar.gz/refs/tags/${TAG}" -o "$TEMP_ROOT/source.tar.gz"
    SOURCE="$TEMP_ROOT/source"
    mkdir -p "$SOURCE"
    /usr/bin/tar -xzf "$TEMP_ROOT/source.tar.gz" --strip-components=1 -C "$SOURCE"
    [ -f "$SOURCE/Sources/Zipkesh.swift" ] || die 'Source archive is incomplete.'
fi
VERSION=$(cat "$SOURCE/VERSION") || die 'Source version is missing.'
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Source version is invalid.'
if [ -n "${TAG:-}" ] && [ "$TAG" != "v$VERSION" ]; then
    die 'Release tag does not match the source version.'
fi

# Homebrew's installer handles Command Line Tools and may request your login
# password. It reads /dev/tty, so this also works from bash -c "$(curl …)".
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
    printf 'Apple Command Line Tools are needed. macOS may show an installation dialog.\n'
fi
BREW=""
if command -v brew >/dev/null 2>&1; then BREW=$(command -v brew); fi
if [ -z "$BREW" ]; then
    for CANDIDATE in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$CANDIDATE" ]; then BREW="$CANDIDATE"; break; fi
    done
fi
if [ -z "$BREW" ]; then
    printf 'Installing Homebrew from its official installer…\n'
    BREW_INSTALL=$(/usr/bin/curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)
    /bin/bash -c "$BREW_INSTALL"
    if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew;
    elif [ -x /usr/local/bin/brew ]; then BREW=/usr/local/bin/brew;
    else die 'Homebrew installation did not finish. Install it, then re-run this command.'; fi
fi
/usr/bin/xcrun --find swiftc >/dev/null 2>&1 || die 'Finish installing Apple Command Line Tools, then re-run this command.'
printf 'Checking dependencies (7zip and Python 3)…\n'
"$BREW" install 7zip python@3.13
SEVENZIP="$("$BREW" --prefix 7zip)/bin/7zz"
PYTHON="$("$BREW" --prefix python@3.13)/bin/python3.13"
if [ ! -x "$SEVENZIP" ] || [ ! -x "$PYTHON" ]; then die 'A required dependency is missing.'; fi

mkdir -p -- "$PREFIX/versions" "$SERVICES"
STAGE=$(mktemp -d "$PREFIX/versions/.install.XXXXXX")
printf 'Building the native Finder window…\n'
/usr/bin/xcrun swiftc -O -framework AppKit -target "$(uname -m)-apple-macosx13.0" \
    "$SOURCE/Sources/Zipkesh.swift" -o "$STAGE/zipkesh-ui"
cp -- "$SOURCE/zipkesh/engine.py" "$STAGE/engine.py"
cp -- "$SOURCE/zipkesh/launch.py" "$STAGE/launch.py"
cp -- "$SOURCE/uninstall.sh" "$STAGE/uninstall.sh"
printf '%s\n' "$VERSION" > "$STAGE/VERSION"
FINAL="$PREFIX/versions/${VERSION}-$(date +%Y%m%d%H%M%S)-$$"
mv -- "$STAGE" "$FINAL"
STAGE=""
{
    printf '#!/bin/bash\nset -euo pipefail\n'
    printf 'exec %q %q %q --python %q --backend %q --sevenzip %q -- "$@"\n' \
        "$PYTHON" "$FINAL/launch.py" "$FINAL/zipkesh-ui" "$PYTHON" "$FINAL/engine.py" "$SEVENZIP"
} > "$FINAL/launch"
chmod 700 "$FINAL/launch" "$FINAL/zipkesh-ui" "$FINAL/uninstall.sh"
"$PYTHON" "$SOURCE/scripts/make_workflow.py" "$FINAL/Zipkesh.workflow" "$FINAL/launch"
/usr/bin/plutil -lint "$FINAL/Zipkesh.workflow/Contents/Info.plist" \
    "$FINAL/Zipkesh.workflow/Contents/document.wflow" >/dev/null
"$PYTHON" "$FINAL/engine.py" --generate strong >/dev/null

# Prepare the new workflow before moving the old one. Restore on failure.
PENDING="$SERVICES/.Zipkesh-new-$$.workflow"
BACKUP="$SERVICES/.Zipkesh-old-$$.workflow"
cp -R -- "$FINAL/Zipkesh.workflow" "$PENDING"
if [ -e "$SERVICE" ] || [ -L "$SERVICE" ]; then mv -- "$SERVICE" "$BACKUP"; fi
if ! mv -- "$PENDING" "$SERVICE"; then
    [ ! -e "$BACKUP" ] || mv -- "$BACKUP" "$SERVICE"
    die 'Could not activate the Finder service.'
fi
rm -rf -- "$BACKUP"
ln -sfn "$FINAL" "$PREFIX/current"
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
printf '\nZipkesh v%s installed.\n' "$VERSION"
printf 'Finder → select files → right-click → Quick Actions / Services → Zipkesh — Encrypt Archive\n'
printf 'If hidden, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services.\n'
printf 'Uninstall: bash %q\n' "$PREFIX/current/uninstall.sh"
