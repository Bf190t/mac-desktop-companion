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
    static let recordingLimit: TimeInterval = 60
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
    /// The Mac's own English variant first (en-AU, en-GB…), then US English.
    static func preferredEnglishLanguage(_ languages: [String], region: String? = Locale.current.region?.identifier) -> String? {
        if let region = region, languages.contains("en-\(region)") { return "en-\(region)" }
        if languages.contains("en-US") { return "en-US" }
        return languages.sorted().first { $0.lowercased().hasPrefix("en-") }
    }
    /// Highest-quality installed voice in the interface language (premium > enhanced > default).
    /// Shared by reply reading and the hourly chime so both pick the same voice.
    static func bestVoice(_ voices: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()) -> AVSpeechSynthesisVoice? {
        let languages = voices.map { $0.language }
        let wanted = Language.current == .english ? preferredEnglishLanguage(languages) : preferredChineseLanguage(languages)
        guard let language = wanted else { return nil }
        return voices.filter { $0.language == language }.max { $0.quality.rawValue < $1.quality.rawValue }
    }
    /// Speech recognition follows the interface language.
    static var recognitionLocale: Locale {
        guard Language.current == .english else { return Locale(identifier: "zh-CN") }
        let region = Locale.current.region?.identifier ?? "US"
        return Locale(identifier: ["US", "GB", "AU", "CA", "NZ", "IE", "IN", "SG"].contains(region) ? "en-\(region)" : "en-US")
    }
    /// Input-device changes (for example AirPods switching to their microphone profile)
    /// restart the engine a few times before the capture is closed with what was heard.
    static let configurationRestartLimit = 3
    /// What is read aloud (B5): action notes in brackets, *actions*, emoji, kaomoji marks and
    /// tildes are dropped so the voice does not say "星号" or "波浪号". The bubble keeps the text.
    static func speakableText(_ text: String) -> String {
        // "3~5个" is a range: say 到 before the tilde is dropped below ("35个" changed the meaning).
        var value = text.replacingOccurrences(of: #"(?<=\d)\s*[~～〜]\s*(?=\d)"#, with: Language.current == .english ? " to " : "到", options: .regularExpression)
        for pattern in [#"（[^）]{0,30}）"#, #"\([^)]{0,30}\)"#, #"【[^】]{0,30}】"#, #"\[[^\]]{0,30}\]"#, #"\*[^*]{0,30}\*"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        value = String(String.UnicodeScalarView(value.unicodeScalars.filter { s in
            let v = s.value
            if v >= 0x1F000 || (0x2600...0x27BF).contains(v) || (0x2B00...0x2BFF).contains(v) { return false } // emoji, symbols
            if v == 0xFE0F || v == 0x200D || v == 0x20E3 { return false }                                     // emoji joiners
            return !"～~*＊^＾♪♡☆★→←".unicodeScalars.contains(s)
        }))
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The new transcriber puts spaces around numbers and punctuation ("我 8:30要", "几 ？").
    /// Spaces next to Chinese characters or full-width punctuation are dropped; spaces between
    /// Latin words ("AirPods Pro") stay.
    static func tidyTranscript(_ text: String) -> String {
        let cjk = #"[\x{3000}-\x{303F}\x{4E00}-\x{9FFF}\x{FF00}-\x{FFEF}]"#
        var value = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?<=" + cjk + ") +", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: " +(?=" + cjk + ")", with: "", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Turns a recognition error into something the user can act on. Known codes get a specific
    /// hint; anything else keeps the system's own description so it can still be diagnosed.
    static func recognitionFailureMessage(domain: String, code: Int, description: String) -> String {
        switch (domain, code) {
        case ("kLSRErrorDomain", 201):
            // "Siri and Dictation are disabled": on-device recognition needs Dictation switched on.
            return L("系统的「听写」没有打开，本机中文识别用不了。请到「系统设置 › 键盘 › 听写」打开听写（语言选普通话），再点一次录音。不会改用联网识别，可以先打字。", "Dictation is turned off, so on-device recognition is unavailable. Turn on Dictation in System Settings › Keyboard › Dictation, then click record again. The app never falls back to online recognition; you can type meanwhile.")
        case ("kAFAssistantErrorDomain", 1110):
            return L("没有听到说话，请靠近麦克风再试一次，或者直接打字。", "No speech was heard. Move closer to the microphone and try again, or type instead.")
        default:
            let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
            return L("本机识别出错（\(domain) \(code)\(detail.isEmpty ? "" : "：" + detail)）。不会改用联网识别，可以先打字。",
                     "On-device recognition error (\(domain) \(code)\(detail.isEmpty ? "" : ": " + detail)). The app never falls back to online recognition; you can type meanwhile.")
        }
    }
}

/// Joins partial results into one transcript. On-device recognition can restart its
/// transcription after a pause, so a later result may no longer contain the first
/// sentence; earlier segments are kept instead of being dropped.
struct VoiceTranscript {
    private(set) var committed = ""
    private(set) var current = ""
    var text: String { Self.join(committed, current) }

    mutating func update(_ raw: String, segmentEnded: Bool) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let bareCommitted = Self.bare(committed)
        if !committed.isEmpty, Self.bare(value).hasPrefix(bareCommitted) {
            // Cumulative transcript (punctuation may have been revised): keep only the new tail.
            current = Self.tail(of: value, afterBare: bareCommitted.count)
        } else {
            if Self.restarted(from: current, to: value) {
                committed = Self.join(committed, current) // recognizer restarted after a pause
            }
            current = value
        }
        if segmentEnded { committed = text; current = "" }
    }

    /// A restart shows up as a much shorter result. Partials normally grow, so a drop to half
    /// (or a result sharing nothing with the old one) means a new segment began, even when it
    /// happens to open with the same word ("我觉得…" / "我…").
    static func restarted(from old: String, to new: String) -> Bool {
        guard old.count >= 3, new.count < old.count else { return false }
        return commonPrefix(new, old) == 0 || (old.count >= 4 && new.count * 2 <= old.count)
    }
    static func isPunctuationOrSpace(_ c: Character) -> Bool {
        c.isWhitespace || "。！？!?，,；;、…：:.\"“”'‘’".contains(c)
    }
    static func bare(_ s: String) -> String { String(s.filter { !isPunctuationOrSpace($0) }) }
    /// The part of `value` after its first `count` non-punctuation characters, without leading punctuation.
    static func tail(of value: String, afterBare count: Int) -> String {
        var seen = 0, index = value.startIndex
        while index < value.endIndex, seen < count {
            if !isPunctuationOrSpace(value[index]) { seen += 1 }
            index = value.index(after: index)
        }
        return String(value[index...].drop(while: isPunctuationOrSpace))
    }
    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }
    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let marks = "。！？!?，,；;、….:："
        let ends = marks.contains(a.last!) || marks.contains(b.first!)
        let latin = a.last!.isASCII && b.first!.isASCII
        return a + (ends ? (latin ? " " : "") : (latin ? ", " : "，")) + b
    }
}

// AVAudioEngine invokes the tap on an audio thread. Serialize append/endAudio
// independently of UI state and never retain the service from the tap.
// The sink feeds either the old recognizer's request or the macOS 26 transcriber.
private final class VoiceAudioSink {
    private let lock = NSLock()
    private var accepting = true
    private let deliver: (AVAudioPCMBuffer) -> Void
    private let close: () -> Void
    /// Format of the first captured buffers. After an input-device change the new
    /// device's buffers are converted back to it, so one request sees one format.
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    init(format: AVAudioFormat, deliver: @escaping (AVAudioPCMBuffer) -> Void, close: @escaping () -> Void) {
        self.format = format; self.deliver = deliver; self.close = close
    }
    convenience init(_ request: SFSpeechAudioBufferRecognitionRequest, format: AVAudioFormat) {
        self.init(format: format, deliver: { request.append($0) }, close: { request.endAudio() })
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        if buffer.format == format { deliver(buffer); return }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter = converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if error == nil, output.frameLength > 0 { deliver(output) }
    }
    func end() {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        accepting = false; close()
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
            else { refreshModernReadiness(); status = L("点一下开始录音，再点一下停止并转写；确认文字后再发送。", "Click to start recording, click again to stop and transcribe; check the text before sending."); changed() }
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
    /// macOS 26+: SpeechAnalyzer/SpeechTranscriber (C2). It needs only the microphone permission,
    /// not Siri/Dictation, so it is preferred whenever its Chinese model is installed.
    private(set) var modernReadiness: ModernSpeechReadiness = .unknown
    /// The running ModernTranscriber (typed AnyObject because it only exists on macOS 26+).
    private var modern: AnyObject?
    private var modernTask: Task<Void, Never>?
    /// Created once and reused while voice stays enabled, so a press does not pay for
    /// recognizer construction again. Dropped when voice is turned off.
    private var warmRecognizer: SFSpeechRecognizer?
    private var transcript = VoiceTranscript()
    private var configurationRestarts = 0
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
    /// C4: replies are read with Qwen3-TTS (NeuralSpeech.swift) unless the system voice is chosen,
    /// the model is not installed, memory is short, or the helper fails before the first sound.
    let neural = NeuralSpeechEngine()
    var readVoice: ReadVoice = .defaultValue {
        didSet { if !readVoice.isNeural { stopNeuralReading(); neural.shutdown() }; changed() }
    }
    /// Under memory pressure the helper is unloaded and replies use the system voice.
    var memoryPressure = false {
        didSet { if memoryPressure && !oldValue { stopNeuralReading(); neural.shutdown() } }
    }
    /// Unloading the helper ends its reply without a callback, so the reply state is ended here
    /// first (otherwise isSpeaking stayed true until the deadline). A system-voice reply keeps going.
    private func stopNeuralReading() { if isSpeaking && utterance == nil { stopSpeaking() } }
    private var neuralToken = 0
    private var neuralHeard = false

    override init() {
        super.init()
        neural.onChange = { [weak self] in self?.changed() }
        refreshModernReadiness()
    }

    /// Loads the read-aloud model ahead of a reply (typing, a mic click, ticking 朗读回复).
    func prepareReadVoice() {
        guard enabled, readVoice.isNeural, !memoryPressure else { return }
        neural.prepare()
    }
    /// One line for the settings window about the reply voice.
    var readVoiceStatus: String {
        guard readVoice.isNeural else { return L("朗读声音：系统声音", "Reading voice: system voice") }
        if memoryPressure { return L("朗读声音：\(readVoice.shortName) · 内存紧张，暂时用系统声音", "Reading voice: \(readVoice.shortName) · memory is tight, using the system voice for now") }
        if !neural.isRunning && !neural.isInstalled { return L("朗读声音：", "Reading voice: ") + NeuralSpeechInstall.installHint }
        let timing = neural.lastTiming.isEmpty ? "" : L(" · 上一句", " · last reply: ") + neural.lastTiming
        return L("朗读声音：\(readVoice.shortName) · \(neural.description)", "Reading voice: \(readVoice.shortName) · \(neural.description)") + timing
    }

    /// The interface language changed: recognition follows it, so the cached recognizer is dropped
    /// and the system model for the new language is looked up again.
    func languageChanged() {
        guard session.phase == .idle else { return }
        warmRecognizer = nil; modernReadiness = .unknown
        refreshModernReadiness(); changed()
    }

    /// Reads whether the new engine's model for the current language is installed. No permission prompt, no download.
    func refreshModernReadiness() {
        guard #available(macOS 26.0, *) else { modernReadiness = .unavailable; return }
        Task { [weak self] in
            let value = await ModernTranscriber.readiness()
            DispatchQueue.main.async { if self?.modernReadiness != .downloading { self?.modernReadiness = value } }
        }
    }
    /// The engine this capture uses. Unknown (the check has not answered yet) counts as modern on
    /// macOS 26+, since it is installed on most of them; a failure then explains itself.
    var usesModernEngine: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return modernReadiness == .ready || modernReadiness == .unknown
    }

    private func changed() { onChange?() }
    /// Results and failures stay visible for a few seconds, also at the small foot input.
    private(set) var noticeUntil: TimeInterval = 0
    var hasRecentNotice: Bool { ProcessInfo.processInfo.systemUptime < noticeUntil }
    func showNotice(_ message: String) { status = message; noticeUntil = ProcessInfo.processInfo.systemUptime + 8; changed() }

    func beginCapture() {
        guard canRecord else { return }
        stopSpeaking()
        if modernReadiness == .downloading { showNotice(L("正在下载系统自带的中文识别模型（只需一次），下载完再点一下录音。", "Downloading the system speech-recognition model (one time only). Click record again when it finishes.")); return }
        if modernReadiness == .needsDownload { downloadModernModel(); return }
        let modernEngine = usesModernEngine
        guard hasUsageDescriptions(microphone: true) else { return }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        guard mic == .authorized, modernEngine || speech == .authorized else {
            requestPermissions(microphone: true, speech: !modernEngine); return
        }
        let local: SFSpeechRecognizer?
        if modernEngine { local = nil } else {
            guard let value = localRecognizer() else { return }
            local = value
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            showNotice(L("未找到可用麦克风。仍可打字聊天。", "No microphone found. You can still type.")); return
        }
        let token = session.begin(.recording)
        transcript = VoiceTranscript(); configurationRestarts = 0
        let audioEngine = AVAudioEngine()
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            failCapture(token, message: L("麦克风当前不可用。请检查输入设备，仍可打字聊天。", "The microphone is unavailable. Check the input device; you can still type."))
            return
        }
        let audioSink: VoiceAudioSink
        var audioRequest: SFSpeechAudioBufferRecognitionRequest?
        if #available(macOS 26.0, *), modernEngine {
            // The transcriber accepts audio at once and sets itself up meanwhile, so nothing is lost.
            let transcriber = ModernTranscriber()
            modern = transcriber
            audioSink = VoiceAudioSink(format: format, deliver: { transcriber.append($0) }, close: { transcriber.endAudio() })
        } else {
            let value = SFSpeechAudioBufferRecognitionRequest()
            configure(value)
            audioRequest = value; recognizer = local; request = value
            audioSink = VoiceAudioSink(value, format: format)
        }
        sink = audioSink
        engine = audioEngine; inputNode = node
        // Start the microphone before creating the recognition task: audio is queued
        // in the request, so words spoken while the recognizer loads are kept.
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in audioSink.append(buffer) }
        tapInstalled = true
        do {
            audioEngine.prepare(); try audioEngine.start()
            if let local, let audioRequest {
                recognition = local.recognitionTask(with: audioRequest) { [weak self] result, error in
                    DispatchQueue.main.async { self?.recognitionResult(result, error: error, token: token) }
                }
            }
            engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
                guard let self = self, self.session.accepts(token, [.recording]) else { return }
                self.resumeAfterConfigurationChange(token)
            }
            status = L("正在录音…再点一下停止并转写，最长 60 秒。", "Recording… Click again to stop and transcribe (up to 60 seconds).")
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, self.session.accepts(token, [.recording]) else { return }
                self.finishCapture()
                if self.session.accepts(token, [.processing]) {
                    self.status = L("已达到 60 秒上限，正在本机转写…", "Reached the 60-second limit; transcribing on this Mac…"); self.changed()
                }
            }
            captureDeadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.recordingLimit, execute: deadline)
            changed()
        } catch {
            failCapture(token, message: L("无法启动麦克风。请检查输入设备和权限，仍可打字聊天。", "Could not start the microphone. Check the input device and permission; you can still type."))
        }
    }

    func finishCapture() {
        if isRequestingPermission {
            // Mouse-up while a system dialog is open cannot start capture later.
            cancelCapture(reason: L("授权结束后请再点一下开始录音。", "When you have answered the permission prompt, click record again."))
            return
        }
        guard isRecording else { return }
        let token = session.generation
        stopMicrophone()
        session.transition(token, to: .processing)
        status = L("正在本机转写…完成后请检查文字再发送。", "Transcribing on this Mac… Check the text before sending.")
        scheduleFinalDeadline(token)
        if #available(macOS 26.0, *), let transcriber = modern as? ModernTranscriber {
            modernTask = Task { [weak self] in
                let outcome: Result<String, Error>
                do { outcome = .success(try await transcriber.finish()) } catch { outcome = .failure(error) }
                DispatchQueue.main.async { self?.modernResult(outcome, token: token) }
            }
        }
        changed()
    }

    private func modernResult(_ outcome: Result<String, Error>, token: UInt64) {
        guard enabled, session.accepts(token, [.processing]) else { return }
        switch outcome {
        case .success(let text):
            transcript = VoiceTranscript()
            transcript.update(text, segmentEnded: true)
            deliverTranscript()
        case .failure(let error):
            if error is CancellationError { return }
            let ns = error as NSError
            failCapture(token, message: VoicePolicy.recognitionFailureMessage(domain: ns.domain, code: ns.code, description: ns.localizedDescription))
        }
    }

    /// One-time system download of the new engine's Chinese model, started by the user's click.
    private func downloadModernModel() {
        guard #available(macOS 26.0, *) else { return }
        modernReadiness = .downloading
        showNotice(L("第一次使用新的本机识别：正在下载系统自带的中文识别模型（只需一次），下载完再点一下录音。", "First use of on-device recognition: downloading the system model (one time only). Click record again when it finishes."))
        Task { [weak self] in
            let value = await ModernTranscriber.install()
            DispatchQueue.main.async {
                guard let self else { return }
                self.modernReadiness = value
                self.showNotice(value == .ready ? L("中文识别模型已下载好，点一下麦克风开始录音。", "The recognition model is ready. Click the microphone to start recording.") : L("中文识别模型没有下载成功，先改用系统听写识别；也可以继续打字。", "The recognition model did not download, so system Dictation recognition is used instead. You can also keep typing."))
            }
        }
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
        guard url.isFileURL else { status = L("测试只接受本地音频文件。", "The test accepts local audio files only."); changed(); return }
        let modernEngine = usesModernEngine
        if !modernEngine {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                requestPermissions(microphone: false, speech: true); return
            }
        }
        let local = modernEngine ? nil : localRecognizer()
        guard modernEngine || local != nil else { return }
        do {
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            guard seconds.isFinite, seconds > 0, seconds <= VoicePolicy.recordingLimit else {
                status = L("测试音频需为 0–60 秒。", "The test audio must be 0–60 seconds long."); changed(); return
            }
        } catch { status = L("测试音频无法读取。", "The test audio could not be read."); changed(); return }
        let token = session.begin(.processing)
        transcript = VoiceTranscript()
        if #available(macOS 26.0, *), modernEngine {
            status = L("正在本机转写测试音频；麦克风未开启。", "Transcribing the test audio on this Mac; the microphone is off.")
            modernTask = Task { [weak self] in
                let outcome: Result<String, Error>
                do { outcome = .success(try await ModernTranscriber.transcribe(file: url)) } catch { outcome = .failure(error) }
                DispatchQueue.main.async { self?.modernResult(outcome, token: token) }
            }
            scheduleFinalDeadline(token); changed()
            return
        }
        guard let local else { return }
        let fileRequest = SFSpeechURLRecognitionRequest(url: url)
        configure(fileRequest)
        recognizer = local; request = fileRequest
        status = L("正在本机转写测试音频；麦克风未开启。", "Transcribing the test audio on this Mac; the microphone is off.")
        recognition = local.recognitionTask(with: fileRequest) { [weak self] result, error in
            DispatchQueue.main.async { self?.recognitionResult(result, error: error, token: token) }
        }
        scheduleFinalDeadline(token); changed()
    }

    private func hasUsageDescriptions(microphone: Bool) -> Bool {
        let keys = microphone ? ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] : ["NSSpeechRecognitionUsageDescription"]
        guard keys.allSatisfy({ !(Bundle.main.object(forInfoDictionaryKey: $0) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            showNotice(L("当前应用缺少语音权限说明，未开启录音。请使用完整安装包。", "This build lacks the voice permission descriptions, so recording is off. Please use the full release.")); return false
        }
        return true
    }

    private func requestPermissions(microphone: Bool, speech: Bool) {
        let token = session.begin(.permission)
        status = L("请确认系统权限；授权后再点一下开始录音。", "Please answer the permission prompt, then click record again."); changed()
        if microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self = self, self.enabled, self.session.accepts(token, [.permission]) else { return }
                        if granted, speech { self.requestSpeechPermission(token) }
                        else if granted { self.permissionResult(token, message: L("麦克风权限已就绪。请再点一下开始录音。", "Microphone access is ready. Click record again.")) }
                        else { self.permissionResult(token, message: L("未获麦克风权限。可在系统设置的隐私与安全性中开启，或继续打字。", "Microphone access was not granted. You can allow it in System Settings › Privacy & Security, or keep typing.")) }
                    }
                }
                return
            default:
                permissionResult(token, message: L("麦克风权限未开启。请在系统设置的隐私与安全性中检查，或继续打字。", "Microphone access is off. Check System Settings › Privacy & Security, or keep typing."))
                return
            }
        }
        if speech { requestSpeechPermission(token) }
        else { permissionResult(token, message: L("麦克风权限已就绪。请再点一下开始录音。", "Microphone access is ready. Click record again.")) }
    }

    private func requestSpeechPermission(_ token: UInt64) {
        guard enabled, session.accepts(token, [.permission]) else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: permissionResult(token, message: L("权限已就绪。请再点一下开始录音，或点击示例转写。", "Permissions are ready. Click record again, or try the sample."))
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
                DispatchQueue.main.async {
                    guard let self = self, self.enabled, self.session.accepts(token, [.permission]) else { return }
                    self.permissionResult(token, message: authorization == .authorized ? L("权限已就绪。请再点一下开始录音，或点击示例转写。", "Permissions are ready. Click record again, or try the sample.") : L("未获语音识别权限。请在系统设置的隐私与安全性中检查，或继续打字。", "Speech recognition access was not granted. Check System Settings › Privacy & Security, or keep typing."))
                }
            }
        default: permissionResult(token, message: L("语音识别权限未开启。请在系统设置的隐私与安全性中检查，或继续打字。", "Speech recognition access is off. Check System Settings › Privacy & Security, or keep typing."))
        }
    }

    private func permissionResult(_ token: UInt64, message: String) {
        guard session.accepts(token, [.permission]) else { return }
        session.invalidate(); showNotice(message)
    }

    private func localRecognizer() -> SFSpeechRecognizer? {
        guard let value = warmRecognizer ?? SFSpeechRecognizer(locale: VoicePolicy.recognitionLocale),
              VoicePolicy.acceptsLocalRecognizer(available: value.isAvailable, onDevice: value.supportsOnDeviceRecognition) else {
            warmRecognizer = nil
            showNotice(L("这台 Mac 当前无法使用本地中文识别。不会切换到联网识别，请继续打字。", "On-device recognition is not available on this Mac. The app never switches to online recognition; please keep typing.")); return nil
        }
        warmRecognizer = value
        return value
    }

    private func configure(_ request: SFSpeechRecognitionRequest) {
        // Only reached after supportsOnDeviceRecognition is positively checked.
        request.requiresOnDeviceRecognition = true
        // Partial results show live text while holding, keep earlier segments when the
        // recognizer restarts after a pause, and give a fallback if the final result is late.
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.contextualStrings = ["Mochi", "小团"]
    }

    /// Reattaches the tap after the input device or its format changed. The engine stops
    /// itself on such a change; restarting keeps the words already queued in the request.
    private func resumeAfterConfigurationChange(_ token: UInt64) {
        guard session.accepts(token, [.recording]), let audioEngine = engine, let audioSink = sink else { return }
        configurationRestarts += 1
        guard configurationRestarts <= VoicePolicy.configurationRestartLimit else { finishCapture(); return }
        if tapInstalled { inputNode?.removeTap(onBus: 0); tapInstalled = false }
        let node = audioEngine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { finishCapture(); return }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in audioSink.append(buffer) }
        tapInstalled = true; inputNode = node
        do {
            audioEngine.prepare(); try audioEngine.start()
            status = L("输入设备切换了，继续录音…再点一下停止并转写。", "The input device changed; still recording… Click again to stop and transcribe."); changed()
        } catch {
            finishCapture()
        }
    }

    private func recognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?, token: UInt64) {
        guard enabled, session.accepts(token, [.recording, .processing]) else { return }
        if let result = result {
            transcript.update(result.bestTranscription.formattedString, segmentEnded: result.speechRecognitionMetadata != nil && !result.isFinal)
            if result.isFinal { deliverTranscript(); return }
            // Partial results are only collected (so a pause cannot drop earlier sentences);
            // the text is shown once, after the user stops recording.
        } else if let error = error {
            // Keep what was already recognized instead of discarding the whole capture.
            if session.accepts(token, [.processing]), !transcript.text.isEmpty { deliverTranscript(); return }
            let ns = error as NSError
            failCapture(token, message: VoicePolicy.recognitionFailureMessage(domain: ns.domain, code: ns.code, description: ns.localizedDescription))
        }
    }

    private func deliverTranscript() {
        let text = VoicePolicy.finalizedText(transcript.text, isFinal: true)
        session.invalidate(); cleanupRecognition()
        showNotice(text == nil ? L("没有识别到有效文字，请重试或打字。", "No usable text was recognised. Try again or type.") : L("转写已填入输入框，请检查后发送。", "The transcript is in the input box. Check it before sending."))
        if let text = text { onTranscript?(text) }
    }

    private func scheduleFinalDeadline(_ token: UInt64) {
        finalDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, self.session.accepts(token, [.processing]) else { return }
            if !self.transcript.text.isEmpty { self.deliverTranscript(); return }
            self.failCapture(token, message: L("本地转写等待超时，已停止。请重试或继续打字。", "On-device transcription timed out and stopped. Try again or keep typing."))
        }
        finalDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + VoicePolicy.finalResultLimit, execute: deadline)
    }

    private func failCapture(_ token: UInt64, message: String) {
        guard session.accepts(token, [.recording, .processing]) else { return }
        session.invalidate(); cleanupRecognition(); showNotice(message)
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
        modernTask?.cancel(); modernTask = nil
        if #available(macOS 26.0, *), let transcriber = modern as? ModernTranscriber { transcriber.cancel() }
        modern = nil
    }

    func speak(_ text: String) {
        guard enabled, session.phase == .idle else { return }
        let value = VoicePolicy.speakableText(text)
        guard !value.isEmpty else { return }
        stopSpeaking()
        let line = String(value.prefix(500))
        if readVoice.isNeural, !memoryPressure, neural.isInstalled { speakNeural(line); return }
        let note = readVoice.isNeural && !memoryPressure ? L("朗读声音还没装，先用系统声音念。", "The reading voice is not installed yet, so the system voice reads this reply.") : nil
        speakSystem(line, note: note)
    }

    private func speakNeural(_ line: String) {
        neuralToken += 1
        let token = neuralToken, voice = readVoice
        neuralHeard = false; isSpeaking = true
        status = L("\(voice.shortName)的声音准备中…", "Getting \(voice.shortName)'s voice ready…")
        armSpeechDeadline(for: line) { [weak self] in self?.neuralToken == token }
        neural.speak(line, voice: voice, onStart: { [weak self] in
            guard let self = self, self.neuralToken == token, self.isSpeaking else { return }
            self.neuralHeard = true; self.status = L("正在用\(voice.shortName)的声音朗读…", "Reading in \(voice.shortName)'s voice…"); self.changed()
        }, onFinish: { [weak self] outcome in
            guard let self = self, self.neuralToken == token, self.isSpeaking else { return }
            switch outcome {
            case .finished:
                self.finishSpeaking(self.neural.lastTiming.isEmpty ? L("朗读结束。", "Finished reading. ") : L("朗读结束（\(self.neural.lastTiming)）。", "Finished reading (\(self.neural.lastTiming)). "))
            case .failed(let why) where !self.neuralHeard:
                // Nothing was heard yet: the system voice reads this reply, so the pet is never silent.
                self.speakSystem(line, note: L("新声音暂时不可用（\(why)），这次用系统声音。", "The reading voice is unavailable (\(why)), so the system voice reads this reply."))
            case .failed(let why):
                self.finishSpeaking(L("朗读中断（\(why)）。", "Reading interrupted (\(why)). "))
            }
        })
        // Starting the helper can change state, and a UI sync during that may already have stopped
        // this reply; then the job just created must not play untracked.
        if neuralToken != token { neural.stop(); return }
        changed()
    }

    private func speakSystem(_ text: String, note: String?) {
        speechDeadline?.cancel(); speechDeadline = nil
        guard let voice = VoicePolicy.bestVoice() else {
            let wasSpeaking = isSpeaking
            isSpeaking = false
            status = L("系统没有可用的中文朗读声音，仍会显示文字；本应用不会自动下载声音。", "No system voice is available for this language. Replies stay on screen; the app never downloads voices by itself."); changed()
            if wasSpeaking { onSpeechFinished?() }
            return
        }
        let synth = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = synth; synth.delegate = self
        let line = AVSpeechUtterance(string: text)
        line.voice = voice; line.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance = line; isSpeaking = true
        status = note ?? L("正在用系统中文声音朗读…", "Reading with the system voice…")
        synth.speak(line)
        armSpeechDeadline(for: text) { [weak self, weak line] in line != nil && self?.utterance === line }
        changed()
    }

    /// A reply is stopped if it runs far past its length (0.35 s a character, at least 90 seconds).
    private func armSpeechDeadline(for text: String, _ stillCurrent: @escaping () -> Bool) {
        speechDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self = self, stillCurrent() else { return }
            self.stopSpeaking(); self.status = L("朗读已到时停止。", "Reading stopped at the time limit."); self.changed()
        }
        speechDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + max(90, Double(text.count) * 0.35 + 20), execute: deadline)
    }

    private func finishSpeaking(_ message: String) {
        speechDeadline?.cancel(); speechDeadline = nil
        isSpeaking = false
        status = enabled ? message + L("可继续打字或点一下麦克风录音。", "You can type or click the microphone to record.") : L("语音功能已关闭。", "Voice is off.")
        changed(); onSpeechFinished?()
    }

    func stopSpeaking() {
        let wasSpeaking = isSpeaking
        speechDeadline?.cancel(); speechDeadline = nil
        utterance = nil; isSpeaking = false
        neuralToken += 1; neural.stop()
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
        status = enabled ? L("朗读结束。可继续打字或点一下麦克风录音。", "Finished reading. You can type or click the microphone to record.") : L("语音功能已关闭。", "Voice is off.")
        changed(); onSpeechFinished?()
    }

    func shutdown(reason: String) {
        session.invalidate(); cleanupRecognition(); stopSpeaking(); neural.shutdown()
        if !enabled { warmRecognizer = nil }
        status = reason; changed()
    }

    deinit {
        captureDeadline?.cancel(); finalDeadline?.cancel(); speechDeadline?.cancel()
        if let observer = engineObserver { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
        if tapInstalled { inputNode?.removeTap(onBus: 0) }
        sink?.end(); recognition?.cancel(); modernTask?.cancel()
        if #available(macOS 26.0, *), let transcriber = modern as? ModernTranscriber { transcriber.cancel() }
        synthesizer?.delegate = nil; synthesizer?.stopSpeaking(at: .immediate)
        neural.shutdown()
    }
}
