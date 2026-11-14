#!/bin/sh
#
# install.sh -- install turbod + turboctl.
#
#   sudo ./install.sh              normal install
#   sudo ./install.sh --status     just report what state things are in
#   sudo ./install.sh --recovery   one-time step, only needed for our own kext
#
# The privileged half is whichever kernel extension is available:
#
#   1. Turbo Boost Switcher's DisableTurboBoost.64bits.kext  (preferred)
#      It is covered by an existing per-machine allowance for its bundle
#      identifier, so it loads on a stock system with no csrutil change.
#
#   2. our own TurboLock.kext  (fallback)
#      Unsigned, so it needs a paid Developer ID or one boot with kext signing
#      relaxed (`sudo ./install.sh --recovery`).
#
# turbod picks the backend itself (see the backends[] table in turbod.c). This
# script only has to make sure at least one of them exists and actually loads.
#
set -eu

PREFIX=/usr/local/libexec/turbodisable
VAR_DIR=/usr/local/var/turbodisable
PLIST_DST=/Library/LaunchDaemons/com.turbodisable.turbod.plist
LABEL=com.turbodisable.turbod
KEXT_DST=/Library/Extensions/TurboLock.kext
KEXT_ID=com.turbodisable.TurboLock
TBS_ID=com.rugarciap.DisableTurboBoost
TBS_TEAM=A7JE7SS8Z7
TBS_HOME=https://www.rugarciap.com/
TBS_DMG_URL=${TBS_DMG_URL:-}       # override to pin a specific build
FETCH=auto                          # auto | never (--no-fetch)
FORCE_FETCH=${TBS_FORCE_FETCH:-0}   # 1 = download even if a copy is already on disk

SRC=$(cd "$(dirname "$0")" && pwd)

for _a in "$@"; do
    case "$_a" in
        --no-fetch)    FETCH=never ;;
        --force-fetch) FORCE_FETCH=1 ;;
    esac
done

need_root() {
    [ "$(id -u)" -eq 0 ] || { echo "install.sh: run me with sudo" >&2; exit 1; }
}

# Must mirror backends[] in turbod.c, or the daemon will disagree with us.
tbs_kext() {
    for p in \
        "/Applications/tbswitcher_resources/DisableTurboBoost.64bits.kext" \
        "/Library/StagedExtensions/Applications/tbswitcher_resources/DisableTurboBoost.64bits.kext" \
        "/Library/Extensions/DisableTurboBoost.64bits.kext"
    do
        [ -d "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

loaded() {   # $1 = bundle identifier
    kmutil showloaded --list-only --bundle-identifier "$1" 2>/dev/null | grep -q "$1"
}

sip_status() {
    _s=$(csrutil status 2>/dev/null) || { echo unknown; return; }
    case "$_s" in
        *"Kext Signing: disabled"*)                      echo relaxed ;;
        "System Integrity Protection status: disabled"*) echo "fully disabled" ;;
        *)                                               echo enforced ;;
    esac
}

backend_name() {
    if loaded "$TBS_ID"; then echo "TBS (loaded)"
    elif loaded "$KEXT_ID"; then echo "TurboLock (loaded)"
    elif tbs_kext >/dev/null; then echo "TBS (on disk)"
    elif [ -d "$KEXT_DST" ]; then echo "TurboLock (on disk)"
    else echo "none"; fi
}

report() {
    echo "  backend      : $(backend_name)"
    echo "  tbs kext     : $(tbs_kext 2>/dev/null || echo 'not installed')"
    echo "  our kext     : $([ -d "$KEXT_DST" ] && echo yes || echo no)"
    echo "  kext loaded  : $(loaded "$TBS_ID" || loaded "$KEXT_ID" && echo yes || echo no)"
    echo "  kext signing : $(sip_status)"
    echo "  daemon       : $(launchctl print system/$LABEL >/dev/null 2>&1 && echo running || echo stopped)"
    echo "  stored state : $(cat "$VAR_DIR/state" 2>/dev/null || echo unset)"
}

# --------------------------------------------------------------- --status ---
if [ "${1:-}" = "--status" ]; then
    need_root
    echo "turbodisable:"
    report
    echo
    if loaded "$TBS_ID" || loaded "$KEXT_ID"; then
        echo "turbo is currently $(cat "$VAR_DIR/state" 2>/dev/null || echo unknown)"
    elif tbs_kext >/dev/null; then
        echo "TBS kext present but not loaded -> daemon stopped, or reinstall TBS"
    elif [ -d "$KEXT_DST" ]; then
        echo "our kext present but not loaded -> approval pending, or daemon stopped"
    else
        echo "no backend on this machine; install Turbo Boost Switcher:"
        echo "  $TBS_HOME"
    fi
    exit 0
fi

# ------------------------------------------------------------- --recovery ---
# Only meaningful for our own kext. If TBS is installed we never get here.
if [ "${1:-}" = "--recovery" ]; then
    need_root
    if tbs_kext >/dev/null; then
        echo "TBS kext found -- the one-time approval is not needed."
        echo "Run 'sudo ./install.sh' and you're done."
        exit 0
    fi
    if [ "$(uname -m)" != "x86_64" ]; then
        cat >&2 <<'MSG'
Apple Silicon: shut down, then hold the power button until "Loading startup
options" appears, and choose Options. Then: Utilities > Terminal.
MSG
        exit 1
    fi
    echo "==> next boot will be Recovery"
    nvram "recovery-boot-mode=unused" || { echo "could not set NVRAM" >&2; exit 1; }
    cat <<'MSG'

  ============================================================
   In Recovery:  Utilities > Terminal, type exactly this:

       csrutil enable --without kext

   Then quit Terminal, Apple menu > Restart, and run:

       sudo ./install.sh

  ============================================================

  Rebooting in 10 seconds. Ctrl-C to cancel.

MSG
    sleep 10
    reboot
fi

# -------------------------------------------------------------- fetch TBS ---
# Downloads Turbo Boost Switcher, verifies it really is Rugarciap's notarized
# Developer ID build, mounts it, and installs only the kernel-extension
# component into /Applications. The GUI app is never installed or run.
#
# Verification is the point of this function: an installer that pipes a remote
# disk image into a root process is otherwise just trust-me-bro. We accept the
# download only if it is signed by team $TBS_TEAM and accepted by Gatekeeper.

TBS_MNT=
TBS_TMP=

cleanup_tbs() {
    [ -n "${TBS_MNT:-}" ] && hdiutil detach "$TBS_MNT" >/dev/null 2>&1 || true
    TBS_MNT=
    [ -n "${TBS_TMP:-}" ] && rm -rf "$TBS_TMP" || true
    TBS_TMP=
}
trap cleanup_tbs EXIT INT TERM

tbs_latest_url() {
    if [ -n "${TBS_DMG_URL:-}" ]; then echo "$TBS_DMG_URL"; return 0; fi
    curl -sSL --max-time 25 -A 'Mozilla/5.0' "$TBS_HOME" 2>/dev/null \
        | grep -oiE 'https?://[^"'"'"' <>]+Turbo_Boost_Switcher_v[0-9.]+\.dmg' \
        | sort -uV | tail -1
}

fetch_tbs() {
    url=$(tbs_latest_url)
    [ -n "$url" ] || { echo "    could not determine the download URL" >&2; return 1; }

    TBS_TMP=$(mktemp -d /tmp/turbodisable-tbs.XXXXXX) || return 1
    echo "    url    : $url"
    if ! curl -sSL --fail --max-time 300 "$url" -o "$TBS_TMP/tbs.dmg"; then
        echo "    download failed" >&2
        return 1
    fi
    echo "    bytes  : $(wc -c < "$TBS_TMP/tbs.dmg" | tr -d ' ')"
    echo "    sha256 : $(shasum -a 256 "$TBS_TMP/tbs.dmg" | cut -d' ' -f1)"

    mkdir -p "$TBS_TMP/mnt"
    if ! printf 'Y\n' | hdiutil attach "$TBS_TMP/tbs.dmg" -nobrowse -readonly \
            -mountpoint "$TBS_TMP/mnt" >/dev/null 2>&1; then
        echo "    could not mount the disk image" >&2
        return 1
    fi
    TBS_MNT=$TBS_TMP/mnt

    app=$(find "$TBS_MNT" -maxdepth 1 -name '*.app' 2>/dev/null | head -1)
    [ -n "$app" ] || { echo "    no .app in the image (vendor layout changed)" >&2; return 1; }

    team=$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)
    if [ "$team" != "$TBS_TEAM" ]; then
        echo "    REFUSING: signed by team '${team:-none}', expected $TBS_TEAM" >&2
        return 1
    fi
    if ! spctl -a -t exec "$app" >/dev/null 2>&1; then
        echo "    REFUSING: not notarized / not accepted by Gatekeeper" >&2
        return 1
    fi
    echo "    verified: Developer ID $team, notarized"

    kext=$(find "$TBS_MNT" -maxdepth 4 -name 'DisableTurboBoost.64bits.kext' 2>/dev/null | head -1)
    [ -n "$kext" ] || { echo "    no 64-bit kext in the image" >&2; return 1; }
    resdir=$(dirname "$kext")
    dest=/Applications/$(basename "$resdir")

    echo "    install: $dest"
    rm -rf "$dest"
    cp -R "$resdir" /Applications/
    chown -R root:wheel "$dest"
    chmod -R go-w "$dest"
    xattr -cr "$dest" 2>/dev/null || true

    hdiutil detach "$TBS_MNT" >/dev/null 2>&1 || true
    TBS_MNT=
    return 0
}

# ---------------------------------------------------------------- install ---
need_root

echo "==> building turbod and clocktest"
mkdir -p "$SRC/.build"
clang -O2 -Wall -o "$SRC/.build/turbod" "$SRC/turbod.c" \
      -framework IOKit -framework CoreFoundation
clang -O2 -o "$SRC/.build/clocktest" "$SRC/clocktest.c"

# Built even when TBS is the backend, so a copy can be kept in $PREFIX/kext as
# a fallback for when Turbo Boost Switcher is later removed.
echo "==> building TurboLock.kext (fallback)"
sh "$SRC/kext/build.sh" "$SRC/.build/TurboLock.kext" >/dev/null

# ------------------------------------------------ choose the kext backend --
TBS_PATH=$(tbs_kext 2>/dev/null || true)

if [ "$FETCH" = auto ] && { [ -z "$TBS_PATH" ] || [ "$FORCE_FETCH" = 1 ]; }; then
    echo "==> fetching Turbo Boost Switcher"
    if fetch_tbs; then
        TBS_PATH=$(tbs_kext 2>/dev/null || true)
    else
        echo "    fetch failed; falling back to TurboLock.kext" >&2
    fi
fi

if [ -n "$TBS_PATH" ]; then
    echo "==> backend: Turbo Boost Switcher"
    echo "    $TBS_PATH"
    if loaded "$TBS_ID"; then
        echo "    already loaded (turbo is disabled)"
    else
        LOAD_OUT=$(kextload -v "$TBS_PATH" 2>&1 || true)
        if ! loaded "$TBS_ID"; then
            cat >&2 <<MSG

--------------------------------------------------------------------------
Found the TBS kext but macOS would not load it:

    $(echo "$LOAD_OUT" | head -3)

Nothing else was changed. Reinstall Turbo Boost Switcher so its bundle is
approved for this machine, then run this script again:

    $TBS_HOME
--------------------------------------------------------------------------

MSG
            exit 1
        fi
        echo "    loaded (turbo is now disabled)"
    fi
else
    echo "==> backend: Turbo Boost Switcher not found"
    echo "    using TurboLock.kext as a fallback instead"

    echo "==> installing kext to $KEXT_DST (root:wheel, as the kernel demands)"
    rm -rf "$KEXT_DST"
    mkdir -p "$KEXT_DST/Contents/MacOS"
    cp "$SRC/.build/TurboLock.kext/Contents/Info.plist" "$KEXT_DST/Contents/Info.plist"
    cp "$SRC/.build/TurboLock.kext/Contents/MacOS/TurboLock" "$KEXT_DST/Contents/MacOS/TurboLock"
    chown -R root:wheel "$KEXT_DST"
    chmod 0755 "$KEXT_DST" "$KEXT_DST/Contents" "$KEXT_DST/Contents/MacOS"
    chmod 0644 "$KEXT_DST/Contents/Info.plist"
    chmod 0755 "$KEXT_DST/Contents/MacOS/TurboLock"
    xattr -cr "$KEXT_DST" 2>/dev/null || true

    echo "==> loading our kext"
    LOAD_OUT=$(kextload -v "$KEXT_DST" 2>&1 || true)
    if ! loaded "$KEXT_ID"; then
        cat >&2 <<'MSG'

--------------------------------------------------------------------------
TurboLock.kext is installed but macOS has not approved it yet, so it will
not load. Nothing else was changed.

Two ways forward:

  1. Install Turbo Boost Switcher instead -- its kext needs no approval:
       https://rugarciap.com/turbo-boost-switcher-for-osx/
     then run:  sudo ./install.sh

  2. Approve our kext once, with one boot into Recovery:
       sudo ./install.sh --recovery
     then in Recovery > Utilities > Terminal:  csrutil enable --without kext
     restart, and run:  sudo ./install.sh

--------------------------------------------------------------------------

MSG
        echo "kernel said:" >&2
        echo "$LOAD_OUT" | sed 's/^/    /' >&2
        exit 1
    fi
    echo "    approved and loaded (turbo is now disabled)"
fi

# --------------------------------------------------------- install daemon ---
echo "==> installing tools to $PREFIX"
install -d -o root -g wheel -m 0755 "$PREFIX"
install -o root -g wheel -m 0755 "$SRC/.build/turbod"    "$PREFIX/turbod"
install -o root -g wheel -m 0755 "$SRC/.build/clocktest" "$PREFIX/clocktest"
install -o root -g wheel -m 0755 "$SRC/turboctl"         "$PREFIX/turboctl"
install -o root -g wheel -m 0755 "$SRC/uninstall.sh"     "$PREFIX/uninstall.sh"
chmod -R go-w "$PREFIX"

# Keep a copy of our kext for the fallback backend, even when TBS is the one
# in use, so uninstalling TBS leaves us with something to fall back to.
if [ -d "$SRC/.build/TurboLock.kext" ]; then
    install -d -o root -g wheel -m 0755 "$PREFIX/kext"
    rm -rf "$PREFIX/kext/TurboLock.kext"
    cp -R "$SRC/.build/TurboLock.kext" "$PREFIX/kext/"
    chown -R root:wheel "$PREFIX/kext"
    chmod -R go-w "$PREFIX/kext"
fi

install -d -o root -g wheel -m 0775 "$VAR_DIR"
[ -f "$VAR_DIR/state" ] || { echo off > "$VAR_DIR/state"; chown root:wheel "$VAR_DIR/state"; }
: >> "$VAR_DIR/turbod.log"

echo "==> installing launch daemon"
install -o root -g wheel -m 0644 "$SRC/com.turbodisable.turbod.plist" "$PLIST_DST"
launchctl bootout system/"$LABEL" 2>/dev/null || true
launchctl enable  system/"$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
sleep 2
launchctl print system/"$LABEL" >/dev/null 2>&1 && echo "    daemon running"

[ -d /usr/local/bin ] && ln -sf "$PREFIX/turboctl" /usr/local/bin/turboctl

echo "==> applying stored state"
"$PREFIX/turbod" --apply-saved || true

echo
echo "==> verifying"
"$PREFIX/turboctl" status || true

echo
echo "==> doctor"
"$PREFIX/turbod" --probe 2>/dev/null || true

cat <<'EOF'

Done. From now on, no password is needed:

    turboctl off        disable Turbo Boost
    turboctl on         re-enable Turbo Boost
    turboctl status     show state + measured clock
    turboctl doctor     full diagnostics
EOF
