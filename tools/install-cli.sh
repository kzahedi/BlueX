#!/usr/bin/env bash
# tools/install-cli.sh
#
# Copy the freshly-built BlueX command-line tools (blueX-annotate, blueX-scrape)
# from Xcode's DerivedData into ~/.local/bin so they're on PATH. Safe to re-run
# after every CLI rebuild.

set -euo pipefail

DEST_DIR="${HOME}/.local/bin"
mkdir -p "$DEST_DIR"

BUILD_DIR="${HOME}/Library/Developer/Xcode/DerivedData/BlueX-"*"/Build/Products/Debug"

install_one() {
  local name="$1"
  local bin
  bin=$(find ${BUILD_DIR} -name "$name" -type f 2>/dev/null | head -1)
  if [[ -z "$bin" ]]; then
    echo "✗ $name not found in DerivedData. Build it first:" >&2
    echo "  xcodebuild build -project BlueX.xcodeproj -scheme ${name/blueX-/BlueX} -destination 'platform=macOS,arch=arm64'" >&2
    return 1
  fi
  # SYMLINK instead of cp: newer macOS (Sequoia+ with the provenance xattr)
  # SIGKILLs binaries that have been copied out of their build location when
  # they link statically-included SPM products via package-internal rpaths.
  # The original at DerivedData works; the bytewise-identical copy does not.
  # Symlinking sidesteps the check entirely and has a nice bonus: rebuilds
  # are picked up immediately without re-running this script.
  rm -f "$DEST_DIR/$name"
  ln -s "$bin" "$DEST_DIR/$name"
  echo "✓ symlinked: $DEST_DIR/$name → $bin"
}

install_one blueX-annotate || true
install_one blueX-scrape    || true

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    echo
    echo "NOTE: $DEST_DIR is not on your PATH."
    echo "Add this to your shell rc (~/.zshrc or ~/.bashrc):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "Then open a new terminal and you can run the CLIs."
    ;;
esac
