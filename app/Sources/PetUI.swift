import AppKit
import QuartzCore

final class CompanionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(rect: NSRect) {
        super.init(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        level = .floating; hidesOnDeactivate = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle,.fullScreenNone,.fullScreenDisallowsTiling]
        animationBehavior = .none
    }
}

final class PetView: NSView {
    let sprite = CALayer()
    var artworkSize: NSSize?
    var onDragStart: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onTap: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var startMouse = NSPoint.zero
    var startOrigin = NSPoint.zero
    var didDrag = false
    override init(frame: NSRect) {
        super.init(frame:frame);wantsLayer = true;layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(sprite);sprite.contentsGravity = .resizeAspect
        sprite.anchorPoint = CGPoint(x:0.5,y:0);sprite.magnificationFilter = .linear;sprite.minificationFilter = .trilinear
        setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel(L("小团桌宠，点击对话，拖动位置，右键打开菜单", "Mochi companion. Click to chat, drag to move, right-click for menu."))
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() { super.layout();CATransaction.begin();CATransaction.setDisableActions(true);sprite.bounds=CGRect(origin:.zero,size:artworkSize ?? bounds.size);sprite.position=CGPoint(x:bounds.midX,y:0);CATransaction.commit() }
    override func viewDidChangeBackingProperties(){super.viewDidChangeBackingProperties();updateScale()}
    private func updateScale(){let scale=window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2;layer?.contentsScale=scale;sprite.contentsScale=scale}
    func show(_ image: NSImage) {
        updateScale()
        var rect=NSRect(origin:.zero,size:image.size)
        CATransaction.begin();CATransaction.setDisableActions(true)
        sprite.contents = image.cgImage(forProposedRect:&rect,context:nil,hints:nil)
        CATransaction.commit()
    }
    func smallBreath() {
        let a=CABasicAnimation(keyPath:"transform.scale.y");a.fromValue=1.0;a.toValue=1.006
        a.duration=1.8;a.autoreverses=true;a.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        sprite.add(a,forKey:"breath")
    }
    func stopMotion() { sprite.removeAllAnimations() }
    func smallHop(height: CGFloat) {
        guard sprite.animation(forKey:"hop") == nil else {return}
        func track(_ path:String,_ values:[CGFloat]) -> CAKeyframeAnimation {
            let animation=CAKeyframeAnimation(keyPath:path);animation.values=values
            animation.keyTimes=[0,0.14,0.48,0.84,1]
            animation.timingFunctions=Array(repeating:CAMediaTimingFunction(name:.easeInEaseOut),count:4)
            return animation
        }
        let group=CAAnimationGroup();group.duration=0.88
        group.animations=[track("transform.translation.y",[0,0,height,0,0]),track("transform.scale.x",[1,1.055,0.98,1.04,1]),track("transform.scale.y",[1,0.94,1.025,0.96,1])]
        sprite.add(group,forKey:"hop")
    }
    override func mouseDown(with event:NSEvent) {
        onDragStart?();startMouse=NSEvent.mouseLocation;startOrigin=window?.frame.origin ?? .zero;didDrag=false
    }
    override func mouseDragged(with event:NSEvent) {
        let p=NSEvent.mouseLocation;let dx=p.x-startMouse.x,dy=p.y-startMouse.y
        if abs(dx)+abs(dy)>3 { didDrag=true;onDrag?(NSPoint(x:startOrigin.x+dx,y:startOrigin.y+dy)) }
    }
    override func mouseUp(with event:NSEvent) { if didDrag { onDragEnd?() } else { onTap?() } }
    override func rightMouseDown(with event:NSEvent) { onMenu?(event) }
}

final class BubbleView: NSView {
    let label=NSTextField(wrappingLabelWithString:"")
    var tailOnRight=true
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true
        label.font=NSFont.systemFont(ofSize:14,weight:.medium);label.textColor=NSColor(calibratedRed:0.13,green:0.19,blue:0.28,alpha:1)
        label.maximumNumberOfLines=0;addSubview(label);layoutText()
    }
    required init?(coder:NSCoder) { fatalError() }
    func layoutText(){label.frame=NSRect(x:17,y:22,width:bounds.width-34,height:bounds.height-39);needsDisplay=true}
    override func layout(){super.layout();layoutText()}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedRed:0.95,green:0.98,blue:1,alpha:0.97).setFill()
        let shape=NSBezierPath(roundedRect:NSRect(x:1,y:12,width:bounds.width-2,height:bounds.height-15),xRadius:17,yRadius:17)
        shape.fill();NSColor(calibratedRed:0.52,green:0.67,blue:0.83,alpha:0.85).setStroke();shape.lineWidth=1;shape.stroke()
        let tail=NSBezierPath();let x:CGFloat=tailOnRight ? bounds.width-30:28
        tail.move(to:NSPoint(x:x-10,y:15));tail.line(to:NSPoint(x:x+8,y:1));tail.line(to:NSPoint(x:x+10,y:15));tail.close()
        NSColor(calibratedRed:0.95,green:0.98,blue:1,alpha:0.97).setFill();tail.fill()
    }
}

func label(_ text:String,_ size:CGFloat=13,_ weight:NSFont.Weight = .regular) -> NSTextField {
    let v=NSTextField(labelWithString:text);v.font=NSFont.systemFont(ofSize:size,weight:weight);return v
}

final class MetricsPanelController: NSObject,NSWindowDelegate {
    let panel:NSPanel
    var onClose:(()->Void)?
    var onRefresh:(()->Void)?
    var onBluetoothRefresh:(()->Void)?
    var onPageChange:(()->Void)?
    private(set) var isBluetoothPage=false
    private let root=ResponsiveUtilityContentView(frame:NSRect(x:0,y:0,width:420,height:560))
    private let pages=NSSegmentedControl(labels:[L("电脑", "Computer"),L("蓝牙电量", "Bluetooth")],trackingMode:.selectOne,target:nil,action:nil)
    private let computerContent=NSView()
    private let bluetoothContent=NSView()
    private let bluetoothScroll=NSScrollView()
    private let bluetoothDocument=FlippedBatteryView()
    private var batteryCards:[BatteryCardView]=[]
    private var emptyBatteryNote:NSTextField?
    private let bluetoothHeader=label(L("打开本页时读取 · 约每分钟更新", "Reads while open · Updates about once a minute"),11)
    private let bluetoothFooter=NSTextField(wrappingLabelWithString:"")
    private let bluetoothRefreshButton=NSButton(title:L("刷新电量", "Refresh battery"),target:nil,action:nil)
    private let storageRefreshButton=NSButton(title:L("刷新存储", "Refresh storage"),target:nil,action:nil)
    private var values:[String:NSTextField]=[:]
    private var titles:[String:NSTextField]=[:]
    private let footer=NSTextField(wrappingLabelWithString:"")
    private let memoryNote=NSTextField(wrappingLabelWithString:"")
    private let temperatureNote=NSTextField(wrappingLabelWithString:"")
    private let history=NSTextField(wrappingLabelWithString:"")
    private let header=label(L("窗口打开时更新 · 无历史曲线", "Updates while open · No history graphs"),11)
    override init() {
        panel=NSPanel(contentRect:NSRect(x:0,y:0,width:420,height:560),styleMask:[.titled,.closable,.resizable,.miniaturizable,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init();panel.title=L("状态小窗", "Computer & Bluetooth");panel.hidesOnDeactivate=false;panel.isReleasedWhenClosed=false;panel.level = .floating
        panel.collectionBehavior=[.canJoinAllSpaces,.ignoresCycle];panel.delegate=self
        DesktopWindowBehavior.configure(panel,minimumContentSize:NSSize(width:370,height:510))
        panel.setFrameAutosaveName("CompanionMetricsPanel")
        panel.contentView=root
        root.addSubview(computerContent);root.addSubview(bluetoothContent);bluetoothContent.isHidden=true
        pages.selectedSegment=0;pages.target=self;pages.action=#selector(pageChanged);root.addSubview(pages)
        header.textColor = .secondaryLabelColor;computerContent.addSubview(header)
        for (key,title) in [("cpu",L("CPU 占用", "CPU usage")),("gpu",L("GPU 占用", "GPU usage")),("temp",L("温度", "Temperature")),("pressure",L("当前内存压力", "Memory pressure")),("memory",L("空闲物理内存", "Free physical RAM")),("storage",L("存储可用", "Available storage"))] {
            let left=label(title,13,.medium);computerContent.addSubview(left);titles[key]=left
            let value=label("—",20,.medium);value.alignment = .right;value.font=NSFont.monospacedDigitSystemFont(ofSize:20,weight:.medium)
            computerContent.addSubview(value);values[key]=value
        }
        for note in [temperatureNote,memoryNote,footer] {note.font = .systemFont(ofSize:10);note.textColor = .secondaryLabelColor;computerContent.addSubview(note)}
        history.font = .systemFont(ofSize:11);history.textColor = .secondaryLabelColor;computerContent.addSubview(history)
        storageRefreshButton.target=self;storageRefreshButton.action=#selector(refresh);storageRefreshButton.bezelStyle = .rounded;computerContent.addSubview(storageRefreshButton)
        bluetoothHeader.textColor = .secondaryLabelColor;bluetoothContent.addSubview(bluetoothHeader)
        bluetoothScroll.hasVerticalScroller=true;bluetoothScroll.autohidesScrollers=true;bluetoothScroll.drawsBackground=false;bluetoothScroll.documentView=bluetoothDocument
        bluetoothContent.addSubview(bluetoothScroll)
        bluetoothFooter.font = .systemFont(ofSize:10);bluetoothFooter.textColor = .secondaryLabelColor;bluetoothContent.addSubview(bluetoothFooter)
        bluetoothRefreshButton.target=self;bluetoothRefreshButton.action=#selector(refreshBluetooth);bluetoothRefreshButton.bezelStyle = .rounded;bluetoothContent.addSubview(bluetoothRefreshButton)
        root.onResize={ [weak self] _ in self?.layoutContents() }
        layoutContents();updateBluetooth(BluetoothBatterySnapshot())
    }
    @objc private func refresh(){onRefresh?()}
    @objc private func refreshBluetooth(){onBluetoothRefresh?()}
    @objc private func pageChanged(){selectBluetooth(pages.selectedSegment == 1)}
    func selectBluetooth(_ selected:Bool){
        isBluetoothPage=selected;pages.selectedSegment=selected ? 1:0
        computerContent.isHidden=selected;bluetoothContent.isHidden = !selected;onPageChange?()
    }
    func windowWillClose(_ n:Notification){onClose?()}
    func windowDidMiniaturize(_ n:Notification){onPageChange?()}
    func windowDidDeminiaturize(_ n:Notification){onPageChange?()}
    func windowWillUseStandardFrame(_ window:NSWindow,defaultFrame:NSRect)->NSRect {
        DesktopWindowBehavior.standardFrame(for:window,defaultFrame:defaultFrame)
    }
    private func layoutContents(){
        let size=root.bounds.size
        pages.frame=NSRect(x:(size.width-230)/2,y:size.height-38,width:230,height:25)
        // Text remains at a readable size. Wider windows gain useful line width,
        // while the numeric table stays centred instead of stretching endlessly.
        let cw=min(760,size.width),ch=min(700,max(462,size.height-48))
        computerContent.frame=NSRect(x:(size.width-cw)/2,y:max(0,(size.height-48-ch)/2),width:cw,height:ch)
        let scale=ch/462
        header.frame=NSRect(x:22,y:ch-35,width:cw-44,height:18)
        for (key,y) in [("cpu",CGFloat(378)),("gpu",335),("temp",292),("pressure",226),("memory",140),("storage",71)] {
            titles[key]?.frame=NSRect(x:22,y:y*scale+5,width:150,height:22)
            values[key]?.frame=NSRect(x:170,y:y*scale,width:cw-192,height:30)
        }
        temperatureNote.frame=NSRect(x:22,y:265*scale,width:cw-44,height:26)
        history.frame=NSRect(x:22,y:181*scale,width:cw-44,height:43)
        memoryNote.frame=NSRect(x:22,y:112*scale,width:cw-44,height:26)
        footer.frame=NSRect(x:22,y:3,width:cw-166,height:64)
        storageRefreshButton.frame=NSRect(x:cw-139,y:22,width:120,height:30)
        let bw=min(1120,size.width),bh=max(462,size.height-48)
        bluetoothContent.frame=NSRect(x:(size.width-bw)/2,y:0,width:bw,height:bh)
        bluetoothHeader.frame=NSRect(x:22,y:bh-35,width:bw-44,height:18)
        bluetoothScroll.frame=NSRect(x:16,y:82,width:bw-32,height:bh-133)
        bluetoothFooter.frame=NSRect(x:22,y:10,width:bw-168,height:64)
        bluetoothRefreshButton.frame=NSRect(x:bw-139,y:28,width:120,height:30)
        layoutBatteryCards()
    }
    private func layoutBatteryCards(){
        let previousY=bluetoothScroll.contentView.bounds.origin.y
        let available=max(300,bluetoothScroll.contentSize.width)
        let columns=max(1,min(3,Int((available+12)/324)))
        let cardWidth=(available-CGFloat(columns-1)*12)/CGFloat(columns)
        let rows=(batteryCards.count+columns-1)/columns
        let height=max(bluetoothScroll.contentSize.height,CGFloat(rows)*120)
        bluetoothDocument.setFrameSize(NSSize(width:available,height:height))
        for (i,card) in batteryCards.enumerated(){
            card.frame=NSRect(x:CGFloat(i%columns)*(cardWidth+12),y:CGFloat(i/columns)*120,width:cardWidth,height:108)
            card.layoutCard()
        }
        emptyBatteryNote?.frame=NSRect(x:12,y:36,width:available-24,height:180)
        bluetoothScroll.contentView.scroll(to:NSPoint(x:0,y:min(previousY,max(0,height-bluetoothScroll.contentSize.height))))
        bluetoothScroll.reflectScrolledClipView(bluetoothScroll.contentView)
    }
    func setSuspended(_ suspended:Bool){
        let saving=ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        header.stringValue=suspended ? L("已暂停采样 · 解锁或唤醒后恢复", "Sampling paused · Resumes after unlock or wake"):(saving ? L("节能中 · 窗口打开时约 15 秒更新", "Energy saving · Updates about every 15 seconds while open"):L("窗口打开时约 5 秒更新 · 无历史曲线", "Updates about every 5 seconds while open · No graphs"))
        bluetoothHeader.stringValue=suspended ? L("已暂停读取 · 解锁或唤醒后恢复", "Reading paused · Resumes after unlock or wake"):L("打开本页时读取 · 约每分钟更新", "Reads while open · Updates about once a minute")
        bluetoothRefreshButton.isEnabled = !suspended
    }
    func updateBluetooth(_ snapshot:BluetoothBatterySnapshot){
        for child in bluetoothDocument.subviews {child.removeFromSuperview()}
        batteryCards.removeAll();emptyBatteryNote=nil
        if snapshot.devices.isEmpty {
            let empty=NSTextField(wrappingLabelWithString:Localizer.text(snapshot.statusText)+L("\n\n耳机请在日常使用时打开充电盒或佩戴，\n待 macOS 更新电量后再刷新。\n本应用不会扫描或主动连接设备。", "\n\nUse your headphones or open the charging case normally,\nthen refresh after macOS updates the battery record.\nThis app never scans or connects to devices."))
            empty.font = .systemFont(ofSize:12);empty.textColor = .secondaryLabelColor;bluetoothDocument.addSubview(empty);emptyBatteryNote=empty
        }
        let sameNames=Dictionary(grouping:snapshot.devices,by:{$0.name})
        for device in snapshot.devices {
            let siblings=(sameNames[device.name] ?? []).sorted{$0.id<$1.id}
            let suffix=siblings.count>1 ? L(" · 设备 \((siblings.firstIndex{$0.id==device.id} ?? 0)+1)", " · Device \((siblings.firstIndex{$0.id==device.id} ?? 0)+1)"):""
            let card=BatteryCardView(device:device,displayName:device.name+suffix)
            bluetoothDocument.addSubview(card);batteryCards.append(card)
        }
        layoutBatteryCards()
        let f=DateFormatter();f.dateFormat="HH:mm:ss"
        let stamp=snapshot.updatedAt.map{L("读取于 ", "Read at ")+f.string(from:$0)} ?? L("尚未读取", "Not read yet")
        bluetoothFooter.stringValue=L("\(snapshot.devices.count) 个系统记录 · \(stamp)\n这是系统最近提供的电量，可能滞后。\n关闭本页即停止读取；不扫描、不连接。", "\(snapshot.devices.count) system records · \(stamp)\nLatest battery values from macOS; they may be stale.\nReads stop when this page closes. No scans or connections.")
        bluetoothFooter.toolTip=Localizer.text(snapshot.statusText)
    }
    func update(_ m:MetricsSnapshot) {
        func percent(_ n:Double?)->String {n.map{String(format:"%.0f%%",$0)} ?? L("暂不可读", "Unavailable")}
        func gb(_ n:UInt64)->String {String(format:"%.1f GB",Double(n)/1_000_000_000)}
        values["cpu"]?.stringValue=percent(m.cpuPercent);values["gpu"]?.stringValue=percent(m.gpuPercent);titles["gpu"]?.stringValue=Localizer.text(m.gpuDescription)
        values["temp"]?.stringValue=m.temperatureC.map{String(format:"%.1f °C",$0)} ?? L("未提供读数", "No reading")
        temperatureNote.stringValue=L("\(Localizer.text(m.temperatureDescription)) · 系统热状态：\(Localizer.text(m.thermalDescription))", "\(Localizer.text(m.temperatureDescription)) · Thermal state: \(Localizer.text(m.thermalDescription))")
        values["pressure"]?.stringValue=Localizer.text(m.pressureCurrent)
        values["pressure"]?.textColor=Localizer.text(m.pressureCurrent).contains(L("红", "Red")) ? .systemRed : Localizer.text(m.pressureCurrent).contains(L("黄", "Yellow")) ? .systemOrange : Localizer.text(m.pressureCurrent).contains(L("绿", "Green")) ? .systemGreen : .secondaryLabelColor
        history.stringValue=L("近 1 小时：\(Localizer.text(m.pressureHourSummary))\n按已观察时间统计，非 Apple 官方平均值", "Past hour: \(Localizer.text(m.pressureHourSummary))\nObserved by this app; not an official Apple average")
        if Localizer.text(m.pressureCurrent) == L("未知", "Unknown") {
            titles["memory"]?.stringValue=L("空闲物理内存", "Free physical RAM")
            values["memory"]?.stringValue=m.availableMemoryBytes.map(gb) ?? L("暂不可读", "Unavailable")
            memoryNote.stringValue=L("\(Localizer.text(m.memoryDescription)) · 总计 \(gb(m.totalMemoryBytes))", "\(Localizer.text(m.memoryDescription)) · Total \(gb(m.totalMemoryBytes))")
        } else {
            titles["memory"]?.stringValue=L("有效观察", "Observed time")
            values["memory"]?.stringValue=m.pressureObservedSeconds >= 60 ? L("\(Int(m.pressureObservedSeconds/60)) 分钟", "\(Int(m.pressureObservedSeconds/60)) min"):L("\(Int(m.pressureObservedSeconds)) 秒", "\(Int(m.pressureObservedSeconds)) sec")
            memoryNote.stringValue=L("仅统计最近一小时内有效时段；锁屏、休眠缺口不补样本", "Observed periods within the past hour only; lock and sleep gaps are excluded")
        }
        if let a=m.storageAvailableBytes,let total=m.storageTotalBytes {
            values["storage"]?.stringValue=String(format:"%.0f / %.0f GB",Double(a)/1e9,Double(total)/1e9)
        } else {values["storage"]?.stringValue=L("暂不可读", "Unavailable")}
        let f=DateFormatter();f.dateFormat="HH:mm"
        let stamp=m.storageUpdatedAt.map{L("上次更新 ", "Updated ")+f.string(from:$0)} ?? L("尚未取得存储读数", "No storage reading yet")
        footer.stringValue=L("\(Localizer.text(m.storageDescription))\n每小时刷新 · \(stamp)", "\(Localizer.text(m.storageDescription))\nUpdates hourly · \(stamp)")
    }
}

private final class ResponsiveUtilityContentView:NSView {
    var onResize:((NSSize)->Void)?
    override func resizeSubviews(withOldSize oldSize:NSSize){super.resizeSubviews(withOldSize:oldSize);onResize?(bounds.size)}
}

private class FlippedBatteryView:NSView {
    override var isFlipped:Bool {true}
}

private final class BatteryCardView:FlippedBatteryView {
    let title:NSTextField
    let detail:NSTextField
    var readings:[(NSTextField,NSTextField)]=[]
    var missing:NSTextField?
    init(device:BluetoothBatteryDevice,displayName:String){
        title=label(displayName,13,.semibold)
        detail=label(Localizer.text(device.category)+" · "+Localizer.text(device.connectionStatus),10)
        super.init(frame:.zero);wantsLayer=true;layer?.cornerRadius=10
        title.lineBreakMode = .byTruncatingTail;title.toolTip=displayName;addSubview(title)
        detail.textColor = .secondaryLabelColor;detail.lineBreakMode = .byTruncatingTail;detail.toolTip=detail.stringValue;addSubview(detail)
        if device.batteries.isEmpty {
            let unknown=label(L("系统未提供电量", "No battery value from macOS"),15,.medium);addSubview(unknown);missing=unknown
        } else {
            for battery in device.batteries {
                let value=label("\(battery.percent)%"+(battery.isCharging == true ? " ⚡︎":""),18,.medium)
                value.font=NSFont.monospacedDigitSystemFont(ofSize:18,weight:.medium);addSubview(value)
                let part=label(Localizer.text(battery.label),10);part.textColor = .secondaryLabelColor;addSubview(part)
                readings.append((value,part))
            }
        }
        toolTip=Localizer.text(device.freshnessText);refreshAppearance()
    }
    required init?(coder:NSCoder){fatalError()}
    override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();refreshAppearance()}
    private func refreshAppearance(){effectiveAppearance.performAsCurrentDrawingAppearance{layer?.backgroundColor=NSColor.controlBackgroundColor.cgColor}}
    func layoutCard(){
        let width=bounds.width-24
        title.frame=NSRect(x:12,y:9,width:width,height:19)
        detail.frame=NSRect(x:12,y:31,width:width,height:15)
        missing?.frame=NSRect(x:12,y:52,width:width,height:23)
        guard !readings.isEmpty else{return}
        let column=width/CGFloat(readings.count)
        for (i,pair) in readings.enumerated(){
            pair.0.frame=NSRect(x:12+CGFloat(i)*column,y:49,width:column-4,height:25)
            pair.1.frame=NSRect(x:12+CGFloat(i)*column,y:75,width:column-4,height:15)
        }
    }
}
