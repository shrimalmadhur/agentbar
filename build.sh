#!/bin/sh
# Builds build/AgentBar.app. Run it with: open build/AgentBar.app
set -e
cd "$(dirname "$0")"
app=build/AgentBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -parse-as-library *.swift -o "$app/Contents/MacOS/AgentBar"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AgentBar</string>
    <key>CFBundleIdentifier</key><string>local.agentbar</string>
    <key>CFBundleName</key><string>AgentBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
codesign --force -s - "$app"
echo "built $app"
