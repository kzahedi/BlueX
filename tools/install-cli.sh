#!/usr/bin/env bash
# tools/install-cli.sh
#
# Copy the freshly-built blueX-annotate binary from Xcode's DerivedData into
# ~/.local/bin so it's on PATH. Safe to re-run after every CLI rebuild.

set -euo pipefail

DEST_DIR="${HOME}/.local/bin"
mkdir -p "$DEST_DIR"

BIN=$(find "${HOME}/Library/Developer/Xcode/DerivedData/BlueX-"*"/Build/Products/Debug" \
        -name "blueX-annotate" -type f 2>/dev/null | head -1)

if [[ -z "$BIN" ]]; then
  echo "blueX-annotate binary not found. Build it first:" >&2
  echo "  xcodebuild build -project BlueX.xcodeproj -scheme BlueXAnnotate -destination 'platform=macOS,arch=arm64'" >&2
  exit 1
fi

cp "$BIN" "$DEST_DIR/blueX-annotate"
chmod +x "$DEST_DIR/blueX-annotate"

echo "installed: $DEST_DIR/blueX-annotate"
case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    echo
    echo "NOTE: $DEST_DIR is not on your PATH."
    echo "Add this to your shell rc (~/.zshrc or ~/.bashrc):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "Then open a new terminal and you can run: blueX-annotate --help"
    ;;
esac
