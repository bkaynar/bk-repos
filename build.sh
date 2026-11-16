#!/bin/bash
# Kullanım:
#   ./build.sh            → build/BK Repos.app oluşturur
#   ./build.sh --install  → ayrıca ~/Applications içine kurar ve açar
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="BK Repos"
BUNDLE="build/$APP_NAME.app"

swift build -c release --product BKRepos
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN_DIR/BKRepos" "$BUNDLE/Contents/MacOS/BKRepos"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
# Yerel imza: bildirimler ve giriş öğesi için paketin imzalı olması gerekir.
codesign --force --sign - "$BUNDLE"
echo "Oluşturuldu: $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    pkill -x BKRepos 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$BUNDLE" "$DEST"
    # Masaüstüne kısayol (orada aynı adda gerçek bir dosya varsa dokunulmaz).
    LINK="$HOME/Desktop/$APP_NAME.app"
    if [[ ! -e "$LINK" && ! -L "$LINK" ]]; then
        ln -s "$DEST" "$LINK"
        echo "Masaüstü kısayolu: $LINK"
    fi
    open "$DEST"
    echo "Kuruldu ve açıldı: $DEST"
fi
