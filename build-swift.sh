#!/bin/bash
#
# build-swift.sh — Build Grabby.app (Swift) + DMG installer
#
set -e

echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   Building Grabby.app (Swift)         ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------------
# Step 1: Download yt-dlp + ffmpeg if needed
# ------------------------------------------------------------------
echo "  [1/4] Checking bundled binaries..."
mkdir -p Grabby/Resources

if [ ! -f "Grabby/Resources/yt-dlp" ]; then
    echo "        Downloading yt-dlp..."
    curl -L -o Grabby/Resources/yt-dlp "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos" --progress-bar
    chmod +x Grabby/Resources/yt-dlp
fi
echo "        yt-dlp: $(du -h Grabby/Resources/yt-dlp | awk '{print $1}')"

if [ ! -f "Grabby/Resources/ffmpeg" ]; then
    echo "        Copying ffmpeg from Homebrew..."
    if command -v ffmpeg &> /dev/null; then
        cp "$(which ffmpeg)" Grabby/Resources/ffmpeg
        chmod +x Grabby/Resources/ffmpeg
        FFPROBE=$(which ffprobe 2>/dev/null)
        [ -n "$FFPROBE" ] && cp "$FFPROBE" Grabby/Resources/ffprobe && chmod +x Grabby/Resources/ffprobe
    else
        echo "  ❌ ffmpeg not found. Run: brew install ffmpeg"
        exit 1
    fi
fi
echo "        ffmpeg: $(du -h Grabby/Resources/ffmpeg | awk '{print $1}')"
echo "        ✅ Binaries ready"

# ------------------------------------------------------------------
# Step 2: Build with xcodebuild
# ------------------------------------------------------------------
echo "  [2/4] Building Release..."

# Build without Xcode signing -- we sign manually after
xcodebuild -project Grabby.xcodeproj \
    -scheme Grabby \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
    build 2>&1 | tail -3

APP_PATH="build/DerivedData/Build/Products/Release/Grabby.app"

if [ ! -d "$APP_PATH" ]; then
    echo "  ❌ Build failed."
    exit 1
fi

mkdir -p dist
rm -rf dist/Grabby.app
cp -R "$APP_PATH" dist/Grabby.app

APP_SIZE=$(du -sh dist/Grabby.app | awk '{print $1}')
echo "        ✅ Grabby.app built ($APP_SIZE)"

# ------------------------------------------------------------------
# Step 3: Code sign
# ------------------------------------------------------------------
echo "  [3/4] Code signing..."

DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -n "$DEV_IDENTITY" ]; then
    echo "        Developer ID: $DEV_IDENTITY"
    SIGN_ID="$DEV_IDENTITY"
else
    echo "        Ad-hoc signing (right-click → Open on first launch)"
    SIGN_ID="-"
fi

# Strip resource forks that block codesign
xattr -cr dist/Grabby.app 2>/dev/null || true
find dist/Grabby.app -name "._*" -delete 2>/dev/null || true

# Sign bundled binaries first (inside-out)
for BIN in dist/Grabby.app/Contents/Resources/yt-dlp dist/Grabby.app/Contents/Resources/ffmpeg dist/Grabby.app/Contents/Resources/ffprobe; do
    [ -f "$BIN" ] && codesign --force --sign "$SIGN_ID" --timestamp "$BIN" 2>/dev/null || true
done

# Sign the app with entitlements
ENTITLEMENTS=""
[ -f "Grabby.entitlements" ] && ENTITLEMENTS="--entitlements Grabby.entitlements"
codesign --force --sign "$SIGN_ID" --options runtime $ENTITLEMENTS --timestamp "dist/Grabby.app" 2>/dev/null || \
codesign --force --sign "$SIGN_ID" $ENTITLEMENTS "dist/Grabby.app" 2>/dev/null || true

if codesign --verify "dist/Grabby.app" 2>/dev/null; then
    echo "        ✅ Signed"
else
    echo "        ⚠️  Signing had warnings"
fi

# ------------------------------------------------------------------
# Step 4: Create DMG
# ------------------------------------------------------------------
echo "  [4/4] Creating DMG..."

DMG_TMP="dist/grabby_tmp.dmg"
DMG_FINAL="dist/Grabby.dmg"
rm -f "$DMG_TMP" "$DMG_FINAL"

hdiutil create -size 100m -fs HFS+ -volname "Grabby" -ov "$DMG_TMP" > /dev/null 2>&1
MOUNT_DIR=$(hdiutil attach "$DMG_TMP" -nobrowse -noverify 2>/dev/null | grep "/Volumes" | awk '{print $NF}')
[ -z "$MOUNT_DIR" ] && MOUNT_DIR="/Volumes/Grabby"

cp -R dist/Grabby.app "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"

osascript << 'ASCRIPT' > /dev/null 2>&1 || true
tell application "Finder"
    tell disk "Grabby"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 900, 500}
        set viewOptions to the icon view options of container window
        set icon size of viewOptions to 80
        set position of item "Grabby.app" of container window to {130, 150}
        set position of item "Applications" of container window to {370, 150}
        close
    end tell
end tell
ASCRIPT

sync
hdiutil detach "$MOUNT_DIR" > /dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force > /dev/null 2>&1
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" > /dev/null 2>&1
rm -f "$DMG_TMP"

if [ -f "$DMG_FINAL" ]; then
    codesign --force --sign "$SIGN_ID" "$DMG_FINAL" 2>/dev/null || true
    DMG_SIZE=$(du -h "$DMG_FINAL" | awk '{print $1}')
    echo "        ✅ DMG created ($DMG_SIZE)"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   ✅ Build Complete!                  ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
echo "  📦 DMG:  $(pwd)/dist/Grabby.dmg"
echo "  📂 App:  $(pwd)/dist/Grabby.app"
echo "  📏 Size: $APP_SIZE (was 58MB with Python)"
echo ""
