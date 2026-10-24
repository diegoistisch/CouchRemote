#!/bin/zsh
# Baut CouchRemote, installiert die App auf dem gekoppelten iPhone und startet sie.
# Log: run-iphone.log
cd "$(dirname "$0")"
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

TEAM="8K6F5K4NXG"
DEVICE="YOUR-IPHONE-UDID"
BUNDLE="at.diego.couchremote.ios"

{
  set -e
  echo "▶ Erzeuge Xcode-Projekt …"
  xcodegen generate

  echo "▶ Baue CouchRemote für das iPhone …"
  xcodebuild -project CouchRemote.xcodeproj -scheme CouchRemote -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath build \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
    -quiet build

  APP="build/Build/Products/Debug-iphoneos/CouchRemote.app"
  echo "▶ Installiere auf dem iPhone …"
  xcrun devicectl device install app --device "$DEVICE" "$APP"

  echo "▶ Starte die App …"
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE"
  echo "✓ Fertig"
} 2>&1 | tee run-iphone.log
echo "EXIT=${pipestatus[1]}" >> run-iphone.log
