#!/bin/bash
# Source this file after defining build_dir. It changes no system SDK files.
set -euo pipefail
mkdir -p "$build_dir"
sdk_dir="${COMPANION_SDK:-$(xcrun --show-sdk-path)}"
swift_flags=(-swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$build_dir/modules")
old_map=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
new_map=/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap
if [[ -f "$old_map" && -f "$new_map" ]] && /usr/bin/grep -q 'module SwiftBridging' "$old_map" && /usr/bin/grep -q 'module SwiftBridging' "$new_map"; then
  printf '%s\n' '// Duplicate declaration is supplied by bridging.modulemap.' > "$build_dir/empty.modulemap"
  /usr/bin/python3 - "$build_dir" "$old_map" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
(root/'overlay.json').write_text(json.dumps({'version':0,'roots':[{'type':'file','name':sys.argv[2],'external-contents':str(root/'empty.modulemap')}]}))
PY
  swift_flags+=(-vfsoverlay "$build_dir/overlay.json")
fi
printf 'import AppKit\n' > "$build_dir/probe.swift"
if ! xcrun swiftc "${swift_flags[@]}" -sdk "$sdk_dir" -typecheck "$build_dir/probe.swift" > "$build_dir/sdk-check.log" 2>&1; then
  # Repair only a detected local compiler/SDK mismatch; normal Xcode uses its default.
  matched=0
  if [[ -z "${COMPANION_SDK:-}" ]]; then
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk; do
      if xcrun swiftc "${swift_flags[@]}" -sdk "$candidate" -typecheck "$build_dir/probe.swift" >> "$build_dir/sdk-check.log" 2>&1; then
        sdk_dir="$candidate"; matched=1; break
      fi
    done
  fi
  if [[ "$matched" != 1 ]]; then
    cat "$build_dir/sdk-check.log" >&2
    printf '%s\n' 'Install a matching Xcode/Command Line Tools SDK, or set COMPANION_SDK.' >&2
    exit 1
  fi
fi
swift_flags+=(-sdk "$sdk_dir")
