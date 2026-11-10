#!/bin/bash
set -e

# Builds and runs tests/AudioLockTests.m against the real AudioLock.m with
# plain clang. There is no Xcode test target: the logic under test needs only
# Foundation and CoreAudio, so this runs in a couple of seconds.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

clang -fobjc-arc -Wall -Werror -ILockAudio \
    -framework Foundation -framework CoreAudio \
    LockAudio/AudioLock.m tests/AudioLockTests.m -o "$OUT/audiolock-tests"

"$OUT/audiolock-tests"
