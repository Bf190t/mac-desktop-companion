/// Side-effect-free arbitration for the shared chat, audio, and future roam UI.
/// Callers apply stop/release actions before showing windows or starting work,
/// then evaluate again after state changes. This type starts no work itself.
enum InteractionPolicy {
    enum VoicePhase: String, CaseIterable {
        case idle, listening, transcribing, speaking
        var isCapturing: Bool { self == .listening || self == .transcribing }
    }

    enum ReleaseReason: String {
        case appExit = "app_exit"
        case duplicateInstance = "duplicate_instance"
        case systemSuspended = "system_suspended"
        case petHidden = "pet_hidden"
        case memoryPressure = "memory_pressure"
        case noClient = "no_chat_client"
    }

    struct State {
        var chatEnabled = false
        /// True only for an actually visible, non-miniaturized diagnostic UI.
        var diagnosticVisible = false
        var voiceEnabled = false
        var voicePhase: VoicePhase = .idle
        /// Includes hourly speech from a different AVSpeechSynthesizer.
        var speechPlaying = false
        var petHidden = false
        var systemSuspended = false
        var duplicateInstance = false
        var quitting = false
        /// Supplied by the coordinator; do not clear merely because a window opens.
        var memoryPressure = false
        var clickThrough = false
        var modelBusy = false
        var modelStopping = false
        /// False until the active character has a supported roam implementation.
        var roamSupported = false
        var roamEnabled = false
        var isRoaming = false
        var inputFocused = false
        var hasDraft = false
        var dragging = false
        var userPaused = false
        var energySaving = false
        var chatBubbleVisible = false
    }

    struct Decision {
        let showChatInput: Bool
        let canSendFromPet: Bool
        let canSendFromDiagnostic: Bool
        let canStartVoice: Bool
        let canRoam: Bool
        let shouldStopRoaming: Bool
        let shouldStopVoice: Bool
        let shouldStopSpeech: Bool
        let shouldReleaseModel: Bool
        let releaseReason: ReleaseReason?
        let canShowChatBubble: Bool
        let canSpeakReply: Bool
        let canAnnounceHour: Bool
    }

    static func evaluate(_ state: State) -> Decision {
        let unavailable = state.quitting || state.duplicateInstance || state.systemSuspended || state.petHidden
        let hasFrontend = state.chatEnabled || state.diagnosticVisible
        // A user-started voice exchange is an owner until it finishes/cancels.
        // Merely enabling voice must not keep a model loaded indefinitely.
        let activeVoice = state.voiceEnabled && state.voicePhase != .idle
            && (state.voicePhase != .listening || hasFrontend)
        let hasClient = hasFrontend || activeVoice
        let capturing = state.voicePhase.isCapturing
        let conversationallyBusy = state.modelBusy || state.modelStopping || state.inputFocused || state.hasDraft
            || state.dragging || state.voicePhase != .idle || state.speechPlaying || state.chatBubbleVisible
        let canRoam = !unavailable && !state.memoryPressure && state.roamSupported && state.roamEnabled
            && !state.userPaused && !state.energySaving && !conversationallyBusy
        let showInput = !unavailable && state.chatEnabled && !state.clickThrough && !state.isRoaming
        let canSend = !unavailable && !state.memoryPressure && !state.modelBusy && !state.modelStopping && !capturing

        let reason: ReleaseReason?
        if state.quitting { reason = .appExit }
        else if state.duplicateInstance { reason = .duplicateInstance }
        else if state.systemSuspended { reason = .systemSuspended }
        else if state.petHidden { reason = .petHidden }
        else if state.memoryPressure { reason = .memoryPressure }
        else if !hasClient { reason = .noClient }
        else { reason = nil }

        return Decision(
            showChatInput: showInput,
            canSendFromPet: showInput && canSend,
            canSendFromDiagnostic: state.diagnosticVisible && canSend,
            // Explicit push-to-talk may interrupt speech. Stop TTS before capture.
            canStartVoice: !unavailable && !state.memoryPressure && state.voiceEnabled && hasFrontend
                && !state.clickThrough && !state.isRoaming && !state.modelBusy && !state.modelStopping && !capturing,
            canRoam: canRoam,
            shouldStopRoaming: state.isRoaming && !canRoam,
            shouldStopVoice: state.voicePhase != .idle
                && (unavailable || !state.voiceEnabled || state.memoryPressure || (capturing && state.clickThrough)
                    || (state.voicePhase == .listening && !hasFrontend)),
            shouldStopSpeech: (state.speechPlaying || state.voicePhase == .speaking)
                && (unavailable || capturing || state.modelBusy || (state.voicePhase == .speaking && !state.voiceEnabled)),
            shouldReleaseModel: reason != nil,
            releaseReason: reason,
            canShowChatBubble: !unavailable && state.chatEnabled && !state.isRoaming,
            // Mark generation complete before evaluating a newly finished reply.
            canSpeakReply: !unavailable && state.voiceEnabled && hasClient && !capturing
                && !state.modelBusy && !state.modelStopping && !state.isRoaming,
            // Drop a clashing hourly announcement; do not queue it for later.
            canAnnounceHour: !unavailable && !state.isRoaming && !conversationallyBusy
        )
    }
}
