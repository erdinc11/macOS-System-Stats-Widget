#!/bin/bash
# StatsWidget derleme betiği
set -euo pipefail

cd "$(dirname "$0")"

APP="StatsWidget.app"
MACMON="$(command -v macmon || true)"

echo "→ Eski paket temizleniyor..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Swift derleniyor..."
swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -target arm64-apple-macosx14.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  Sources/StatsWidget.swift \
  -o "$APP/Contents/MacOS/StatsWidget"

cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -n "$MACMON" ] && [ -x "$MACMON" ]; then
  echo "→ macmon pakete gömülüyor: $MACMON"
  cp "$MACMON" "$APP/Contents/Resources/macmon"
  chmod +x "$APP/Contents/Resources/macmon"
  cp Resources/macmon-LICENSE.txt "$APP/Contents/Resources/macmon-LICENSE.txt"
  codesign --force --sign - "$APP/Contents/Resources/macmon" >/dev/null 2>&1 || true
else
  echo "⚠ macmon bulunamadı. Frekans ve sıcaklık için: brew install macmon"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Hazır: $(pwd)/$APP"
echo "  Çalıştır: open \"$APP\""
