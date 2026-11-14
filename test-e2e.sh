#!/bin/sh
#
# test-e2e.sh -- exercise the whole install path from scratch, including the
# Turbo Boost Switcher download. Root required. Reversible.
#
#   sudo ./test-e2e.sh            run the test
#   sudo ./test-e2e.sh --restore  put the previous resources back
#
# What it does:
#   1. moves /Applications/tbswitcher_resources aside (to /tmp, not deleted)
#   2. unloads the TBS kext, so turbo is genuinely ENABLED before we start
#   3. runs install.sh --force-fetch, forcing the download even though a
#      staged copy still exists under /Library/StagedExtensions
#   4. verifies the fetched kext is installed and actually loads
#
# Step 3 is the interesting one: it proves whether a *freshly downloaded*
# kext loads, or whether only the previously-staged one does.
#
set -u

SRC=$(cd "$(dirname "$0")" && pwd)
TBS_ID=com.rugarciap.DisableTurboBoost
RES=/Applications/tbswitcher_resources
LABEL=com.turbodisable.turbod
STAMP=$(date +%Y%m%d-%H%M%S)
BAK=/tmp/tbswitcher_resources.bak.$STAMP

say()    { printf '\n===== %s =====\n' "$*"; }
loaded() { kmutil showloaded --list-only --bundle-identifier "$TBS_ID" 2>/dev/null | grep -q "$TBS_ID"; }
daemon() { launchctl print system/$LABEL >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || { echo "test-e2e.sh: run me with sudo" >&2; exit 1; }

# --------------------------------------------------------------- --restore --
if [ "${1:-}" = "--restore" ]; then
    new=$(ls -dt /tmp/tbswitcher_resources.bak.* 2>/dev/null | head -1)
    [ -n "${new:-}" ] || { echo "no backup found under /tmp" >&2; exit 1; }
    echo "==> restoring $new"
    [ -d "$RES" ] && rm -rf "$RES"
    mv "$new" "$RES" && echo "    -> $RES"
    echo
    echo "Now reload it:  sudo /usr/local/libexec/turbodisable/turbod --apply-saved"
    exit 0
fi

# ------------------------------------------------------------------ step 0 --
say "0. before"
echo "  loaded                    : $(loaded && echo yes || echo no)"
echo "  /Applications/tbswitcher_resources : $([ -d "$RES" ] && echo present || echo absent)"
echo "  staged copy               : $([ -d "/Library/StagedExtensions/Applications/tbswitcher_resources/DisableTurboBoost.64bits.kext" ] && echo present || echo absent)"

# ------------------------------------------------------------------ step 1 --
say "1. moving the existing resources aside"
if [ -d "$RES" ]; then
    mv "$RES" "$BAK" && echo "  moved -> $BAK"
else
    echo "  nothing to move"
fi

# ------------------------------------------------------------------ step 2 --
say "2. unloading the kext (turbo returns to ENABLED)"
if loaded; then
    kextunload -b "$TBS_ID" 2>&1 | sed 's/^/    /'
    loaded && kmutil unload --no-authorization --bundle-identifier "$TBS_ID" 2>&1 | sed 's/^/    /'
    sleep 1
fi
echo "  loaded now                : $(loaded && echo yes || echo no)"

# ------------------------------------------------------------------ step 3 --
say "3. install.sh --force-fetch"
"$SRC/install.sh" --force-fetch
RC=$?
echo
echo "  install.sh exit code      : $RC"

# ------------------------------------------------------------------ step 4 --
say "4. verification"
echo "  /Applications/tbswitcher_resources : $([ -d "$RES" ] && echo present || echo ABSENT)"
echo "  kext present on disk      : $([ -d "$RES/DisableTurboBoost.64bits.kext" ] && echo yes || echo NO)"
echo "  kext id                   : $(plutil -extract CFBundleIdentifier raw "$RES/DisableTurboBoost.64bits.kext/Contents/Info.plist" 2>/dev/null || echo '-')"
echo "  kext owner                : $(ls -ld "$RES/DisableTurboBoost.64bits.kext" 2>/dev/null | awk '{print $3":"$4}')"
echo "  kext loaded               : $(loaded && echo yes || echo NO)"
echo "  daemon                    : $(daemon && echo running || echo stopped)"
echo
"$SRC/turboctl" status 2>&1 | sed 's/^/  /' || true

# ------------------------------------------------------------------ result --
say "result"
if loaded && daemon; then
    echo "  PASS -- fetched kext installed and loaded, daemon up."
    echo "  turbo is currently $(loaded && echo DISABLED || echo ENABLED)."
else
    echo "  FAIL -- see the output above."
    [ "$RC" -ne 0 ] && echo "  install.sh returned $RC."
fi
echo
echo "  previous resources kept at: $BAK"
echo "  restore with             : sudo $SRC/test-e2e.sh --restore"
