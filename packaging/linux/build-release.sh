#!/usr/bin/env bash
# Build a Linux x86_64 release of Ghostty and package it as a .deb plus a
# portable tarball. Intended to run on Debian trixie (or the debian:trixie
# container used by the release workflow).
#
# Usage: build-release.sh <version>   e.g. build-release.sh 1.4.1
set -euo pipefail

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "usage: build-release.sh <version>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT_DIR/dist-out"
STAGE="$OUT/stage"
PREFIX="$STAGE/usr"
ROOT="$STAGE/root"

# Debian upstream versions may not contain a hyphen.
DEB_UPSTREAM=$(printf '%s' "$VERSION" | tr '-' '~')
DEB_VERSION="$DEB_UPSTREAM-1"
ARCH="amd64"
PKG="ghostty_$DEB_UPSTREAM-1_$ARCH.deb"
TARBALL="ghostty-$VERSION-linux-x86_64.tar.gz"

rm -rf "$STAGE"
mkdir -p "$PREFIX" "$ROOT"

echo "==> Building Ghostty $VERSION (ReleaseFast)"
cd "$ROOT_DIR"
zig build \
  -Doptimize=ReleaseFast \
  -p "$PREFIX" \
  -fsys=freetype -fsys=fontconfig -fsys=libpng -fsys=zlib -fsys=oniguruma

if [ ! -x "$PREFIX/bin/ghostty" ]; then
  echo "error: build did not produce a ghostty binary" >&2
  exit 1
fi

echo "==> Staging Debian package tree"
mkdir -p "$ROOT/usr/bin" "$ROOT/usr/lib/systemd/user" "$ROOT/usr/share/doc/ghostty"
cp -a "$PREFIX/bin/." "$ROOT/usr/bin/"
for d in applications ghostty icons locale metainfo dbus-1 bash-completion fish zsh vim nvim bat kio nautilus-python terminfo; do
  if [ -d "$PREFIX/share/$d" ]; then
    cp -a "$PREFIX/share/$d" "$ROOT/usr/share/"
  fi
done
# Upstream installs the systemd user unit under share/; Debian wants lib/.
UNIT="$PREFIX/share/systemd/user/app-com.mitchellh.ghostty.service"
if [ -f "$UNIT" ]; then
  cp -a "$UNIT" "$ROOT/usr/lib/systemd/user/"
fi

# Drop development artifacts so this stays a runtime package.
rm -rf "$ROOT/usr/include" "$ROOT/usr/share/pkgconfig"
rm -f "$ROOT/usr/lib/libghostty-vt.so" "$ROOT/usr/lib/libghostty-vt.so.0" \
      "$ROOT/usr/lib/libghostty-vt.so.0.1.0" "$ROOT/usr/lib/libghostty-vt.a"

echo "==> Resolving runtime dependencies"
SHLIB_TMP="$(mktemp -d)"
mkdir -p "$SHLIB_TMP/debian"
cat > "$SHLIB_TMP/debian/control" <<'CONTROL'
Source: ghostty
Section: x11
Priority: optional
Maintainer: Ghostty release build <root@localhost>
Standards-Version: 4.7.0

Package: ghostty
Architecture: amd64
Description: placeholder
CONTROL
DEPS=$(cd "$SHLIB_TMP" && dpkg-shlibdeps -O "$ROOT/usr/bin/ghostty" 2>/dev/null \
  | sed -n 's/^shlibs:Depends=//p') || DEPS=""
rm -rf "$SHLIB_TMP"
if [ -z "$DEPS" ]; then
  DEPS="libadwaita-1-0, libc6, libegl1, libfontconfig1, libfreetype6, libglib2.0-0t64, libgtk-4-1, libgtk4-layer-shell0, libonig5, libwayland-client0, libx11-6"
fi

INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "$ROOT" | cut -f1)

mkdir -p "$ROOT/DEBIAN"
cat > "$ROOT/DEBIAN/control" <<EOF
Package: ghostty
Version: $DEB_VERSION
Architecture: $ARCH
Maintainer: Ghostty release build <root@localhost>
Installed-Size: $INSTALLED_SIZE
Depends: $DEPS
Recommends: ncurses-term
Suggests: nautilus-python
Section: x11
Priority: optional
Homepage: https://ghostty.org
Description: Fast, feature-rich, cross-platform terminal emulator
 Ghostty is a terminal emulator that differentiates itself by being
 fast, feature-rich, and native.
 .
 This package contains the GTK4/libadwaita application.
EOF

cp "$ROOT_DIR/packaging/linux/copyright" "$ROOT/usr/share/doc/ghostty/copyright"
printf 'ghostty (%s) unstable; urgency=medium\n\n  * Release build of Ghostty %s.\n\n -- Ghostty release build <root@localhost>  %s\n' \
  "$DEB_VERSION" "$VERSION" "$(date -u -R)" \
  | gzip -9n > "$ROOT/usr/share/doc/ghostty/changelog.Debian.gz"

cp "$ROOT_DIR/packaging/linux/postinst" "$ROOT/DEBIAN/postinst"
cp "$ROOT_DIR/packaging/linux/postrm" "$ROOT/DEBIAN/postrm"
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"
chmod 644 "$ROOT/DEBIAN/control" "$ROOT/usr/share/doc/ghostty/copyright" \
  "$ROOT/usr/share/doc/ghostty/changelog.Debian.gz"

( cd "$ROOT" && find . -path ./DEBIAN -prune -o -type f -print0 \
    | sort -z | xargs -0 md5sum > DEBIAN/md5sums )
chmod 644 "$ROOT/DEBIAN/md5sums"

echo "==> Building $PKG"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT/$PKG"

echo "==> Building $TARBALL"
tar -C "$PREFIX" -czf "$OUT/$TARBALL" .

rm -rf "$STAGE"

echo "==> Done"
ls -lh "$OUT/$PKG" "$OUT/$TARBALL"
