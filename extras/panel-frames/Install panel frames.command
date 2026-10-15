#!/bin/zsh
set -eu
NRC_INSTALL_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
/usr/bin/python3 "$NRC_INSTALL_DIR/install.py"
printf '\nInstalled. Quit and reopen OBS after your stream to activate the panel frames.\n'
