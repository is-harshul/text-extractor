#!/usr/bin/env bash
# Build distributable installer for Text Extractor.
# Usage:
#   ./scripts/build-installer.sh              # universal macOS (arm64 + x86_64)
#   ./scripts/build-installer.sh arm64        # Apple silicon only
#   ./scripts/build-installer.sh x86_64       # Intel only
#   ./scripts/build-installer.sh host         # current host arch (fastest)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
TARGET_ARG="${1:-universal}"
PUBLISH="${PUBLISH:-0}"   # PUBLISH=1 -> upload to GitHub Release after build

echo "==> Text Extractor installer build"
echo "    root:   $ROOT"
echo "    target: $TARGET_ARG"

# --- preflight ---
command -v node >/dev/null   || { echo "node missing"; exit 1; }
command -v npm  >/dev/null   || { echo "npm missing"; exit 1; }
command -v cargo >/dev/null  || { echo "cargo missing — install Rust: https://rustup.rs"; exit 1; }

# --- deps ---
if [ ! -d node_modules ]; then
  echo "==> npm install"
  npm install
fi

OS="$(uname -s)"
BUNDLE_ARGS=()
RUST_TARGETS=()

case "$OS" in
  Darwin)
    case "$TARGET_ARG" in
      universal)
        RUST_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
        BUNDLE_ARGS=(--target universal-apple-darwin --bundles dmg)
        ;;
      arm64|aarch64)
        RUST_TARGETS=(aarch64-apple-darwin)
        BUNDLE_ARGS=(--target aarch64-apple-darwin --bundles dmg)
        ;;
      x86_64|intel)
        RUST_TARGETS=(x86_64-apple-darwin)
        BUNDLE_ARGS=(--target x86_64-apple-darwin --bundles dmg)
        ;;
      host)
        BUNDLE_ARGS=(--bundles dmg)
        ;;
      *) echo "unknown target: $TARGET_ARG"; exit 1 ;;
    esac
    for t in "${RUST_TARGETS[@]}"; do
      rustup target add "$t" >/dev/null
    done
    ;;
  Linux)
    BUNDLE_ARGS=(--bundles deb,appimage)
    ;;
  MINGW*|MSYS*|CYGWIN*)
    BUNDLE_ARGS=(--bundles msi,nsis)
    ;;
  *) echo "unsupported OS: $OS"; exit 1 ;;
esac

# --- build ---
echo "==> tauri build ${BUNDLE_ARGS[*]}"
npx tauri build "${BUNDLE_ARGS[@]}"

# --- collect ---
OUT="$ROOT/release"
rm -rf "$OUT"
mkdir -p "$OUT"

BUNDLE_ROOT="$ROOT/src-tauri/target"
find "$BUNDLE_ROOT" -type f \
  \( -name "*.dmg" -o -name "*.deb" -o -name "*.AppImage" \
     -o -name "*.msi" -o -name "*.exe" \) \
  -exec cp -v {} "$OUT/" \;

echo
echo "==> Done. Installers in: $OUT"
ls -lh "$OUT"

if [ "$OS" = "Darwin" ]; then
  cat <<'EOF'

NOTE for friends on macOS:
  App not signed/notarized. On first launch they'll see
  "cannot be opened because the developer cannot be verified".
  Fix: right-click the app -> Open -> Open. Or:
    xattr -dr com.apple.quarantine "/Applications/Text Extractor.app"
EOF
fi

# --- optional: publish to GitHub Release ---
if [ "$PUBLISH" = "1" ]; then
  command -v gh >/dev/null || { echo "gh CLI missing — brew install gh"; exit 1; }
  VERSION="$(node -p "require('./package.json').version")"
  TAG="v$VERSION"

  echo
  echo "==> Publishing to GitHub Release: $TAG"

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "WARN: working tree dirty. Commit before tagging for clean release."
  fi

  if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "    tag $TAG exists locally — skipping tag create"
  else
    git tag "$TAG"
    git push origin "$TAG"
  fi

  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "    release $TAG exists — uploading assets (clobber)"
    gh release upload "$TAG" "$OUT"/* --clobber
  else
    gh release create "$TAG" "$OUT"/* \
      --title "Text Extractor $TAG" \
      --notes "Built from $(git rev-parse --short HEAD). macOS users: right-click → Open on first launch (unsigned)."
  fi

  echo "==> Done. https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$TAG"
fi
