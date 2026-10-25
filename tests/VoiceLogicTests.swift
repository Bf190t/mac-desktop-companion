import Foundation

@main struct VoiceLogicTests {
    static func main() {
        let domain="io.github.bf190t.desktop-companion.test.voice."+UUID().uuidString
        let previous=Language.defaults
        let isolated=UserDefaults(suiteName:domain)!
        Language.defaults=isolated
        defer {Language.defaults=previous;isolated.removePersistentDomain(forName:domain)}
        var results=[[String:Any]]()
        for language in Language.allCases {
            Language.current=language
            let count=runChecks()
            results.append(["language":language.rawValue,"passed":count,"failed":0])
        }
        let result:[String:Any]=["languages":results,"passed":results.reduce(0){$0+($1["passed"] as! Int)},
            "failed":0,"isolatedPreferences":true,"microphone_opened":false,"audio_played":false,"real_speech_recognition":false]
        let data=try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
    static func runChecks()->Int {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            passed += 1
        }
        var state = VoiceSessionGate()
        check(!VoicePolicy.canBegin(enabled: false, phase: state.phase), "disabled cannot start")
        check(VoicePolicy.canBegin(enabled: true, phase: state.phase), "first explicit press can request permissions")
        let permission = state.begin(.permission)
        check(!VoicePolicy.canBegin(enabled: true, phase: state.phase), "duplicate permission press blocked")
        state.invalidate() // release, hide or shutdown while permission UI is open
        check(!state.accepts(permission, [.permission]), "late authorization callback cannot start capture")
        check(state.phase == .idle, "permission release returns idle without recording")
        let capture = state.begin(.recording)
        check(!VoicePolicy.canBegin(enabled: true, phase: state.phase), "overlapping capture blocked")
        check(state.transition(capture, to: .processing), "release enters final-only processing")
        check(!VoicePolicy.canBegin(enabled: true, phase: state.phase), "new capture blocked during final processing")
        check(VoicePolicy.finalizedText("旧的半句", isFinal: false) == nil, "partial result never enters chat input")
        state.invalidate() // cancellation / timeout / feature disabled
        check(!state.accepts(capture, [.recording, .processing]), "cancelled final result rejected")
        let fresh = state.begin(.recording)
        check(fresh != capture && !state.accepts(capture, [.recording]), "old timeout cannot stop new capture")
        check(!state.transition(capture, to: .processing) && state.phase == .recording, "stale release preserves newer recording")
        state.invalidate()
        check(!state.accepts(fresh, [.recording, .processing]), "shutdown invalidates active session")
        check(VoicePolicy.recordingLimit == 30 && VoicePolicy.finalResultLimit == 12, "bounded recording and finalization")
        check(!VoicePolicy.acceptsLocalRecognizer(available: true, onDevice: false), "network-only recognizer rejected")
        check(!VoicePolicy.acceptsLocalRecognizer(available: false, onDevice: true), "unavailable local recognizer rejected")
        check(VoicePolicy.acceptsLocalRecognizer(available: true, onDevice: true), "ready local recognizer accepted")
        check(VoicePolicy.finalizedText(" \n你好，小团。\n", isFinal: true) == "你好，小团。", "final transcript trimmed")
        check(VoicePolicy.finalizedText(" \n", isFinal: true) == nil, "empty final rejected")
        check(VoicePolicy.finalizedText(String(repeating: "字", count: 5001), isFinal: true) == nil, "oversized transcript rejected")
        check(VoicePolicy.preferredChineseLanguage(["en-US"]) == nil, "no foreign voice fallback or download")
        check(VoicePolicy.preferredChineseLanguage(["zh-TW", "zh-CN", "en-US"]) == "zh-CN", "Mandarin preferred")
        check(VoicePolicy.preferredChineseLanguage(["zh-TW", "en-US"]) == "zh-TW", "installed Chinese fallback")
        // No enabled capture/speak calls: this verifies the default-off boundary
        // without querying permission, creating an engine, or playing audio.
        let service = PetVoiceService()
        check(!service.enabled && !service.canRecord, "service starts fully disabled")
        var received = 0
        service.onTranscript = { _ in received += 1 }
        service.beginCapture(); service.speak("这句不能播放。")
        service.transcribeFileForQA(URL(fileURLWithPath: "/not-an-audio-file"))
        check(!service.isRecording && !service.isSpeaking && !service.isProcessing && !service.isRequestingPermission && received == 0, "disabled public entry points do nothing")
        service.enabled = true
        check(service.canRecord && !service.isRequestingPermission && !service.isRecording, "enabling does not request or record")
        service.shutdown(reason: "测试取消")
        check(!service.isRecording && !service.isProcessing && !service.isSpeaking, "idle shutdown remains stopped")
        service.enabled = false
        check(!service.canRecord && service.status == L("语音功能已关闭。", "Voice is off."), "disabling resets visible state")
        return passed
    }
}
