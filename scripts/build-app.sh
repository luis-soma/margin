#!/usr/bin/env bash
# Builds Margin.app from the Swift package.
#   scripts/build-app.sh            -> build/Margin.app
#   scripts/build-app.sh --install  -> also copies it to /Applications and launches it
#   MARGIN_RELEASE=1 scripts/build-app.sh -> a build to give away: no API keys, nothing
#     pointing back at this repo, signed ad hoc, never installed here
#     (scripts/package-release.sh wraps it in a disk image)
#
# To always install (one copy of Margin on this Mac, the one in /Applications):
#   git config margin.install true
# MARGIN_BUILD_ONLY=1 skips that, for tools that install the build themselves.
set -euo pipefail
cd "$(dirname "$0")/.."
RELEASE="${MARGIN_RELEASE:-0}"

# macOS draws the window buttons and other system chrome in the style of
# the SDK an app is built with. Build with the newest Xcode on this Mac, so
# Margin gets the current look rather than an older one.
sdk_version() { DEVELOPER_DIR="$1" xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0; }
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]; }
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  current="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
  best=""; best_version="$current"
  for xcode in /Applications/Xcode*.app; do
    [[ -d "$xcode/Contents/Developer" ]] || continue
    version="$(sdk_version "$xcode/Contents/Developer")"
    if newer "$version" "$best_version"; then best="$xcode/Contents/Developer"; best_version="$version"; fi
  done
  [[ -n "$best" ]] && export DEVELOPER_DIR="$best"
fi
SDK="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
echo "Building with the macOS $SDK SDK${DEVELOPER_DIR:+ ($DEVELOPER_DIR)}"
# A different SDK can't reuse the old build products.
mkdir -p .build
if [[ "$(cat .build/margin-sdk 2>/dev/null)" != "$SDK" ]]; then
  rm -rf .build/release .build/*-apple-macosx*/release 2>/dev/null || true
  echo "$SDK" > .build/margin-sdk
fi

if [[ "$RELEASE" == 1 ]] && swift build -c release --arch arm64 --arch x86_64; then
  # One app for Apple silicon and Intel Macs.
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c release
  BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP="build/Margin.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Margin" "$APP/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from the 1024px PNG.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Also as an asset catalog: newer macOS takes the icon for notifications
# from Assets.car (CFBundleIconName). Compiled with Xcode's actool when it
# works here, otherwise the copy CI compiled (Resources/Assets.car).
ACTOOL=""
if xcrun --find actool >/dev/null 2>&1; then
  ACTOOL="xcrun actool"
elif [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/actool ]]; then
  # Xcode is installed but xcode-select points at the Command Line Tools.
  ACTOOL="env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /Applications/Xcode.app/Contents/Developer/usr/bin/actool"
fi
ICON_CAR=0
if [[ -n "$ACTOOL" ]]; then
  XCASSETS="build/Assets.xcassets"
  rm -rf "$XCASSETS"
  mkdir -p "$XCASSETS/AppIcon.appiconset"
  echo '{"info":{"version":1,"author":"xcode"}}' > "$XCASSETS/Contents.json"
  IMAGES=""
  for size in 16 32 128 256 512; do
    cp "$ICONSET/icon_${size}x${size}.png" "$XCASSETS/AppIcon.appiconset/icon_${size}.png"
    cp "$ICONSET/icon_${size}x${size}@2x.png" "$XCASSETS/AppIcon.appiconset/icon_${size}@2x.png"
    IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"1x\",\"filename\":\"icon_${size}.png\"},"
    IMAGES="$IMAGES{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"2x\",\"filename\":\"icon_${size}@2x.png\"},"
  done
  echo "{\"images\":[${IMAGES%,}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$XCASSETS/AppIcon.appiconset/Contents.json"
  if $ACTOOL "$XCASSETS" --compile "$APP/Contents/Resources" --platform macosx \
      --minimum-deployment-target 13.0 --app-icon AppIcon \
      --output-partial-info-plist build/assets-info.plist >build/actool.log 2>&1 \
      && [[ -f "$APP/Contents/Resources/Assets.car" ]]; then
    ICON_CAR=1
    echo "Icon compiled into Assets.car."
  else
    echo "actool couldn't compile the icon ($(grep -m1 -i error build/actool.log || tail -1 build/actool.log)); using the prebuilt one."
  fi
fi
if [[ "$ICON_CAR" == 0 && -f Resources/Assets.car ]]; then
  cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"
  ICON_CAR=1
  echo "Icon from the prebuilt Assets.car."
fi
if [[ "$ICON_CAR" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconName AppIcon' "$APP/Contents/Info.plist"
fi

# A new build number every build, so macOS doesn't keep showing an icon it
# cached for an earlier build (notifications do this).
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || date +%s)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"

# Keys for the intelligence layer (Gemini, OpenAI), if the repo has them.
# Never in a release: whoever downloads Margin brings their own.
if [[ "$RELEASE" != 1 && -f Resources/ai-keys.json ]]; then
  cp Resources/ai-keys.json "$APP/Contents/Resources/ai-keys.json"
fi

# Fonts the app registers at launch (Mona Sans and Geist Mono).
if [[ -d Resources/Fonts ]]; then
  rm -rf "$APP/Contents/Resources/Fonts"
  cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
fi

# The demo projects (Settings → Demo): the repo's, or MARGIN_DEMO_DIR (a
# release ships the projects scripts/export-demo.py took from a real archive).
DEMO_DIR="${MARGIN_DEMO_DIR:-Resources/Demo}"
if [[ -d "$DEMO_DIR" ]]; then
  rm -rf "$APP/Contents/Resources/Demo"
  mkdir -p "$APP/Contents/Resources/Demo"
  cp "$DEMO_DIR/entries.json" "$DEMO_DIR/summaries.json" "$APP/Contents/Resources/Demo/" 2>/dev/null || true
  # What Margin worked out about the demo (cluster layout and names), if exported.
  for extra in map-arrangement.json map-edits.json pattern-names.json patterns.json embeddings.json; do
    if [[ -f "$DEMO_DIR/$extra" ]]; then cp "$DEMO_DIR/$extra" "$APP/Contents/Resources/Demo/"; fi
  done
  cp -R "$DEMO_DIR/images" "$APP/Contents/Resources/Demo/images"
  if [[ -d "$DEMO_DIR/sites" ]]; then cp -R "$DEMO_DIR/sites" "$APP/Contents/Resources/Demo/sites"; fi
fi

# Covers that ship with the app for the portfolio's projects.
if [[ -d Resources/Covers ]]; then
  rm -rf "$APP/Contents/Resources/Covers"
  cp -R Resources/Covers "$APP/Contents/Resources/Covers"
fi

# Remember where the repo lives and which commit this is, so Margin can
# update itself from its menu and tell when it's already up to date.
# (Not in a release: it would point at this Mac's folders.)
if [[ "$RELEASE" != 1 ]]; then
  pwd > "$APP/Contents/Resources/repo-path"
  git rev-parse HEAD > "$APP/Contents/Resources/commit" 2>/dev/null || true
fi

# Signing. macOS ties Screen Recording and Accessibility to the app's
# signature, and unsigned (ad hoc) builds lose them on every rebuild. So sign
# with a stable certificate: MARGIN_SIGN_IDENTITY if set, otherwise a local
# "Margin Dev" certificate kept in its own keychain (created once).
# MARGIN_STABLE_SIGNING=0 signs ad hoc instead.
if [[ "$RELEASE" == 1 ]]; then
  # The published app: no updater, demo switch or advanced settings.
  /usr/libexec/PlistBuddy -c 'Add :MarginRelease bool true' "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Set :MarginRelease true' "$APP/Contents/Info.plist"
  # Ad hoc: the stable certificate only means something on this Mac. Leaves
  # this Mac's permissions for the installed Margin alone.
  codesign --force --deep --sign - "$APP"
  echo "Built $APP (release: no API keys, signed ad hoc)"
  exit 0
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/margin-signing.keychain-db"
# The certificate this app was last signed with, so permissions are reset
# only when it really changes (once), never on an ordinary update.
STATE_DIR="$HOME/Library/Application Support/Margin"
LAST_IDENTITY="$STATE_DIR/signing-identity-$BUNDLE_ID"
mkdir -p "$STATE_DIR"
SIGN_ARGS=()
IDENTITY="${MARGIN_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" && "${MARGIN_STABLE_SIGNING:-1}" == 1 ]]; then
  if scripts/make-signing-cert.sh >/dev/null; then
    IDENTITY="$({ security find-identity -p codesigning "$SIGNING_KEYCHAIN" 2>/dev/null || true; } \
      | { grep '"Margin Dev"' || true; } | head -1 | awk '{print $2}')"
    SIGN_ARGS=(--keychain "$SIGNING_KEYCHAIN")
  else
    echo "Couldn't set up the Margin Dev certificate (see above)."
  fi
fi
if [[ -n "$IDENTITY" ]] && codesign --force --sign "$IDENTITY" "${SIGN_ARGS[@]}" "$APP"; then
  if [[ "$(cat "$LAST_IDENTITY" 2>/dev/null)" != "$IDENTITY" ]]; then
    # A new certificate (or the first stable build): what was allowed for
    # the old signature no longer applies, and a stale entry would show as
    # on without working. Clear it, once.
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "New signing certificate: allow Screen Recording and Accessibility once more. After that they stay."
    echo "$IDENTITY" > "$LAST_IDENTITY"
  fi
  echo "Signed with a stable certificate ($IDENTITY). Permissions will survive rebuilds."
else
  codesign --force --sign - "$APP"
  # The next stable build counts as a change of certificate.
  echo "adhoc" > "$LAST_IDENTITY"
  tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "WARNING: signed ad hoc, so macOS forgets Margin's permissions on every build. Screen Recording and Accessibility were reset."
fi
echo "Built $APP"

INSTALL=0
[[ "${1:-}" == "--install" ]] && INSTALL=1
if [[ -z "${MARGIN_BUILD_ONLY:-}" && "$(git config --get margin.install 2>/dev/null || true)" == "true" ]]; then
  INSTALL=1
fi
if [[ "$INSTALL" == 1 ]]; then
  osascript -e 'quit app "Margin"' 2>/dev/null || true
  # Wait for it to be gone, or opening the new copy fails (-600).
  for _ in $(seq 1 50); do pgrep -f "/Margin.app/Contents/MacOS/Margin" >/dev/null || break; sleep 0.1; done
  rm -rf /Applications/Margin.app
  cp -R "$APP" /Applications/
  # Tell macOS about the new copy, so its icon shows in notifications.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Margin.app >/dev/null 2>&1 || true
  rm -rf build/Margin.app  # one copy only, so macOS takes the icon from the installed one
  # Back on the right half of the screen, where it sits while we work on it.
  open /Applications/Margin.app --args --right-half
  echo "Installed to /Applications. Launch it any time from Spotlight: Margin"
fi
