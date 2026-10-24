#!/bin/zsh
# Baut CouchHost als Release und legt eine ZIP zum Weitergeben in dist/ ab.
# Nicht notarisiert: auf anderen Macs beim ersten Start
# Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen“.
# Log: share-host.log
cd "$(dirname "$0")"
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

TEAM="8K6F5K4NXG"

{
  set -e
  echo "▶ Erzeuge Xcode-Projekt …"
  xcodegen generate

  echo "▶ Baue CouchHost (Release) …"
  xcodebuild -project CouchRemote.xcodeproj -scheme CouchHost -configuration Release \
    -derivedDataPath build/release -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
    -quiet build

  APP=build/release/Build/Products/Release/CouchHost.app
  VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
  mkdir -p dist
  ZIP="dist/CouchHost-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  echo "✓ Fertig: $ZIP ($(du -h "$ZIP" | cut -f1))"
  open -R "$ZIP"
} 2>&1 | tee share-host.log
echo "EXIT=${pipestatus[1]}" >> share-host.log
