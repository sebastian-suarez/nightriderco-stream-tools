#!/bin/zsh
set -eu
NRC_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
/usr/bin/python3 -B "$NRC_ROOT/NIGHTRIDERCO-OBS-AUTOSTART/start-services.py"
print 'Open Chat Studio: http://127.0.0.1:3377'
print 'For the live typing buddy, open NIGHTRIDERCO-HUSKY/Husky Typist.app.'
