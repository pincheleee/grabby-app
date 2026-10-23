#!/bin/bash
#
# build.sh — Build Grabby.app + DMG installer for macOS
#
# What this does:
#   1. Installs Python build dependencies (flask, pywebview, pyinstaller)
#   2. Downloads yt-dlp and ffmpeg binaries (bundled INSIDE the app)
#   3. Generates an app icon
#   4. Builds Grabby.app with PyInstaller
#   5. Copies bundled binaries into the .app
#   6. Code signs the .app (Developer ID or ad-hoc)
#   7. Creates a Grabby.dmg with drag-to-Applications layout
#
# Usage:
#   bash build.sh
#
# Result:
#   dist/Grabby.dmg — double-click to install
#
set -e

ARCH=$(uname -m)  # arm64 or x86_64
echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   Building Grabby.app for macOS       ║"
echo "  ║   Architecture: $ARCH               ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------------
# Step 1: Python dependencies
# ------------------------------------------------------------------
echo "  [1/7] Installing Python build dependencies..."
pip3 install flask pywebview pyinstaller --break-system-packages -q 2>/dev/null || \
pip3 install flask pywebview pyinstaller -q
echo "        ✅ Done"

# ------------------------------------------------------------------
# Step 2: Download yt-dlp binary
# ------------------------------------------------------------------
echo "  [2/7] Downloading yt-dlp..."
mkdir -p bin

if [ ! -f "bin/yt-dlp" ]; then
    YT_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    curl -L -o bin/yt-dlp "$YT_URL" --progress-bar
    chmod +x bin/yt-dlp
    echo "        ✅ yt-dlp downloaded"
else
    echo "        ✅ yt-dlp already present"
fi

# ------------------------------------------------------------------
# Step 3: Download ffmpeg binary
# ------------------------------------------------------------------
echo "  [3/7] Downloading ffmpeg..."

if [ ! -f "bin/ffmpeg" ]; then
    # Use yt-dlp's recommended ffmpeg builds
    FFMPEG_URL="https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-macos-universal.tar.xz"

    echo "        Downloading ffmpeg (this may take a minute)..."
    curl -L -o /tmp/ffmpeg.tar.xz "$FFMPEG_URL" --progress-bar 2>/dev/null

    if [ -f /tmp/ffmpeg.tar.xz ]; then
        cd /tmp
        tar xf ffmpeg.tar.xz 2>/dev/null || true
        FFDIR=$(find /tmp -maxdepth 1 -name "ffmpeg-*" -type d | head -1)
        if [ -n "$FFDIR" ] && [ -f "$FFDIR/bin/ffmpeg" ]; then
            cp "$FFDIR/bin/ffmpeg" "$OLDPWD/bin/ffmpeg"
            cp "$FFDIR/bin/ffprobe" "$OLDPWD/bin/ffprobe" 2>/dev/null || true
            chmod +x "$OLDPWD/bin/ffmpeg" "$OLDPWD/bin/ffprobe" 2>/dev/null || true
            cd "$OLDPWD"
            echo "        ✅ ffmpeg downloaded"
        else
            cd "$OLDPWD"
            echo "        ⚠️  ffmpeg download failed. Checking Homebrew..."
            if command -v ffmpeg &> /dev/null; then
                FFPATH=$(which ffmpeg)
                cp "$FFPATH" bin/ffmpeg
                chmod +x bin/ffmpeg
                FFPROBE=$(which ffprobe 2>/dev/null)
                [ -n "$FFPROBE" ] && cp "$FFPROBE" bin/ffprobe && chmod +x bin/ffprobe
                echo "        ✅ Copied ffmpeg from Homebrew"
            else
                echo ""
                echo "  ❌ Cannot find ffmpeg. Install it first:"
                echo "     brew install ffmpeg"
                exit 1
            fi
        fi
        rm -rf /tmp/ffmpeg.tar.xz /tmp/ffmpeg-*
    else
        echo "        ⚠️  Download failed, trying Homebrew copy..."
        if command -v ffmpeg &> /dev/null; then
            cp "$(which ffmpeg)" bin/ffmpeg
            chmod +x bin/ffmpeg
            echo "        ✅ Copied from Homebrew"
        else
            echo "  ❌ No ffmpeg found. Run: brew install ffmpeg"
            exit 1
        fi
    fi
else
    echo "        ✅ ffmpeg already present"
fi

# ------------------------------------------------------------------
# Step 4: Generate icon
# ------------------------------------------------------------------
echo "  [4/7] Generating app icon..."
python3 generate_icon.py

# Create .icns
mkdir -p Grabby.iconset
for size in 16 32 64 128 256 512; do
    sips -z $size $size assets/icon_512.png --out Grabby.iconset/icon_${size}x${size}.png > /dev/null 2>&1
    double=$((size * 2))
    if [ $double -le 1024 ]; then
        sips -z $double $double assets/icon_512.png --out Grabby.iconset/icon_${size}x${size}@2x.png > /dev/null 2>&1
    fi
done
iconutil -c icns Grabby.iconset -o assets/Grabby.icns 2>/dev/null && echo "        ✅ .icns created" || echo "        ⚠️  iconutil failed, using default"
rm -rf Grabby.iconset

# ------------------------------------------------------------------
# Step 5: Build .app with PyInstaller
# ------------------------------------------------------------------
echo "  [5/7] Building Grabby.app with PyInstaller..."

ICON_FLAG=""
[ -f "assets/Grabby.icns" ] && ICON_FLAG="--icon=assets/Grabby.icns"

pyinstaller \
    --name="Grabby" \
    --windowed \
    --onedir \
    --osx-bundle-identifier="com.grabby.app" \
    $ICON_FLAG \
    --add-data="bin:bin" \
    --hidden-import=webview \
    --hidden-import=flask \
    --hidden-import=webview.platforms.cocoa \
    --hidden-import=sqlite3 \
    --hidden-import=objc \
    --hidden-import=Foundation \
    --hidden-import=WebKit \
    --hidden-import=AppKit \
    --collect-all=webview \
    --noconfirm \
    --clean \
    grabby_app.py 2>&1 | tail -5

if [ ! -d "dist/Grabby.app" ]; then
    echo "  ❌ PyInstaller build failed."
    exit 1
fi

# Patch Info.plist with proper metadata
PLIST="dist/Grabby.app/Contents/Info.plist"
if [ -f "$PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 2.0.0" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 2.0.0" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2.0.0" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 2.0.0" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 12.0" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 12.0" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.grabby.app" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright 'Copyright 2025 Grabby'" "$PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :NSHumanReadableCopyright string 'Copyright 2025 Grabby'" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true" "$PLIST" 2>/dev/null || true
    echo "        Info.plist patched"
fi

# Ensure bin directory is inside the app bundle
APP_RESOURCES="dist/Grabby.app/Contents/Resources"
APP_INTERNAL="dist/Grabby.app/Contents/Frameworks"
mkdir -p "$APP_RESOURCES/bin"
cp bin/yt-dlp "$APP_RESOURCES/bin/" 2>/dev/null || true
cp bin/ffmpeg "$APP_RESOURCES/bin/" 2>/dev/null || true
cp bin/ffprobe "$APP_RESOURCES/bin/" 2>/dev/null || true
chmod +x "$APP_RESOURCES/bin/"* 2>/dev/null || true

# Also put in the _internal dir where PyInstaller puts --add-data files
if [ -d "dist/Grabby.app/Contents/Frameworks/bin" ]; then
    cp bin/yt-dlp "dist/Grabby.app/Contents/Frameworks/bin/" 2>/dev/null || true
    cp bin/ffmpeg "dist/Grabby.app/Contents/Frameworks/bin/" 2>/dev/null || true
    cp bin/ffprobe "dist/Grabby.app/Contents/Frameworks/bin/" 2>/dev/null || true
    chmod +x "dist/Grabby.app/Contents/Frameworks/bin/"* 2>/dev/null || true
fi

echo "        ✅ Grabby.app built"

# ------------------------------------------------------------------
# Step 6: Code signing
# ------------------------------------------------------------------
echo "  [6/7] Code signing..."

# Create entitlements for hardened runtime
cat > entitlements.plist << 'ENTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://purl.apple.com/dtds/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
ENTEOF

# Check for Developer ID first, fall back to ad-hoc
DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')

if [ -n "$DEV_IDENTITY" ]; then
    echo "        Found Developer ID: $DEV_IDENTITY"
    SIGN_ID="$DEV_IDENTITY"
else
    echo "        No Developer ID found — using ad-hoc signing"
    echo "        (Recipients will need to right-click → Open on first launch)"
    SIGN_ID="-"
fi

# Sign all binaries inside the app bundle first (inside-out)
find "dist/Grabby.app" -type f \( -name "*.dylib" -o -name "*.so" -o -perm +111 \) -exec \
    codesign --force --sign "$SIGN_ID" --options runtime --entitlements entitlements.plist --timestamp 2>/dev/null {} \; 2>/dev/null || true

# Sign the bundled tools explicitly
for BIN_FILE in "$APP_RESOURCES/bin/yt-dlp" "$APP_RESOURCES/bin/ffmpeg" "$APP_RESOURCES/bin/ffprobe"; do
    [ -f "$BIN_FILE" ] && codesign --force --sign "$SIGN_ID" --options runtime --entitlements entitlements.plist --timestamp 2>/dev/null "$BIN_FILE" 2>/dev/null || true
done

# Sign the main app bundle (no --deep, inner binaries already signed)
codesign --force --sign "$SIGN_ID" --options runtime --entitlements entitlements.plist --timestamp 2>/dev/null "dist/Grabby.app" 2>/dev/null || \
codesign --force --sign "$SIGN_ID" --options runtime --entitlements entitlements.plist "dist/Grabby.app" 2>/dev/null || true

rm -f entitlements.plist

# Verify
if codesign --verify --deep "dist/Grabby.app" 2>/dev/null; then
    echo "        ✅ Code signing verified"
else
    echo "        ⚠️  Signing verification had warnings (app will still work)"
fi

# Notarize if we have a Developer ID and xcrun is available
if [ "$SIGN_ID" != "-" ] && command -v xcrun &> /dev/null; then
    echo ""
    echo "        To notarize (optional, removes all Gatekeeper warnings):"
    echo "        ─────────────────────────────────────────────────────────"
    echo "        ditto -c -k --keepParent dist/Grabby.app /tmp/Grabby.zip"
    echo "        xcrun notarytool submit /tmp/Grabby.zip \\"
    echo "          --apple-id YOUR_APPLE_ID \\"
    echo "          --team-id YOUR_TEAM_ID \\"
    echo "          --password YOUR_APP_SPECIFIC_PASSWORD \\"
    echo "          --wait"
    echo "        xcrun stapler staple dist/Grabby.app"
    echo "        ─────────────────────────────────────────────────────────"
    echo "        Then re-run the DMG step or just re-run this script."
    echo ""
fi

# ------------------------------------------------------------------
# Step 7: Create DMG
# ------------------------------------------------------------------
echo "  [7/7] Creating DMG installer..."

DMG_TMP="dist/grabby_tmp.dmg"
DMG_FINAL="dist/Grabby.dmg"
DMG_VOLUME="Grabby"
DMG_SIZE="300m"

rm -f "$DMG_TMP" "$DMG_FINAL"

# Create temp DMG
hdiutil create -size "$DMG_SIZE" -fs HFS+ -volname "$DMG_VOLUME" -ov "$DMG_TMP" > /dev/null 2>&1

# Mount it
MOUNT_DIR=$(hdiutil attach "$DMG_TMP" -nobrowse -noverify 2>/dev/null | grep "/Volumes" | awk '{print $NF}')
if [ -z "$MOUNT_DIR" ]; then
    MOUNT_DIR="/Volumes/$DMG_VOLUME"
fi

# Copy app
cp -R "dist/Grabby.app" "$MOUNT_DIR/"

# Create Applications symlink
ln -s /Applications "$MOUNT_DIR/Applications"

# Create a background instructions file
cat > "$MOUNT_DIR/.background_info" << 'BGEOF'
Drag Grabby to Applications to install.
BGEOF

# Set DMG window appearance via AppleScript
osascript << ASCRIPT > /dev/null 2>&1 || true
tell application "Finder"
    tell disk "$DMG_VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 900, 500}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 80
        set position of item "Grabby.app" of container window to {130, 150}
        set position of item "Applications" of container window to {370, 150}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
ASCRIPT

# Unmount
sync
hdiutil detach "$MOUNT_DIR" > /dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" -force > /dev/null 2>&1

# Convert to compressed DMG
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" > /dev/null 2>&1
rm -f "$DMG_TMP"

if [ -f "$DMG_FINAL" ]; then
    # Sign the DMG too
    codesign --force --sign "$SIGN_ID" "$DMG_FINAL" 2>/dev/null || true
    DMG_SIZE_MB=$(du -h "$DMG_FINAL" | awk '{print $1}')
    echo "        ✅ DMG created ($DMG_SIZE_MB)"
else
    echo "        ⚠️  DMG creation failed (you can still use dist/Grabby.app directly)"
fi

# ------------------------------------------------------------------
# Done
# ------------------------------------------------------------------
echo ""
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   ✅ Build Complete!                  ║"
echo "  ╚═══════════════════════════════════════╝"
echo ""
if [ -f "$DMG_FINAL" ]; then
echo "  📦 Installer:  $(pwd)/dist/Grabby.dmg"
echo ""
echo "  To install:"
echo "     1. Double-click Grabby.dmg"
echo "     2. Drag Grabby to Applications"
echo "     3. Launch from Spotlight or Applications"
echo ""
fi
echo "  📂 Standalone: $(pwd)/dist/Grabby.app"
echo ""
echo "  ⚡ Everything is bundled — no Homebrew needed."
echo ""
if [ "$SIGN_ID" = "-" ]; then
echo "  📋 Sharing note (ad-hoc signed):"
echo "     Tell recipients: right-click Grabby → Open → Open"
echo "     This is only needed the first time they launch it."
echo ""
echo "     For zero-friction installs, get an Apple Developer ID (\$99/yr)"
echo "     and re-run this script — it auto-detects and uses it."
else
echo "  🔐 Signed with: $SIGN_ID"
echo "     Share the DMG freely — Gatekeeper will allow it."
echo ""
echo "     To notarize (removes ALL warnings):"
echo "     ditto -c -k --keepParent dist/Grabby.app /tmp/Grabby.zip"
echo "     xcrun notarytool submit /tmp/Grabby.zip --apple-id YOU --team-id TEAM --password PWD --wait"
echo "     xcrun stapler staple dist/Grabby.app"
echo "     Then re-run: bash build.sh"
fi
echo ""
