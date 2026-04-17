#!/bin/bash
# Build the rs-poseidon Rust crate as a static library and package it
# as an xcframework for use by the RailgunCrypto Swift package.
#
# Prerequisites: Rust toolchain (rustup.rs)
# Usage: scripts/build-rs-poseidon.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RS_DIR="$REPO_ROOT/vendor/rs-poseidon"
XCF_DIR="$RS_DIR/RsPoseidon.xcframework"
HEADER_SRC="$REPO_ROOT/vendor/rs-poseidon/include/cposeidon.h"

echo "Building rs-poseidon..."
cd "$RS_DIR"
cargo build --release

echo "Creating xcframework..."
rm -rf "$XCF_DIR"
xcodebuild -create-xcframework \
  -library "$RS_DIR/target/release/librs_poseidon.a" \
  -headers "$RS_DIR/include" \
  -output "$XCF_DIR"

# Add module map (xcodebuild doesn't generate one for C static libs)
HEADERS_DIR="$XCF_DIR/macos-arm64/Headers"
cat > "$HEADERS_DIR/module.modulemap" << 'EOF'
module RsPoseidon {
    header "cposeidon.h"
    export *
}
EOF

echo "Done: $XCF_DIR"
