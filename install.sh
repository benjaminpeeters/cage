#!/usr/bin/env bash

# install.sh - Install cage CLI
# Same interpreter lookup as bin/cage, so the version check below tests the
# bash cage will actually run under (macOS: /bin/bash is 3.2)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"

echo "Installing cage CLI..."

# Check dependencies
echo "Checking dependencies..."

# Check for bash 4.3+ (namerefs: local -n)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "Error: bash 4.3+ is required (found $BASH_VERSION)"
    exit 1
fi

# Check for GNU getopt (returns exit code 4 when enhanced getopt is present).
# The probe must not run as a bare statement: under `set -e` its non-zero
# "success" code (4) would kill the script before the check below runs.
getopt_rc=0
getopt -T >/dev/null 2>&1 || getopt_rc=$?
if [ "$getopt_rc" -ne 4 ]; then
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

# Check for gum (interactive profile editor, resume picker, clean confirmation)
if ! command -v gum >/dev/null 2>&1; then
    echo "Warning: gum not found (needed by 'cage resume' picker, 'cage profile edit', 'cage clean')."
    echo "Install: https://github.com/charmbracelet/gum"
fi

# Check for batcat (cage tail renders logs through it)
if ! command -v batcat >/dev/null 2>&1; then
    echo "Warning: batcat not found (needed by 'cage tail'). Install the bat package."
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
