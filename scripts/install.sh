#!/usr/bin/env bash
# Regenerate, Release-build, install to /Applications, and launch Hush.
#
# Signing: ad-hoc (CODE_SIGN_IDENTITY="-" in project.yml) — no Apple Development
# identity exists on this machine (`security find-identity -v -p codesigning` →
# 0 valid identities). Ad-hoc signatures are NOT stable: the code signature changes
# every build, so macOS treats each rebuild as a different app — Accessibility,
# Input Monitoring and Microphone grants must be re-approved after every install.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

xcodebuild \
  -project Hush.xcodeproj \
  -scheme Hush \
  -configuration Release \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build

BUILT_APP=$(xcodebuild \
  -project Hush.xcodeproj \
  -scheme Hush \
  -configuration Release \
  -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null \
  | awk '/CONFIGURATION_BUILD_DIR =/{print $3; exit}')/Hush.app

if [ ! -d "$BUILT_APP" ]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

osascript -e 'quit app "Hush"' 2>/dev/null || true
sleep 1  # let the quit AppleEvent land before we replace + relaunch
rm -rf /Applications/Hush.app
cp -R "$BUILT_APP" /Applications/Hush.app
# Unregister the DerivedData copy so Spotlight/`open` resolve only /Applications.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$BUILT_APP" 2>/dev/null || true
open /Applications/Hush.app
echo "installed and launched /Applications/Hush.app"
