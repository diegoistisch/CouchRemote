#!/bin/zsh
# Lässt Codex die App-Icons erzeugen und legt daraus die Asset-Kataloge an.
# Log: make-icons.log
cd "$(dirname "$0")"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
[[ -s "$HOME/.nvm/nvm.sh" ]] && source "$HOME/.nvm/nvm.sh"

{
  echo "▶ Codex: $(command -v codex || echo 'nicht gefunden')"
  codex --version 2>&1

  mkdir -p Design/Icons
  if [[ ! -f Design/Icons/CouchHost-1024.png || ! -f Design/Icons/CouchRemote-1024.png ]]; then
    codex exec --help > Design/codex-exec-help.txt 2>&1
    PROMPT="$(cat Design/icon-prompt.md)"
    echo "▶ Codex erstellt die Icons …"
    # Schreibrechte nur im Projektordner (Sandbox), ohne Rückfragen.
    codex exec --sandbox workspace-write --skip-git-repo-check --cd "$PWD" "$PROMPT"
    code=$?
    if [[ $code -eq 2 ]]; then
      echo "▶ Optionen nicht erkannt, versuche es ohne …"
      codex exec "$PROMPT"
      code=$?
    fi
    echo "Codex-Exit: $code"
  fi

  for f in Design/Icons/CouchHost-1024.png Design/Icons/CouchRemote-1024.png; do
    [[ -f "$f" ]] || { echo "✗ Fehlt: $f"; echo "EXIT=1"; exit 1; }
    sips -g pixelWidth -g pixelHeight -g hasAlpha "$f"
  done

  echo "▶ Asset-Kataloge anlegen …"
  # macOS: alle Größen
  MAC=HostApp/Assets.xcassets/AppIcon.appiconset
  mkdir -p "$MAC"
  for s in 16 32 128 256 512; do
    sips -z $s $s Design/Icons/CouchHost-1024.png --out "$MAC/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Design/Icons/CouchHost-1024.png --out "$MAC/icon_${s}x${s}@2x.png" >/dev/null
  done
  cat > "$MAC/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

  # iOS: eine 1024er-Datei (Xcode erzeugt die übrigen Größen)
  IOS=RemoteApp/Assets.xcassets/AppIcon.appiconset
  mkdir -p "$IOS"
  cp Design/Icons/CouchRemote-1024.png "$IOS/icon_1024.png"
  cat > "$IOS/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

  for catalog in HostApp/Assets.xcassets RemoteApp/Assets.xcassets; do
    echo '{ "info" : { "author" : "xcode", "version" : 1 } }' > "$catalog/Contents.json"
  done

  echo "✓ Icons fertig"
  echo "EXIT=0"
} 2>&1 | tee make-icons.log
