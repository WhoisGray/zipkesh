#!/bin/bash
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { printf 'Zipkesh is a macOS service.\n' >&2; exit 1; }
rm -rf -- "$HOME/Library/Services/Zipkesh.workflow"
rm -rf -- "$HOME/Library/Application Support/Zipkesh"
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true
printf 'Zipkesh removed. Your archives, Homebrew and shared dependencies were kept.\n'
