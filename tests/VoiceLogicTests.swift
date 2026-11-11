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
        check(VoicePolicy.recordingLimit == 60 && VoicePolicy.finalResultLimit == 12, "bounded recording and finalization")
        check(!VoicePolicy.acceptsLocalRecognizer(available: true, onDevice: false), "network-only recognizer rejected")
        check(!VoicePolicy.acceptsLocalRecognizer(available: false, onDevice: true), "unavailable local recognizer rejected")
        check(VoicePolicy.acceptsLocalRecognizer(available: true, onDevice: true), "ready local recognizer accepted")
        check(VoicePolicy.finalizedText(" \n你好，小团。\n", isFinal: true) == "你好，小团。", "final transcript trimmed")
        check(VoicePolicy.finalizedText(" \n", isFinal: true) == nil, "empty final rejected")
        check(VoicePolicy.finalizedText(String(repeating: "字", count: 5001), isFinal: true) == nil, "oversized transcript rejected")
        check(VoicePolicy.preferredChineseLanguage(["en-US"]) == nil, "no foreign voice fallback or download")
        check(VoicePolicy.preferredChineseLanguage(["zh-TW", "zh-CN", "en-US"]) == "zh-CN", "Mandarin preferred")
        check(VoicePolicy.preferredChineseLanguage(["zh-TW", "en-US"]) == "zh-TW", "installed Chinese fallback")
        check(VoicePolicy.preferredEnglishLanguage(["en-US", "en-AU", "zh-CN"], region: "AU") == "en-AU", "the Mac's English variant first")
        check(VoicePolicy.preferredEnglishLanguage(["en-GB", "en-US"], region: "FR") == "en-US", "US English otherwise")
        // Pauses: a recognizer that restarts after a pause keeps what was said before.
        func joined(_ steps: [(String, Bool)]) -> String {
            var t = VoiceTranscript(); for (text, ended) in steps { t.update(text, segmentEnded: ended) }; return t.text
        }
        let joins: [(String, [(String, Bool)], String)] = [
            ("cumulative partials", [("今天", false), ("今天天气", false), ("今天天气不错", false)], "今天天气不错"),
            ("revision keeps latest", [("今天天期", false), ("今天天气", false)], "今天天气"),
            ("reset after pause keeps first sentence", [("今天天气不错", false), ("我们", false), ("我们出去玩", false)], "今天天气不错，我们出去玩"),
            ("segment metadata then fresh segment", [("今天天气不错", true), ("我们出去玩", false)], "今天天气不错，我们出去玩"),
            ("segment metadata then cumulative", [("今天天气不错", true), ("今天天气不错我们出去玩", false)], "今天天气不错，我们出去玩"),
            ("punctuation revision is not duplicated", [("你好今天", true), ("你好，今天我们去公园", false)], "你好今天，我们去公园"),
            ("same opening words after a pause", [("今天好累", true), ("今天还", false), ("今天还要加班吗", false)], "今天好累，今天还要加班吗"),
            ("restart with the same first character", [("我觉得还行", false), ("我", false), ("我们走吧", false)], "我觉得还行，我们走吧"),
            ("revised punctuation, no stray comma", [("你好", true), ("你好。今天", false)], "你好，今天"),
            ("growing partial with revised middle", [("我觉得还行", false), ("我觉得还挺好的", false)], "我觉得还挺好的"),
            ("punctuated segment joins without extra comma", [("今天天气不错。", true), ("我们出去玩", false)], "今天天气不错。我们出去玩"),
            ("empty partial ignored", [("今天", false), ("", false)], "今天"),
            ("short early revision is not a reset", [("他是", false), ("它", false)], "它"),
            ("English segments", [("I am tired", true), ("let's rest", false)], "I am tired, let's rest"),
            ("English sentence end", [("I am tired.", true), ("Let's rest", false)], "I am tired. Let's rest"),
        ]
        for (name, steps, expected) in joins { check(joined(steps) == expected, "join: \(name)") }
        // The macOS 26 transcriber's spaces around numbers and punctuation.
        for (raw, expected) in [("我 8:30要到公司路上要 40分钟 ，我几点起床。", "我8:30要到公司路上要40分钟，我几点起床。"),
                                ("  用 AirPods Pro 听歌  ", "用AirPods Pro听歌"), ("hello world", "hello world")] {
            check(VoicePolicy.tidyTranscript(raw) == expected, "tidy: \(raw)")
        }
        // What is read aloud: no emoji, stage directions or tildes; ranges keep their meaning.
        for (raw, expected) in [("嗯～累就歇会儿，我在这儿陪你。✨💙", "嗯累就歇会儿，我在这儿陪你。"), ("（轻轻蹭蹭你）辛苦啦～", "辛苦啦"),
                                ("*wags tail* Sure!", "Sure!"), ("👍🏻👨‍👩‍👧", ""), ("Lifeline 13 11 14。", "Lifeline 13 11 14。")] {
            check(VoicePolicy.speakableText(raw) == expected, "speakable: \(raw)")
        }
        check(VoicePolicy.speakableText("睡 7~8 个小时") == (Language.current == .english ? "睡 7 to 8 个小时" : "睡 7到8 个小时"), "tilde range")
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
