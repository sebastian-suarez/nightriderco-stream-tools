#!/bin/sh
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=13.0 -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework Security \
    "$native_dir/keychain-tool.m" -o "$native_dir/keychain-tool"
/bin/chmod 700 "$native_dir/keychain-tool"
# A stable signed executable is used by the login Keychain access control list.
/usr/bin/codesign --force --sign - --identifier com.nightriderco.keychain-tool "$native_dir/keychain-tool"
printf '%s\n' "Built the NIGHTRIDERCO Keychain helper."
