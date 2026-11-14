#!/bin/sh
#
# uninstall.sh -- remove turbod/turboctl and our own kext, restoring turbo.
# Turbo Boost Switcher, if installed, is left alone.
#
set -u

PREFIX=/usr/local/libexec/turbodisable
VAR_DIR=/usr/local/var/turbodisable
PLIST=/Library/LaunchDaemons/com.turbodisable.turbod.plist
LABEL=com.turbodisable.turbod
KEXT_ID=com.turbodisable.TurboLock
KEXT_DIR=/Library/Extensions/TurboLock.kext
TBS_ID=com.rugarciap.DisableTurboBoost

[ "$(id -u)" -eq 0 ] || { echo "uninstall.sh: run me with sudo" >&2; exit 1; }

echo "==> stopping daemon"
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -f /var/run/turbodisable.sock

echo "==> unloading kext (this restores Turbo Boost)"
for id in "$KEXT_ID" "$TBS_ID"; do
    if kmutil showloaded --list-only --bundle-identifier "$id" 2>/dev/null | grep -q "$id"; then
        kextunload -b "$id" 2>/dev/null \
            || kmutil unload --no-authorization --bundle-identifier "$id" 2>/dev/null \
            || echo "   ($id could not be unloaded; turbo returns on next reboot)"
    fi
done

echo "==> removing files"
rm -rf "$KEXT_DIR"
rm -f /usr/local/bin/turboctl
rm -rf "$PREFIX"
rm -rf "$VAR_DIR"

echo
echo "Removed. Turbo Boost is enabled again."
echo "Turbo Boost Switcher was not touched -- it is still installed and works"
echo "as before, password prompts and all."
echo
echo "If you relaxed kext signing for our own kext, you can restore full SIP:"
echo "reboot to Recovery and run    csrutil enable"
