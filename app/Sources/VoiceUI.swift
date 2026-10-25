import AppKit

final class HoldToTalkButton: NSButton {
    var onPress:(()->UInt64?)?
    var onRelease:((UInt64)->Void)?
    var onKeyboardToggle:(()->Void)?
    private var trackingMouse=false
    override init(frame:NSRect){super.init(frame:frame);target=self;action=#selector(activate);bezelStyle = .rounded}
    required init?(coder:NSCoder){fatalError()}
    override func mouseDown(with event:NSEvent){
        guard isEnabled else{return}
        trackingMouse=true;let token=onPress?()
        super.mouseDown(with:event)
        trackingMouse=false;if let token=token{onRelease?(token)}
    }
    @objc private func activate(){if !trackingMouse{onKeyboardToggle?()}}
}

final class VoiceExperimentController:NSObject,NSWindowDelegate,NSTextViewDelegate {
    let window:NSWindow
    let input=NSTextView()
    let enable=NSButton(checkboxWithTitle:L("开启语音实验（默认关闭）", "Enable voice experiment (off by default)"),target:nil,action:nil)
    let readReplies=NSButton(checkboxWithTitle:L("朗读聊天回复", "Read chat replies aloud"),target:nil,action:nil)
    let hold=HoldToTalkButton(frame:.zero)
    let status=NSTextField(wrappingLabelWithString:"")
    private let reply=NSTextField(wrappingLabelWithString:L("识别文字后，可在下方修改，再点发送。", "Review and edit the transcript below, then send it."))
    private let send=NSButton(title:L("发送给角色", "Send to Mochi"),target:nil,action:nil)
    private let cancel=NSButton(title:L("取消录音 / 转写", "Cancel recording / transcription"),target:nil,action:nil)
    private let stopRead=NSButton(title:L("停止朗读", "Stop reading"),target:nil,action:nil)
    var onEnable:((Bool)->Void)?,onReadReplies:((Bool)->Void)?
    var onSend:((String)->Bool)?,onCancel:(()->Void)?,onStopRead:(()->Void)?,onTyping:(()->Void)?,onVisibility:(()->Void)?
    override init(){
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:690,height:580),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init();window.title=L("语音实验 · 按住说话与朗读", "Voice experiment · Push to talk & read aloud");window.isReleasedWhenClosed=false;window.delegate=self
        DesktopWindowBehavior.configure(window,minimumContentSize:NSSize(width:650,height:550));window.setFrameAutosaveName("CompanionVoice015");window.center()
        enable.target=self;enable.action=#selector(toggleEnabled);readReplies.target=self;readReplies.action=#selector(toggleRead)
        let title=label(L("说完，确认，再发送", "Speak, review, then send"),21,.semibold)
        let note=NSTextField(wrappingLabelWithString:L("只在按住时使用麦克风；松开后用系统离线中文识别。首次使用先完成权限确认，再按住一次。没有持续监听或唤醒词，不回退云端。", "The microphone runs only while you hold the button. Transcription uses offline Chinese recognition. On first use, grant permissions, then hold again. No wake word, continuous listening, or cloud fallback."))
        note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor
        let toggles=NSStackView(views:[enable,readReplies]);toggles.orientation = .horizontal;toggles.spacing=15
        hold.title=L("按住说话", "Hold to talk");hold.setAccessibilityLabel(L("按住说话；键盘激活可开始或结束", "Hold to talk. Keyboard activation starts or stops recording."))
        status.font = .systemFont(ofSize:12);status.textColor = .secondaryLabelColor
        reply.font = .systemFont(ofSize:13);reply.isSelectable=true;reply.maximumNumberOfLines=4
        let scroll=ChatInspector.textScroll(input,editable:true);input.delegate=self;input.setAccessibilityLabel(L("语音实验确认文字", "Review voice transcript"))
        for (button,action) in [(send,#selector(sendMessage)),(cancel,#selector(cancelCapture)),(stopRead,#selector(stopSpeaking))]{button.target=self;button.action=action;button.bezelStyle = .rounded}
        let captureActions=NSStackView(views:[hold]);captureActions.orientation = .horizontal;captureActions.spacing=12
        let actions=NSStackView(views:[send,cancel,stopRead]);actions.orientation = .horizontal;actions.spacing=10
        let footer=NSTextField(wrappingLabelWithString:L("一次最多30秒；仅采纳最终识别结果。转写保留在此处，关闭窗口不清空。聊天与脚边输入、模型调试共用上下文。隐藏角色、锁屏或退出会停止语音。", "Record up to 30 seconds. Only final transcripts are used. Closing keeps this draft. Chat context is shared with the companion. Hiding, locking, or quitting stops voice."))
        footer.font = .systemFont(ofSize:11);footer.textColor = .secondaryLabelColor
        let stack=NSStackView(views:[title,note,toggles,captureActions,status,reply,scroll,actions,footer]);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
        let root=window.contentView!;root.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:root.topAnchor,constant:20),stack.bottomAnchor.constraint(equalTo:root.bottomAnchor,constant:-20),scroll.widthAnchor.constraint(equalTo:stack.widthAnchor),scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100)])
        for v in [note,status,reply,footer]{v.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
    }
    func show(){if window.isMiniaturized{window.deminiaturize(nil)};window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);onVisibility?()}
    func update(voice:PetVoiceService,chat:PetChatService,read:Bool,canRecord:Bool,canSend:Bool){
        enable.state=voice.enabled ? .on:.off;readReplies.state=read ? .on:.off;readReplies.isEnabled=voice.enabled
        hold.title=voice.isRecording ? L("正在录音 · 松开转写", "Recording · Release to transcribe"):voice.isProcessing ? L("正在转写…", "Transcribing…"):L("按住说话", "Hold to talk")
        hold.isEnabled=canRecord || voice.isRecording
        status.stringValue=Localizer.text(voice.status)+"\n"+Localizer.text(chat.status)
        cancel.isEnabled=voice.isRecording || voice.isProcessing || voice.isRequestingPermission;stopRead.isEnabled=voice.isSpeaking
        send.isEnabled=canSend
        reply.stringValue=chat.isBusy ? L("角色正在想… 可在模型状态窗口停止回复。", "Mochi is thinking… Stop the reply in the model window."):chat.lines.last(where:{$0.role == "assistant" && $0.eligible})?.text ?? L("识别文字后，可在下方修改，再点发送。", "Review and edit the transcript below, then send it.")
    }
    func appendTranscript(_ text:String){input.string += (input.string.isEmpty ? "":"\n")+text;input.scrollToEndOfDocument(nil);onTyping?()}
    @objc private func toggleEnabled(){onEnable?(enable.state == .on)}
    @objc private func toggleRead(){onReadReplies?(readReplies.state == .on)}
    @objc private func sendMessage(){if onSend?(input.string)==true{input.string=""}}
    @objc private func cancelCapture(){onCancel?()}
    @objc private func stopSpeaking(){onStopRead?()}
    func textDidChange(_ notification:Notification){onTyping?()}
    func textView(_ textView:NSTextView,doCommandBy commandSelector:Selector)->Bool{
        if commandSelector == #selector(NSResponder.insertNewline(_:)),NSApp.currentEvent?.modifierFlags.contains(.shift) != true{sendMessage();return true};return false
    }
    func windowWillClose(_ notification:Notification){onCancel?();DispatchQueue.main.async{[weak self] in self?.onVisibility?()}}
    func windowDidMiniaturize(_ notification:Notification){onCancel?();onVisibility?()}
    func windowDidDeminiaturize(_ notification:Notification){onVisibility?()}
    func windowWillUseStandardFrame(_ window:NSWindow,defaultFrame:NSRect)->NSRect{DesktopWindowBehavior.standardFrame(for:window,defaultFrame:defaultFrame)}
}
