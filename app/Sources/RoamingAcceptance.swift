import AppKit

// Explicit --ui-check helper only. The caller supplies its existing recorder
// and waits for completion before ending the native QA run. No chat send,
// microphone access, sleep command, or model process is started here.
func runRoamingAcceptance(_ app: AppDelegate,
                          record: @escaping (String, Bool) -> Void,
                          capture: ((NSWindow, String) -> Void)? = nil,
                          completion: @escaping () -> Void) {
    guard app.prefs.defaults !== UserDefaults.standard else {
        record("roam_qa_requires_isolated_preferences", false); completion(); return
    }
    record("roam_qa_requires_isolated_preferences", true)
    let character = app.prefs.character, chat = app.prefs.chatEnabled, through = app.prefs.clickThrough
    let paused = app.prefs.userPaused, hidden = app.prefs.petHidden, mode = app.prefs.chibiRoamMode
    let originalDraft = app.chatInputView?.input.string ?? ""
    let priorQuit = app.isQuitting
    let initialWorker = app.chat.hasWorker
    let inspectorVisible = app.chatInspector?.window.isVisible == true
    let voiceVisible = app.voiceWindow?.window.isVisible == true
    guard !initialWorker, !app.voice.isRecording, !app.voice.isProcessing, !app.voice.isSpeaking else {
        record("roam_qa_requires_no_existing_model_or_audio", false); completion(); return
    }
    record("roam_qa_requires_no_existing_model_or_audio", true)
    record("roam_mode_initially_off", !app.roamingEnabled)
    app.setRoaming(false); app.prefs.userPaused = false; app.prefs.petHidden = false
    app.hideBubble(); app.chatBubbleUntil = 0; app.dragging = false
    app.chatInspector?.window.close(); app.voiceWindow?.window.close()
    app.selectCharacter(.chibi)
    guard app.prefs.character == .chibi else {
        record("roam_chibi_artwork_loads", false)
        app.prefs.userPaused = paused; app.prefs.petHidden = hidden; app.refreshRuntime()
        completion(); return
    }
    record("roam_chibi_artwork_loads", true)

    for originalChat in [false, true] {
        for originalThrough in [false, true] {
            let label = "chat_\(originalChat)_through_\(originalThrough)"
            app.setRoaming(false)
            app.prefs.chatEnabled = originalChat; app.prefs.clickThrough = originalThrough
            app.refreshRuntime(); app.setRoaming(true)
            record("roam_enable_\(label)", app.roamingEnabled && app.effectiveClickThrough && !app.effectiveChatEnabled && app.pet.ignoresMouseEvents && app.chatInput?.isVisible != true)
            record("roam_preferences_unchanged_\(label)", app.prefs.chatEnabled == originalChat && app.prefs.clickThrough == originalThrough)
            app.setRoaming(true) // Repeated enabling must not capture overridden values.
            app.toggleChat(); app.toggleThrough()
            record("roam_locked_controls_preserve_preferences_\(label)", app.prefs.chatEnabled == originalChat && app.prefs.clickThrough == originalThrough)
            app.setRoaming(false)
            record("roam_restore_\(label)", !app.roamingEnabled && app.effectiveChatEnabled == originalChat && app.effectiveClickThrough == originalThrough && app.pet.ignoresMouseEvents == originalThrough)
            record("roam_restore_input_visibility_\(label)", (app.chatInput?.isVisible == true) == (originalChat && !originalThrough))
            record("roam_no_timers_after_disable_\(label)", app.roamController?.hasTimers != true && app.roamController?.isRunning != true)
        }
    }

    app.prefs.chatEnabled = true; app.prefs.clickThrough = false
    app.chatInputView?.input.string = "这是保留的未发送草稿。"
    app.refreshRuntime(); app.setRoaming(true)
    record("roam_hidden_draft_preserved", app.chatInputView?.input.string == "这是保留的未发送草稿。")
    record("roam_hidden_draft_does_not_block_motion", app.interactionDecision.canRoam || app.policy.energySaving || app.chat.memoryPressureBlocked)
    app.prefs.userPaused = true; app.refreshRuntime()
    record("roam_pause_cancels_all_timers", app.roamingEnabled && app.roamController?.hasTimers != true)
    record("roam_pause_keeps_input_hidden_and_mouse_through", !app.effectiveChatEnabled && app.effectiveClickThrough && app.chatInput?.isVisible != true && app.pet.ignoresMouseEvents)
    app.prefs.userPaused = false; app.refreshRuntime()
    app.prefs.petHidden = true; app.refreshRuntime()
    record("roam_hide_cancels_all_timers", app.roamController?.hasTimers != true && !app.pet.isVisible)
    app.prefs.petHidden = false; app.refreshRuntime()
    app.setSuspension("qa_roam_lock", true)
    record("roam_lock_cancels_motion_and_chat", app.roamController?.hasTimers != true && !app.pet.isVisible && !app.chat.canSend && !app.chat.hasWorker)
    record("roam_lock_preserves_base_preferences", app.prefs.chatEnabled && !app.prefs.clickThrough)
    app.setSuspension("qa_roam_lock", false)
    record("roam_unlock_does_not_start_model_or_audio", !app.chat.hasWorker && !app.voice.isRecording && !app.voice.isSpeaking)

    app.showChatInspector(); app.chatInspector?.window.setFrameAutosaveName(""); app.chatInspector?.window.orderFront(nil)
    app.showVoiceExperiment(); app.voiceWindow?.window.setFrameAutosaveName(""); app.voiceWindow?.window.orderFront(nil)
    app.syncChatVisibility()
    record("roam_two_diagnostic_windows_use_no_extra_worker", app.diagnosticVisible && !app.chat.hasWorker && app.interactionDecision.canSendFromDiagnostic)
    app.chatInspector?.window.close(); app.syncChatVisibility()
    record("roam_other_diagnostic_window_remains_owner", app.voiceWindow?.window.isVisible == true && !app.interactionDecision.shouldReleaseModel)
    app.voiceWindow?.window.close(); app.syncChatVisibility()
    record("roam_last_diagnostic_close_releases_owner", !app.diagnosticVisible && app.interactionDecision.shouldReleaseModel)
    app.setRoaming(false)
    record("roam_disabled_restores_user_preferences", !app.roamingEnabled && app.effectiveChatEnabled && !app.effectiveClickThrough && !app.pet.ignoresMouseEvents)
    record("roam_disabled_cancels_timers", app.roamController?.hasTimers != true)

    app.selectCharacter(.chibi); app.prefs.chibiRoamMode = .horizontal
    app.setRoaming(true)
    let firstController = app.roamController
    app.syncRoaming(); app.syncRoaming()
    record("roam_reconcile_keeps_one_controller", app.roamController === firstController)
    let first = app.ground
    // A short actual timer sample supplements deterministic engine tests. It
    // does not wait for a whole 8–18 second rest cycle or extend the QA by 15s.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
        let shouldMove = app.interactionDecision.canRoam
        record("roam_timer_follows_current_policy", shouldMove ? app.roamController?.hasTimers == true : app.roamController?.hasTimers != true)
        if shouldMove, app.roamController?.isWalking == true {
            record("roam_horizontal_timer_preserves_y", abs(app.ground.y - first.y) < 0.01)
            record("roam_timer_moves_window", abs(app.ground.x - first.x) > 0.01)
            record("roam_sprite_pose_matches_displacement", app.lastRoamPose == app.roamController?.engine?.pose)
            capture?(app.pet,"chibi-native-walking")
        }
        app.isQuitting = true; app.syncRoaming()
        record("roam_quitting_state_cancels_timers", app.roamController?.hasTimers != true)
        app.isQuitting = priorQuit
        app.setRoaming(false)
        capture?(app.pet,"chibi-native-stopped")
        if let window=app.settings {capture?(window,"chibi-settings-restored")}
        let stopped = app.ground
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            record("roam_old_tick_does_not_move_after_stop", abs(app.ground.x - stopped.x) < 0.01 && abs(app.ground.y - stopped.y) < 0.01)
            record("roam_no_model_started_by_toggles_or_windows", !app.chat.hasWorker)
            app.prefs.chatEnabled = chat; app.prefs.clickThrough = through
            app.prefs.chibiRoamMode = mode; app.prefs.userPaused = paused; app.prefs.petHidden = hidden
            app.chatInputView?.input.string = originalDraft
            app.selectCharacter(character); app.refreshRuntime()
            if inspectorVisible { app.showChatInspector(); app.chatInspector?.window.orderFront(nil) }
            if voiceVisible { app.showVoiceExperiment(); app.voiceWindow?.window.orderFront(nil) }
            app.syncChatVisibility()
            record("roam_qa_restores_preferences", app.prefs.character == character && app.prefs.chatEnabled == chat && app.prefs.clickThrough == through && !app.roamingEnabled)
            completion()
        }
    }
}
