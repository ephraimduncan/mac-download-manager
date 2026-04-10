#!/usr/bin/env bash
set -euo pipefail

ARIA2_VERSION="1.37.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.cache"
CACHED_BINARY="$CACHE_DIR/aria2c"

if [[ -x "$CACHED_BINARY" ]]; then
    echo "aria2c already cached at $CACHED_BINARY"
    exit 0
fi

mkdir -p "$CACHE_DIR"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

TARBALL="$WORK_DIR/aria2-${ARIA2_VERSION}.tar.xz"
echo "Downloading aria2 ${ARIA2_VERSION}..."
curl -fsSL "https://github.com/aria2/aria2/releases/download/release-${ARIA2_VERSION}/aria2-${ARIA2_VERSION}.tar.xz" -o "$TARBALL"

echo "Extracting..."
tar -xf "$TARBALL" -C "$WORK_DIR"

SRC_DIR="$WORK_DIR/aria2-${ARIA2_VERSION}"
cd "$SRC_DIR"

echo "Configuring (Apple TLS, no external deps)..."
./configure \
    --without-openssl \
    --without-gnutls \
    --without-libssh2 \
    --without-sqlite3 \
    --without-libgcrypt \
    --without-libnettle \
    --with-appletls \
    --with-libxml2 \
    --disable-nls \
    --prefix=/dev/null \
    CXXFLAGS="-O2 -I$(xcrun --show-sdk-path)/usr/include/libxml2" \
    LDFLAGS="-lxml2" \
    > /dev/null

echo "Building ($(sysctl -n hw.ncpu) threads)..."
make -j"$(sysctl -n hw.ncpu)" > /dev/null

cp src/aria2c "$CACHED_BINARY"
echo "Built aria2c -> $CACHED_BINARY"
