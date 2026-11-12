#!/usr/bin/env bash
# Packages Margin to give away: one disk image with the app, an Applications
# shortcut, the Read Me and a template for the user's own API keys.
#   scripts/package-release.sh   -> dist/Margin.dmg
# The app inside has no API keys and nothing pointing back at this repo
# (MARGIN_RELEASE=1 in build-app.sh); this script checks that before packing.
set -euo pipefail
cd "$(dirname "$0")/.."

# The projects people start with: Umbrella and Margin, as they are in the
# demo archive on this Mac right now.
# On a Mac with a live demo archive, take it from there; elsewhere (GitHub's
# build servers) ship the demo that's in the repo.
DEMO_SOURCE="${MARGIN_DEMO_SOURCE:-$HOME/Library/Application Support/Margin/Demo}"
if [[ -f "$DEMO_SOURCE/entries.json" ]]; then
  python3 scripts/export-demo.py "$DEMO_SOURCE" build/release-demo Umbrella Margin
  DEMO_DIR=build/release-demo
else
  DEMO_DIR=Resources/Demo
fi
MARGIN_RELEASE=1 MARGIN_BUILD_ONLY=1 MARGIN_DEMO_DIR="$DEMO_DIR" scripts/build-app.sh
APP="build/Margin.app"

# Nothing private may ship.
for leak in ai-keys.json repo-path commit; do
  if [[ -e "$APP/Contents/Resources/$leak" ]]; then
    echo "Refusing to package: $leak is inside the app." >&2
    exit 1
  fi
done
KEYS="$(python3 -c 'import json; d=json.load(open("Resources/ai-keys.json")); print("\n".join(v for k, v in d.items() if k in ("gemini", "openai") and v))' 2>/dev/null || true)"
if [[ -n "$KEYS" ]]; then
  while IFS= read -r key; do
    if grep -rqF -- "$key" "$APP"; then
      echo "Refusing to package: an API key from Resources/ai-keys.json is inside the app." >&2
      exit 1
    fi
  done <<< "$KEYS"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="build/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/Margin.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/Release/README.md "$STAGE/README.md"
cp Resources/Release/ai-keys.example.json "$STAGE/ai-keys.example.json"

rm -f dist/Margin.dmg
hdiutil create -volname "Margin" -srcfolder "$STAGE" -ov -format UDZO dist/Margin.dmg >/dev/null
rm -rf "$STAGE" "$APP"   # one Margin on this Mac: the installed one
echo "Packaged dist/Margin.dmg (Margin $VERSION, $(du -h dist/Margin.dmg | cut -f1)): no API keys inside."
