#!/bin/bash
# Build OpenVM.app: compile with SwiftPM, wrap in a bundle, sign with the
# virtualization entitlement. Ad-hoc signing ("-") is enough for local use.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${CODESIGN_IDENTITY:--}"
APP="build/OpenVM.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/OpenVM"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenVM"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Vendors' logos shown in the new-VM gallery (see tools/prepare-logo.swift).
mkdir -p "$APP/Contents/Resources/OSLogos" && cp Resources/OSLogos/*.png "$APP/Contents/Resources/OSLogos/"

# App icon: Apple's Icon Composer format, compiled by actool into Assets.car (what macOS 26 renders
# natively, without the gray plate it puts under older .icns icons) plus a fallback AppIcon.icns.
# The artwork must be a full-bleed 1024x1024 square; tools/fill-corners.swift produces one from
# Resources/AppIcon.png, whose rounded corners are transparent.
ICONOUT="$(mktemp -d)"
if xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$ICONOUT" --output-format human-readable-text \
  --notices --warnings --errors --output-partial-info-plist "$ICONOUT/partial.plist" \
  --app-icon AppIcon --include-all-app-icons --target-device mac --minimum-deployment-target 26.0 \
  --platform macosx >/dev/null 2>&1 && [ -f "$ICONOUT/Assets.car" ] && [ -f "$ICONOUT/AppIcon.icns" ]; then
  cp "$ICONOUT/Assets.car" "$ICONOUT/AppIcon.icns" "$APP/Contents/Resources/"
else
  # Older Xcode without Icon Composer support: build a classic .icns from the PNG instead.
  # (macOS 26 shows such an icon on a gray plate; everything else renders it normally.)
  echo "warning: actool could not compile AppIcon.icon; falling back to iconutil" >&2
  SET="$ICONOUT/AppIcon.iconset"; mkdir -p "$SET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Finder/Spotlight can attach metadata to a freshly written bundle (notably right after the icon is
# added), which makes codesign refuse it. Clear it and retry until the signature sticks.
signed=false
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP"
  if codesign --force --options runtime --entitlements Resources/OpenVM.entitlements --sign "$IDENTITY" "$APP"; then
    signed=true; break
  fi
  echo "codesign attempt $attempt failed; retrying" >&2
  sleep 1
done
$signed || { echo "ERROR: could not sign $APP" >&2; exit 1; }
codesign --verify --verbose=2 "$APP"
# A bundle without the virtualization entitlement builds fine but cannot start any VM.
codesign -d --entitlements - "$APP" 2>&1 | grep -q "com.apple.security.virtualization" \
  || { echo "ERROR: $APP is missing the virtualization entitlement" >&2; exit 1; }
# Command-line front end: same binary, routed by its first argument (see main.swift).
ln -sf OpenVM.app/Contents/MacOS/OpenVM build/openvmctl
echo "Built $APP and build/openvmctl"
