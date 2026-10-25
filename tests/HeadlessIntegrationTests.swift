import Foundation
import Darwin

@main struct Release016HeadlessIntegrationTests {
    static func main() throws {
        var checks = [String: Bool]()
        func check(_ name: String, _ value: @autoclosure () -> Bool) { checks[name] = value() }
        func decision(_ mutate: (inout InteractionPolicy.State) -> Void) -> InteractionPolicy.Decision {
            var s = InteractionPolicy.State(); s.roamSupported = true; s.roamEnabled = true; mutate(&s)
            return InteractionPolicy.evaluate(s)
        }
        check("roam_default_not_enabled", !InteractionPolicy.State().roamEnabled)
        check("enabled_idle_can_roam", decision { _ in }.canRoam)
        check("low_power_blocks_roam", !decision { $0.energySaving = true }.canRoam)
        check("user_pause_blocks_roam", !decision { $0.userPaused = true }.canRoam)
        check("locked_stops_movement_and_model", decision { $0.systemSuspended = true; $0.isRoaming = true }.shouldStopRoaming && decision { $0.systemSuspended = true }.shouldReleaseModel)
        check("hidden_stops_movement_and_model", decision { $0.petHidden = true; $0.isRoaming = true }.shouldStopRoaming && decision { $0.petHidden = true }.shouldReleaseModel)
        check("quit_stops_movement_and_model", decision { $0.quitting = true; $0.isRoaming = true }.shouldStopRoaming && decision { $0.quitting = true }.releaseReason == .appExit)
        check("duplicate_instance_no_model_or_motion", !decision { $0.duplicateInstance = true }.canRoam && decision { $0.duplicateInstance = true }.shouldReleaseModel)
        check("memory_pressure_stops_movement", !decision { $0.memoryPressure = true }.canRoam)
        for voice in InteractionPolicy.VoicePhase.allCases where voice != .idle {
            check("voice_\(voice.rawValue)_pauses_roam", !decision { $0.voiceEnabled = true; $0.voicePhase = voice }.canRoam)
        }
        check("model_generation_pauses_roam", !decision { $0.modelBusy = true }.canRoam)
        check("model_termination_pauses_roam", !decision { $0.modelStopping = true }.canRoam)
        check("visible_draft_pauses_roam", !decision { $0.hasDraft = true }.canRoam)
        check("no_visible_frontend_releases_model", decision { $0.chatEnabled = false; $0.diagnosticVisible = false }.shouldReleaseModel)
        check("diagnostic_frontend_retains_shared_service", !decision { $0.chatEnabled = false; $0.diagnosticVisible = true }.shouldReleaseModel)
        check("through_does_not_block_diagnostic_typing", decision { $0.clickThrough = true; $0.diagnosticVisible = true }.canSendFromDiagnostic)
        check("through_blocks_pet_typing", !decision { $0.clickThrough = true; $0.chatEnabled = true }.canSendFromPet)
        check("voice_enable_alone_does_not_retain_model", decision { $0.voiceEnabled = true }.shouldReleaseModel)

        let service = PetChatService()
        check("service_initially_has_no_worker", !service.hasWorker && service.canSend)
        service.longResidency = true; service.inspecting = true
        check("opening_inspection_or_long_mode_does_not_start_model", !service.hasWorker)
        service.inspecting = false
        service.customPersona = ""
        check("empty_custom_persona_uses_current_default", service.persona == ChatBoundary.defaultPersona)
        service.customPersona = "用户自己的安静语气。"
        check("real_custom_persona_is_preserved", service.persona == "用户自己的安静语气。")
        service.testingBeginRequest("first")
        let originalCount = service.lines.count
        check("second_window_cannot_start_duplicate_request", !service.send("不应开始第二个请求") && service.lines.count == originalCount && !service.hasWorker)
        service.testingEvent(["type": "delta", "id": "older-request", "text": "旧回包"])
        check("old_request_delta_ignored", service.draft.isEmpty)
        service.testingEvent(["type": "delta", "id": "first", "text": "尚未完成"])
        service.testingEvent(["type": "done", "id": "first", "text": "尚未完成", "finish_reason": "cancelled"])
        check("cancelled_assistant_excluded_from_context", service.lines.last?.role == "assistant" && service.lines.last?.eligible == false)
        check("cancelled_user_input_retained", service.lines.contains { $0.role == "user" && $0.text == "first" })
        service.clear()
        service.testingBeginRequest("old")
        service.onReply = { _ in service.testingBeginRequest("new") }
        service.testingEvent(["type": "done", "id": "old", "text": "你好。", "finish_reason": "stop"])
        check("reply_callback_may_start_next_request_without_old_cleanup_erasing_it", service.currentID == "new")
        service.testingEvent(["type": "done", "id": "old", "text": "迟到的完成。", "finish_reason": "stop"])
        check("old_done_cannot_complete_new_request", service.currentID == "new")
        service.onReply = nil
        service.testingEvent(["type": "done", "id": "new", "text": "完成。", "finish_reason": "stop"])
        service.clear(); service.suspended = true
        check("suspended_send_does_not_start_worker", !service.send("不应加载") && !service.hasWorker && service.lines.isEmpty)
        service.suspended = false; service.testingPressure(.warning)
        check("warning_blocks_reload_after_release", !service.canSend && !service.send("不应加载") && !service.hasWorker)
        service.testingPressure(.normal)
        check("pressure_recovery_does_not_auto_reload", service.canSend && !service.hasWorker)
        service.terminateSynchronously()

        // Exercise the actual asynchronous writer with real OS pipes, no model
        // subprocesses. A full pipe must not block the caller or leak queued
        // bytes into a subsequently installed worker destination.
        let writer = PetChatInputWriter(), blocked = Pipe(), fresh = Pipe()
        let oldToken = UUID(), newToken = UUID()
        var oldFailures = 0, newFailures = 0
        try writer.install(blocked.fileHandleForWriting, token: oldToken)
        let began = ProcessInfo.processInfo.systemUptime
        writer.enqueue(Data(repeating: 0x58, count: 2 * 1024 * 1024), token: oldToken) { _ in oldFailures += 1 }
        check("large_pipe_write_returns_to_caller_promptly", ProcessInfo.processInfo.systemUptime - began < 0.25)
        // Let the OS pipe fill while the main run loop stays available.
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        writer.enqueue(Data("old-queued\n".utf8), token: oldToken) { _ in oldFailures += 1 }
        let retiredAt = ProcessInfo.processInfo.systemUptime
        writer.invalidate(oldToken)
        try writer.install(fresh.fileHandleForWriting, token: newToken)
        writer.enqueue(Data("fresh\n".utf8), token: newToken) { _ in newFailures += 1 }
        let fd = fresh.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var received = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while ProcessInfo.processInfo.systemUptime - retiredAt < 1.0 && !received.contains(10) {
            let n = read(fd, &bytes, bytes.count)
            if n > 0 { received.append(contentsOf: bytes.prefix(n)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check("blocked_old_write_retired_within_one_second", received == Data("fresh\n".utf8))
        check("retired_failure_does_not_affect_new_worker", oldFailures == 0 && newFailures == 0)
        writer.invalidate(oldToken) // A stale close cannot invalidate newToken.
        writer.enqueue(Data("still-fresh\n".utf8), token: newToken) { _ in newFailures += 1 }
        received = Data(); let secondAt = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - secondAt < 1.0 && !received.contains(10) {
            let n = read(fd, &bytes, bytes.count)
            if n > 0 { received.append(contentsOf: bytes.prefix(n)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check("stale_invalidate_preserves_new_destination", received == Data("still-fresh\n".utf8))
        writer.invalidate(newToken)
        try? blocked.fileHandleForReading.close(); try? fresh.fileHandleForReading.close()
        let broken = Pipe(), brokenToken = UUID(); var brokenFailures = 0
        try writer.install(broken.fileHandleForWriting, token: brokenToken)
        try broken.fileHandleForReading.close()
        writer.enqueue(Data("closed\n".utf8), token: brokenToken) { _ in brokenFailures += 1 }
        let failAt = ProcessInfo.processInfo.systemUptime
        while brokenFailures == 0 && ProcessInfo.processInfo.systemUptime - failAt < 1.0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check("broken_pipe_reports_error_without_sigpipe", brokenFailures == 1)
        writer.invalidate()
        let failed = checks.filter { !$0.value }.map { $0.key }.sorted()
        let report: [String: Any] = ["checks": checks, "passed": checks.count - failed.count, "failed": failed,
                                   "model_started": false, "gui_started": false, "microphone_used": false,
                                   "pipe_retirement_seconds": ProcessInfo.processInfo.systemUptime - retiredAt]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try data.write(to: output, options: .atomic)
        print("Release 0.1.6 headless checks: \(checks.count - failed.count)/\(checks.count); failures: \(failed)")
        if !failed.isEmpty { exit(1) }
    }
}
