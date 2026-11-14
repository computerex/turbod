#!/bin/sh
#
# test-sandbox.sh -- end-to-end test of turbod's control socket.
#
# Needs no root and never touches the real kernel state: the daemon is built
# with sandboxed paths, and the stored state is pre-set to whatever the
# machine's current reality is, so no kext operation is attempted.
#
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
TD=${TMPDIR:-/tmp}/turbodisable-test.$$
SOCK=$TD.sock
BIN=$TD/turbod
KEXT_ID=com.turbodisable.TurboLock
TBS_ID=com.rugarciap.DisableTurboBoost

PID=
cleanup() {
    [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
    rm -rf "$TD" "$SOCK" "$BIN"
}
trap cleanup EXIT INT TERM

rm -rf "$TD" "$SOCK" "$BIN"
mkdir -p "$TD"

# Make the stored state agree with reality so the daemon stays hands-off.
# turbod accepts either backend, so mirror that here or the daemon will think
# the machine disagrees with it and try to act.
loaded() {
    kmutil showloaded --list-only --bundle-identifier "$1" 2>/dev/null | grep -q "$1"
}
if loaded "$TBS_ID" || loaded "$KEXT_ID"; then
    NOW=off
else
    NOW=on
fi
echo "$NOW" > "$TD/state"

echo "==> building sandboxed daemon"
clang -O2 -Wall -o "$BIN" "$SRC/turbod.c" \
      -framework IOKit -framework CoreFoundation \
      -DVAR_DIR="\"$TD\"" -DSOCK_PATH="\"$SOCK\""

echo "==> starting it"
"$BIN" > "$TD/out" 2>&1 &
PID=$!

i=0
while [ ! -S "$SOCK" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -S "$SOCK" ]; then
    echo "FAIL: control socket never appeared"
    cat "$TD/out" 2>/dev/null || true
    exit 1
fi

chk() {   # $1 = request, $2 = expected reply
    got=$(printf '%s\n' "$1" | nc -U -w 2 "$SOCK" || true)
    if [ "$got" = "$2" ]; then
        echo "ok   '$1' -> '$got'"
    else
        echo "FAIL '$1' -> '$got' (expected '$2')"
        exit 1
    fi
}

echo "==> exercising the protocol (machine state: turbo $NOW)"
chk ping   "ok pong"
chk status "ok $NOW"
chk bogus  "error unknown command"

if [ "$(ls -l "$SOCK" | cut -c1-10)" = "srw-rw----" ]; then
    echo "ok   socket mode is srw-rw----"
else
    echo "FAIL unexpected socket mode: $(ls -l "$SOCK" | cut -c1-10)"
    exit 1
fi

echo
echo "PASS"
