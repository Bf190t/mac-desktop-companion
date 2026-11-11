import AppKit

extension NSWindow.Level {
    /// The pet uses .floating. Its foot input and speech bubble sit one level higher, so
    /// clicking the pet or closing its menu can never raise the pet over them.
    static let petOverlay = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
}

final class PetInputPanel: NSPanel {
    override var canBecomeKey: Bool {true}
    override var canBecomeMain: Bool {false}
    init() {
        super.init(contentRect:NSRect(x:0,y:0,width:290,height:66),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        title=L("角色聊天输入", "Companion chat input");backgroundColor = .clear;isOpaque=false;hasShadow=true
        level = .petOverlay;hidesOnDeactivate=false;isReleasedWhenClosed=false
        collectionBehavior=[.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenNone,.fullScreenDisallowsTiling]
        animationBehavior = .none
    }
}

final class PetInputView: NSVisualEffectView, NSTextViewDelegate {
    let input=NSTextView()
    let hint=NSTextField(labelWithString:L("聊一句 · 回车发送", "Say something · Enter to send"))
    private let scroll=NSScrollView()
    private let send=NSButton()
    let mic=RecordToggleButton(frame:.zero)
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
        mic.image=NSImage(systemSymbolName:"mic",accessibilityDescription:L("开始录音", "Start recording"))
        mic.isBordered=false;mic.isEnabled=false;mic.toolTip=L("点一下开始录音，再点一下停止并转写；转写后检查文字再发送", "Click to start recording, click again to stop and transcribe; check the text before sending");addSubview(mic)
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
        mic.image=NSImage(systemSymbolName:voice.isRecording ? "stop.circle.fill":"mic",accessibilityDescription:voice.isRecording ? L("停止录音并转写", "Stop recording and transcribe"):L("开始录音", "Start recording"))
        mic.contentTintColor=voice.isRecording ? .systemRed:nil
        mic.toolTip=voice.isRecording ? L("再点一下停止并转写", "Click again to stop and transcribe"):L("点一下开始录音，再点一下停止并转写；转写后检查文字再发送", "Click to start recording, click again to stop and transcribe; check the text before sending")
        if voice.isRecording || voice.isProcessing || voice.isRequestingPermission || voice.hasRecentNotice {hint.stringValue=voice.status}
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
    private let transcript=NSTextView()
    let input=NSTextView()
    // Voice input lives in the same window: record → transcript lands in `input` → check → send.
    let voiceEnable=NSButton(checkboxWithTitle:L("开启语音输入", "Enable voice input"),target:nil,action:nil)
    let readReplies=NSButton(checkboxWithTitle:L("朗读回复", "Read replies aloud"),target:nil,action:nil)
    // C4: reply voice (Qwen3-TTS speakers or the system voice) and a one-sentence preview.
    let readVoicePopup=NSPopUpButton(frame:.zero,pullsDown:false)
    let previewVoice=NSButton(title:L("试听", "Preview"),target:nil,action:nil)
    // Optional reading voice (ModelInstallation.voice): install, cancel, remove.
    private let installVoice=NSButton(title:L("安装朗读声音…", "Install reading voice…"),target:nil,action:nil)
    private let cancelVoiceInstall=NSButton(title:L("取消下载", "Cancel download"),target:nil,action:nil)
    private let removeVoice=NSButton(title:L("移除朗读声音", "Remove reading voice"),target:nil,action:nil)
    private let voiceInstallStatus=NSTextField(wrappingLabelWithString:"")
    var onRemoveVoice:(()->Void)?,onVoiceInstallChange:(()->Void)?
    let record=RecordToggleButton(frame:.zero)
    private let cancelVoice=NSButton(title:L("取消录音 / 转写", "Cancel recording / transcription"),target:nil,action:nil)
    private let stopRead=NSButton(title:L("停止朗读", "Stop reading"),target:nil,action:nil)
    private let voiceStatus=NSTextField(wrappingLabelWithString:"")
    private let send=NSButton(title:L("发送", "Send"),target:nil,action:nil),stop=NSButton(title:L("停止回复", "Stop reply"),target:nil,action:nil),unload=NSButton(title:L("卸载模型", "Unload model"),target:nil,action:nil),clear=NSButton(title:L("清空对话", "Clear chat"),target:nil,action:nil)
    private let longMode=NSButton(checkboxWithTitle:L("长驻留 30 分钟（适合插电的 Mac mini）", "Keep loaded for 30 min (for plugged-in Macs)"),target:nil,action:nil)
    // The optional chat model is installed from here into the app's own Application Support folder.
    private let installerStatus=NSTextField(wrappingLabelWithString:"")
    private let installModel=NSButton(title:L("安装可选聊天模型…", "Install optional chat model…"),target:nil,action:nil)
    private let cancelInstall=NSButton(title:L("取消下载", "Cancel download"),target:nil,action:nil)
    private let removeModel=NSButton(title:L("移除模型资源", "Remove model files"),target:nil,action:nil)
    private var personaWindow:NSWindow?,personaEditor:NSTextView?
    // B3: the small "about you" note, edited in its own window.
    private let profileButton=NSButton(title:L("记住的关于你…", "What I remember about you…"),target:nil,action:nil)
    private var profileWindow:NSWindow?,profileNameField:NSTextField?,profileFactsView:NSTextView?
    var currentProfile:(()->UserProfile)?
    var onProfile:((UserProfile)->Void)?
    var onLongMode:((Bool)->Void)?
    var onPersona:((String)->Void)?
    var onClose:(()->Void)?
    var onVisibility:(()->Void)?
    var onSend:((String)->Bool)?
    var maySend:(()->Bool)?
    var onTyping:(()->Void)?
    var onReadVoice:((ReadVoice)->Void)?,onPreviewVoice:(()->Void)?
    var onVoiceEnable:((Bool)->Void)?,onReadReplies:((Bool)->Void)?,onCancelVoice:(()->Void)?,onWindowHidden:(()->Void)?,onStopRead:(()->Void)?
    init(service:PetChatService) {
        self.service=service
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:880),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init();window.title=L("本地聊天 · 模型与语音", "Local chat · Model & voice");window.isReleasedWhenClosed=false;window.delegate=self
        DesktopWindowBehavior.configure(window,minimumContentSize:NSSize(width:700,height:840));window.setFrameAutosaveName("CompanionChatInspector");window.center()
        let title=label(L("本地聊天，和角色共用一段对话", "Local chat, shared with your companion"),21,.semibold)
        let note=NSTextField(wrappingLabelWithString:L("Qwen3 1.7B 在本机运行 · 文字和语音输入 · 不读取电脑状态、不执行电脑操作 · 语音用系统离线识别，点一下开始录音、再点一下停止，没有常驻监听", "Qwen3 1.7B runs on this Mac · Text and voice input · No computer readings or actions · Voice uses on-device system recognition; click once to record, again to stop; no always-on listening"))
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize:13,weight:.medium);status.textColor = .systemBlue
        for l in [metrics,releaseNote,context] {l.font = .systemFont(ofSize:11);l.textColor = .secondaryLabelColor;l.isSelectable=true}
        let persona=NSButton(title:L("性格提示词…", "Personality prompt…"),target:self,action:#selector(editPersona));persona.bezelStyle = .rounded
        longMode.target=self;longMode.action=#selector(changeLongMode)
        profileButton.target=self;profileButton.action=#selector(editProfile);profileButton.bezelStyle = .rounded
        let toolbar=NSStackView(views:[longMode,persona,profileButton]);toolbar.orientation = .horizontal;toolbar.spacing=10
        for (button,action) in [(installModel,#selector(installOptionalModel)),(cancelInstall,#selector(cancelOptionalInstall)),(removeModel,#selector(removeOptionalModel))] {button.target=self;button.action=action;button.bezelStyle = .rounded}
        let installActions=NSStackView(views:[installModel,cancelInstall,removeModel]);installActions.orientation = .horizontal;installActions.spacing=8
        installerStatus.font = .systemFont(ofSize:11);installerStatus.textColor = .secondaryLabelColor
        let memoryHint=NSTextField(wrappingLabelWithString:L("模型在第一次发消息（或开始打字）时加载，默认闲置120秒后释放；长驻留仍受内存压力、锁屏、熄屏和退出限制。内存为推理进程系统计账值，CPU 100%约为一核，不代表耗电。", "The model loads with your first message (or when you start typing) and unloads after 120 seconds idle. Longer residency still stops for memory pressure, lock, display sleep, and exit. Memory is process-accounted usage; CPU 100% is roughly one core, not a power reading."))
        memoryHint.font = .systemFont(ofSize:11);memoryHint.textColor = .secondaryLabelColor
        voiceEnable.target=self;voiceEnable.action=#selector(toggleVoiceEnable);readReplies.target=self;readReplies.action=#selector(toggleReadReplies)
        record.title=L("开始录音", "Start recording");record.bezelStyle = .rounded;record.setAccessibilityLabel(L("开始录音；再点一次停止并转写", "Start recording; click again to stop and transcribe"))
        for (b,action) in [(cancelVoice,#selector(cancelVoiceCapture)),(stopRead,#selector(stopReading))] {b.target=self;b.action=action;b.bezelStyle = .rounded}
        voiceStatus.font = .systemFont(ofSize:11);voiceStatus.textColor = .secondaryLabelColor
        readVoicePopup.addItems(withTitles:ReadVoice.allCases.map{$0.title});readVoicePopup.target=self;readVoicePopup.action=#selector(changeReadVoice)
        readVoicePopup.setAccessibilityLabel(L("朗读声音", "Reading voice"));previewVoice.target=self;previewVoice.action=#selector(previewReadVoice);previewVoice.bezelStyle = .rounded
        let voiceToggles=NSStackView(views:[voiceEnable,readReplies,readVoicePopup,previewVoice]);voiceToggles.orientation = .horizontal;voiceToggles.spacing=12
        let voiceActions=NSStackView(views:[record,cancelVoice,stopRead]);voiceActions.orientation = .horizontal;voiceActions.spacing=10
        for (button,action) in [(installVoice,#selector(installReadingVoice)),(cancelVoiceInstall,#selector(cancelReadingVoice)),(removeVoice,#selector(removeReadingVoice))] {button.target=self;button.action=action;button.bezelStyle = .rounded}
        let voiceInstallActions=NSStackView(views:[installVoice,cancelVoiceInstall,removeVoice]);voiceInstallActions.orientation = .horizontal;voiceInstallActions.spacing=8
        voiceInstallStatus.font = .systemFont(ofSize:11);voiceInstallStatus.textColor = .secondaryLabelColor
        let outputScroll=Self.textScroll(transcript,editable:false);transcript.setAccessibilityLabel(L("模型检查聊天记录", "Model inspector chat history"))
        let inputScroll=Self.textScroll(input,editable:true);input.setAccessibilityLabel(L("模型检查输入消息", "Model inspector message input"));input.delegate=self
        inputScroll.heightAnchor.constraint(equalToConstant:70).isActive=true
        for (b,action) in [(send,#selector(sendMessage)),(stop,#selector(stopMessage)),(unload,#selector(unloadModel)),(clear,#selector(clearChat))] {b.target=self;b.action=action;b.bezelStyle = .rounded}
        let actions=NSStackView(views:[send,stop,unload,clear]);actions.orientation = .horizontal;actions.spacing=10
        let footer=NSTextField(wrappingLabelWithString:L("回车发送 · Shift＋回车换行 · 转写文字填进上面的输入框，检查后再发送 · 一次录音最长60秒 · 退出即清空聊天；关闭本窗口不影响脚边聊天。", "Enter sends · Shift+Enter adds a line · Transcripts go into the box above; check before sending · Up to 60 seconds per recording · Quitting clears chat; closing this window keeps companion chat available."))
        footer.font = .systemFont(ofSize:11);footer.textColor = .secondaryLabelColor
        let stack=NSStackView(views:[title,note,installActions,installerStatus,status,toolbar,memoryHint,metrics,releaseNote,context,outputScroll,voiceToggles,voiceInstallActions,voiceInstallStatus,voiceActions,voiceStatus,inputScroll,actions,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false
        let root=window.contentView!;root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-18),outputScroll.widthAnchor.constraint(equalTo:stack.widthAnchor),inputScroll.widthAnchor.constraint(equalTo:stack.widthAnchor),outputScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:140)])
        for view in [note,installerStatus,status,metrics,releaseNote,context,memoryHint,voiceInstallStatus,voiceStatus,footer] {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        ModelInstallation.shared.onChange={ [weak self] in self?.update() }
        ModelInstallation.voice.onChange={ [weak self] in self?.update();self?.onVoiceInstallChange?() }
        update()
    }
    static func textScroll(_ view:NSTextView,editable:Bool)->NSScrollView {
        let s=NSScrollView();s.hasVerticalScroller=true;s.autohidesScrollers=true;s.borderType = .bezelBorder;s.translatesAutoresizingMaskIntoConstraints=false
        view.isEditable=editable;view.isRichText=false;view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.textContainer?.widthTracksTextView=true;view.textContainer?.containerSize=NSSize(width:0,height:CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask=[.width];view.font = .systemFont(ofSize:14);view.textContainerInset=NSSize(width:10,height:8)
        view.isAutomaticQuoteSubstitutionEnabled=false;view.isAutomaticDashSubstitutionEnabled=false;s.documentView=view;return s
    }
    func hideAuxiliaryWindows(){personaWindow?.orderOut(nil);profileWindow?.orderOut(nil)}
    /// Briefly shows what was just remembered on the button.
    func noteLearned(_ items:[String]) {
        guard !items.isEmpty else{return}
        profileButton.title=L("记住的关于你（新：\(items.joined(separator:"、").prefix(14))）…", "What I remember about you (new: \(items.joined(separator:", ").prefix(24)))…")
        if profileWindow?.isVisible == true {loadProfile()}
    }
    @objc private func editProfile(){
        if profileWindow == nil {
            let w=NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:380),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            w.title=L("记住的关于你", "What I remember about you");w.isReleasedWhenClosed=false;w.delegate=self;DesktopWindowBehavior.configure(w,minimumContentSize:NSSize(width:420,height:320));w.center()
            let note=NSTextField(wrappingLabelWithString:L("聊天里说「我叫…」「叫我…」「我是做…的」「我在…上班」「我喜欢 / 不喜欢…」「记住…」时会自动记下。只存在这台 Mac 上，每次聊天带给模型，让它记得你。可以在这里修改或清空。", "Saying things like \"my name is…\", \"call me…\", \"I work as…\", \"I like / don't like…\" or \"remember…\" in chat saves them here. Kept only on this Mac and given to the model in every chat so it remembers you. You can edit or clear them here."))
            note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor
            let nameLabel=label(L("称呼", "Name"),13,.medium);let nameField=NSTextField(string:"");nameField.placeholderString=L("例如：阿杰", "e.g. Sam")
            nameField.widthAnchor.constraint(equalToConstant:200).isActive=true
            let nameRow=NSStackView(views:[nameLabel,nameField]);nameRow.orientation = .horizontal;nameRow.spacing=8
            let factsLabel=label(L("其他记住的事（一行一条，最多 \(UserProfile.maxFacts) 条）", "Other things to remember (one per line, up to \(UserProfile.maxFacts))"),13,.medium)
            let factsView=NSTextView();let scroll=Self.textScroll(factsView,editable:true)
            let clear=NSButton(title:L("全部清空", "Clear all"),target:self,action:#selector(clearProfile));clear.bezelStyle = .rounded
            let save=NSButton(title:L("保存", "Save"),target:self,action:#selector(saveProfile));save.bezelStyle = .rounded;save.keyEquivalent="\r"
            let actions=NSStackView(views:[clear,save]);actions.orientation = .horizontal;actions.spacing=12
            let stack=NSStackView(views:[note,nameRow,factsLabel,scroll,actions]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=10;stack.translatesAutoresizingMaskIntoConstraints=false
            let root=w.contentView!;root.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),note.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:120)])
            profileWindow=w;profileNameField=nameField;profileFactsView=factsView
        }
        loadProfile();profileButton.title=L("记住的关于你…", "What I remember about you…");profileWindow?.makeKeyAndOrderFront(nil)
    }
    private func loadProfile(){
        let p=currentProfile?() ?? UserProfile()
        profileNameField?.stringValue=p.name;profileFactsView?.string=p.facts.joined(separator:"\n")
    }
    @objc private func saveProfile(){
        var p=UserProfile()
        p.name=(profileNameField?.stringValue ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        p.facts=(profileFactsView?.string ?? "").split(separator:"\n").map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}.filter{!$0.isEmpty}.map{String($0.prefix(40))}
        if p.facts.count>UserProfile.maxFacts {p.facts=Array(p.facts.suffix(UserProfile.maxFacts))}
        onProfile?(p);profileWindow?.orderOut(nil)
    }
    @objc private func clearProfile(){profileNameField?.stringValue="";profileFactsView?.string=""}
    func show(){if window.isMiniaturized{window.deminiaturize(nil)};window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);service.inspecting=true;window.makeFirstResponder(input);update()}
    func update(){
        let installation=ModelInstallation.shared
        installerStatus.stringValue=installation.status
        installModel.isEnabled = !installation.isInstalled && !installation.isBusy && !service.hasWorker
        cancelInstall.isEnabled=installation.isBusy
        removeModel.isEnabled=installation.isInstalled && !installation.isBusy && !service.hasWorker && !service.isBusy
        removeModel.toolTip=L("先卸载正在使用的模型，再移除已下载资源。", "Unload the active model before removing downloaded files.")
        let voiceInstall=ModelInstallation.voice
        voiceInstallStatus.stringValue=voiceInstall.status
        installVoice.isEnabled = !voiceInstall.isInstalled && !voiceInstall.isBusy
        cancelVoiceInstall.isEnabled=voiceInstall.isBusy
        removeVoice.isEnabled=voiceInstall.isInstalled && !voiceInstall.isBusy
        status.stringValue=Localizer.text(service.status)
        let remain=service.idleRemaining.map{String(format:L("%.0f 秒", "%.0f sec"),max(0,$0))} ?? "—"
        metrics.stringValue=L("推理内存：\(Localizer.text(service.memory)) · CPU：\(service.cpu) · 待机剩余：\(remain)\n\(Localizer.text(service.timing))", "Inference memory: \(Localizer.text(service.memory)) · CPU: \(service.cpu) · Idle remaining: \(remain)\n\(Localizer.text(service.timing))")
        releaseNote.stringValue=L("最近释放原因：\(Localizer.text(service.lastRelease))", "Last unload: \(Localizer.text(service.lastRelease))");context.stringValue=Localizer.text(service.context)
        longMode.state=service.longResidency ? .on:.off
        send.isEnabled=(maySend?() ?? service.canSend);stop.isEnabled=service.isBusy;unload.isEnabled=service.hasWorker && !service.stopping;clear.isEnabled=service.canSend
        let lines=service.lines.map{line->String in
            let who=line.role == "user" ? L("你", "You"):L("角色", "Mochi")
            let note = !line.eligible ? L("（未完成，不用于后续对话）", "(Incomplete; excluded from future context)") : line.inModelContext ? "" : line.role == "user" ? L("（不再带入后续对话）", "(No longer sent to the model)"):L("（应用固定回复，不发给模型）", "(App reply; not sent to the model)")
            return who+note+"\n"+line.text
        }
        let current=service.draft.isEmpty ? []:[L("生成中的草稿（尚未作为气泡发布）\n", "Draft reply (not yet shown as a bubble)\n")+service.draft]
        let text=(lines+current).joined(separator:"\n\n")
        if transcript.string != text {transcript.string=text;transcript.scrollToEndOfDocument(nil)}
    }
    func updateVoice(_ voice:PetVoiceService,read:Bool,canRecord:Bool){
        voiceEnable.state=voice.enabled ? .on:.off;readReplies.state=read ? .on:.off;readReplies.isEnabled=voice.enabled
        record.title=voice.isRecording ? L("停止并转写", "Stop and transcribe"):voice.isProcessing ? L("正在转写…", "Transcribing…"):L("开始录音", "Start recording")
        record.contentTintColor=voice.isRecording ? .systemRed:nil
        record.isEnabled=canRecord || voice.isRecording
        cancelVoice.isEnabled=voice.isRecording || voice.isProcessing || voice.isRequestingPermission;stopRead.isEnabled=voice.isSpeaking
        if let index=ReadVoice.allCases.firstIndex(of:voice.readVoice),readVoicePopup.indexOfSelectedItem != index {readVoicePopup.selectItem(at:index)}
        previewVoice.isEnabled=voice.enabled && !voice.isRecording && !voice.isProcessing && !voice.isRequestingPermission
        voiceStatus.stringValue=L("语音：", "Voice: ") + voice.status + "\n" + voice.readVoiceStatus
    }
    func appendTranscript(_ text:String){input.string += (input.string.isEmpty ? "":"\n")+text;input.scrollToEndOfDocument(nil);window.makeFirstResponder(input);onTyping?()}
    @objc private func installOptionalModel(){ModelInstallation.shared.install()}
    @objc private func installReadingVoice(){ModelInstallation.voice.install()}
    @objc private func cancelReadingVoice(){ModelInstallation.voice.cancel()}
    @objc private func removeReadingVoice(){onRemoveVoice?();ModelInstallation.voice.uninstall()}
    @objc private func cancelOptionalInstall(){ModelInstallation.shared.cancel()}
    @objc private func removeOptionalModel(){
        guard !service.hasWorker,!service.isBusy else{return}
        ModelInstallation.shared.uninstall()
    }
    @objc private func toggleVoiceEnable(){onVoiceEnable?(voiceEnable.state == .on)}
    @objc private func toggleReadReplies(){onReadReplies?(readReplies.state == .on)}
    @objc private func changeReadVoice(){let all=ReadVoice.allCases;let i=readVoicePopup.indexOfSelectedItem;if all.indices.contains(i){onReadVoice?(all[i])}}
    @objc private func previewReadVoice(){onPreviewVoice?()}
    @objc private func cancelVoiceCapture(){onCancelVoice?()}
    @objc private func stopReading(){onStopRead?()}
    @objc private func sendMessage(){if (onSend?(input.string) ?? service.send(input.string)){input.string=""}}
    @objc private func stopMessage(){service.stopReply()}
    @objc private func unloadModel(){service.release("user_unload")}
    @objc private func clearChat(){service.clear()}
    @objc private func changeLongMode(){onLongMode?(longMode.state == .on)}
    func textView(_ textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        if textView === input,commandSelector == #selector(NSResponder.insertNewline(_:)),NSApp.currentEvent?.modifierFlags.contains(.shift) != true {sendMessage();return true};return false
    }
    func textDidChange(_ notification:Notification){if notification.object as? NSTextView === input{onTyping?()}}
    func windowWillClose(_ notification:Notification){if notification.object as? NSWindow === window {onWindowHidden?();hideAuxiliaryWindows();service.inspecting=false;onClose?()}}
    func windowDidMiniaturize(_ notification:Notification){if notification.object as? NSWindow === window {onWindowHidden?();service.inspecting=false;onVisibility?()}}
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
