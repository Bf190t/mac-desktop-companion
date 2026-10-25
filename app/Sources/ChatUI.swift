import AppKit

final class PetInputPanel: NSPanel {
    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}
    init() {
        super.init(contentRect:NSRect(x:0,y:0,width:290,height:66),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        title=L("角色聊天输入", "Companion chat input");backgroundColor = .clear;isOpaque=false;hasShadow=true
        level = .floating;hidesOnDeactivate=false;isReleasedWhenClosed=false
        collectionBehavior=[.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenNone,.fullScreenDisallowsTiling]
        animationBehavior = .none
    }
}

final class PetInputView: NSVisualEffectView, NSTextViewDelegate {
    let input=NSTextView()
    let hint=NSTextField(labelWithString:L("聊一句 · 回车发送", "Say something · Enter to send"))
    private let scroll=NSScrollView()
    private let send=NSButton()
    let mic=HoldToTalkButton(frame:.zero)
    var onSend:((String)->Bool)?
    var onStop:(()->Void)?
    var onTyping:(()->Void)?
    private var busy=false
    override init(frame:NSRect) {
        super.init(frame:frame)
        material = .hudWindow;blendingMode = .behindWindow;state = .active
        wantsLayer=true;layer?.cornerRadius=15;layer?.masksToBounds=true
        layer?.borderWidth=0.7;layer?.borderColor=NSColor.white.withAlphaComponent(0.24).cgColor
        hint.font = .systemFont(ofSize:10);hint.textColor = .secondaryLabelColor;addSubview(hint)
        input.isRichText=false;input.font = .systemFont(ofSize:13);input.textColor = .labelColor
        input.backgroundColor = .clear;input.drawsBackground=false;input.isHorizontallyResizable=false;input.isVerticallyResizable=true
        input.autoresizingMask=[.width];input.textContainer?.widthTracksTextView=true;input.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        input.textContainerInset=NSSize(width:0,height:3);input.delegate=self
        input.isAutomaticQuoteSubstitutionEnabled=false;input.isAutomaticDashSubstitutionEnabled=false
        input.setAccessibilityLabel(L("角色脚边输入消息", "Message the companion"))
        scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=input;addSubview(scroll)
        send.image=NSImage(systemSymbolName:"arrow.up.circle.fill",accessibilityDescription:L("发送消息", "Send message"))
        send.imageScaling = .scaleProportionallyUpOrDown;send.isBordered=false;send.target=self;send.action=#selector(submit);send.toolTip=L("发送；回复过程中点击可停止", "Send; click while generating to stop the reply");addSubview(send)
        mic.image=NSImage(systemSymbolName:"mic",accessibilityDescription:L("按住说话", "Hold to talk"))
        mic.isBordered=false;mic.isEnabled=false;mic.toolTip=L("先在语音实验中开启；按住说话，松开后确认文字再发送", "Enable the voice experiment first. Hold to talk, then review the transcript before sending.");addSubview(mic)
    }
    required init?(coder:NSCoder){fatalError()}
    override func layout() {
        super.layout();let w=bounds.width,h=bounds.height
        hint.frame=NSRect(x:12,y:h-19,width:w-24,height:13)
        scroll.frame=NSRect(x:12,y:8,width:w-91,height:h-31)
        send.frame=NSRect(x:w-72,y:9,width:28,height:30);mic.frame=NSRect(x:w-38,y:9,width:24,height:30)
        input.font = .systemFont(ofSize:h>76 ? 14:13)
    }
    func update(busy:Bool,canSend:Bool,blockedReason:String?=nil) {
        self.busy=busy;send.isEnabled=busy || canSend
        send.image=NSImage(systemSymbolName:busy ? "stop.circle.fill":"arrow.up.circle.fill",accessibilityDescription:busy ? L("停止回复", "Stop reply"):L("发送消息", "Send message"))
        hint.stringValue=busy ? L("正在想… · 点击方块停止", "Thinking… · Click the square to stop"):(!canSend ? String((blockedReason.map{Localizer.text($0)} ?? L("暂时无法发送", "Sending is temporarily unavailable")).prefix(38)):L("聊一句 · 回车发送", "Say something · Enter to send"))
        hint.toolTip=blockedReason
    }
    func updateVoice(_ voice:PetVoiceService,canRecord:Bool){
        mic.isEnabled=canRecord || voice.isRecording
        mic.image=NSImage(systemSymbolName:voice.isRecording ? "mic.fill":"mic",accessibilityDescription:L("按住说话", "Hold to talk"))
        if voice.isRecording || voice.isProcessing || voice.isRequestingPermission {hint.stringValue=Localizer.text(voice.status)}
    }
    func appendTranscript(_ text:String){input.string += (input.string.isEmpty ? "":"\n")+text;input.scrollToEndOfDocument(nil);onTyping?()}
    @objc private func submit(){if busy{onStop?()}else if onSend?(input.string)==true{input.string=""}}
    func textView(_ textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
            if !busy {submit()};return true
        };return false
    }
    func textDidChange(_ notification:Notification){onTyping?()}
}

final class ChatInspector: NSObject,NSWindowDelegate,NSTextViewDelegate {
    let window:NSWindow
    private let service:PetChatService
    private let status=NSTextField(wrappingLabelWithString:"")
    private let metrics=NSTextField(wrappingLabelWithString:"")
    private let releaseNote=NSTextField(wrappingLabelWithString:"")
    private let context=NSTextField(wrappingLabelWithString:"")
    private let transcript=NSTextView(), input=NSTextView()
    private let send=NSButton(title:L("发送", "Send"),target:nil,action:nil),stop=NSButton(title:L("停止回复", "Stop reply"),target:nil,action:nil),unload=NSButton(title:L("卸载模型", "Unload model"),target:nil,action:nil),clear=NSButton(title:L("清空对话", "Clear chat"),target:nil,action:nil)
    private let longMode=NSButton(checkboxWithTitle:L("实验：长驻留 30 分钟（适合插电的 Mac mini）", "Experiment: keep loaded for 30 min (for plugged-in Macs)"),target:nil,action:nil)
    private let installerStatus=NSTextField(wrappingLabelWithString:"")
    private let installModel=NSButton(title:L("安装可选聊天模型…", "Install optional chat model…"),target:nil,action:nil)
    private let cancelInstall=NSButton(title:L("取消下载", "Cancel download"),target:nil,action:nil)
    private let removeModel=NSButton(title:L("移除模型资源", "Remove model files"),target:nil,action:nil)
    private var personaWindow:NSWindow?,personaEditor:NSTextView?
    var onLongMode:((Bool)->Void)?
    var onPersona:((String)->Void)?
    var onClose:(()->Void)?
    var onVisibility:(()->Void)?
    var onSend:((String)->Bool)?
    var maySend:(()->Bool)?
    var onTyping:(()->Void)?
    init(service:PetChatService) {
        self.service=service
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:820),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init();window.title=L("本地模型 · 状态与调试", "Local model · Status & debugging");window.isReleasedWhenClosed=false;window.delegate=self
        DesktopWindowBehavior.configure(window,minimumContentSize:NSSize(width:700,height:780));window.setFrameAutosaveName("CompanionChatInspector");window.center()
        let title=label(L("本地聊天，和角色共用一段对话", "Local chat, shared with your companion"),21,.semibold)
        let note=NSTextField(wrappingLabelWithString:L("Qwen3 1.7B · 文字聊天 · 不读取电脑状态、不执行电脑操作 · 语音从设置单独开启，无唤醒监听", "Qwen3 1.7B · Text chat · No computer readings or actions · Voice is enabled separately; no wake-word listening"))
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize:13,weight:.medium);status.textColor = .systemBlue
        for l in [metrics,releaseNote,context] {l.font = .systemFont(ofSize:11);l.textColor = .secondaryLabelColor;l.isSelectable=true}
        let persona=NSButton(title:L("性格提示词…", "Personality prompt…"),target:self,action:#selector(editPersona));persona.bezelStyle = .rounded
        longMode.target=self;longMode.action=#selector(changeLongMode)
        let toolbar=NSStackView(views:[longMode,persona]);toolbar.orientation = .horizontal;toolbar.spacing=10
        for (button,action) in [(installModel,#selector(installOptionalModel)),(cancelInstall,#selector(cancelOptionalInstall)),(removeModel,#selector(removeOptionalModel))] {button.target=self;button.action=action;button.bezelStyle = .rounded}
        let installActions=NSStackView(views:[installModel,cancelInstall,removeModel]);installActions.orientation = .horizontal;installActions.spacing=8
        installerStatus.font = .systemFont(ofSize:11);installerStatus.textColor = .secondaryLabelColor
        let memoryHint=NSTextField(wrappingLabelWithString:L("默认闲置120秒后释放；长驻留仍受内存压力、锁屏、熄屏和退出限制。内存为推理进程系统计账值，CPU 100%约为一核，不代表耗电。", "Unloads after 120 seconds idle. Longer residency still stops for memory pressure, lock, display sleep, and exit. Memory is process-accounted usage; CPU 100% is roughly one core, not a power reading."))
        memoryHint.font = .systemFont(ofSize:11);memoryHint.textColor = .secondaryLabelColor
        let outputScroll=Self.textScroll(transcript,editable:false);transcript.setAccessibilityLabel(L("模型检查聊天记录", "Model inspector chat history"))
        let inputScroll=Self.textScroll(input,editable:true);input.setAccessibilityLabel(L("模型检查输入消息", "Model inspector message input"));input.delegate=self
        inputScroll.heightAnchor.constraint(equalToConstant:70).isActive=true
        for (b,action) in [(send,#selector(sendMessage)),(stop,#selector(stopMessage)),(unload,#selector(unloadModel)),(clear,#selector(clearChat))] {b.target=self;b.action=action;b.bezelStyle = .rounded}
        let actions=NSStackView(views:[send,stop,unload,clear]);actions.orientation = .horizontal;actions.spacing=10
        let footer=NSTextField(wrappingLabelWithString:L("回车发送 · Shift＋回车换行 · 退出即清空聊天；关闭本窗口不影响脚边聊天。", "Enter sends · Shift+Enter adds a line · Quitting clears chat; closing this window keeps companion chat available."));footer.font = .systemFont(ofSize:11)
        let stack=NSStackView(views:[title,note,installActions,installerStatus,status,toolbar,memoryHint,metrics,releaseNote,context,outputScroll,inputScroll,actions,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false
        let root=window.contentView!;root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-18),outputScroll.widthAnchor.constraint(equalTo:stack.widthAnchor),inputScroll.widthAnchor.constraint(equalTo:stack.widthAnchor),outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:140)])
        for view in [note,installerStatus,status,metrics,releaseNote,context,memoryHint,footer] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        ModelInstallation.shared.onChange={ [weak self] in self?.update() }
        update()
    }
    static func textScroll(_ view:NSTextView,editable:Bool)->NSScrollView {
        let s=NSScrollView();s.hasVerticalScroller=true;s.autohidesScrollers=true;s.borderType = .bezelBorder;s.translatesAutoresizingMaskIntoConstraints=false
        view.isEditable=editable;view.isRichText=false;view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.textContainer?.widthTracksTextView=true;view.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask=[.width];view.font = .systemFont(ofSize:14);view.textContainerInset=NSSize(width:10,height:8)
        view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false;s.documentView=view;return s
    }
    func hideAuxiliaryWindows(){personaWindow?.orderOut(nil)}
    func show(){if window.isMiniaturized{window.deminiaturize(nil)};window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);service.inspecting=true;window.makeFirstResponder(input);update()}
    func update(){
        let installation=ModelInstallation.shared
        installerStatus.stringValue=installation.status
        installModel.isEnabled = !installation.isInstalled && !installation.isBusy && !service.hasWorker
        cancelInstall.isEnabled=installation.isBusy
        removeModel.isEnabled=installation.isInstalled && !installation.isBusy && !service.hasWorker && !service.isBusy
        removeModel.toolTip=L("先卸载正在使用的模型，再移除已下载资源。", "Unload the active model before removing downloaded files.")
        status.stringValue=Localizer.text(service.status)
        let remain=service.idleRemaining.map{String(format:L("%.0f 秒", "%.0f sec"),max(0,$0))} ?? "—"
        metrics.stringValue=L("推理内存：\(Localizer.text(service.memory)) · CPU：\(service.cpu) · 待机剩余：\(remain)\n\(Localizer.text(service.timing))", "Inference memory: \(Localizer.text(service.memory)) · CPU: \(service.cpu) · Idle remaining: \(remain)\n\(Localizer.text(service.timing))")
        releaseNote.stringValue=L("最近释放原因：\(Localizer.text(service.lastRelease))", "Last unload: \(Localizer.text(service.lastRelease))");context.stringValue=Localizer.text(service.context)
        longMode.state=service.longResidency ? .on:.off
        send.isEnabled=(maySend?() ?? service.canSend);stop.isEnabled=service.isBusy;unload.isEnabled=service.hasWorker && !service.stopping;clear.isEnabled=service.canSend
        let lines=service.lines.map{($0.role == "user" ? L("你", "You"):L("角色", "Mochi") + ($0.eligible ? "":L("（未完成，不用于后续对话）", "(Incomplete; excluded from future context)")))+"\n"+$0.text}
        let current=service.draft.isEmpty ? []:[L("生成中的草稿（尚未作为气泡发布）\n", "Draft reply (not yet shown as a bubble)\n")+service.draft]
        let text=(lines+current).joined(separator:"\n\n")
        if transcript.string != text {transcript.string=text;transcript.scrollToEndOfDocument(nil)}
    }
    @objc private func installOptionalModel(){ModelInstallation.shared.install()}
    @objc private func cancelOptionalInstall(){ModelInstallation.shared.cancel()}
    @objc private func removeOptionalModel(){
        guard !service.hasWorker,!service.isBusy else{return}
        ModelInstallation.shared.uninstall()
    }
    @objc private func sendMessage(){if (onSend?(input.string) ?? service.send(input.string)){input.string=""}}
    @objc private func stopMessage(){service.stopReply()}
    @objc private func unloadModel(){service.release("user_unload")}
    @objc private func clearChat(){service.clear()}
    @objc private func changeLongMode(){onLongMode?(longMode.state == .on)}
    func textView(_ textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        if textView === input,commandSelector == #selector(NSResponder.insertNewline(_:)),NSApp.currentEvent?.modifierFlags.contains(.shift) != true {sendMessage();return true};return false
    }
    func textDidChange(_ notification:Notification){if notification.object as? NSTextView === input{onTyping?()}}
    func windowWillClose(_ notification:Notification){if notification.object as? NSWindow === window {hideAuxiliaryWindows();service.inspecting=false;onClose?()}}
    func windowDidMiniaturize(_ notification:Notification){if notification.object as? NSWindow === window {service.inspecting=false;onVisibility?()}}
    func windowDidDeminiaturize(_ notification:Notification){if notification.object as? NSWindow === window {service.inspecting=true;onVisibility?()}}
    func windowWillUseStandardFrame(_ window:NSWindow,defaultFrame:NSRect)->NSRect{DesktopWindowBehavior.standardFrame(for:window,defaultFrame:defaultFrame)}
    @objc private func editPersona(){
        if personaWindow == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            w.title=L("角色性格提示词", "Companion personality prompt");w.isReleasedWhenClosed=false;w.delegate=self;DesktopWindowBehavior.configure(w,minimumContentSize:NSSize(width:510,height:380));w.center()
            let editor=NSTextView();let scroll=Self.textScroll(editor,editable:true);personaEditor=editor
            let note=NSTextField(wrappingLabelWithString:L("修改角色语气，不训练模型。保存会开始新对话；短回复、无电脑状态及无操作能力的边界仍保留。限1500字。", "Changes the voice of the character, not model training. Saving starts a new conversation. Short replies and no computer-reading/action abilities remain enforced. Up to 1,500 characters."))
            note.font = .systemFont(ofSize:12)
            let save=NSButton(title:L("保存并开始新对话", "Save & start new chat"),target:self,action:#selector(savePersona));save.bezelStyle = .rounded
            let restore=NSButton(title:L("恢复默认", "Restore default"),target:self,action:#selector(resetPersona));restore.bezelStyle = .rounded
            let actions=NSStackView(views:[restore,save]);actions.orientation = .horizontal;actions.spacing=12
            let stack=NSStackView(views:[note,scroll,actions]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
            let root=w.contentView!;root.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),note.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:200)])
            personaWindow=w
        }
        personaEditor?.string=service.persona;personaWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func resetPersona(){personaEditor?.string=ChatBoundary.defaultPersona}
    @objc private func savePersona(){
        guard service.canSend else {NSSound.beep();return}
        let text=(personaEditor?.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,text.unicodeScalars.count<=1500 else {let a=NSAlert();a.messageText=L("请保留1–1500字的性格设定", "Please enter a personality prompt of 1–1,500 characters");a.runModal();return}
        onPersona?(text == ChatBoundary.defaultPersona ? "":text);personaWindow?.orderOut(nil)
    }
}
