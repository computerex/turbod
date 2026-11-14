#!/bin/sh
#
# build-package.sh -- build the self-contained installer package.
#
#   ./packaging/build-package.sh          -> dist/turbodisable-1.0.0.pkg
#   VERSION=1.2.0 ./packaging/build-package.sh
#
# Contains our kext, our daemon, our CLI. Nothing third-party.
# No root, no Apple account, no certificates needed to build it.
#
set -eu

SRC=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${VERSION:-1.0.0}
IDENTIFIER=${IDENTIFIER:-com.turbodisable.turbod}
DIST=${DIST:-$SRC/dist}
BUILD=$SRC/.build
ROOT=$BUILD/pkgroot
KEXT=TurboLock.kext

echo "==> building kext"
rm -rf "$BUILD"
mkdir -p "$BUILD"
sh "$SRC/kext/build.sh" "$BUILD/$KEXT" >/dev/null

echo "==> building turbod and clocktest"
clang -O2 -Wall -o "$BUILD/turbod" "$SRC/turbod.c" \
      -framework IOKit -framework CoreFoundation
clang -O2 -o "$BUILD/clocktest" "$SRC/clocktest.c"

echo "==> assembling payload"
rm -rf "$ROOT"
LIBEXEC=$ROOT/usr/local/libexec/turbodisable
mkdir -p "$ROOT/Library/Extensions" "$LIBEXEC/kext" \
         "$ROOT/Library/LaunchDaemons" "$ROOT/usr/local/var/turbodisable" \
         "$ROOT/usr/local/bin"

cp -R "$BUILD/$KEXT" "$ROOT/Library/Extensions/$KEXT"
cp -R "$BUILD/$KEXT" "$LIBEXEC/kext/$KEXT"

install -m 0755 "$BUILD/turbod"     "$LIBEXEC/turbod"
install -m 0755 "$BUILD/clocktest"  "$LIBEXEC/clocktest"
install -m 0755 "$SRC/turboctl"     "$LIBEXEC/turboctl"
install -m 0755 "$SRC/uninstall.sh" "$LIBEXEC/uninstall.sh"
install -m 0644 "$SRC/com.turbodisable.turbod.plist" "$ROOT/Library/LaunchDaemons/"
echo off > "$ROOT/usr/local/var/turbodisable/state"

ln -s /usr/local/libexec/turbodisable/turboctl "$ROOT/usr/local/bin/turboctl"

echo "==> fixing ownership and xattrs"
# The kernel validates ownership on every path inside the bundle.
find "$ROOT" -exec chown root:wheel {} \; 2>/dev/null || true
find "$ROOT" -exec chmod go-w {} \; 2>/dev/null || true
xattr -cr "$ROOT" 2>/dev/null || true

echo "==> building package"
mkdir -p "$DIST"
COMPONENT=$BUILD/turbodisable-component.pkg
pkgbuild \
    --root "$ROOT" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --scripts "$SRC/packaging/scripts" \
    --ownership recommended \
    --install-location / \
    "$COMPONENT"

PKG=$DIST/turbodisable-$VERSION.pkg
productbuild --package "$COMPONENT" "$PKG"

echo
echo "==> built $PKG"
echo
echo "Install with:   sudo installer -pkg $(basename "$PKG") -target /"
echo "or double-click it."
echo
echo "Unsigned by design -- no Apple Developer account is involved. The kext"
echo "needs a one-time local approval; the installer explains it in one line"
echo "and costs nothing:  see README, 'The one-time approval'."
echo
