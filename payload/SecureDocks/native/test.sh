#!/bin/sh
set -eu
native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/nrc-keychain-tests.XXXXXX")
trap '/bin/rm -rf "$test_dir"' EXIT HUP INT TERM
/usr/bin/xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -framework Foundation -framework Security \
    "$native_dir/native-self-test.m" -o "$test_dir/native-self-test"
/usr/bin/codesign --force --sign - --identifier com.nightriderco.keychain-self-test "$test_dir/native-self-test"
"$test_dir/native-self-test" "$test_dir/isolated.keychain"
