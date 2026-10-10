#!/bin/sh
# Builds build/AuthBar.app. Run it with: open build/AuthBar.app
set -e
cd "$(dirname "$0")"
app=build/AuthBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library AuthBar.swift -o "$app/Contents/MacOS/AuthBar"
# LSUIElement keeps it out of the Dock and app switcher.
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AuthBar</string>
    <key>CFBundleIdentifier</key><string>local.authbar</string>
    <key>CFBundleName</key><string>AuthBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force -s - "$app"
echo "built $app"
