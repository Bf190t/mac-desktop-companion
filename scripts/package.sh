#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="${1:-$project_dir/dist/Desktop Companion.app}"
output="${2:-$project_dir/dist/Desktop-Companion-0.1.0-AppleSilicon.zip}"
if [[ -e "$output" ]]; then echo 'Archive already exists; choose a new output.' >&2; exit 1; fi
/usr/bin/codesign --verify --deep --strict "$app_dir"
"$app_dir/Contents/MacOS/DesktopCompanion" --self-test
stage="$(mktemp -d "$project_dir/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
folder="$stage/Desktop Companion 0.1.0"
mkdir -p "$folder"
/usr/bin/ditto --noextattr --noqtn "$app_dir" "$folder/Desktop Companion.app"
cp "$project_dir/README.md" "$folder/README.md"
cp "$project_dir/README.zh-CN.md" "$folder/说明.md"
cp "$project_dir/LICENSE" "$folder/LICENSE"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$folder/THIRD_PARTY_NOTICES.md"
/usr/bin/ditto -c -k --norsrc --keepParent "$folder" "$output"
/usr/bin/unzip -tq "$output"
(cd "$(dirname "$output")" && /usr/bin/shasum -a 256 "$(basename "$output")" > "$(basename "$output").sha256")
printf '%s\n' "$output"
