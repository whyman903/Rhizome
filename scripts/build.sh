#!/usr/bin/env bash
set -euo pipefail

UPDATE_WORKSPACE=0
for arg in "$@"; do
  case "$arg" in
    --update) UPDATE_WORKSPACE=1 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT/Rhizome"
BUILD_ROOT="$ROOT/.build/rhizome"
DIST_ROOT="$ROOT/dist"
APP_BUNDLE="$DIST_ROOT/Rhizome.app"
SIDECAR_DIST="$BUILD_ROOT/sidecar-dist"
SIDECAR_BUILD="$BUILD_ROOT/sidecar-build"

rm -rf "$APP_BUNDLE" "$SIDECAR_DIST" "$SIDECAR_BUILD"
mkdir -p "$DIST_ROOT" "$SIDECAR_DIST" "$SIDECAR_BUILD"

echo "Building compile-bin sidecar..."
uv run pyinstaller "$APP_ROOT/support/compile-bin.spec" \
  --noconfirm \
  --distpath "$SIDECAR_DIST" \
  --workpath "$SIDECAR_BUILD"

echo "Building Rhizome executable..."
swift build --package-path "$APP_ROOT" -c release --product Rhizome >/dev/null
APP_BIN_DIR="$(swift build --package-path "$APP_ROOT" -c release --show-bin-path)"
APP_EXECUTABLE="$APP_BIN_DIR/Rhizome"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$APP_EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Rhizome"
cp "$APP_ROOT/support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_ROOT/support/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R "$APP_ROOT/Sources/RhizomeApp/Resources/web" "$APP_BUNDLE/Contents/Resources/web"
cp "$SIDECAR_DIST/compile-bin" "$APP_BUNDLE/Contents/Resources/compile-bin"
cp -R "$ROOT/compile/templates" "$APP_BUNDLE/Contents/Resources/templates"

chmod +x "$APP_BUNDLE/Contents/MacOS/Rhizome" "$APP_BUNDLE/Contents/Resources/compile-bin"

echo "Ad-hoc signing sidecar and app..."
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/compile-bin"
codesign --force --sign - --deep "$APP_BUNDLE"

echo "Built app bundle at: $APP_BUNDLE"

if [[ "$UPDATE_WORKSPACE" -eq 1 ]]; then
  DEV_WORKSPACE="${RHIZOME_DEV_WORKSPACE:-$HOME/wiki}"
  DEV_WORKSPACE="${DEV_WORKSPACE/#\~/$HOME}"
  if [[ -d "$DEV_WORKSPACE" ]]; then
    echo "Syncing Claude templates into $DEV_WORKSPACE..."
    uv run compile claude setup "$DEV_WORKSPACE" --force
  else
    echo "Wiki workspace $DEV_WORKSPACE is not a directory; skipping template sync."
  fi
else
  echo "Skipping Claude template sync (pass --update to refresh workspace)."
fi

if [[ -n "${RHIZOME_SKIP_LAUNCH:-}" || -n "${CI:-}" ]]; then
  echo "Skipping app launch (RHIZOME_SKIP_LAUNCH or CI is set)."
  exit 0
fi

echo "Launching Rhizome.app..."
pkill -f "$APP_BUNDLE/Contents/MacOS/Rhizome" >/dev/null 2>&1 || true
open "$APP_BUNDLE"
