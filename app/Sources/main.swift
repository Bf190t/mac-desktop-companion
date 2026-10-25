import AppKit
import QuartzCore
import AVFoundation
import Foundation

final class AppDelegate: NSObject,NSApplicationDelegate,NSMenuDelegate,NSWindowDelegate {
    static let qaDefaultsName="io.github.bf190t.desktop-companion.qa."+UUID().uuidString
    let prefs:Preferences = {
        if CommandLine.arguments.contains("--ui-check") {return Preferences(defaults:UserDefaults(suiteName:AppDelegate.qaDefaultsName)!)}
        return Preferences()
    }()
    let monitor=MetricsMonitor()
    let bluetoothMonitor=BluetoothBatteryMonitor()
    var pet:CompanionPanel!
    var petView:PetView!
    var bubble:CompanionPanel!
    var bubbleView:BubbleView!
    var status:NSStatusItem!
    let statusMenu=NSMenu()
    let metricsPanel=MetricsPanelController()
    var settings:NSWindow?
    var controls:[String:NSControl]=[:]
    var sizeLabel:NSTextField?
    var idle:NSImage!
    var blink:NSImage!
    var chibiArtwork:ChibiArtwork?
    var roamingEnabled=false
    var roamController:PetRoamController?
    var lastRoamPose:PetRoamPose = .standing
    var ground=NSPoint.zero
    var dragging=false
    var idleTimer:Timer?,blinkReturn:Timer?,bubbleTimer:Timer?,hourTimer:Timer?
    var suspensions=Set<String>()
    var monitorSuspended=false
    var metricsRequested=false
    var speech:AVSpeechSynthesizer?
    var workspaceObservers:[NSObjectProtocol]=[]
    var appObservers:[NSObjectProtocol]=[]
    var distributedObservers:[NSObjectProtocol]=[]
    var clicked=0
    var isQuitting=false
    let voice=PetVoiceService()
    var voiceWindow:VoiceExperimentController?
    var voiceOriginIsPet=false
    var reconcilingInteraction=false
    let chat=PetChatService()
    var chatInspector:ChatInspector?
    var chatInput:PetInputPanel?
    var chatInputView:PetInputView?
    var chatBubbleUntil:TimeInterval=0

    var policy:ActivityPolicy {
        ActivityPolicy(petHidden:prefs.petHidden,userPaused:prefs.userPaused,suspended:!suspensions.isEmpty,
            energySaving:ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
            idleEnabled:prefs.idleEnabled)
    }
    var canHop:Bool {policy.canAnimate && prefs.character == .blueberry && prefs.blueberryHopEnabled}
    var hourly:HourlyPolicy {HourlyPolicy(enabled:prefs.hourlyEnabled,firstHour:prefs.firstHour,lastHour:prefs.lastHour)}
    var resourceURL:URL {Bundle.main.resourceURL!}
    func applicationDidFinishLaunching(_ notification:Notification) {
        Language.defaults=prefs.defaults
        guard loadCharacterArtwork(prefs.character) else {
            let alert=NSAlert();alert.messageText=L("桌宠素材缺失", "Companion artwork is unavailable");alert.informativeText=L("请重新解压完整的桌面伴伴.app。", "Please extract the complete Desktop Companion.app again.");alert.runModal();NSApp.terminate(nil);return
        }
        let mainMenu=NSMenu();let appItem=NSMenuItem();let applicationMenu=NSMenu(title:L("桌面伴伴", "Desktop Companion"))
        let settingsItem=NSMenuItem(title:L("设置…", "Settings…"),action:#selector(showSettings),keyEquivalent:",");settingsItem.target=self;applicationMenu.addItem(settingsItem)
        let quitItem=NSMenuItem(title:L("完全退出桌面伴伴", "Quit Desktop Companion"),action:#selector(quit),keyEquivalent:"q");quitItem.target=self;applicationMenu.addItem(quitItem)
        appItem.submenu=applicationMenu;mainMenu.addItem(appItem)
        let editItem=NSMenuItem(title:L("编辑", "Edit"),action:nil,keyEquivalent:"");let edit=NSMenu(title:L("编辑", "Edit"))
        for (title,action,key) in [(L("剪切", "Cut"),#selector(NSText.cut(_:)),"x"),(L("复制", "Copy"),#selector(NSText.copy(_:)),"c"),(L("粘贴", "Paste"),#selector(NSText.paste(_:)),"v"),(L("全选", "Select All"),#selector(NSText.selectAll(_:)),"a")] {edit.addItem(withTitle:title,action:action,keyEquivalent:key)}
        editItem.submenu=edit;mainMenu.addItem(editItem);NSApp.mainMenu=mainMenu
        pet=CompanionPanel(rect:NSRect(x:0,y:0,width:84,height:320));pet.title=L("桌面伴伴", "Desktop Companion")
        petView=PetView(frame:pet.contentView!.bounds);petView.autoresizingMask=[.width,.height];pet.contentView=petView
        petView.onDragStart={ [weak self] in guard let self=self else{return};self.dragging=true;self.stopCharacterMotion();self.hideBubble() }
        petView.onDrag={ [weak self] origin in self?.drag(to:origin) }
        petView.onDragEnd={ [weak self] in guard let self=self else{return};self.dragging=false;self.savePosition();self.scheduleIdle();self.syncRoaming() }
        petView.onTap={ [weak self] in guard let self=self else{return};self.dragging=false;self.interact();self.scheduleIdle() }
        petView.onMenu={ [weak self] event in guard let self=self else{return};NSMenu.popUpContextMenu(self.statusMenu,with:event,for:self.petView) }
        bubble=CompanionPanel(rect:NSRect(x:0,y:0,width:240,height:104));bubble.ignoresMouseEvents=true
        bubbleView=BubbleView(frame:NSRect(x:0,y:0,width:240,height:104));bubble.contentView=bubbleView
        metricsPanel.onClose={ [weak self] in self?.metricsRequested=false;self?.monitor.setPanelVisible(false);self?.bluetoothMonitor.setVisible(false) }
        metricsPanel.onRefresh={ [weak self] in self?.monitor.refreshStorage() }
        metricsPanel.onBluetoothRefresh={ [weak self] in self?.bluetoothMonitor.refresh(manual:true) }
        metricsPanel.onPageChange={ [weak self] in self?.syncMetricVisibility() }
        monitor.onUpdate={ [weak self] value in self?.metricsPanel.update(value) }
        bluetoothMonitor.onUpdate={ [weak self] value in self?.metricsPanel.updateBluetooth(value) }
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.title="✿";status.button?.font = .systemFont(ofSize:14,weight:.semibold);status.button?.toolTip=L("桌面伴伴", "Desktop Companion")
        status.menu=statusMenu;statusMenu.delegate=self;statusMenu.autoenablesItems=false;buildMenu()
        let screen=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1280,height:800)
        ground=prefs.position ?? NSPoint(x:screen.maxX-120,y:screen.minY+14)
        showIdle();constrainToScreens();pet.ignoresMouseEvents=effectiveClickThrough
        petView.setAccessibilityLabel(prefs.character.title+L("桌宠，点击对话，拖动位置，右键打开菜单", " companion. Click to chat, drag to move, right-click for menu."))
        status.button?.toolTip=L("桌面伴伴 · ", "Desktop Companion · ")+prefs.character.title
        setupChat();setupVoice();installObservers();checkInitialSession()
        monitor.start();refreshRuntime()
        if CommandLine.arguments.contains("--show-settings") {DispatchQueue.main.asyncAfter(deadline:.now()+0.5){[weak self] in self?.showSettings()}}
        if let index=CommandLine.arguments.firstIndex(of:"--ui-check"),CommandLine.arguments.count>index+1 {
            let output=URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
            DispatchQueue.main.asyncAfter(deadline:.now()+1){[weak self] in if let self=self{runUIAcceptance(self,output:output)}}
        }
        if !CommandLine.arguments.contains("--ui-check") && !prefs.defaults.bool(forKey:"didIntroduceCompanion010") {
            prefs.defaults.set(true,forKey:"didIntroduceCompanion010")
            DispatchQueue.main.asyncAfter(deadline:.now()+0.6){[weak self] in self?.showSettings()}
        }
        metricsPanel.update(monitor.latest)
        if !prefs.defaults.bool(forKey:"didIntroduce") && policy.canChime {
            prefs.defaults.set(true,forKey:"didIntroduce")
            say(L("我在这里。\n点我说句话，拖动能换位置。\n设置在菜单栏的「✿」。", "I'm here.\nClick to chat or drag to move me.\nFind settings under ✿ in the menu bar."),duration:10)
        }
    }
    func buildMenu() {
        statusMenu.removeAllItems()
        @discardableResult func item(_ title:String,_ action:Selector?,_ key:String="") -> NSMenuItem {
            let v=NSMenuItem(title:title,action:action,keyEquivalent:key);v.target=self;statusMenu.addItem(v);return v
        }
        let heading=item(L("桌面伴伴 · 0.1.0 开源版", "Desktop Companion · 0.1.0 Open source"),nil);heading.isEnabled=false
        let characterMenu=NSMenu(title:L("选择角色", "Choose character"))
        for character in PetCharacter.allCases {
            let choice=NSMenuItem(title:character.title,action:#selector(characterMenuChanged(_:)),keyEquivalent:"")
            choice.target=self;choice.representedObject=character.rawValue;choice.state=prefs.character == character ? .on:.off;characterMenu.addItem(choice)
        }
        item(L("选择角色", "Choose character"),nil).submenu=characterMenu
        item(L("电脑状态小窗", "Computer status"),#selector(toggleMetrics)).state=metricsPanel.panel.isVisible ? .on:.off
        item(L("蓝牙设备电量", "Bluetooth battery"),#selector(showBluetooth))
        item(roamingEnabled ? L("脚边聊天（散步时暂时隐藏）", "Foot-level chat (hidden while roaming)"):L("角色脚边聊天", "Foot-level chat"),#selector(toggleChat)).state=effectiveChatEnabled ? .on:.off
        statusMenu.items.last?.isEnabled = !roamingEnabled
        item(L("本地模型状态与调试…", "Local model status & debugging…"),#selector(showChatInspector))
        item(L("语音实验…", "Voice experiment…"),#selector(showVoiceExperiment))
        statusMenu.addItem(.separator())
        item(prefs.petHidden ? L("显示桌宠", "Show companion"):L("隐藏桌宠", "Hide companion"),#selector(toggleHidden))
        item(prefs.userPaused ? L("继续动作", "Resume motion"):L("暂停动作", "Pause motion"),#selector(togglePause))
        item(roamingEnabled ? L("鼠标穿透（散步时自动开启）", "Click-through (on while roaming)"):L("鼠标穿透", "Click-through"),#selector(toggleThrough)).state=effectiveClickThrough ? .on:.off
        statusMenu.items.last?.isEnabled = !roamingEnabled
        if prefs.character == .portrait {item(L("轻微待机动作", "Subtle idle motion"),#selector(toggleIdle)).state=prefs.idleEnabled ? .on:.off}
        statusMenu.addItem(.separator())
        if prefs.character == .blueberry {
            item(L("小团小跳（默认关闭）", "Occasional hops (off by default)"),#selector(toggleHop)).state=prefs.blueberryHopEnabled ? .on:.off
            item(L("试跳一下", "Try a hop"),#selector(hopNow)).isEnabled=canHop
            let hint=item(L("开启后约每 1–2 分钟轻轻跳一下", "When enabled, a small hop every 1–2 minutes"),nil);hint.isEnabled=false
        }
        if prefs.character == .chibi {
            item(L("实验：小团散步", "Experiment: Mochi roaming"),#selector(toggleRoaming)).state=roamingEnabled ? .on:.off
            let modes=NSMenu(title:L("散步范围", "Roam area"))
            for (title,mode) in [(L("横向溜达", "Horizontal stroll"),PetRoamMode.horizontal),(L("全屏八向", "All directions"),PetRoamMode.free)] {
                let v=NSMenuItem(title:title,action:#selector(roamModeMenuChanged(_:)),keyEquivalent:"");v.target=self;v.representedObject=mode.rawValue;v.state=prefs.chibiRoamMode == mode ? .on:.off;modes.addItem(v)
            }
            item(L("散步范围", "Roam area"),nil).submenu=modes
        }
        statusMenu.addItem(.separator())
        item(L("整点气泡报时", "Hourly time bubble"),#selector(toggleHourly)).state=prefs.hourlyEnabled ? .on:.off
        item(L("试一下报时气泡", "Preview time bubble"),#selector(testChime)).isEnabled=policy.canChime
        item(L("角色、大小与报时…", "Character, size & time…"),#selector(showSettings),",")
        item(L("重置桌宠位置", "Reset companion position"),#selector(resetPosition))
        item(L("使用说明与限制…", "Help & limitations…"),#selector(showHelp))
        statusMenu.addItem(.separator())
        item(L("完全退出", "Quit"),#selector(quit),"q")
    }
    func menuWillOpen(_ menu:NSMenu){buildMenu()}
    @objc func toggleHidden(){prefs.petHidden.toggle();refreshRuntime()}
    @objc func togglePause(){prefs.userPaused.toggle();refreshRuntime();if !prefs.petHidden{say(prefs.userPaused ? L("先安静待一会儿。\n报时开关仍独立保留。", "Let's stay quiet for a moment.\nHourly announcements keep their own setting."):L("嗯，继续陪你。", "I'm here with you."))}}
    @objc func toggleThrough(){guard !roamingEnabled else{return};prefs.clickThrough.toggle();pet.ignoresMouseEvents=effectiveClickThrough;syncChatVisibility();if prefs.clickThrough{say(L("鼠标会穿过我。\n在菜单栏「✿」里可以关闭。", "Clicks pass through me now.\nTurn this off under ✿ in the menu bar."))};syncSettings()}
    @objc func toggleIdle(){prefs.idleEnabled.toggle();refreshRuntime()}
    @objc func toggleHop(){prefs.blueberryHopEnabled.toggle();refreshRuntime()}
    @objc func characterMenuChanged(_ sender:NSMenuItem){
        guard let raw=sender.representedObject as? String,let character=PetCharacter(rawValue:raw) else{return}
        selectCharacter(character)
    }
    func loadCharacterArtwork(_ character:PetCharacter)->Bool {
        guard let artwork=ChibiArtwork.load(resourceURL:resourceURL) else{return false}
        chibiArtwork=artwork;idle=artwork.standing;blink=OriginalArtwork.image(blink:true)
        return true
    }
    func selectCharacter(_ character:PetCharacter){
        guard character != prefs.character else{return}
        idleTimer?.invalidate();blinkReturn?.invalidate();stopCharacterMotion();hideBubble()
        guard loadCharacterArtwork(character) else{say(L("这个角色的素材没有完整加载。\n请重新解压应用再试。", "The character could not be loaded.\nPlease extract the application again."));scheduleIdle();syncRoaming();return}
        roamingEnabled=false;chibiArtwork = character == .chibi ? chibiArtwork:nil
        prefs.character=character;showIdle();constrainToScreens();savePosition();refreshRuntime()
        petView.setAccessibilityLabel(character.title+L("桌宠，点击对话，拖动位置，右键打开菜单", " companion. Click to chat, drag to move, right-click for menu."))
        status.button?.toolTip=L("桌面伴伴 · ", "Desktop Companion · ")+character.title
    }
    @objc func toggleHourly(){prefs.hourlyEnabled.toggle();scheduleHour();syncSettings()}
    @objc func toggleMetrics(){if metricsPanel.panel.isVisible && !metricsPanel.panel.isMiniaturized{metricsPanel.panel.close()}else{showMetrics()}}
    @objc func showBluetooth(){metricsPanel.selectBluetooth(true);showMetrics()}
    func syncMetricVisibility(){
        let visible=metricsRequested && metricsPanel.panel.isVisible && !metricsPanel.panel.isMiniaturized && suspensions.isEmpty
        monitor.setPanelVisible(visible && !metricsPanel.isBluetoothPage)
        bluetoothMonitor.setVisible(visible && metricsPanel.isBluetoothPage)
    }
    func showMetrics(){
        metricsRequested=true
        if metricsPanel.panel.frame.origin == .zero {metricsPanel.panel.center()}
        guard suspensions.isEmpty else{return}
        if metricsPanel.panel.isMiniaturized {metricsPanel.panel.deminiaturize(nil)}
        constrainUtilityWindows();metricsPanel.panel.makeKeyAndOrderFront(nil);syncMetricVisibility();metricsPanel.update(monitor.latest);metricsPanel.updateBluetooth(bluetoothMonitor.latest)
    }
    @objc func testChime(){guard policy.canChime else{return};chime(Date(),test:true)}
    @objc func resetPosition(){stopCharacterMotion();let r=NSScreen.main?.visibleFrame ?? NSScreen.screens[0].visibleFrame;ground=NSPoint(x:r.maxX-120,y:r.minY+14);showIdle();constrainToScreens();savePosition();if !prefs.petHidden && suspensions.isEmpty{pet.orderFrontRegardless()};scheduleIdle();syncRoaming()}
    func place(image:NSImage){
        let h=prefs.height,w=h*image.size.width/image.size.height
        let panelHeight=h+prefs.character.headroom(for:h),padding=prefs.character.sidePadding(for:w),panelWidth=w+2*padding
        pet.setFrame(NSRect(x:ground.x-w/2-padding,y:ground.y,width:panelWidth,height:panelHeight),display:true)
        if !roamingEnabled {positionChatInput()}
        petView.artworkSize=NSSize(width:w,height:h);petView.frame=NSRect(x:0,y:0,width:panelWidth,height:panelHeight);petView.needsLayout=true;petView.layoutSubtreeIfNeeded();petView.show(image)
    }
    func showIdle(){guard idle != nil else{return};lastRoamPose = .standing;place(image:idle)}
    func screenForPet()->NSScreen{
        NSScreen.screens.first{ $0.visibleFrame.insetBy(dx:-1,dy:-1).contains(ground) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    func constrainToScreens(){
        let r=screenForPet().visibleFrame
        let origin=clampedOrigin(pet.frame.origin,size:pet.frame.size,visible:r)
        ground.x += origin.x-pet.frame.origin.x;ground.y += origin.y-pet.frame.origin.y;showIdle()
    }
    func drag(to origin:NSPoint){
        let center=NSPoint(x:origin.x+pet.frame.width/2,y:origin.y+pet.frame.height/2)
        let screen=NSScreen.screens.first{$0.visibleFrame.contains(center)} ?? screenForPet()
        let p=clampedOrigin(origin,size:pet.frame.size,visible:screen.visibleFrame)
        ground=NSPoint(x:p.x+pet.frame.width/2,y:p.y);pet.setFrameOrigin(p);positionChatInput();if bubble.isVisible{positionBubble()}
    }
    func savePosition(){prefs.position=ground}
    func scheduleIdle(){
        idleTimer?.invalidate();idleTimer=nil;blinkReturn?.invalidate();blinkReturn=nil
        if prefs.character == .chibi {return}
        if prefs.character == .blueberry {
            guard canHop,!dragging else{return}
            idleTimer=Timer.scheduledTimer(withTimeInterval:Double.random(in:75...120),repeats:false){[weak self] _ in self?.hopNow();self?.scheduleIdle()}
            idleTimer?.tolerance=10;return
        }
        guard policy.canAnimate,prefs.idleEnabled,!dragging else{return}
        idleTimer=Timer.scheduledTimer(withTimeInterval:Double.random(in:9...15),repeats:false){[weak self] _ in
            guard let self=self,self.policy.canAnimate,!self.dragging else{return}
            self.petView.show(self.blink)
            self.blinkReturn=Timer.scheduledTimer(withTimeInterval:0.16,repeats:false){[weak self] _ in
                guard let self=self else{return};self.petView.show(self.idle)
                // Resting uses only a brief blink; breathing is triggered by a click.
                self.scheduleIdle()
            }
        };idleTimer?.tolerance=2
    }
    @objc func hopNow(){
        guard canHop,!dragging else{return}
        petView.smallHop(height:prefs.character.jumpHeight(for:prefs.height))
    }
    func stopCharacterMotion(){roamController?.stop();petView?.stopMotion();if idle != nil {showIdle()}}
    func interact(){
        if effectiveChatEnabled && !effectiveClickThrough {
            syncChatVisibility();chatInput?.makeKeyAndOrderFront(nil);chatInput?.makeFirstResponder(chatInputView?.input);return
        }
        if prefs.character == .blueberry {hopNow()} else if prefs.character == .portrait && policy.canAnimate && prefs.idleEnabled {petView.smallBreath()}
        let replies=prefs.character == .blueberry ? [L("嗯，小团在这里。\n今天也慢慢来。", "Mochi is here.\nOne small step at a time."),L("圆一点，也能好好陪你。\n要看电脑状态，就点菜单栏「✿」。", "A little round friend for your desktop.\nComputer readings live under ✿ in the menu bar."),L("休息一小会儿吧。\n我会安静待着。", "Take a little break.\nI'll wait here quietly."),L("想换个位置的话，\n轻轻拖动我就好。", "To move me,\njust give me a gentle drag.")]:[L("嗯，我在。\n要看电脑状态，可以点菜单栏的「✿」。", "I'm here.\nComputer readings live under ✿ in the menu bar."),L("不用一直赶路。\n稍微休息一下也没关系。", "No need to rush.\nIt's okay to take a short break."),L("今天也慢慢来。\n我会在这里陪着你。", "One small step at a time.\nI'll keep you company."),L("想换个位置的话，\n直接拖动我就好。", "To change my spot,\njust drag me over.")]
        say(replies[clicked % replies.count]);clicked += 1
    }
    func say(_ text:String,duration:TimeInterval=7){
        guard policy.canChime,!roamingEnabled,ProcessInfo.processInfo.systemUptime >= chatBubbleUntil else{return}
        bubble.setContentSize(NSSize(width:240,height:104));bubbleView.frame=NSRect(x:0,y:0,width:240,height:104);bubbleView.layoutText()
        bubbleTimer?.invalidate();bubbleView.label.stringValue=text
        positionBubble();bubble.orderFrontRegardless()
        bubbleTimer=Timer.scheduledTimer(withTimeInterval:duration,repeats:false){[weak self] _ in self?.hideBubble()};bubbleTimer?.tolerance=1
    }
    func positionBubble(){
        let r=screenForPet().visibleFrame;let f=pet.frame;let onLeft=f.midX>r.midX
        bubbleView.tailOnRight=onLeft;bubbleView.needsDisplay=true
        let x=onLeft ? f.minX-bubble.frame.width+11:f.maxX-11;let y=prefs.character == .blueberry ? ground.y+prefs.height*0.55-52:f.maxY-83
        bubble.setFrameOrigin(clampedOrigin(NSPoint(x:x,y:y),size:bubble.frame.size,visible:r))
    }
    func hideBubble(){bubbleTimer?.invalidate();bubbleTimer=nil;bubble?.orderOut(nil)}
    func chime(_ date:Date,test:Bool=false){
        guard policy.canChime,interactionDecision.canAnnounceHour else{return}
        let h=Calendar.current.component(.hour,from:date)
        let hourNote=h>=22 ? L("今天辛苦了，记得休息。", "Time to rest after a long day."):L("别忘了偶尔活动一下。", "Remember to take a little stretch.")
        let text=test ? L("这是报时气泡示例。\n整点时，我会在这里告诉你时间。", "This is a time-bubble preview.\nAt the hour, I'll show the time here."):L("现在是\(h)点。\n\(hourNote)", "It is \(h):00.\n\(hourNote)")
        say(text,duration:9)
        if prefs.speechEnabled,let voice=AVSpeechSynthesisVoice.speechVoices().first(where:{$0.language.hasPrefix("zh")}) {
            if speech == nil {speech=AVSpeechSynthesizer()}
            speech?.stopSpeaking(at:.immediate);let u=AVSpeechUtterance(string:test ? L("这是报时示例。", "This is a time announcement preview."):L("现在是\(h)点。", "It is \(h):00."));u.voice=voice;u.rate=0.47;speech?.speak(u)
        }
    }
    func scheduleHour(){
        hourTimer?.invalidate();hourTimer=nil
        guard policy.canChime,let next=hourly.next(after:Date()) else{return}
        hourTimer=Timer(fire:next,interval:0,repeats:false){[weak self] _ in
            guard let self=self else{return};let now=Date()
            if self.policy.canChime,self.hourly.enabled,self.hourly.isFresh(target:next,now:now),self.hourly.permits(Calendar.current.component(.hour,from:now)){self.chime(now)}
            self.scheduleHour()
        };hourTimer?.tolerance=1;RunLoop.main.add(hourTimer!,forMode:.common)
    }
    func refreshRuntime(){
        guard pet != nil else{return}
        idleTimer?.invalidate();blinkReturn?.invalidate();stopCharacterMotion();petView.stopMotion();showIdle()
        if prefs.petHidden || !suspensions.isEmpty {pet.orderOut(nil);hideBubble();speech?.stopSpeaking(at:.immediate)}else{pet.orderFrontRegardless()}
        pet.ignoresMouseEvents=effectiveClickThrough
        syncChatVisibility()
        let shouldSuspend = !suspensions.isEmpty
        if shouldSuspend != monitorSuspended {
            monitorSuspended=shouldSuspend
            if shouldSuspend {monitor.suspend();bluetoothMonitor.suspend();metricsPanel.panel.orderOut(nil)} else {monitor.resume();bluetoothMonitor.resume();if metricsRequested{metricsPanel.panel.orderFrontRegardless()}}
        }
        syncMetricVisibility()
        metricsPanel.setSuspended(shouldSuspend)
        scheduleIdle();scheduleHour();syncSettings()
    }
    func setSuspension(_ cause:String,_ active:Bool){
        if active {chat.suspended=true;chat.release(cause);chatInspector?.window.orderOut(nil);chatInspector?.hideAuxiliaryWindows();voiceWindow?.window.orderOut(nil);voice.shutdown(reason:L("系统暂停", "System pause"));chat.inspecting=false}
        if active{suspensions.insert(cause)}else{suspensions.remove(cause);checkInitialSession()}
        chat.suspended = !suspensions.isEmpty || prefs.petHidden
        refreshRuntime()
        if !active && ["sleep","screen","session","lock"].contains(cause) {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.7){[weak self] in self?.checkInitialSession();self?.refreshRuntime()}
        }
    }
    func checkInitialSession(){
        if let s=CGSessionCopyCurrentDictionary() as? [String:Any] {
            // This compatibility key is not a public lock-state contract. Workspace
            // display/sleep/session events provide separate conservative stops.
            if let locked=s["CGSSessionScreenIsLocked"] as? Bool {if locked{suspensions.insert("lock")}else{suspensions.remove("lock")}}
            if let onConsole=s[kCGSessionOnConsoleKey as String] as? Bool {if !onConsole{suspensions.insert("session")}else{suspensions.remove("session")}}
        }
    }
    func installObservers(){
        let wc=NSWorkspace.shared.notificationCenter
        let events:[(Notification.Name,String,Bool)]=[(NSWorkspace.willSleepNotification,"sleep",true),(NSWorkspace.didWakeNotification,"sleep",false),(NSWorkspace.screensDidSleepNotification,"screen",true),(NSWorkspace.screensDidWakeNotification,"screen",false),(NSWorkspace.sessionDidResignActiveNotification,"session",true),(NSWorkspace.sessionDidBecomeActiveNotification,"session",false)]
        for (name,cause,state) in events {workspaceObservers.append(wc.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.setSuspension(cause,state)})}
        let dc=DistributedNotificationCenter.default()
        for (name,state) in [("com.apple.screenIsLocked",true),("com.apple.screenIsUnlocked",false)] {
            distributedObservers.append(dc.addObserver(forName:Notification.Name(name),object:nil,queue:.main){[weak self] _ in self?.setSuspension("lock",state)})
        }
        _=ProcessInfo.processInfo.thermalState
        for name in [ProcessInfo.thermalStateDidChangeNotification,Notification.Name.NSProcessInfoPowerStateDidChange] {
            appObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.refreshRuntime()})
        }
        appObservers.append(NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.stopCharacterMotion();self?.constrainToScreens();self?.constrainUtilityWindows();self?.savePosition();self?.refreshRuntime()})
        for name in [Notification.Name.NSSystemTimeZoneDidChange,Notification.Name.NSSystemClockDidChange] {
            appObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in self?.scheduleHour()})
        }
    }
    func constrainUtilityWindows(){
        for w in [metricsPanel.panel as NSWindow,settings,chatInspector?.window,voiceWindow?.window].compactMap({$0}) {
            let screen=w.screen ?? NSScreen.screens.max(by:{
                let a=$0.visibleFrame.intersection(w.frame),b=$1.visibleFrame.intersection(w.frame)
                return (a.isNull ? 0:a.width*a.height) < (b.isNull ? 0:b.width*b.height)
            }) ?? screenForPet()
            w.setFrame(DesktopWindowBehavior.constrainedFrame(w.frame,visibleFrame:screen.visibleFrame),display:true)
        }
        positionChatInput();if bubble.isVisible {positionBubble()}
    }
    func windowWillUseStandardFrame(_ window:NSWindow,defaultFrame:NSRect)->NSRect {
        DesktopWindowBehavior.standardFrame(for:window,defaultFrame:defaultFrame)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool {
        if !hasVisibleWindows {
            if effectiveChatEnabled && !effectiveClickThrough && !prefs.petHidden {
                syncChatVisibility();chatInput?.makeKeyAndOrderFront(nil);chatInput?.makeFirstResponder(chatInputView?.input)
            } else {showSettings()}
        }
        return true
    }
    @objc func showSettings(){
        if !CommandLine.arguments.contains("--ui-check") {NSApp.setActivationPolicy(.regular)}
        if settings == nil {makeSettings()}
        if settings?.isMiniaturized == true {settings?.deminiaturize(nil)}
        syncSettings();if CommandLine.arguments.contains("--ui-check"){settings?.orderFront(nil)}else{settings?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    }
    func makeSettings(){
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:470,height:660),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title=L("桌面伴伴 · 设置", "Desktop Companion · Settings");w.isReleasedWhenClosed=false;w.delegate=self
        DesktopWindowBehavior.configure(w,minimumContentSize:NSSize(width:430,height:620))
        w.center();settings=w
        if !CommandLine.arguments.contains("--ui-check") {w.setFrameAutosaveName("CompanionSettingsPanel")}
        let content=SettingsLayoutView(frame:NSRect(x:0,y:0,width:470,height:660));content.autoresizingMask=[.width,.height];w.contentView=content
        let title=label(L("安静地陪在桌面上", "A quiet friend on your desktop"),22,.semibold);title.frame=NSRect(x:25,y:568,width:380,height:32);content.addSubview(title)
        let languageLabel=label(L("语言 / Language", "Language / 语言"),11);languageLabel.frame=NSRect(x:25,y:518,width:135,height:20);content.addSubview(languageLabel)
        let language=NSPopUpButton(frame:NSRect(x:160,y:514,width:245,height:28),pullsDown:false);language.addItems(withTitles:["简体中文","English"]);language.target=self;language.action=#selector(languageChanged(_:));content.addSubview(language);controls["language"]=language
        let sub=label(L("默认不自启、不联网；完全退出可从菜单栏操作。", "No auto-start. Quit from the ✿ menu."),11);sub.textColor = .secondaryLabelColor;sub.frame=NSRect(x:25,y:542,width:385,height:20);content.addSubview(sub)
        let characterLabel=label(L("当前角色", "Character"),13,.medium);characterLabel.frame=NSRect(x:25,y:402,width:90,height:22);content.addSubview(characterLabel)
        let characterPicker=NSPopUpButton(frame:NSRect(x:120,y:398,width:240,height:28),pullsDown:false)
        characterPicker.addItems(withTitles:PetCharacter.allCases.map{$0.title});characterPicker.identifier=NSUserInterfaceItemIdentifier("character");characterPicker.target=self;characterPicker.action=#selector(settingChanged(_:));content.addSubview(characterPicker);controls["character"]=characterPicker
        let slabel=label(L("角色大小", "Character size"),13,.medium);slabel.frame=NSRect(x:25,y:361,width:90,height:22);content.addSubview(slabel)
        let slider=NSSlider(value:Double(prefs.height),minValue:220,maxValue:480,target:self,action:#selector(sizeChanged(_:)));slider.isContinuous=true;slider.frame=NSRect(x:120,y:359,width:205,height:25);content.addSubview(slider);controls["height"]=slider
        sizeLabel=label("320",12);sizeLabel!.frame=NSRect(x:344,y:361,width:62,height:22);content.addSubview(sizeLabel!)
        func check(_ key:String,_ title:String,_ y:CGFloat){let b=NSButton(checkboxWithTitle:title,target:self,action:#selector(settingChanged(_:)));b.identifier=NSUserInterfaceItemIdentifier(key);b.frame=NSRect(x:25,y:y,width:390,height:25);content.addSubview(b);controls[key]=b}
        check("idle",L("轻微待机：眨眼，点击时轻微呼吸", "Subtle idle: blinking and a soft breath on click"),316)
        check("through",L("鼠标穿透（从菜单栏关闭）", "Click-through (turn off from menu bar)"),281)
        check("hop",L("小团小跳：偶尔跳一下（默认关闭）", "Occasional hops (off by default)"),246)
        check("roam",L("实验：小团散步（每次启动默认关闭）", "Experiment: Mochi roaming (off at each launch)"),246)
        let roamLabel=label(L("散步范围", "Roam area"),13,.medium);roamLabel.frame=NSRect(x:25,y:316,width:90,height:24);content.addSubview(roamLabel);controls["roamModeLabel"]=roamLabel
        let roamMode=NSPopUpButton(frame:NSRect(x:120,y:314,width:240,height:28),pullsDown:false);roamMode.addItems(withTitles:[L("横向溜达", "Horizontal stroll"),L("全屏八向", "All directions")]);roamMode.identifier=NSUserInterfaceItemIdentifier("roamMode");roamMode.target=self;roamMode.action=#selector(settingChanged(_:));content.addSubview(roamMode);controls["roamMode"]=roamMode
        check("hourly",L("整点用角色气泡报时", "Hourly time bubble"),198)
        check("speech",L("同时使用系统中文语音（默认关闭）", "Also use the system Chinese voice (off by default)"),163)
        let range=label(L("报时时段", "Active hours"),12);range.frame=NSRect(x:25,y:117,width:85,height:22);content.addSubview(range)
        for (key,x) in [("first",CGFloat(119)),("last",CGFloat(248))] {
            let p=NSPopUpButton(frame:NSRect(x:x,y:113,width:92,height:28),pullsDown:false);p.addItems(withTitles:(0..<24).map{String(format:"%02d:00",$0)});p.identifier=NSUserInterfaceItemIdentifier(key);p.target=self;p.action=#selector(settingChanged(_:));content.addSubview(p);controls[key]=p
        }
        let dash=label(L("至", "to"),12);dash.frame=NSRect(x:224,y:118,width:24,height:20);content.addSubview(dash)
        let note=NSTextField(wrappingLabelWithString:L("隐藏、锁屏或休眠时不报时，恢复后不补报。\n低电量或热压力升高时自动暂停动作。存储每小时刷新。", "No announcements while hidden, locked, or asleep; none are replayed.\nMotion pauses for low power or heat. Storage updates hourly."))
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor;note.frame=NSRect(x:25,y:39,width:382,height:55);content.addSubview(note)
        for (title,action,x) in [(L("使用说明", "Help"),#selector(showHelp),CGFloat(23)),(L("状态小窗", "Status"),#selector(toggleMetrics),CGFloat(218)),(L("完全退出", "Quit"),#selector(quit),CGFloat(318))] {
            let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.frame=NSRect(x:x,y:7,width:91,height:28);content.addSubview(b)
        }
        let chatButton=NSButton(title:L("本地聊天与模型设置…", "Local chat & model settings…"),target:self,action:#selector(showChatInspector));chatButton.bezelStyle = .rounded;chatButton.frame=NSRect(x:25,y:488,width:210,height:30);content.addSubview(chatButton)
        let chatSwitch=NSButton(checkboxWithTitle:L("显示脚边输入框", "Show foot-level input"),target:self,action:#selector(toggleChat));chatSwitch.frame=NSRect(x:250,y:490,width:180,height:26);content.addSubview(chatSwitch);controls["chat"]=chatSwitch
        let voiceButton=NSButton(title:L("语音实验：按住说话与朗读…", "Voice experiment: talk & read…"),target:self,action:#selector(showVoiceExperiment));voiceButton.bezelStyle = .rounded;voiceButton.frame=NSRect(x:25,y:445,width:330,height:30);content.addSubview(voiceButton)
        content.captureBaseline();constrainUtilityWindows()
    }
    func syncSettings(){
        (controls["language"] as? NSPopUpButton)?.selectItem(at:Language.current == .chinese ? 0:1)
        (controls["chat"] as? NSButton)?.state=effectiveChatEnabled ? .on:.off
        (controls["chat"] as? NSButton)?.isEnabled = !roamingEnabled
        (controls["chat"] as? NSButton)?.title=roamingEnabled ? L("散步时暂时隐藏", "Hidden while roaming"):L("显示脚边输入框", "Show foot-level input")
        (controls["through"] as? NSButton)?.isEnabled = !roamingEnabled
        (controls["through"] as? NSButton)?.title=roamingEnabled ? L("鼠标穿透（散步时自动开启）", "Click-through (on while roaming)"):L("鼠标穿透（从菜单栏关闭）", "Click-through (turn off from menu bar)")
        (controls["idle"] as? NSButton)?.isHidden=prefs.character == .chibi
        for key in ["roam","roamMode","roamModeLabel"] {controls[key]?.isHidden=prefs.character != .chibi}
        (controls["roam"] as? NSButton)?.state=roamingEnabled ? .on:.off
        (controls["roamMode"] as? NSPopUpButton)?.selectItem(at:prefs.chibiRoamMode == .horizontal ? 0:1)
        if let slider=controls["height"] as? NSSlider {slider.minValue=Double(prefs.character.minimumHeight);slider.maxValue=Double(prefs.character.maximumHeight);slider.doubleValue=Double(prefs.height)}
        sizeLabel?.stringValue=L("\(Int(prefs.height)) 点", "\(Int(prefs.height)) pt")
        (controls["character"] as? NSPopUpButton)?.selectItem(at:PetCharacter.allCases.firstIndex(of:prefs.character) ?? 0)
        (controls["idle"] as? NSButton)?.isEnabled=prefs.character == .portrait
        (controls["idle"] as? NSButton)?.title=prefs.character == .portrait ? L("轻微待机：眨眼，点击时轻微呼吸", "Subtle idle: blinking and a soft breath on click"):L("立绘待机动作（小团默认静止）", "Idle motion (Mochi stays still by default)")
        (controls["hop"] as? NSButton)?.isHidden=prefs.character != .blueberry
        for (key,value) in [("idle",prefs.character == .portrait && prefs.idleEnabled),("through",effectiveClickThrough),("hop",prefs.blueberryHopEnabled),("hourly",prefs.hourlyEnabled),("speech",prefs.speechEnabled)]{(controls[key] as? NSButton)?.state=value ? .on:.off}
        (controls["first"] as? NSPopUpButton)?.selectItem(at:prefs.firstHour);(controls["last"] as? NSPopUpButton)?.selectItem(at:prefs.lastHour)
    }
    @objc func languageChanged(_ sender:NSPopUpButton){
        Language.current=sender.indexOfSelectedItem == 0 ? .chinese:.english
        for window in NSApp.windows {Localizer.localize(window)}
        if let menu=NSApp.mainMenu {Localizer.localize(menu)}
        buildMenu();syncSettings();syncChatVisibility()
        monitor.refreshLocalization();metricsPanel.update(monitor.latest);metricsPanel.updateBluetooth(bluetoothMonitor.latest)
        pet.title=L("桌面伴伴", "Desktop Companion")
        status.button?.toolTip=L("桌面伴伴 · ", "Desktop Companion · ")+prefs.character.title
    }
    @objc func sizeChanged(_ sender:NSSlider){stopCharacterMotion();prefs.height=CGFloat(sender.doubleValue);showIdle();constrainToScreens();savePosition();sizeLabel?.stringValue=L("\(Int(prefs.height)) 点", "\(Int(prefs.height)) pt");hideBubble();scheduleIdle();syncRoaming()}
    @objc func settingChanged(_ sender:NSControl){
        let enabled=(sender as? NSButton)?.state == .on
        switch sender.identifier?.rawValue {
        case "idle":prefs.idleEnabled=enabled
        case "through":guard !roamingEnabled else{return};prefs.clickThrough=enabled
        case "roam":setRoaming(enabled);return
        case "roamMode":prefs.chibiRoamMode=(sender as? NSPopUpButton)?.indexOfSelectedItem == 1 ? .free:.horizontal
        case "hop":prefs.blueberryHopEnabled=enabled
        case "character":
            if let index=(sender as? NSPopUpButton)?.indexOfSelectedItem,PetCharacter.allCases.indices.contains(index){selectCharacter(PetCharacter.allCases[index])};return
        case "hourly":prefs.hourlyEnabled=enabled
        case "speech":prefs.speechEnabled=enabled;if !enabled{speech?.stopSpeaking(at:.immediate)}
        case "first":prefs.firstHour=(sender as! NSPopUpButton).indexOfSelectedItem
        case "last":prefs.lastHour=(sender as! NSPopUpButton).indexOfSelectedItem
        default:break
        };refreshRuntime()
    }
    @objc func showHelp(){
        let a=NSAlert();a.messageText=L("桌面伴伴 · 本地实验版", "Desktop Companion · Open source")
        a.informativeText=L("点击小团查看对话气泡，拖动换位置；右键或菜单栏 ✿ 打开控制菜单。原创形象由程序绘制，不包含第三方角色素材。\n\n电脑与蓝牙状态窗口可拖动、缩放。仅在相应页面可见时轮询；蓝牙电量是 macOS 最近记录，可能滞后，不扫描、不主动连接。存储每小时刷新；内存压力近一小时统计只包含本应用观察到的时段。温度与 GPU 读数依赖机型和系统。\n\n散步是默认关闭的实验功能；开启后暂时隐藏脚边输入框并启用鼠标穿透，关闭后恢复原设置。隐藏、锁屏、休眠或低电量时暂停动作，不阻止系统休眠。\n\n本地聊天模型为可选安装；只有主动安装时下载资源，聊天推理禁止网络访问。闲置120秒释放，长驻留实验为30分钟；内存压力、锁屏、熄屏仍会提前释放。聊天不读取电脑状态、不执行操作。语音实验默认关闭，只使用系统离线中文识别和本机朗读，无唤醒词或云端回退。\n\n源码按 MIT 开源。此分发包使用本机签名，未获 Apple 开发者公证。", "Click Mochi for a bubble, drag to move, or use the ✿ menu to control the app. The original mascot is drawn in code and includes no third-party character art.\n\nComputer and Bluetooth windows can be moved and resized. Only the visible page polls. Battery values are the latest macOS records and may be stale; the app never scans or connects. Storage updates hourly. Past-hour memory pressure includes only periods observed by this app. Temperature and GPU readings depend on hardware and macOS.\n\nRoaming is experimental and off by default. It temporarily hides the foot-level input and enables click-through, restoring your settings when stopped. Motion pauses when hidden, locked, asleep, or in low power. The app does not prevent system sleep.\n\nLocal chat is an optional installation. Resources download only when you choose Install; model inference cannot use the network. The model unloads after 120 seconds idle, or 30 minutes in the long-residency experiment. Memory pressure, lock, and display sleep can unload it earlier. Chat cannot read computer state or perform actions. Voice is an optional experiment using offline Chinese recognition and local system speech, with no wake word or cloud fallback.\n\nSource code is MIT licensed. This build is locally signed, not Apple notarized.")
        a.addButton(withTitle:L("知道了", "Got it"));a.runModal()
    }
    func windowWillClose(_ notification:Notification) {
        if notification.object as? NSWindow === settings {
            DispatchQueue.main.async { [weak self] in
                if self?.chatInspector?.window.isVisible != true && self?.voiceWindow?.window.isVisible != true {NSApp.setActivationPolicy(.accessory)}
            }
        }
    }
    @objc func quit(){NSApp.terminate(nil)}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationWillTerminate(_ n:Notification){
        isQuitting=true;ModelInstallation.shared.cancel();roamingEnabled=false;roamController?.stop();voice.shutdown(reason:L("应用退出", "App exit"));chat.terminateSynchronously();savePosition();
        if CommandLine.arguments.contains("--ui-check"){prefs.defaults.removePersistentDomain(forName:AppDelegate.qaDefaultsName)}
        idleTimer?.invalidate();blinkReturn?.invalidate();bubbleTimer?.invalidate();hourTimer?.invalidate()
        monitor.stop();bluetoothMonitor.stop();speech?.stopSpeaking(at:.immediate)
        for t in workspaceObservers{NSWorkspace.shared.notificationCenter.removeObserver(t)}
        for t in appObservers{NotificationCenter.default.removeObserver(t)}
        for t in distributedObservers{DistributedNotificationCenter.default().removeObserver(t)}
    }
}

func selfTest()->Bool{
    var checks:[String:Bool]=[:]
    var p=ActivityPolicy();checks["voice_default_off"] = !Preferences(defaults:UserDefaults(suiteName:"io.github.bf190t.desktop-companion.voice-self-test")!).voiceEnabled
    p.userPaused=true;checks["user_pause_blocks_motion"] = !p.canAnimate
    p.suspended=true;p.suspended=false;checks["wake_preserves_user_pause"] = !p.canAnimate
    p.userPaused=false;p.energySaving=true;checks["low_power_blocks_motion"] = !p.canAnimate
    p.energySaving=false;p.petHidden=true;checks["hidden_blocks_chime"] = !p.canChime
    var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(secondsFromGMT:0)!
    let d=c.date(from:DateComponents(year:2026,month:10,day:25,hour:22,minute:0,second:2))!
    let h=HourlyPolicy();let next=h.next(after:d,calendar:c)!
    checks["next_hour_skips_quiet_hours"] = c.component(.hour,from:next)==9 && c.component(.day,from:next)==26
    checks["stale_chime_dropped"] = !h.isFresh(target:d,now:d.addingTimeInterval(90))
    checks["fresh_chime_allowed"] = h.isFresh(target:d,now:d.addingTimeInterval(1))
    let r=NSRect(x:-1200,y:30,width:1200,height:800)
    let o=clampedOrigin(NSPoint(x:2000,y:-1000),size:NSSize(width:100,height:320),visible:r)
    checks["negative_monitor_coordinates"] = o.x == -100 && o.y == 30
    let suite="io.github.bf190t.desktop-companion.preference-test."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!,preferences=Preferences(defaults:UserDefaults(suiteName:suite)!)
    defer{defaults.removePersistentDomain(forName:suite)}
    checks["original_character_default"] = preferences.character == .chibi && preferences.height == 220
    checks["one_public_character"] = PetCharacter.allCases == [.chibi]
    checks["roam_horizontal_default"] = preferences.chibiRoamMode == .horizontal
    preferences.height=999;checks["size_clamped"] = preferences.height == 360
    preferences.chibiRoamMode = .free
    let restored=Preferences(defaults:UserDefaults(suiteName:suite)!)
    checks["range_persistent"] = restored.chibiRoamMode == .free
    checks["size_persistent"] = restored.height == 360
    defaults.set("missing-character",forKey:"character");checks["unknown_character_falls_back"] = preferences.character == .chibi
    let text=try! JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]);print(String(data:text,encoding:.utf8)!)
    return checks.values.allSatisfy{$0}
}
if let index=CommandLine.arguments.firstIndex(of:"--export-icon"),CommandLine.arguments.count>index+1 {
    let picture=OriginalArtwork.image()
    if let data=picture.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data),let png=bitmap.representation(using:.png,properties:[:]) {
        do {try png.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]));exit(0)} catch {fputs("Unable to export icon.\n",stderr);exit(1)}
    };exit(1)
}
if CommandLine.arguments.contains("--self-test") {exit(selfTest() ? 0:1)}
let app=NSApplication.shared
var instanceGuard:SingleInstanceGuard?
if !CommandLine.arguments.contains("--ui-check") {
    switch SingleInstanceGuard.acquire(bundleID:"io.github.bf190t.desktop-companion") {
    case .acquired(let value):instanceGuard=value
    case .alreadyRunning:
        let alert=NSAlert();alert.messageText=L("桌宠已经在运行", "Companion is already running");alert.informativeText=L("本次没有重复启动。若要切换新版，请先从旧版菜单栏「✿」选择“完全退出”，再打开这个版本。", "A second copy was not started. Quit Desktop Companion from the ✿ menu before opening another version.");alert.addButton(withTitle:L("知道了", "Got it"));alert.runModal();exit(0)
    case .failed(let message):
        let alert=NSAlert();alert.messageText=L("桌宠暂未启动", "Companion could not start");alert.informativeText=message+L(" 为避免重复运行，本次已停止。", " Startup stopped to avoid duplicate instances.");alert.runModal();exit(1)
    }
}
app.setActivationPolicy(.accessory)
let delegate=AppDelegate();app.delegate=delegate
app.run()
