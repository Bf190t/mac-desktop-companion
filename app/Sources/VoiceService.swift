import Foundation
import AVFoundation
import Speech

// Main-thread state machine. Tokens cover permission dialogs, recognition and
// deadlines, so a completed old operation cannot revive a cancelled capture.
struct VoiceSessionGate {
    enum Phase { case idle, permission, recording, processing }
    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .idle
    mutating func begin(_ phase: Phase) -> UInt64 {
        generation &+= 1; self.phase = phase; return generation
    }
    func accepts(_ token: UInt64, _ phases: [Phase]) -> Bool {
        token == generation && phases.contains(phase)
    }
    @discardableResult mutating func transition(_ token: UInt64, to phase: Phase) -> Bool {
        guard token == generation, self.phase != .idle else { return false }
        self.phase = phase; return true
    }
    mutating func invalidate() { generation &+= 1; phase = .idle }
}

enum VoicePolicy {
    static let recordingLimit: TimeInterval = 30
    static let finalResultLimit: TimeInterval = 12
    static func canBegin(enabled: Bool, phase: VoiceSessionGate.Phase) -> Bool {
        enabled && phase == .idle
    }
    static func acceptsLocalRecognizer(available: Bool, onDevice: Bool) -> Bool {
        available && onDevice
    }
    static func finalizedText(_ text: String, isFinal: Bool) -> String? {
        guard isFinal else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 5000 else { return nil }
        return value
    }
    static func preferredChineseLanguage(_ languages: [String]) -> String? {
        for preferred in ["zh-CN", "zh-TW", "zh-HK"] {
            if languages.contains(preferred) { return preferred }
        }
        return languages.sorted().first { $0.lowercased().hasPrefix("zh-") }
    }
}

// AVAudioEngine invokes the tap on an audio thread. Serialize append/endAudio
// independently of UI state and never retain the service from the tap.
private final class VoiceAudioSink {
    private let lock = NSLock()
    private var accepting = true
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if accepting { request.append(buffer) }
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        accepting = false; request.endAudio()
    }
}

// All public methods and callbacks are main-thread confined. Construction and
// enabling do not request permission, instantiate an audio engine, or speak.
final class PetVoiceService: NSObject, AVSpeechSynthesizerDelegate {
    var onChange: (() -> Void)?
    var onTranscript: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?
    var enabled = false {
        didSet {
            guard oldValue != enabled else { return }
            if !enabled { shutdown(reason: L("语音功能已关闭。", "Voice is off.")) }
            else { status = L("按住说话，松开后转写；确认文字后再发送。", "Hold to talk, then review the transcript before sending."); changed() }
        }
    }
    private(set) var status = L("语音功能已关闭。", "Voice is off.")
    private(set) var isSpeaking = false
    var isRecording: Bool { session.phase == .recording }
    var isProcessing: Bool { session.phase == .processing }
    var isRequestingPermission: Bool { session.phase == .permission }
    // An unapproved first press may request permission. Denial remains retryable
    // after the user changes macOS Settings; it never falls back to a server.
    var captureGeneration: UInt64 { session.generation }
    var canRecord: Bool { VoicePolicy.canBegin(enabled: enabled, phase: session.phase) }

    private var session = VoiceSessionGate()
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechRecognitionRequest?
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var sink: VoiceAudioSink?
    private var tapInstalled = false
    private var captureDeadline: DispatchWorkItem?
    private var finalDeadline: DispatchWorkItem?
    private var engineObserver: NSObjectProtocol?
    private var synthesizer: AVSpeechSynthesizer?
    private var utterance: AVSpeechUtterance?
    private var speechDeadline: DispatchWorkItem?

    private func changed() { onChange?() }

    func beginCapture() {
        guard canRecord else { return }
        stopSpeaking()
        guard hasUsageDescriptions(microphone: true) else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        guard mic == .authorized, speech == .authorized else {
            requestPermissions(microphone: true); return
        }
        guard let local = localRecognizer() else { return }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            status = L("未找到可用麦克风。仍可打字聊天。", "No microphone found. You can still type."); changed(); return
        }
        let token = session.begin(.recording)
        let audioEngine = AVAudioEngine()
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            failCapture(token, message: L("麦克风当前不可用。请检查输入设备，仍可打字聊天。", "The microphone is unavailable. Check your input device or continue typing."))
            return
        }
        let audioRequest = SFSpeechAudioBufferRecognitionRequest()
        configure(audioRequest)
        let audioSink = VoiceAudioSink(audioRequest)
        recognizer = local; request = audioRequest; sink = audioSink
        engine = audioEngine; inputNode = node
        // A bound request receives buffers only until finish/cancel closes it.
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in audioSink.append(buffer) }
        tapInstalled = true
        recognition = local.recognitionTask(with: audioRequest) { [weak self] result, error in
            DispatchQueue.main.async { self?.recognitionResult(result, error: error, token: token) }
        }
        do {
            audioEngine.prepare(); try audioEngine.start()
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
                guard let self = self, self.session.accepts(token, [.recording]) else { return }
                self.failCapture(token, message: L("音频输入设备发生变化，录音已停止。请重新按住说话。", "The audio input device changed. Recording stopped; hold to talk again."))
            }
            status = L("正在聆听…松开后转写，最长 30 秒。", "Listening… Release to transcribe. Up to 30 seconds.")
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, self.session.accepts(token, [.recording]) else { return }
                self.finishCapture()
                if self.session.accepts(token, [.processing]) {
                    self.status = L("已达到 30 秒上限，正在本机转写…", "The 30-second limit was reached. Transcribing locally…"); self.changed()
                }
            }
            captureDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.recordingLimit, execute: deadline)
            changed()
        } catch {
            failCapture(token, message: L("无法启动麦克风。请检查输入设备和权限，仍可打字聊天。", "Cannot start the microphone. Check your input device and permissions, or continue typing."))
        }
    }

    func finishCapture() {
        if isRequestingPermission {
            // Mouse-up while a system dialog is open cannot start capture later.
            cancelCapture(reason: L("授权结束后请再次按住说话。", "After granting permission, hold to talk again."))
            return
        }
        guard isRecording else { return }
        let token = session.generation
        stopMicrophone()
        session.transition(token, to: .processing)
        status = L("正在本机转写…完成后请检查文字再发送。", "Transcribing locally… Review the result before sending.")
        scheduleFinalDeadline(token)
        changed()
    }

    func cancelCapture(reason: String = L("语音输入已取消。", "Voice input cancelled.")) {
        session.invalidate()
        cleanupRecognition()
        status = reason; changed()
    }

    // Explicit sample diagnostic. It never opens a microphone or requests microphone permission.
    func transcribeFileForQA(_ url: URL) {
        guard canRecord else { return }
        stopSpeaking()
        guard hasUsageDescriptions(microphone: false) else { return }
        guard url.isFileURL else { status = L("测试只接受本地音频文件。", "Tests accept local audio files only."); changed(); return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            requestPermissions(microphone: false); return
        }
        guard let local = localRecognizer() else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            guard seconds.isFinite, seconds > 0, seconds <= VoicePolicy.recordingLimit else {
                status = L("测试音频需为 0–30 秒。", "Test audio must be 0–30 seconds long."); changed(); return
            }
        } catch { status = L("测试音频无法读取。", "Cannot read the test audio."); changed(); return }
        let token = session.begin(.processing)
        let fileRequest = SFSpeechURLRecognitionRequest(url: url)
        configure(fileRequest)
        recognizer = local; request = fileRequest
        status = L("正在本机转写测试音频；麦克风未开启。", "Transcribing a local test file. The microphone is off.")
        recognition = local.recognitionTask(with: fileRequest) { [weak self] result, error in
            DispatchQueue.main.async { self?.recognitionResult(result, error: error, token: token) }
        }
        scheduleFinalDeadline(token); changed()
    }

    private func hasUsageDescriptions(microphone: Bool) -> Bool {
        let keys = microphone ? ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] : ["NSSpeechRecognitionUsageDescription"]
        guard keys.allSatisfy({ !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            status = L("当前应用缺少语音权限说明，未开启录音。请使用完整安装包。", "This app is missing voice permission descriptions. Use the complete app package."); changed(); return false
        }
        return true
    }

    private func requestPermissions(microphone: Bool) {
        let token = session.begin(.permission)
        status = L("请确认系统权限；授权后需再次按住说话。", "Please confirm system permissions, then hold to talk again."); changed()
        if microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self = self, self.enabled, self.session.accepts(token, [.permission]) else { return }
                        if granted { self.requestSpeechPermission(token) }
                        else { self.permissionResult(token, message: L("未获麦克风权限。可在系统设置的隐私与安全性中开启，或继续打字。", "Microphone permission was not granted. Enable it in System Settings → Privacy & Security, or continue typing.")) }
                    }
                }
                return
            default:
                permissionResult(token, message: L("麦克风权限未开启。请在系统设置的隐私与安全性中检查，或继续打字。", "Microphone permission is off. Check System Settings → Privacy & Security, or continue typing."))
                return
            }
        }
        requestSpeechPermission(token)
    }

    private func requestSpeechPermission(_ token: UInt64) {
        guard enabled, session.accepts(token, [.permission]) else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: permissionResult(token, message: L("权限已就绪。请再次按住说话。", "Permissions are ready. Hold to talk again."))
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard let self = self, self.enabled, self.session.accepts(token, [.permission]) else { return }
                    self.permissionResult(token, message: authorization == .authorized ? L("权限已就绪。请再次按住说话。", "Permissions are ready. Hold to talk again.") : L("未获语音识别权限。请在系统设置的隐私与安全性中检查，或继续打字。", "Speech recognition permission was not granted. Check System Settings → Privacy & Security, or continue typing."))
                }
            }
        default: permissionResult(token, message: L("语音识别权限未开启。请在系统设置的隐私与安全性中检查，或继续打字。", "Speech recognition permission is off. Check System Settings → Privacy & Security, or continue typing."))
        }
    }

    private func permissionResult(_ token: UInt64, message: String) {
        guard session.accepts(token, [.permission]) else { return }
        session.invalidate(); status = message; changed()
    }

    private func localRecognizer() -> SFSpeechRecognizer? {
        guard let value = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              VoicePolicy.acceptsLocalRecognizer(available: value.isAvailable, onDevice: value.supportsOnDeviceRecognition) else {
            status = L("这台 Mac 当前无法使用本地中文识别。不会切换到联网识别，请继续打字。", "Offline Chinese recognition is unavailable on this Mac. No cloud fallback will be used; continue typing."); changed(); return nil
        }
        return value
    }

    private func configure(_ request: SFSpeechRecognitionRequest) {
        // Only reached after supportsOnDeviceRecognition is positively checked.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.contextualStrings = [L("小团", "Mochi"), L("小团", "Mochi")]
    }

    private func recognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?, token: UInt64) {
        guard enabled, session.accepts(token, [.recording, .processing]) else { return }
        if let result = result, result.isFinal {
            let text = VoicePolicy.finalizedText(result.bestTranscription.formattedString, isFinal: true)
            session.invalidate(); cleanupRecognition()
            status = text == nil ? L("没有识别到有效文字，请重试或打字。", "No usable speech was recognized. Try again or type instead.") : L("转写已填入输入框，请检查后发送。", "The transcript is in the input box. Review it before sending.")
            changed()
            if let text = text { onTranscript?(text) }
        } else if let error = error {
            let ns = error as NSError
            failCapture(token, message: L("本地中文转写未完成（\(ns.domain) \(ns.code)）。可能缺少系统语音资源；不会使用联网识别，可继续打字。", "Offline Chinese transcription did not finish (\(ns.domain) \(ns.code)). System speech resources may be missing. No cloud fallback; continue typing."))
        }
    }

    private func scheduleFinalDeadline(_ token: UInt64) {
        finalDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, self.session.accepts(token, [.processing]) else { return }
            self.failCapture(token, message: L("本地转写等待超时，已停止。请重试或继续打字。", "Local transcription timed out and stopped. Try again or continue typing."))
        }
        finalDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.finalResultLimit, execute: deadline)
    }

    private func failCapture(_ token: UInt64, message: String) {
        guard session.accepts(token, [.recording, .processing]) else { return }
        session.invalidate(); cleanupRecognition(); status = message; changed()
    }

    private func stopMicrophone() {
        captureDeadline?.cancel(); captureDeadline = nil
        if let observer = engineObserver { NotificationCenter.default.removeObserver(observer); engineObserver = nil }
        engine?.stop()
        if tapInstalled { inputNode?.removeTap(onBus: 0); tapInstalled = false }
        sink?.end(); sink = nil
        engine?.reset(); engine = nil; inputNode = nil
    }

    private func cleanupRecognition() {
        stopMicrophone()
        finalDeadline?.cancel(); finalDeadline = nil
        recognition?.cancel(); recognition = nil; request = nil; recognizer = nil
    }

    func speak(_ text: String) {
        guard enabled, session.phase == .idle else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        stopSpeaking()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let language = VoicePolicy.preferredChineseLanguage(voices.map { $0.language }),
              let voice = voices.filter({ $0.language == language }).sorted(by: { $0.quality.rawValue < $1.quality.rawValue }).first else {
            status = L("系统没有可用的中文朗读声音，仍会显示文字；本应用不会自动下载声音。", "No Chinese system voice is available. Text will still be shown; this app does not download voices automatically."); changed(); return
        }
        let synth = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = synth; synth.delegate = self
        let line = AVSpeechUtterance(string: String(value.prefix(500)))
        line.voice = voice; line.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance = line; isSpeaking = true
        status = L("正在用系统中文声音朗读…", "Reading with the system Chinese voice…")
        synth.speak(line)
        let deadline = DispatchWorkItem { [weak self, weak line] in
            guard let self = self, let line = line, self.utterance === line else { return }
            self.stopSpeaking(); self.status = L("朗读已到时停止。", "Reading stopped at the time limit."); self.changed()
        }
        speechDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: deadline)
        changed()
    }

    func stopSpeaking() {
        let wasSpeaking = isSpeaking
        speechDeadline?.cancel(); speechDeadline = nil
        utterance = nil; isSpeaking = false
        // Clearing identity before stopping rejects delayed didCancel callbacks.
        let previous = synthesizer; synthesizer = nil
        previous?.delegate = nil; previous?.stopSpeaking(at: .immediate)
        if wasSpeaking { status = L("朗读已停止。", "Reading stopped."); changed(); onSpeechFinished?() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speechEnded(utterance) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.speechEnded(utterance) }
    }
    private func speechEnded(_ line: AVSpeechUtterance) {
        guard utterance === line else { return }
        speechDeadline?.cancel(); speechDeadline = nil
        utterance = nil; isSpeaking = false
        synthesizer?.delegate = nil; synthesizer = nil
        status = enabled ? L("朗读结束。可继续打字或按住说话。", "Reading finished. You can type or hold to talk again.") : L("语音功能已关闭。", "Voice is off.")
        changed(); onSpeechFinished?()
    }

    func shutdown(reason: String) {
        session.invalidate(); cleanupRecognition(); stopSpeaking()
        status = reason; changed()
    }

    deinit {
        captureDeadline?.cancel(); finalDeadline?.cancel(); speechDeadline?.cancel()
        if let observer = engineObserver { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
        if tapInstalled { inputNode?.removeTap(onBus: 0) }
        sink?.end(); recognition?.cancel()
        synthesizer?.delegate = nil; synthesizer?.stopSpeaking(at: .immediate)
    }
}
