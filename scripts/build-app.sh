#!/bin/bash
# Builds build/Smol.app.
#   --open      launch it afterwards
#   --install   copy it to /Applications and link the CLI as /usr/local/bin/smol (or ~/.local/bin/smol)
#   --dmg       also write build/Smol-<version>.dmg, a universal build for sharing
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift "$PWD"

ARCHS=()
case " $* " in *" --dmg "*) ARCHS=(--arch arm64 --arch x86_64) ;; esac

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"
APP="build/Smol.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Smol" "$APP/Contents/MacOS/Smol"
cp "$BIN_DIR/smol-cli" "$APP/Contents/Resources/smol-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1   # ad-hoc signature so macOS will launch it locally
echo "Built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      rm -rf /Applications/Smol.app
      cp -R "$APP" /Applications/
      echo "Installed /Applications/Smol.app"
      for dir in /usr/local/bin "$HOME/.local/bin"; do
        if mkdir -p "$dir" 2>/dev/null && ln -sf /Applications/Smol.app/Contents/Resources/smol-cli "$dir/smol" 2>/dev/null; then
          echo "Linked CLI: $dir/smol"
          break
        fi
      done ;;
    --open)
      open "$APP" ;;
    --dmg)
      STAGE="$(mktemp -d)"
      cp -R "$APP" "$STAGE/"
      ln -s /Applications "$STAGE/Applications"
      DMG="build/Smol-$VERSION.dmg"
      rm -f "$DMG"
      hdiutil create -volname Smol -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
      rm -rf "$STAGE"
      echo "Wrote $DMG" ;;
  esac
done
