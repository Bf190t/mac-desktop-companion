import AppKit

extension AppDelegate {
    var diagnosticVisible:Bool {
        [chatInspector?.window,voiceWindow?.window].compactMap{$0}.contains{$0.isVisible && !$0.isMiniaturized}
    }
    var interactionDecision:InteractionPolicy.Decision {
        var s=InteractionPolicy.State()
        s.chatEnabled=effectiveChatEnabled;s.diagnosticVisible=diagnosticVisible;s.voiceEnabled=voice.enabled
        s.voicePhase=voice.isRecording || voice.isRequestingPermission ? .listening:voice.isProcessing ? .transcribing:voice.isSpeaking ? .speaking:.idle
        s.speechPlaying=speech?.isSpeaking == true;s.petHidden=prefs.petHidden;s.systemSuspended = !suspensions.isEmpty;s.quitting=isQuitting
        s.memoryPressure=chat.memoryPressureBlocked;s.clickThrough=effectiveClickThrough;s.modelBusy=chat.isBusy;s.modelStopping=chat.stopping
        s.inputFocused=effectiveChatEnabled && chatInput?.isKeyWindow == true;s.hasDraft = effectiveChatEnabled && !(chatInputView?.input.string.isEmpty ?? true)
        s.dragging=dragging;s.userPaused=prefs.userPaused;s.energySaving=policy.energySaving
        s.chatBubbleVisible=ProcessInfo.processInfo.systemUptime<chatBubbleUntil
        s.roamSupported=prefs.character == .chibi;s.roamEnabled=roamingEnabled;s.isRoaming=roamingEnabled
        return InteractionPolicy.evaluate(s)
    }
    func setupChat() {
        let migrated=ChatBoundary.migratedCustomPersona(prefs.chatPersona)
        if migrated != prefs.chatPersona {prefs.chatPersona=migrated}
        chat.longResidency=prefs.chatLongResidency;chat.customPersona=prefs.chatPersona
        chat.onChange={ [weak self] in self?.syncChatVisibility() }
        chat.onReply={ [weak self] text in
            guard let self=self else{return}
            self.showChatBubble(text)
            if self.prefs.readChatReplies,self.interactionDecision.canSpeakReply {
                self.speech?.stopSpeaking(at:.immediate);self.voice.speak(text)
            }
        }
        let panel=PetInputPanel(),view=PetInputView(frame:panel.contentView!.bounds)
        view.autoresizingMask=[.width,.height];panel.contentView=view;chatInput=panel;chatInputView=view
        view.onSend={ [weak self] text in guard let self=self,self.interactionDecision.canSendFromPet else{return false};return self.sendChat(text) }
        view.onStop={ [weak self] in self?.chat.stopReply() }
        view.onTyping={ [weak self] in self?.chat.userTyped() }
    }
    func sendChat(_ text:String)->Bool {
        guard chat.canSend,!voice.isRecording,!voice.isProcessing,!voice.isRequestingPermission else{return false}
        speech?.stopSpeaking(at:.immediate);voice.stopSpeaking()
        return chat.send(text)
    }
    func positionChatInput() {
        guard let panel=chatInput,pet != nil else{return}
        let scale=prefs.height/prefs.character.defaultHeight
        let width=min(370,max(250,290*scale)),height=min(90,max(62,68*scale))
        let r=screenForPet().visibleFrame
        let origin=clampedOrigin(NSPoint(x:pet.frame.midX-width/2,y:ground.y+3),size:NSSize(width:width,height:height),visible:r)
        panel.setFrame(NSRect(origin:origin,size:NSSize(width:width,height:height)),display:true)
        if bubble?.isVisible == true {positionBubble()}
    }
    func syncChatVisibility() {
        guard let panel=chatInput,!reconcilingInteraction else{return}
        reconcilingInteraction=true;defer{reconcilingInteraction=false;syncRoaming()}
        chat.suspended = !suspensions.isEmpty || prefs.petHidden || isQuitting
        let d=interactionDecision
        if d.shouldStopVoice {voice.shutdown(reason:L("语音已随当前状态暂停；恢复后需手动开始。", "Voice paused with the current app state. Start again manually when ready."))}
        if d.shouldStopSpeech {speech?.stopSpeaking(at:.immediate);voice.stopSpeaking()}
        let releaseDecision=interactionDecision
        if releaseDecision.shouldReleaseModel,chat.hasWorker,!chat.stopping {chat.release(releaseDecision.releaseReason?.rawValue ?? "no_chat_client")}
        let refreshed=interactionDecision
        if refreshed.showChatInput {positionChatInput();if !panel.isVisible{panel.orderFrontRegardless()}} else {panel.orderOut(nil)}
        chatInputView?.update(busy:chat.isBusy,canSend:chat.canSend && refreshed.canSendFromPet && !voice.isRequestingPermission,blockedReason:chat.status)
        chatInputView?.updateVoice(voice,canRecord:refreshed.canStartVoice && refreshed.showChatInput && voice.canRecord)
        chatInspector?.update()
        voiceWindow?.update(voice:voice,chat:chat,read:prefs.readChatReplies,canRecord:refreshed.canStartVoice && voice.canRecord,canSend:chat.canSend && refreshed.canSendFromDiagnostic && !voice.isRequestingPermission)
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
            inspector.onLongMode={ [weak self] value in self?.prefs.chatLongResidency=value;self?.chat.longResidency=value }
            inspector.onPersona={ [weak self] value in self?.prefs.chatPersona=value;self?.chat.setPersona(value) }
            inspector.onTyping={ [weak self] in self?.chat.userTyped() }
            inspector.maySend={ [weak self] in guard let self=self else{return false};return self.chat.canSend && self.interactionDecision.canSendFromDiagnostic && !self.voice.isRequestingPermission }
            inspector.onSend={ [weak self] text in guard let self=self,self.interactionDecision.canSendFromDiagnostic else{return false};return self.sendChat(text) }
            inspector.onVisibility={ [weak self] in self?.utilityVisibilityChanged() }
            inspector.onClose={ [weak self] in DispatchQueue.main.async{self?.utilityVisibilityChanged()} }
            chatInspector=inspector
        }
        constrainUtilityWindows()
        if !CommandLine.arguments.contains("--ui-check"){NSApp.setActivationPolicy(.regular);chatInspector?.show()}else{chatInspector?.update()}
        syncChatVisibility()
    }
    func showChatBubble(_ text:String) {
        guard interactionDecision.canShowChatBubble else{return}
        let reply=String(text.prefix(120))
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
        voice.onChange={ [weak self] in self?.syncChatVisibility() }
        voice.onTranscript={ [weak self] text in
            guard let self=self,!self.prefs.petHidden,self.suspensions.isEmpty else{return}
            if self.voiceOriginIsPet {self.chatInputView?.appendTranscript(text)} else {self.voiceWindow?.appendTranscript(text)}
            self.chat.userTyped();self.syncChatVisibility()
        }
        chatInputView?.mic.onPress={ [weak self] in self?.beginVoice(fromPet:true) }
        chatInputView?.mic.onRelease={ [weak self] token in self?.finishVoice(token:token) }
        chatInputView?.mic.onKeyboardToggle={ [weak self] in self?.toggleVoiceCapture(fromPet:true) }
    }
    @discardableResult func beginVoice(fromPet:Bool)->UInt64?{
        guard interactionDecision.canStartVoice,voice.canRecord else{return nil}
        if fromPet && chatInput?.isVisible != true {return nil}
        if !fromPet && (voiceWindow?.window.isVisible != true || voiceWindow?.window.isMiniaturized == true){return nil}
        voiceOriginIsPet=fromPet;speech?.stopSpeaking(at:.immediate);voice.beginCapture()
        return voice.isRecording || voice.isRequestingPermission ? voice.captureGeneration:nil
    }
    func finishVoice(token:UInt64){if voice.captureGeneration == token {voice.finishCapture()}}
    func toggleVoiceCapture(fromPet:Bool){if voice.isRecording{if voiceOriginIsPet == fromPet{voice.finishCapture()}}else{beginVoice(fromPet:fromPet)}}
    @objc func showVoiceExperiment(){
        guard suspensions.isEmpty else{return}
        if voiceWindow == nil {
            let c=VoiceExperimentController()
            c.onEnable={ [weak self] value in self?.prefs.voiceEnabled=value;self?.voice.enabled=value;self?.syncChatVisibility() }
            c.onReadReplies={ [weak self] value in self?.prefs.readChatReplies=value;if !value{self?.voice.stopSpeaking()};self?.syncChatVisibility() }
            c.onSend={ [weak self] text in guard let self=self,self.interactionDecision.canSendFromDiagnostic else{return false};return self.sendChat(text) }
            c.onCancel={ [weak self] in guard let self=self,!self.voiceOriginIsPet else{return};self.voice.cancelCapture() }
            c.onStopRead={ [weak self] in self?.voice.stopSpeaking() }
            c.onTyping={ [weak self] in self?.chat.userTyped() }
            c.onVisibility={ [weak self] in self?.utilityVisibilityChanged() }
            c.hold.onPress={ [weak self] in self?.beginVoice(fromPet:false) }
            c.hold.onRelease={ [weak self] token in self?.finishVoice(token:token) }
            c.hold.onKeyboardToggle={ [weak self] in self?.toggleVoiceCapture(fromPet:false) }
            voiceWindow=c
        }
        constrainUtilityWindows()
        if !CommandLine.arguments.contains("--ui-check"){NSApp.setActivationPolicy(.regular);voiceWindow?.show()}
        else {voiceWindow?.window.orderFront(nil)}
        syncChatVisibility()
    }
}
