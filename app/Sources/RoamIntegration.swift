import AppKit

extension AppDelegate {
    // Walking is a temporary override. The saved user preferences remain the
    // source of truth when walking ends, including after a character change.
    var effectiveChatEnabled: Bool { prefs.chatEnabled && !roamingEnabled }
    var effectiveClickThrough: Bool { prefs.clickThrough || roamingEnabled }

    @objc func toggleRoaming() { setRoaming(!roamingEnabled) }

    func setRoaming(_ enabled: Bool) {
        guard !enabled || prefs.character == .chibi else { return }
        guard roamingEnabled != enabled else { return }
        roamingEnabled = enabled
        hideBubble(); chatBubbleUntil = 0
        if enabled {
            chatInput?.orderOut(nil)
            voice.cancelCapture(reason: L("散步时暂停语音输入。", "Voice input pauses during roaming."))
            voice.stopSpeaking(); speech?.stopSpeaking(at: .immediate)
        }
        refreshRuntime()
    }

    @objc func roamModeMenuChanged(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let mode = PetRoamMode(rawValue: value) else { return }
        prefs.chibiRoamMode = mode
        refreshRuntime()
    }

    func syncRoaming() {
        guard pet != nil else { return }
        guard roamingEnabled, prefs.character == .chibi, interactionDecision.canRoam else {
            if roamController?.isRunning == true {
                roamController?.stop()
                showIdle()
            }
            return
        }
        // Chat/voice status changes often reconcile the UI. They must not
        // restart a journey or its rest timer on every notification.
        guard roamController?.isRunning != true else { return }
        if roamController == nil {
            let controller = PetRoamController()
            controller.onUpdate = { [weak self] state in self?.applyRoam(state) }
            roamController = controller
        }
        var engine = roamController?.engine ?? PetRoamEngine(ground: ground, visibleFrame: screenForPet().visibleFrame,
                                                            artworkSize: pet.frame.size, mode: prefs.chibiRoamMode)
        engine.configure(ground: ground, visibleFrame: screenForPet().visibleFrame,
                         artworkSize: pet.frame.size, mode: prefs.chibiRoamMode)
        applyRoam(engine)
        roamController?.start(engine: engine)
    }

    private func applyRoam(_ state: PetRoamEngine) {
        guard roamingEnabled, prefs.character == .chibi, let artwork = chibiArtwork else { return }
        ground = state.ground
        pet.setFrameOrigin(NSPoint(x: ground.x - pet.frame.width / 2, y: ground.y))
        let next = state.pose
        if next != lastRoamPose {
            petView.show(artwork.image(for: next))
            lastRoamPose = next
            // Persist once per rest, never at animation frequency.
            if next == .standing { savePosition() }
        }
    }
}
