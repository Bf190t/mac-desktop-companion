#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build/toolchain"
source "$project_dir/scripts/toolchain.sh"
app_dir="${COMPANION_APP_DIR:-$project_dir/dist/Desktop Companion.app}"
if [[ -e "$app_dir" ]]; then
  printf '%s\n' 'Output already exists. Choose a fresh COMPANION_APP_DIR; existing apps are never overwritten.' >&2
  exit 1
fi
mkdir -p "$(dirname "$app_dir")"
staging="$(mktemp -d "$(dirname "$app_dir")/.companion-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Desktop Companion.app"
resources="$bundle/Contents/Resources"
mkdir -p "$bundle/Contents/MacOS" "$resources"
xcrun swiftc "${swift_flags[@]}" -O -whole-module-optimization \
  -debug-prefix-map "$project_dir"=. -file-prefix-map "$project_dir"=. -file-compilation-dir . \
  "$project_dir"/app/Sources/*.swift \
  -framework AppKit -framework QuartzCore -framework IOKit -framework AVFoundation -framework Speech \
  -o "$bundle/Contents/MacOS/DesktopCompanion"
# Explicit distribution list: no user assets, local model weights, or environment copies.
mkdir -p "$resources/Chat"
for file in worker.py model-manifest.json requirements-lock.txt MODEL-LICENSE.txt THIRD-PARTY-NOTICES.txt launch.py runtime-manifest.json install.py install.sh; do
  if [[ -f "$project_dir/chat/$file" ]]; then cp "$project_dir/chat/$file" "$resources/Chat/$file"; fi
done
if [[ -d "$project_dir/chat/persona" ]]; then cp -R "$project_dir/chat/persona" "$resources/Chat/"; fi
if [[ -f "$project_dir/scripts/chat_boundary.py" ]]; then cp "$project_dir/scripts/chat_boundary.py" "$resources/Chat/"; fi
for file in LICENSE THIRD_PARTY_NOTICES.md; do cp "$project_dir/$file" "$resources/$file"; done
mkdir -p "$resources/Licenses"
cp "$project_dir/docs/licenses/Stats-MIT.txt" "$resources/Licenses/Stats-MIT.txt"
if [[ -d "$project_dir/app/Resources/ChatLicenses" ]]; then cp -R "$project_dir/app/Resources/ChatLicenses" "$resources/"; fi
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.bf190t.desktop-companion</string>
<key>CFBundleName</key><string>Desktop Companion</string>
<key>CFBundleDisplayName</key><string>Desktop Companion</string>
<key>CFBundleExecutable</key><string>DesktopCompanion</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>NSMicrophoneUsageDescription</key><string>Records only while you hold the talk button, to make an editable local transcript.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Transcribes speech locally when on-device recognition is available; cloud fallback is disabled.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Copyright 2026 Bf190t and contributors. MIT; third-party components retain their own licenses.</string>
</dict></plist>
PLIST
mkdir -p "$resources/en.lproj" "$resources/zh-Hans.lproj"
cat > "$resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"NSMicrophoneUsageDescription" = "仅在按住说话时录音，在本机生成可修改的文字。";
"NSSpeechRecognitionUsageDescription" = "使用本机离线语音识别；不可用时不会回退到云端识别。";
STRINGS
"$bundle/Contents/MacOS/DesktopCompanion" --export-icon "$staging/mascot.png"
mkdir -p "$staging/AppIcon.iconset"
/usr/bin/sips --padToHeightWidth 1024 1024 "$staging/mascot.png" --out "$staging/icon-square.png" >/dev/null
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$staging/icon-square.png" --out "$staging/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size*2))
  /usr/bin/sips -z "$double" "$double" "$staging/icon-square.png" --out "$staging/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$staging/AppIcon.iconset" -o "$resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --options runtime --entitlements "$project_dir/app/Voice.entitlements" "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"
"$bundle/Contents/MacOS/DesktopCompanion" --self-test
mv "$bundle" "$app_dir"
printf '%s\n' "$app_dir"
