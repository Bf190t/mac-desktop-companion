#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/build/test-toolchain"
source "$project_dir/scripts/toolchain.sh"
s="$project_dir/app/Sources"
t="$project_dir/tests"
compile_test() {
  local name="$1"; shift
  xcrun swiftc "${swift_flags[@]}" -D CHAT_SERVICE_TESTING "$@" -framework AppKit -framework AVFoundation -framework Speech -framework IOKit -o "$build_dir/$name"
  "$build_dir/$name"
}
compile_test interaction "$s/InteractionPolicy.swift" "$project_dir/scripts/tests/InteractionPolicyTests.swift"
compile_test roaming "$s/Roaming.swift" "$t/RoamingTests.swift"
compile_test windows "$s/Localization.swift" "$s/WindowBehavior.swift" "$t/WindowBehaviorTests.swift"
# Localization has no dependency on application windows.
compile_test voice "$s/Localization.swift" "$s/VoiceService.swift" "$t/VoiceLogicTests.swift"
compile_test instance "$s/Localization.swift" "$s/SingleInstanceGuard.swift" "$t/SingleInstanceTests.swift"
compile_test bluetooth "$s/Localization.swift" "$s/BluetoothBattery.swift" "$t/ReaderTests.swift"
compile_test bluetooth-monitor "$s/Localization.swift" "$s/BluetoothBattery.swift" "$s/BluetoothMonitor.swift" "$t/MonitorTests.swift"
compile_test chat "$s/Localization.swift" "$s/ModelInstallation.swift" "$s/ChatBoundary.swift" "$s/ChatService.swift" "$project_dir/scripts/tests/ChatServiceConcurrencyTests.swift"
xcrun swiftc "${swift_flags[@]}" "$s/Localization.swift" "$s/ChatBoundary.swift" "$project_dir/scripts/tests/ChatBoundaryTests.swift" -framework AppKit -o "$build_dir/boundary"
"$build_dir/boundary" "$project_dir/scripts/tests/chat_boundary_cases.json"
python3 "$project_dir/tests/test_optional_install.py"
python3 "$project_dir/scripts/tests/test_chat_boundary.py"
python3 "$project_dir/scripts/tests/test_companion_prompt.py"
printf '%s\n' 'All headless tests passed.'
