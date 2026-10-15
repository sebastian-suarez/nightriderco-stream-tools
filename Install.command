#!/bin/sh
set -eu
installer_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'Python 3 is required. Install it, then run this command again.' >&2
  exit 1
fi
exec python3 "$installer_root/install.py" "$@"
