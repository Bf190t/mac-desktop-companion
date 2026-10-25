import AppKit
import QuartzCore
import Darwin

// Explicit --ui-check only. Never requests microphone, model downloads, OS lock/sleep,
// or external input. Synthetic fixtures keep screenshots free of device names.
private var acceptance: PublicAcceptance?
func runUIAcceptance(_ app:AppDelegate,output:URL) {
    acceptance=PublicAcceptance(app,output);acceptance?.run()
}
private final class PublicAcceptance {
    let app:AppDelegate, output:URL
    var checks=[String:Bool](), pictures=[String](), performance=[String:Double]()
    var finished=false
    init(_ app:AppDelegate,_ output:URL){self.app=app;self.output=output}
    func record(_ name:String,_ pass:Bool){checks[name]=pass}
    func later(_ seconds:Double,_ action:@escaping ()->Void){DispatchQueue.main.asyncAfter(deadline:.now()+seconds){[weak self] in guard self?.finished == false else{return};action()}}
    func capture(_ window:NSWindow,_ name:String){
        guard let view=window.contentView else{record("capture_"+name,false);return}
        view.layoutSubtreeIfNeeded();view.displayIfNeeded();CATransaction.flush()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{record("capture_"+name,false);return}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]),data.count>200 else{record("capture_"+name,false);return}
        do{try data.write(to:output.appendingPathComponent(name+".png"));pictures.append(name+".png");record("capture_"+name,true)}catch{record("capture_"+name,false)}
    }
    func cpu()->Double {var r=rusage();getrusage(RUSAGE_SELF,&r);return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6}
    func run(){
        try? FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        record("isolated_preferences",app.prefs.defaults !== UserDefaults.standard)
        guard checks["isolated_preferences"] == true else{finish();return}
        later(45){self.record("watchdog",false);self.finish()}
        record("separate_bundle_identity",Bundle.main.bundleIdentifier == "io.github.bf190t.desktop-companion")
        record("one_original_public_character",PetCharacter.allCases == [.chibi] && app.prefs.character == .chibi)
        record("no_automatic_model_or_voice",!app.chat.hasWorker && !app.voice.enabled && !app.voice.isRecording)
        record("roaming_defaults_off",!app.roamingEnabled)
        record("model_not_bundled",!FileManager.default.fileExists(atPath:app.resourceURL.appendingPathComponent("Chat/model").path))
        record("no_voice_sample",!FileManager.default.fileExists(atPath:app.resourceURL.appendingPathComponent("VoiceSample.aiff").path))
        record("original_art_loads",app.chibiArtwork?.left.count == 8 && app.chibiArtwork?.right.count == 8)
        if let art=app.chibiArtwork {
            record("directional_art_differs",art.left[2].tiffRepresentation != art.right[2].tiffRepresentation)
            record("walk_frames_change",art.left[0].tiffRepresentation != art.left[2].tiffRepresentation)
        }
        app.prefs.hourlyEnabled=false;app.refreshRuntime();app.hideBubble()
        app.showSettings();app.settings?.setFrameAutosaveName("")
        checkLanguage(.chinese,"zh")
        checkLanguage(.english,"en")
        app.prefs.height=360;app.showIdle();app.constrainToScreens()
        record("maximum_original_size",app.prefs.height == 360)
        capture(app.pet,"mochi-large")
        for h:CGFloat in [140,220,360] {
            app.prefs.height=h;app.showIdle();app.constrainToScreens()
            record("pet_on_screen_\(Int(h))",app.screenForPet().visibleFrame.insetBy(dx:-1,dy:-1).contains(app.pet.frame))
        }
        app.prefs.height=220;app.showIdle();app.constrainToScreens()
        app.prefs.chatEnabled=true;app.prefs.clickThrough=false;app.refreshRuntime()
        record("foot_chat_visible",app.chatInput?.isVisible == true)
        app.chatInputView?.input.string="Synthetic unsent draft"
        app.setRoaming(true)
        record("roam_hides_chat_and_enables_click_through",app.chatInput?.isVisible != true && app.pet.ignoresMouseEvents)
        app.setRoaming(false)
        record("stop_restores_chat_and_clicks",app.chatInput?.isVisible == true && !app.pet.ignoresMouseEvents)
        record("draft_preserved",app.chatInputView?.input.string == "Synthetic unsent draft")
        app.chatInputView?.input.string=""
        app.setSuspension("qa_only_lock",true)
        record("suspend_hides_and_releases",!app.pet.isVisible && !app.chat.hasWorker && !app.chat.canSend)
        app.setSuspension("qa_only_lock",false)
        record("resume_does_not_load_model",!app.chat.hasWorker)
        runRoamingAcceptance(app,record:{self.record($0,$1)},capture:{self.capture($0,$1)}) {
            self.checkIdle()
        }
    }
    func checkLanguage(_ language:Language,_ suffix:String){
        app.showSettings()
        if let picker=app.controls["language"] as? NSPopUpButton,let index=Language.allCases.firstIndex(of:language){
            picker.selectItem(at:index)
            if let action=picker.action{record("language_action_"+suffix,picker.sendAction(action,to:picker.target))}
        }else{record("language_picker_"+suffix,false)}
        record("language_selected_"+suffix,Language.current == language)
        app.buildMenu()
        let menuText=app.statusMenu.items.map{$0.title}.joined(separator:" ")
        record("menu_translated_"+suffix,language == .english ? menuText.contains("Settings") || menuText.contains("Character"):menuText.contains("角色"))
        app.showSettings()
        if let window=app.settings {
            window.setFrameAutosaveName("")
            record("settings_title_"+suffix,window.title.contains(language == .english ? "Settings":"设置"))
            record("settings_resizable_"+suffix,window.styleMask.contains(.resizable))
            let original=window.frame
            window.setContentSize(window.contentMinSize)
            capture(window,"settings-min-"+suffix)
            window.setFrame(original,display:true)
            capture(window,"settings-"+suffix)
        }
        let panel=app.metricsPanel
        panel.panel.setFrameAutosaveName("")
        panel.onPageChange=nil // Render synthetic fixtures only; do not start device reads.
        panel.panel.orderFront(nil);panel.selectBluetooth(false)
        var sample=MetricsSnapshot();sample.cpuPercent=12;sample.gpuPercent=4;sample.temperatureC=42
        sample.pressureCurrent=L("绿色 · 正常", "Green · Normal");sample.pressureHourSummary=L("绿 100%", "Green 100%")
        sample.pressureObservedSeconds=600;sample.storageAvailableBytes=128_000_000_000;sample.storageTotalBytes=512_000_000_000
        panel.update(sample)
        record("metrics_resizable_"+suffix,panel.panel.styleMask.contains(.resizable))
        capture(panel.panel,"computer-"+suffix)
        panel.selectBluetooth(true)
        let accessory=BluetoothBatteryDevice(id:"demo-device",name:"Demo headphones",category:L("耳机", "Headphones"),connectionStatus:L("已连接", "Connected"),batteries:[BluetoothBatteryLevel(label:L("左耳", "Left"),percent:80),BluetoothBatteryLevel(label:L("右耳", "Right"),percent:78),BluetoothBatteryLevel(label:L("充电盒", "Case"),percent:65)],freshnessText:L("示例数据", "Demo data"))
        panel.updateBluetooth(BluetoothBatterySnapshot(devices:[accessory],updatedAt:Date(),statusText:L("示例数据", "Demo data"),readSucceeded:true))
        capture(panel.panel,"bluetooth-"+suffix)
        let full=panel.panel.frame;panel.panel.setContentSize(panel.panel.contentMinSize)
        capture(panel.panel,"bluetooth-min-"+suffix);panel.panel.setFrame(full,display:true)
        panel.panel.close();panel.onPageChange={ [weak app=self.app] in app?.syncMetricVisibility() }
        app.showChatInspector()
        if let window=app.chatInspector?.window {window.setFrameAutosaveName("");record("chat_resizable_"+suffix,window.styleMask.contains(.resizable));capture(window,"model-"+suffix);window.close()}
        app.showVoiceExperiment()
        if let window=app.voiceWindow?.window {window.setFrameAutosaveName("");capture(window,"voice-"+suffix);window.close()}
        record("opening_diagnostics_is_inert_"+suffix,!app.chat.hasWorker && !app.voice.isRecording)
        app.syncChatVisibility()
    }
    func checkIdle(){
        app.setRoaming(false);app.prefs.chatEnabled=false;app.refreshRuntime();app.hideBubble()
        app.settings?.close();app.metricsPanel.panel.close();app.chatInspector?.window.close();app.voiceWindow?.window.close()
        let began=ProcessInfo.processInfo.systemUptime, used=cpu()
        later(6){
            self.performance["idleSeconds"]=ProcessInfo.processInfo.systemUptime-began
            self.performance["oneCoreCPUPercent"]=(self.cpu()-used)/max(0.1,ProcessInfo.processInfo.systemUptime-began)*100
            self.record("idle_no_model_no_audio_no_roam",!self.app.chat.hasWorker && !self.app.voice.isRecording && self.app.roamController?.hasTimers != true)
            self.record("watchdog",true);self.finish()
        }
    }
    func finish(){
        guard !finished else{return};finished=true
        let report:[String:Any]=["passed":checks.values.allSatisfy{$0},"checks":checks,"screenshots":pictures,"performance":performance,"physicalSleepLockTested":false,"realMicrophoneTested":false,"batteryEnergyMeasured":false,"notes":"App-local controls and lifecycle simulation; no OS sleep, lock, or physical battery test."]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:output.appendingPathComponent("report.json"))}
        print("Public native acceptance: \(checks.filter{$0.value}.count)/\(checks.count)")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2){self.app.quit()}
    }
}
