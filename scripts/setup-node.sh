#!/bin/bash
#
# Downloads a pinned Node.js binary to vendor/node/.
# Run this once after cloning, or after changing NODE_VERSION.
#
set -euo pipefail

NODE_VERSION="22.14.0"
VENDOR_DIR="$(cd "$(dirname "$0")/.." && pwd)/vendor/node"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    arm64|aarch64) NODE_ARCH="arm64" ;;
    x86_64)        NODE_ARCH="x64" ;;
    *)             echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

NODE_DIST="node-v${NODE_VERSION}-darwin-${NODE_ARCH}"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIST}.tar.gz"

if [ -f "$VENDOR_DIR/bin/node" ]; then
    EXISTING_VERSION=$("$VENDOR_DIR/bin/node" --version 2>/dev/null || echo "unknown")
    if [ "$EXISTING_VERSION" = "v${NODE_VERSION}" ]; then
        echo "Node.js v${NODE_VERSION} already installed at $VENDOR_DIR"
        exit 0
    fi
    echo "Replacing Node.js ${EXISTING_VERSION} with v${NODE_VERSION}..."
fi

echo "Downloading Node.js v${NODE_VERSION} (${NODE_ARCH})..."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

curl -fsSL "$NODE_URL" -o "$TMPDIR/node.tar.gz"
tar -xzf "$TMPDIR/node.tar.gz" -C "$TMPDIR"

# Replace vendor/node with the full distribution (preserving symlinks)
rm -rf "$VENDOR_DIR"
mv "$TMPDIR/$NODE_DIST" "$VENDOR_DIR"

# Remove files we don't need to keep the vendor dir smaller
rm -rf "$VENDOR_DIR/include" \
       "$VENDOR_DIR/share" \
       "$VENDOR_DIR/CHANGELOG.md" \
       "$VENDOR_DIR/README.md" \
       "$VENDOR_DIR/LICENSE"

echo "Node.js v${NODE_VERSION} installed to $VENDOR_DIR"
echo ""
echo "Next: install Node.js dependencies:"
echo "  cd nodejs-project && ../vendor/node/bin/npm install"
