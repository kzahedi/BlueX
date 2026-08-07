#!/usr/bin/env bash
# tools/install-cli.sh
#
# Build the BlueX command-line tools and put them on PATH at ~/.local/bin.
# Safe to re-run after every change.
#
# Builds into a STABLE derived-data path rather than Xcode's default. The default
# location is disposable: cleaning DerivedData on 2026-06 broke both symlinks and
# the nightly jobs failed silently for 61 days.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${HOME}/.local/share/bluex-build"
BUILD_DIR="${BUILD_ROOT}/Build/Products/Debug"
DEST_DIR="${HOME}/.local/bin"

mkdir -p "$DEST_DIR" "$BUILD_ROOT"

echo "==> building (derivedDataPath: $BUILD_ROOT)"
for scheme in BlueXAnnotate BlueXScrape BlueXAuthors; do
  xcodebuild build \
    -project "$REPO_ROOT/BlueX.xcodeproj" \
    -scheme "$scheme" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD_ROOT" \
    -quiet
  echo "  ✓ $scheme"
done

install_one() {
  local name="$1"
  local bin="$BUILD_DIR/$name"
  if [[ ! -f "$bin" ]]; then
    echo "✗ $name not found at $bin after a successful build." >&2
    return 1
  fi
  # SYMLINK instead of cp: newer macOS (Sequoia+ with the provenance xattr)
  # SIGKILLs binaries that have been copied out of their build location when
  # they link statically-included SPM products via package-internal rpaths.
  # The original at the build location works; the bytewise-identical copy does
  # not. Symlinking sidesteps the check entirely, and rebuilds are picked up
  # without re-running this script.
  ln -sfn "$bin" "$DEST_DIR/$name"
  echo "✓ symlinked: $DEST_DIR/$name → $bin"
}

install_one blueX-annotate
install_one blueX-scrape
install_one blueX-authors

case ":$PATH:" in
  *":$DEST_DIR:"*) ;;
  *)
    echo
    echo "NOTE: $DEST_DIR is not on your PATH."
    echo "Add this to your shell rc (~/.zshrc):"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
