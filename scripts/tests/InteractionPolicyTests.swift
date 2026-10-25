import Foundation

@main
struct InteractionPolicyTests {
    static func main() {
        typealias S = InteractionPolicy.State
        var failures = [String]()
        var checks = 0
        func check(_ name: String, _ value: @autoclosure () -> Bool) {
            checks += 1
            if !value() { failures.append(name) }
        }
        func decision(_ transform: (inout S) -> Void = { _ in }) -> InteractionPolicy.Decision {
            var state = S(); transform(&state); return InteractionPolicy.evaluate(state)
        }

        check("no client does not retain model", decision().releaseReason == .noClient)
        check("no client has no input", !decision().showChatInput)
        let pet = decision { $0.chatEnabled = true }
        check("enabled pet can type", pet.showChatInput && pet.canSendFromPet)
        check("pet owns shared model", !pet.shouldReleaseModel)
        check("enabled without request does not imply speech", !pet.canSpeakReply)
        let diagnostic = decision { $0.diagnosticVisible = true }
        check("diagnostic sends independently of foot input", diagnostic.canSendFromDiagnostic && !diagnostic.showChatInput)
        check("diagnostic prevents switch-off unload", !diagnostic.shouldReleaseModel)
        check("diagnostic alone does not publish foot bubble", !diagnostic.canShowChatBubble)
        check("closing diagnostic preserves pet ownership", !pet.shouldReleaseModel)
        let busyDiagnostic = decision { $0.diagnosticVisible = true; $0.modelBusy = true }
        check("diagnostic request survives pet switch off", !busyDiagnostic.shouldReleaseModel)
        check("busy disables second sender", !busyDiagnostic.canSendFromDiagnostic)
        check("stopping blocks new request", !decision { $0.chatEnabled = true; $0.modelStopping = true }.canSendFromPet)

        let roaming = decision { $0.chatEnabled = true; $0.roamSupported = true; $0.roamEnabled = true; $0.isRoaming = true }
        check("chat enabled can coexist with idle roaming", roaming.canRoam && !roaming.shouldStopRoaming)
        check("roaming temporarily hides input", !roaming.showChatInput && !roaming.canSendFromPet)
        check("roaming does not unload model", !roaming.shouldReleaseModel)
        check("roaming does not publish bubble", !roaming.canShowChatBubble)
        check("stopping roaming restores enabled input", pet.showChatInput)
        check("unsupported portrait never roams", !decision { $0.roamEnabled = true }.canRoam)
        let focused = decision { $0.chatEnabled = true; $0.roamSupported = true; $0.roamEnabled = true; $0.isRoaming = true; $0.inputFocused = true }
        check("focus stops current roam", focused.shouldStopRoaming && !focused.canRoam)
        check("draft preserves editing position", !decision { $0.roamSupported = true; $0.roamEnabled = true; $0.hasDraft = true }.canRoam)
        check("generation stops current roam", decision { $0.roamSupported = true; $0.roamEnabled = true; $0.isRoaming = true; $0.modelBusy = true }.shouldStopRoaming)
        check("animation pause does not disable text", decision { $0.chatEnabled = true; $0.userPaused = true }.canSendFromPet)
        check("low power blocks roam", !decision { $0.roamSupported = true; $0.roamEnabled = true; $0.energySaving = true }.canRoam)

        let through = decision { $0.chatEnabled = true; $0.diagnosticVisible = true; $0.clickThrough = true }
        check("passthrough hides only foot input", !through.showChatInput && through.canSendFromDiagnostic)
        check("passthrough alone does not unload", !through.shouldReleaseModel)
        check("passthrough prevents new capture", !decision { $0.chatEnabled = true; $0.voiceEnabled = true; $0.clickThrough = true }.canStartVoice)
        check("hiding recording control cancels capture", decision { $0.chatEnabled = true; $0.voiceEnabled = true; $0.voicePhase = .listening; $0.clickThrough = true }.shouldStopVoice)

        let listening = decision { $0.chatEnabled = true; $0.diagnosticVisible = true; $0.voiceEnabled = true; $0.voicePhase = .listening; $0.speechPlaying = true }
        check("capture stops competing TTS", listening.shouldStopSpeech)
        check("capture rejects second mic start", !listening.canStartVoice)
        check("capture blocks concurrent text send", !listening.canSendFromPet && !listening.canSendFromDiagnostic)
        check("capture suppresses hourly sound", !listening.canAnnounceHour)
        check("capture suppresses reply TTS", !listening.canSpeakReply)
        check("transcription owns single turn", !decision { $0.diagnosticVisible = true; $0.voiceEnabled = true; $0.voicePhase = .transcribing }.canSendFromDiagnostic)
        let speaking = decision { $0.chatEnabled = true; $0.voiceEnabled = true; $0.voicePhase = .speaking }
        check("explicit input can interrupt TTS", speaking.canSendFromPet && speaking.canStartVoice)
        check("new generation stops old TTS", decision { $0.chatEnabled = true; $0.voiceEnabled = true; $0.voicePhase = .speaking; $0.modelBusy = true }.shouldStopSpeech)
        check("active voice owns model when a window closes", !decision { $0.voiceEnabled = true; $0.voicePhase = .transcribing }.shouldReleaseModel)
        let unseenCapture = decision { $0.voiceEnabled = true; $0.voicePhase = .listening }
        check("last recording control closed cancels microphone", unseenCapture.shouldStopVoice && unseenCapture.shouldReleaseModel)
        check("idle voice switch is not a resident client", decision { $0.voiceEnabled = true }.shouldReleaseModel)
        check("voice disabled stops current voice", decision { $0.voicePhase = .listening }.shouldStopVoice)
        check("new reply may be spoken only after generation ends", decision { $0.chatEnabled = true; $0.voiceEnabled = true }.canSpeakReply)
        check("old chat bubble suppresses hourly announcement", !decision { $0.chatBubbleVisible = true }.canAnnounceHour)
        check("idle can announce hour", decision().canAnnounceHour)

        let pressure = decision { $0.chatEnabled = true; $0.diagnosticVisible = true; $0.memoryPressure = true }
        check("memory warning releases all chat clients", pressure.releaseReason == .memoryPressure && !pressure.canSendFromDiagnostic && !pressure.canSendFromPet)
        check("memory warning keeps controls visible", pressure.showChatInput)
        check("hiding overrides diagnostic and long ownership", decision { $0.chatEnabled = true; $0.diagnosticVisible = true; $0.petHidden = true }.releaseReason == .petHidden)
        check("lock priority above hide", decision { $0.petHidden = true; $0.systemSuspended = true }.releaseReason == .systemSuspended)
        check("exit priority above lock", decision { $0.quitting = true; $0.systemSuspended = true }.releaseReason == .appExit)
        check("duplicate process never becomes model owner", decision { $0.chatEnabled = true; $0.duplicateInstance = true }.releaseReason == .duplicateInstance)

        // Cross-product catches feature combinations bypassing a top-level stop.
        for blocker in 0..<4 {
            for mask in 0..<64 {
                var s = S()
                s.chatEnabled = mask & 1 != 0; s.diagnosticVisible = mask & 2 != 0
                s.voiceEnabled = mask & 4 != 0; s.voicePhase = mask & 8 != 0 ? .listening : .speaking
                s.isRoaming = mask & 16 != 0; s.clickThrough = mask & 32 != 0
                s.roamSupported = true; s.roamEnabled = true; s.speechPlaying = true
                if blocker == 0 { s.petHidden = true }
                if blocker == 1 { s.systemSuspended = true }
                if blocker == 2 { s.quitting = true }
                if blocker == 3 { s.duplicateInstance = true }
                let d = InteractionPolicy.evaluate(s)
                check("hard stop all clients \(blocker)-\(mask)", d.shouldReleaseModel && !d.showChatInput && !d.canSendFromPet && !d.canSendFromDiagnostic && !d.canStartVoice && !d.canRoam && !d.canSpeakReply && !d.canAnnounceHour && !d.canShowChatBubble && d.shouldStopVoice && d.shouldStopSpeech)
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: ["checks":checks,"failures":failures], options:[.prettyPrinted,.sortedKeys])
        print(String(data:data,encoding:.utf8)!)
        exit(failures.isEmpty ? 0 : 1)
    }
}
