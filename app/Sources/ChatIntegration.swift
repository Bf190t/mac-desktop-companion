import AppKit

extension AppDelegate {
    var diagnosticVisible:Bool {
        chatInspector.map{$0.window.isVisible && !$0.window.isMiniaturized} ?? false
    }
    var interactionDecision:InteractionPolicy.Decision {InteractionPolicy.evaluate(interactionState)}
    /// A mic click may turn voice input on first, so judge it as if voice were already enabled.
    var canStartVoiceOnClick:Bool {
        var s=interactionState;s.voiceEnabled=true
        return InteractionPolicy.evaluate(s).canStartVoice && !voice.isRecording && !voice.isProcessing && !voice.isRequestingPermission
    }
    var interactionState:InteractionPolicy.State {
        var s=InteractionPolicy.State()
        s.chatEnabled=effectiveChatEnabled;s.diagnosticVisible=diagnosticVisible;s.voiceEnabled=voice.enabled
        s.voicePhase=voice.isRecording || voice.isRequestingPermission ? .listening:voice.isProcessing ? .transcribing:voice.isSpeaking ? .speaking:.idle
        s.speechPlaying=chimeSpeaking;s.petHidden=prefs.petHidden;s.systemSuspended = !suspensions.isEmpty;s.quitting=isQuitting
        s.memoryPressure=chat.memoryPressureBlocked;s.clickThrough=effectiveClickThrough;s.modelBusy=chat.isBusy;s.modelStopping=chat.stopping
        s.inputFocused=effectiveChatEnabled && chatInput?.isKeyWindow == true;s.hasDraft = effectiveChatEnabled && !(chatInputView?.input.string.isEmpty ?? true) && ProcessInfo.processInfo.systemUptime-lastDraftEdit < 120
        s.dragging=dragging;s.userPaused=prefs.userPaused;s.energySaving=policy.energySaving
        s.chatBubbleVisible=ProcessInfo.processInfo.systemUptime<chatBubbleUntil
        s.roamSupported=prefs.character == .chibi;s.roamEnabled=roamingEnabled;s.isRoaming=roamingEnabled
        return s
    }
    func setupChat() {
        let migrated=ChatBoundary.migratedCustomPersona(prefs.chatPersona)
        if migrated != prefs.chatPersona {prefs.chatPersona=migrated}
        chat.longResidency=prefs.chatLongResidency;chat.customPersona=prefs.chatPersona
        chat.profile=prefs.userProfile
        chat.onProfileLearned={ [weak self] profile,items in self?.prefs.userProfile=profile;self?.chatInspector?.noteLearned(items) }
        chat.onChange={ [weak self] in self?.syncChatVisibility() }
        chat.onReply={ [weak self] text in
            guard let self=self else{return}
            self.showChatBubble(text)
            if self.prefs.readChatReplies,self.interactionDecision.canSpeakReply {
                self.stopChimeSpeech();self.voice.speak(text)
            }
        }
        let panel=PetInputPanel(),view=PetInputView(frame:panel.contentView!.bounds)
        view.autoresizingMask=[.width,.height];panel.contentView=view;chatInput=panel;chatInputView=view
        view.onSend={ [weak self] text in guard let self=self,self.interactionDecision.canSendFromPet else{return false};return self.sendChat(text) }
        view.onStop={ [weak self] in self?.chat.stopReply() }
        view.onTyping={ [weak self] in self?.lastDraftEdit=ProcessInfo.processInfo.systemUptime;self?.chat.userTyped();self?.prewarmReadVoice() }
    }
    /// Typing or a mic click means a reply is coming: load the read-aloud model meanwhile (C4).
    func prewarmReadVoice(){if prefs.readChatReplies{voice.prepareReadVoice()}}
    func sendChat(_ text:String)->Bool {
        guard chat.canSend,!voice.isRecording,!voice.isProcessing,!voice.isRequestingPermission else{return false}
        stopChimeSpeech();voice.stopSpeaking()
        return chat.send(text)
    }
    func positionChatInput() {
        guard let panel=chatInput,pet != nil else{return}
        let scale=prefs.height/prefs.character.defaultHeight
        let width=min(370,max(250,290*scale)),height=min(90,max(62,68*scale))
        let r=petVisibleFrame
        let origin=clampedOrigin(NSPoint(x:pet.frame.midX-width/2,y:ground.y+3),size:NSSize(width:width,height:height),visible:r)
        panel.setFrame(NSRect(origin:origin,size:NSSize(width:width,height:height)),display:true)
        if bubble?.isVisible == true {positionBubble()}
    }
    func syncChatVisibility() {
        guard let panel=chatInput,!reconcilingInteraction else{return}
        reconcilingInteraction=true;defer{reconcilingInteraction=false;syncRoaming()}
        chat.suspended = !suspensions.isEmpty || prefs.petHidden || isQuitting
        voice.memoryPressure=chat.memoryPressureBlocked
        let d=interactionDecision
        if d.shouldStopVoice {voice.shutdown(reason:L("语音已随当前状态暂停；恢复后需手动开始。", "Voice paused with the current app state. Start again manually when ready."))}
        if d.shouldStopSpeech {stopChimeSpeech();voice.stopSpeaking()}
        let releaseDecision=interactionDecision
        if releaseDecision.shouldReleaseModel,chat.hasWorker,!chat.stopping {chat.release(releaseDecision.releaseReason?.rawValue ?? "no_chat_client")}
        let refreshed=interactionDecision
        // Pet and input share the floating level; refreshRuntime re-fronts the pet, so the input
        // is ordered back above it every time instead of only when it was hidden.
        if refreshed.showChatInput {positionChatInput();if !panel.isVisible{panel.orderFrontRegardless()};panel.order(.above,relativeTo:pet.windowNumber)} else {panel.orderOut(nil)}
        chatInputView?.update(busy:chat.isBusy,canSend:chat.canSend && refreshed.canSendFromPet && !voice.isRequestingPermission,blockedReason:chat.status)
        chatInputView?.updateVoice(voice,canRecord:refreshed.showChatInput && canStartVoiceOnClick)
        chatInspector?.update()
        chatInspector?.updateVoice(voice,read:prefs.readChatReplies,canRecord:diagnosticVisible && canStartVoiceOnClick)
    }
    @objc func toggleChat() {
        guard !roamingEnabled else{return}
        prefs.chatEnabled.toggle();stopCharacterMotion()
        if !prefs.chatEnabled {if voiceOriginIsPet{voice.cancelCapture(reason:L("脚边聊天已关闭。", "Foot-level chat is off."))};hideBubble();chatBubbleUntil=0}
        syncChatVisibility();syncSettings()
    }
    func utilityVisibilityChanged(){
        syncChatVisibility()
        if settings?.isVisible != true && !diagnosticVisible {NSApp.setActivationPolicy(.accessory)}
    }
    @objc func showChatInspector() {
        guard suspensions.isEmpty else{return}
        if chatInspector == nil {
            let inspector=ChatInspector(service:chat)
            inspector.onLongMode={ [weak self] value in self?.prefs.chatLongResidency=value;self?.chat.longResidency=value;self?.voice.neural.idleUnloadSeconds=value ? 1800:300 }
            inspector.onPersona={ [weak self] value in self?.prefs.chatPersona=value;self?.chat.setPersona(value) }
            inspector.onTyping={ [weak self] in self?.chat.userTyped();self?.prewarmReadVoice() }
            inspector.currentProfile={ [weak self] in self?.chat.profile ?? UserProfile() }
            inspector.onProfile={ [weak self] profile in self?.prefs.userProfile=profile;self?.chat.profile=profile }
            inspector.maySend={ [weak self] in guard let self=self else{return false};return self.chat.canSend && self.interactionDecision.canSendFromDiagnostic && !self.voice.isRequestingPermission }
            inspector.onSend={ [weak self] text in guard let self=self,self.interactionDecision.canSendFromDiagnostic else{return false};return self.sendChat(text) }
            inspector.onVisibility={ [weak self] in self?.utilityVisibilityChanged() }
            inspector.onClose={ [weak self] in DispatchQueue.main.async{self?.utilityVisibilityChanged()} }
            inspector.onVoiceEnable={ [weak self] value in self?.prefs.voiceEnabled=value;self?.voice.enabled=value;self?.syncChatVisibility();self?.syncSettings() }
            inspector.onReadReplies={ [weak self] value in
                guard let self=self else{return}
                self.prefs.readChatReplies=value
                if value {self.voice.prepareReadVoice()} else {self.voice.stopSpeaking();self.voice.neural.shutdown()}
                self.syncChatVisibility()
            }
            inspector.onReadVoice={ [weak self] value in
                guard let self=self else{return}
                self.prefs.readVoice=value;self.voice.readVoice=value
                if self.prefs.readChatReplies {self.voice.prepareReadVoice()}
                self.syncChatVisibility()
            }
            inspector.onPreviewVoice={ [weak self] in
                guard let self=self,self.voice.enabled,!self.chat.isBusy else{return}
                self.stopChimeSpeech();self.voice.speak(ReadVoice.previewText)
            }
            // The cancel button stops any capture; closing or minimizing only stops one started here.
            inspector.onCancelVoice={ [weak self] in guard let self=self,self.voice.isRecording || self.voice.isProcessing || self.voice.isRequestingPermission else{return};self.voice.cancelCapture() }
            inspector.onWindowHidden={ [weak self] in guard let self=self,!self.voiceOriginIsPet,self.voice.isRecording || self.voice.isProcessing || self.voice.isRequestingPermission else{return};self.voice.cancelCapture() }
            inspector.onStopRead={ [weak self] in self?.voice.stopSpeaking() }
            // The helper must not run from files that are being removed.
            inspector.onRemoveVoice={ [weak self] in self?.voice.stopSpeaking();self?.voice.neural.shutdown() }
            inspector.onVoiceInstallChange={ [weak self] in self?.syncChatVisibility() }
            inspector.record.onToggle={ [weak self] in self?.toggleVoiceCapture(fromPet:false) }
            chatInspector=inspector
        }
        constrainUtilityWindows()
        if !CommandLine.arguments.contains("--ui-check"){NSApp.setActivationPolicy(.regular);chatInspector?.show()}else{chatInspector?.update()}
        syncChatVisibility()
    }
    func showChatBubble(_ text:String) {
        guard interactionDecision.canShowChatBubble else{return}
        // Room for a reply plus the crisis-support line (B6).
        let reply=String(text.prefix(200))
        bubbleTimer?.invalidate();bubbleView.label.stringValue=reply
        let width:CGFloat=min(320,max(260,prefs.height*0.7))
        let measured=(reply as NSString).boundingRect(with:NSSize(width:width-34,height:300),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium)])
        let height=min(240,max(94,ceil(measured.height)+48))
        bubble.setContentSize(NSSize(width:width,height:height));bubbleView.frame=NSRect(x:0,y:0,width:width,height:height);bubbleView.layoutText()
        positionBubble();bubble.orderFrontRegardless();chatBubbleUntil=ProcessInfo.processInfo.systemUptime+30
        bubbleTimer=Timer.scheduledTimer(withTimeInterval:30,repeats:false){[weak self] _ in self?.hideBubble();self?.chatBubbleUntil=0}
        bubbleTimer?.tolerance=0.5
    }
    func setupVoice(){
        voice.enabled=prefs.voiceEnabled
        voice.readVoice=prefs.readVoice;voice.neural.idleUnloadSeconds=prefs.chatLongResidency ? 1800:300
        voice.onChange={ [weak self] in
            guard let self=self else{return}
            self.syncChatVisibility()
            // Clear a short notice from the foot input once it expires.
            if self.voice.hasRecentNotice {DispatchQueue.main.asyncAfter(deadline:.now()+8.2){[weak self] in self?.syncChatVisibility()}}
        }
        voice.onTranscript={ [weak self] text in
            guard let self=self,!self.prefs.petHidden,self.suspensions.isEmpty else{return}
            if self.voiceOriginIsPet {self.chatInputView?.appendTranscript(text)} else {self.chatInspector?.appendTranscript(text)}
            self.chat.userTyped();self.prewarmReadVoice();self.syncChatVisibility()
        }
        chatInputView?.mic.onToggle={ [weak self] in self?.toggleVoiceCapture(fromPet:true) }
    }
    /// A mic click turns voice input on for this attempt. The switch is saved only when capture
    /// really starts (or asks for permission), so e.g. a missing microphone leaves voice off.
    /// Turning voice on never records by itself; only this click starts a capture.
    @discardableResult func beginVoice(fromPet:Bool)->UInt64?{
        if fromPet && chatInput?.isVisible != true {return nil}
        if !fromPet && !diagnosticVisible {return nil}
        guard canStartVoiceOnClick else{return nil}
        let wasEnabled=voice.enabled
        if !wasEnabled {voice.enabled=true}
        guard interactionDecision.canStartVoice,voice.canRecord else{if !wasEnabled{voice.enabled=false};return nil}
        // Recording takes a few seconds: load the chat model in parallel so the reply is quick.
        chat.prewarm();prewarmReadVoice()
        voiceOriginIsPet=fromPet;stopChimeSpeech();voice.beginCapture()
        let started=voice.isRecording || voice.isRequestingPermission
        if !wasEnabled {
            if started {prefs.voiceEnabled=true} else {let note=voice.status;voice.enabled=false;voice.showNotice(note)}
            syncSettings()
        }
        return started ? voice.captureGeneration:nil
    }
    /// Click once to start, click again (on either mic) to stop and transcribe. The text goes to
    /// the side where recording was stopped. During the permission dialog clicks are ignored.
    func toggleVoiceCapture(fromPet:Bool){
        if voice.isRecording {voiceOriginIsPet=fromPet;voice.finishCapture()}
        else if !voice.isProcessing && !voice.isRequestingPermission {beginVoice(fromPet:fromPet)}
    }
    /// Voice input is part of the merged chat window now; kept for old menu/QA callers.
    @objc func showVoiceExperiment(){showChatInspector()}
}
