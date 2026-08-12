#!/usr/bin/env bash
# bootstrap.sh — one-time prep on a Mac. Installs XcodeGen if needed, generates
# the Xcode project, and builds the app ONCE for the simulator. The sweep then
# installs this prebuilt .app into every booted sim (never rebuilding per-sim).
#
# Safe to run on any Mac with Xcode + command line tools — no AWS required.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
DERIVED="$APP_DIR/build"
SCHEME="SimDensity"

log() { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[bootstrap] error:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

# --- XcodeGen: turns project.yml into SimDensity.xcodeproj (keeps a fragile
#     pbxproj out of git). Install via Homebrew if absent. ---
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    log "installing xcodegen via Homebrew..."
    brew install xcodegen
  else
    die "xcodegen not found and Homebrew unavailable. Install from https://github.com/yonaskolb/XcodeGen"
  fi
fi

log "generating Xcode project..."
( cd "$APP_DIR" && xcodegen generate )

log "building $SCHEME for iphonesimulator (Debug)..."
xcodebuild \
  -project "$APP_DIR/SimDensity.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "$DERIVED" \
  build \
  CODE_SIGNING_ALLOWED=NO | \
  { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || cat; }

APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"
[ -d "$APP_PATH" ] || die "expected app not found at $APP_PATH"

log "done. Built app:"
echo "$APP_PATH"
log "next: harness/sweep.sh --app \"$APP_PATH\" --levels \"1 2 4 8\""
