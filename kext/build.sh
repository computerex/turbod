#!/bin/sh
#
# build.sh -- build TurboLock.kext using only the Xcode Command Line Tools.
#
#   ./kext/build.sh               -> kext/TurboLock.kext
#   ./kext/build.sh /tmp/out.kext
#
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
NAME=TurboLock
OUT=${1:-$SRC/$NAME.kext}

SDK=$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)
KERN=$SDK/System/Library/Frameworks/Kernel.framework

if [ ! -d "$KERN/Headers" ]; then
    echo "build.sh: Kernel.framework headers not found under $SDK" >&2
    echo "          install the Command Line Tools: xcode-select --install" >&2
    exit 1
fi

INCS="-I$KERN/Headers"
if [ -d "$KERN/PrivateHeaders" ]; then
    INCS="$INCS -I$KERN/PrivateHeaders"
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$SRC/Info.plist" "$OUT/Contents/Info.plist"

clang -mkernel -O2 -Wall \
      -fno-builtin -fno-common -fno-stack-protector \
      -nostdinc $INCS \
      -c "$SRC/$NAME.c" -o "$OUT/Contents/MacOS/$NAME.o"

ld -kext -arch x86_64 -o "$OUT/Contents/MacOS/$NAME" "$OUT/Contents/MacOS/$NAME.o"
rm -f "$OUT/Contents/MacOS/$NAME.o"
chmod 0755 "$OUT/Contents/MacOS/$NAME"

file "$OUT/Contents/MacOS/$NAME"
nm -a "$OUT/Contents/MacOS/$NAME" | grep -E "_kmod_info|TurboLock_start|TurboLock_stop"
echo "rdmsr/wrmsr instructions: $(otool -tV "$OUT/Contents/MacOS/$NAME" | grep -cE '\b(rdmsr|wrmsr)\b')"
