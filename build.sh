#!/bin/zsh
set -eu
cd "${0:A:h}"
APP="$HOME/Applications/QuotaDesk.app"
# Override for your own builds, e.g. BUNDLE_ID=com.yourname.quotadesk zsh build.sh
BUNDLE_ID="${BUNDLE_ID:-local.quotadesk}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build-cache
xcrun swiftc QuotaDesk.swift -o "$APP/Contents/MacOS/QuotaDesk" -module-cache-path "$PWD/build-cache" -framework AppKit -framework SwiftUI -framework Security -O
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>QuotaDesk</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>QuotaDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
