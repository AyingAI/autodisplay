#!/bin/zsh
set -euo pipefail
task_root=${0:A:h:h}
app_path="$task_root/build/AutoDisplay.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$task_root/.build/module-cache"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
  -module-cache-path "$task_root/.build/module-cache" \
  -framework AppKit -framework IOKit -framework Network -framework Security \
  "$task_root"/NativeApp/Sources/*.swift -o "$app_path/Contents/MacOS/AutoDisplay"
cp "$task_root/NativeApp/Resources/extension-id.txt" "$app_path/Contents/Resources/extension-id.txt"
cp "$task_root/NativeApp/Resources/使用说明.html" "$app_path/Contents/Resources/使用说明.html"
iconset_path="$task_root/.build/AppIcon.iconset"
mkdir -p "$iconset_path"
for icon_size in 16 32 128 256 512; do
  sips -z "$icon_size" "$icon_size" "$task_root/NativeApp/Resources/AppIcon.png" \
    --out "$iconset_path/icon_${icon_size}x${icon_size}.png" >/dev/null
  retina_size=$((icon_size * 2))
  sips -z "$retina_size" "$retina_size" "$task_root/NativeApp/Resources/AppIcon.png" \
    --out "$iconset_path/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/AppIcon.icns"
ditto "$task_root/BrowserExtension" "$app_path/Contents/Resources/BrowserExtension"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autodisplay</string>
<key>CFBundleExecutable</key><string>AutoDisplay</string>
<key>CFBundleName</key><string>AutoDisplay</string>
<key>CFBundleDisplayName</key><string>AutoDisplay</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.autodisplay "$app_path"
print -r -- "$app_path"
