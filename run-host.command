#!/bin/zsh
# Baut CouchHost und startet die App. Per Doppelklick im Finder ausführbar.
# Log: run-host.log
cd "$(dirname "$0")"
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

TEAM="8K6F5K4NXG"

{
  set -e
  if ! command -v xcodegen >/dev/null; then
    echo "▶ Installiere XcodeGen …"
    brew install xcodegen
  fi

  echo "▶ Teste RemoteKit …"
  if (cd RemoteKit && swift test 2>&1 | tail -15); then :; fi

  echo "▶ Erzeuge Xcode-Projekt …"
  xcodegen generate

  # Mit dem Entwicklerzertifikat signieren: dann bleibt die Bedienungshilfen-Berechtigung
  # über Neu-Builds hinweg erhalten (ad-hoc-Signaturen ändern sich bei jedem Build).
  echo "▶ Baue CouchHost …"
  if ! xcodebuild -project CouchRemote.xcodeproj -scheme CouchHost -configuration Debug \
        -derivedDataPath build -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
        -quiet build; then
    echo "⚠︎ Signieren mit Team fehlgeschlagen, baue ad-hoc signiert …"
    xcodebuild -project CouchRemote.xcodeproj -scheme CouchHost -configuration Debug \
      -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
      -quiet build
  fi

  APP=build/Build/Products/Debug/CouchHost.app

  # macOS merkt sich App-Icons: App neu registrieren, bei neuem Icon das Dock neu laden.
  touch "$APP"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true
  ICONHASH=$(md5 -q HostApp/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png 2>/dev/null)
  if [[ -n "$ICONHASH" && "$ICONHASH" != "$(cat build/.iconhash 2>/dev/null)" ]]; then
    echo "▶ Neues Icon → Dock wird neu geladen …"
    echo "$ICONHASH" > build/.iconhash
    killall Dock || true
  fi

  echo "▶ Starte CouchHost …"
  pkill -x CouchHost 2>/dev/null || true
  sleep 0.5
  open "$APP"
  echo "✓ Fertig"
} 2>&1 | tee run-host.log
echo "EXIT=${pipestatus[1]}" >> run-host.log
