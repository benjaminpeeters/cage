#!/bin/bash

# install.sh - Install cage CLI

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo "Installing cage CLI..."

# Check dependencies
echo "Checking dependencies..."

# Check for bash 4.0+
BASH_VERSION_NUM="${BASH_VERSION%%[^0-9]*}"
if [ "$BASH_VERSION_NUM" -lt 4 ]; then
    echo "Warning: bash 4.0+ recommended (found $BASH_VERSION)"
fi

# Check for GNU getopt (returns exit code 4 when enhanced getopt is present)
getopt -T >/dev/null 2>&1
if [ $? -ne 4 ]; then
    echo "Warning: GNU getopt not found."
    echo "On macOS: brew install gnu-getopt"
    echo "Then add to your shell config:"
    echo "  export PATH=\"/usr/local/opt/gnu-getopt/bin:\$PATH\""
fi

# Check for jq
if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found. Install with your package manager."
fi

# Check for uuidgen
if ! command -v uuidgen >/dev/null 2>&1; then
    echo "Warning: uuidgen not found. Install with your package manager."
fi

# Create bin directory if needed
mkdir -p "$BIN_DIR"

# Create symlink
ln -sf "$SCRIPT_DIR/bin/cage" "$BIN_DIR/cage"

echo "✓ Installed: $BIN_DIR/cage -> $SCRIPT_DIR/bin/cage"
echo ""
echo "Make sure $BIN_DIR is in your PATH."
echo "Add to ~/.bashrc or ~/.zshrc if needed:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
