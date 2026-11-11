import Foundation
import AVFoundation

/// Optional reading voice: replies read aloud with Qwen3-TTS 0.6B (Base model, cloning the companion's
/// designed voice by its speaker embedding). The model runs in a helper process (Resources/Voice/
/// tts_worker.py) inside its own runtime under Application Support, installed from the chat window.
/// Audio comes back in ~0.3 s chunks and plays as it arrives. When anything is missing or fails,
/// PetVoiceService reads the reply with the system voice instead, so the companion never goes quiet.

/// The voice used for replies. `.companion` is Mochi's voice: designed once with Qwen3-TTS
/// VoiceDesign (a clear, slightly high young voice with an even tone) and cloned at runtime from
/// Resources/Voice/companion_voice.wav. `.system` is macOS.
enum ReadVoice: String, CaseIterable {
    case companion, system
    static let defaultValue: ReadVoice = .companion
    /// What the Preview button reads.
    static var previewText: String { L("你好，我是小团。今天辛苦了，先喝口水，歇一会儿再说吧。", "Hi, I'm Mochi. You've worked hard today, so have some water and take a little break.") }
    var title: String { self == .companion ? L("小团的声音", "Mochi's voice") : L("系统声音", "System voice") }
    var shortName: String { self == .companion ? L("小团", "Mochi") : L("系统", "System") }
    var isNeural: Bool { self != .system }
}

/// Where the optional reading voice was installed (ModelInstallation.voice), checked on every use
/// so installing while the app runs works without a restart.
struct NeuralSpeechInstall {
    let python: URL, model: URL, worker: URL, deps: URL
    /// Reference audio of the companion's designed voice (cloned by speaker embedding).
    let voice: URL
    static var root: URL { ModelInstallation.voice.root }
    static var installHint: String { L("朗读声音还没装：在「本地聊天 · 模型与语音」里点「安装朗读声音…」，装好后不用重启。", "The reading voice is not installed: click Install reading voice… in Local chat · Model & voice. No restart needed afterwards.") }

    /// Hourly chime in the companion's voice, recorded once per language by the installer
    /// ("现在是9点。" / "It's nine o'clock."); nil when the clip is missing (the system voice is used then).
    static func chimeClip(hour: Int?) -> URL? {
        let name = hour.map { String(format: "chime-%02d.wav", $0) } ?? "chime-test.wav"
        let url = root.appendingPathComponent("voices/chimes/\(Language.current == .english ? "en" : "zh")/\(name)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What the hourly chime says: the same words as the recorded clips (voice/install.py), so the
    /// system voice fallback says exactly the same thing.
    static func chimeText(hour: Int?) -> String {
        guard let hour = hour else { return L("这是报时示例。", "This is a time announcement preview.") }
        guard Language.current == .english else { return "现在是\(hour)点。" }
        if hour == 0 { return "It's midnight." }
        if hour == 12 { return "It's noon." }
        let words = ["midnight", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven"]
        let part = hour < 12 ? "in the morning" : hour < 18 ? "in the afternoon" : "in the evening"
        return "It's \(words[hour % 12]) o'clock \(part)."
    }

    static func load(resources: URL? = Bundle.main.resourceURL) -> NeuralSpeechInstall? {
        let installation = ModelInstallation.voice
        guard !installation.isBusy, installation.isInstalled,
              let worker = resources?.appendingPathComponent("Voice/tts_worker.py"),
              FileManager.default.fileExists(atPath: worker.path) else { return nil }
        let root = installation.root
        return NeuralSpeechInstall(python: installation.python, model: root.appendingPathComponent("model", isDirectory: true),
                                   worker: worker, deps: root.appendingPathComponent("deps", isDirectory: true),
                                   voice: root.appendingPathComponent("voices/companion_voice.wav"))
    }
}

/// Plays 16-bit mono PCM as it streams in. One player per utterance, so a change of output
/// device (AirPods connecting) never leaves a stale engine behind.
final class PCMStreamPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var pending = 0, inputEnded = false, started = false, stopped = false
    private var observer: NSObjectProtocol?
    private(set) var scheduledSeconds = 0.0
    var onDrained: (() -> Void)?
    var onInterrupted: (() -> Void)?

    init?(sampleRate: Double, muted: Bool = false) {
        guard let value = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return nil }
        format = value
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: value)
        if muted { node.volume = 0 }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self = self, !self.stopped else { return }
            self.stop(); self.onInterrupted?()
        }
    }
    deinit { stop() }

    static func samples(_ data: Data) -> [Float] {
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            (0..<count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    /// False when playback could not start (no output device).
    func append(_ data: Data) -> Bool {
        guard !stopped else { return false }
        let values = Self.samples(data)
        guard !values.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count)),
              let channel = buffer.floatChannelData?[0] else { return true }
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: values.count) }
        if !started {
            do { try engine.start() } catch { stop(); return false }
            node.play(); started = true
        }
        pending += 1; scheduledSeconds += Double(values.count) / format.sampleRate
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.played() }
        }
        return true
    }
    func endInput() { inputEnded = true; drainedIfDone() }
    func stop() {
        guard !stopped else { return }
        stopped = true
        if let observer = observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        if started { node.stop(); engine.stop() }
    }
    private func played() { guard !stopped else { return }; pending -= 1; drainedIfDone() }
    private func drainedIfDone() {
        guard inputEnded, pending <= 0, !stopped else { return }
        stop(); onDrained?()
    }
}

/// Runs the helper process and turns one reply into streamed playback. Main-thread confined.
final class NeuralSpeechEngine {
    enum State: Equatable { case notInstalled, idle, loading, ready, failed(String) }
    enum Outcome: Equatable { case finished, failed(String) }

    private(set) var state: State = .idle
    /// The last reply's speed, e.g. "first sound 0.12 s · 3.2× faster than real time".
    private(set) var lastTiming = ""
    var onChange: (() -> Void)?
    /// Unloaded after this long without speaking (memory goes back to LM Studio and the system).
    var idleUnloadSeconds: TimeInterval = 300
    /// For `--tts-check`: plays at zero volume.
    var muted = false

    private final class Job {
        let id: String, text: String, voice: String
        var language = "chinese"
        let onStart: () -> Void, onFinish: (Outcome) -> Void
        var player: PCMStreamPlayer?
        var sent = false, gotAudio = false, requested = Date()
        var deadline: DispatchWorkItem?
        /// Ends the reply if the helper goes quiet after the first sound (no "done" ever comes).
        var stall: DispatchWorkItem?
        init(id: String, text: String, voice: String, onStart: @escaping () -> Void, onFinish: @escaping (Outcome) -> Void) {
            self.id = id; self.text = text; self.voice = voice; self.onStart = onStart; self.onFinish = onFinish
        }
    }
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var sampleRate = 24000.0
    private var counter = 0
    private var job: Job?
    private var idleTimer: DispatchWorkItem?
    private var loadStarted: Date?
    private(set) var lastLoadSeconds: Double?
    /// After the model failed to load, replies use the system voice for a while instead of
    /// waiting for a helper that keeps failing.
    private var loadFailedUntil: Date?
    /// installation.json as it was when loading failed; a new install lifts the wait at once.
    private var failedInstall: Date?
    static let stallSeconds: TimeInterval = 8

    var isInstalled: Bool { NeuralSpeechInstall.load() != nil }
    var isRunning: Bool { process != nil }
    var description: String {
        switch state {
        case .notInstalled: return L("未安装", "not installed")
        case .idle: return L("待命（第一次念时加载，约 2 秒）", "standing by (loads on first use, about 2 s)")
        case .loading: return L("正在加载…", "loading…")
        case .ready: return L("已就绪", "ready")
        case .failed(let why): return L("暂时不可用（\(why)），用系统声音", "unavailable (\(why)); using the system voice")
        }
    }

    /// Starts the helper ahead of a reply (typing, mic click, ticking 朗读回复). No sound, no download.
    func prepare() {
        scheduleIdleUnload()
        guard process == nil else { return }
        if let until = loadFailedUntil, until > Date(), failedInstall == Self.installStamp() { return }
        loadFailedUntil = nil
        guard let install = NeuralSpeechInstall.load() else { setState(.notInstalled); return }
        signal(SIGPIPE, SIG_IGN)   // a write to a helper that just exited must not end the pet
        let p = Process()
        // Like the chat worker: the helper runs with network access denied.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)(allow default)(deny network*)", install.python.path, "-I", "-B", "-u", install.worker.path,
                       "--deps", install.deps.path, "--model-path", install.model.path, "--voice-ref", install.voice.path,
                       "--parent-pid", "\(getpid())"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = Self.logHandle()
        // Weak references only: nothing here keeps the Process or its pipes alive after it is dropped.
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { if let p = p { self?.received(data, from: p) } }
        }
        p.terminationHandler = { [weak self] finished in DispatchQueue.main.async { self?.exited(finished) } }
        do { try p.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            try? stdin.fileHandleForWriting.close(); try? stdout.fileHandleForReading.close()
            backOff(); setState(.failed(L("启动失败", "could not start"))); return
        }
        process = p; input = stdin.fileHandleForWriting; buffer = Data(); loadStarted = Date()
        setState(.loading)
    }

    /// Reads `text`. `onStart` comes with the first sound; `onFinish(.failed)` before any sound
    /// means the caller should use the system voice. `stop()` ends it without a callback.
    func speak(_ text: String, voice: ReadVoice, language: Language = Language.current, firstSoundWithin seconds: TimeInterval = 6,
               onStart: @escaping () -> Void, onFinish: @escaping (Outcome) -> Void) {
        stop()
        guard voice.isNeural else { onFinish(.failed("system")); return }
        prepare()
        guard process != nil else {
            if case .failed(let why) = state { onFinish(.failed(why)) } else { onFinish(.failed(state == .notInstalled ? L("未安装", "not installed") : L("启动失败", "could not start"))) }
            return
        }
        counter += 1
        let next = Job(id: "\(counter)", text: text, voice: voice.rawValue, onStart: onStart, onFinish: onFinish)
        next.language = language == .english ? "english" : "chinese"
        job = next
        idleTimer?.cancel()
        let deadline = DispatchWorkItem { [weak self, weak next] in
            guard let self = self, let next = next, self.job === next, !next.gotAudio else { return }
            let loading = self.state == .loading
            self.end(next, .failed(loading ? L("还在加载", "still loading") : L("没有出声", "no sound")))
            if !loading { self.shutdown() }   // ready but silent: the helper is stuck, start a fresh one next time
        }
        next.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: deadline)
        if state == .ready { send(next) }
    }

    /// Stops the current reply at once (the helper is told to stop generating).
    func stop() {
        guard let current = job else { return }
        job = nil
        current.deadline?.cancel(); current.player?.stop()
        if current.sent { write(["op": "cancel", "id": current.id]) }
        scheduleIdleUnload()
    }

    /// Ends the helper and frees its memory (voice off, system sleep, memory pressure, quit).
    func shutdown() {
        stop()
        idleTimer?.cancel(); idleTimer = nil
        guard let p = process else { return }
        write(["op": "quit"])
        try? input?.close()
        process = nil; input = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p.isRunning { p.terminate() } }
        setState(.idle)
    }

    // MARK: helper events

    private func received(_ data: Data, from source: Process) {
        guard source === process else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { handle(event) }
        }
    }

    private func handle(_ event: [String: Any]) {
        let id = event["id"] as? String
        switch event["event"] as? String {
        case "ready":
            sampleRate = (event["sample_rate"] as? Double) ?? 24000
            lastLoadSeconds = loadStarted.map { Date().timeIntervalSince($0) }
            setState(.ready)
            if let waiting = job, !waiting.sent { send(waiting) }
        case "audio":
            guard let current = job, current.id == id, let text = event["pcm"] as? String, let pcm = Data(base64Encoded: text) else { return }
            if current.player == nil {
                let player = PCMStreamPlayer(sampleRate: sampleRate, muted: muted)
                player?.onDrained = { [weak self, weak current] in if let self = self, let current = current { self.end(current, .finished) } }
                player?.onInterrupted = { [weak self, weak current] in if let self = self, let current = current { self.end(current, .failed(L("输出设备变了", "output device changed"))) } }
                current.player = player
            }
            guard let player = current.player, player.append(pcm) else { end(current, .failed(L("没有可用的扬声器", "no speaker available"))); return }
            armStall(current)
            if !current.gotAudio { current.gotAudio = true; current.deadline?.cancel(); current.onStart() }
        case "done":
            guard let current = job, current.id == id else { return }
            current.stall?.cancel()
            if let audio = event["audio_seconds"] as? Double, let generation = event["generation_seconds"] as? Double, audio > 0 {
                let first = (event["first_audio_seconds"] as? Double).map { String(format: L("第一声 %.2f 秒 · ", "first sound %.2f s · "), $0) } ?? ""
                lastTiming = first + String(format: L("比实时快 %.1f 倍", "%.1f× faster than real time"), audio / max(generation, 0.001))
            }
            if let player = current.player { player.endInput() } else { end(current, current.gotAudio ? .finished : .failed(L("没有可念的字", "nothing to read"))) }
        case "error":
            if let id = id {
                guard let current = job, current.id == id else { return }
                end(current, .failed(event["code"] as? String ?? L("出错", "error")))
            } else {
                let p = process
                process = nil; input = nil
                p?.terminate()
                backOff()
                setState(.failed(L("模型加载失败", "model failed to load")))
                if let current = job { end(current, .failed(L("模型加载失败", "model failed to load"))) }
            }
        default: break   // "loading", "cancelled"
        }
    }

    private func exited(_ finished: Process) {
        guard finished === process else { return }
        if state == .loading { backOff() }   // crashed while loading: do not reload on every keystroke
        process = nil; input = nil
        setState(NeuralSpeechInstall.load() == nil ? .notInstalled : .failed(L("朗读进程退出了", "the voice helper quit")))
        if let current = job { end(current, .failed(L("朗读进程退出了", "the voice helper quit"))) }
    }

    private func end(_ finishedJob: Job, _ outcome: Outcome) {
        guard job === finishedJob else { return }
        job = nil
        finishedJob.deadline?.cancel(); finishedJob.stall?.cancel()
        if case .failed = outcome {
            finishedJob.player?.stop()
            if finishedJob.sent { write(["op": "cancel", "id": finishedJob.id]) }
        }
        scheduleIdleUnload()
        finishedJob.onFinish(outcome)
    }

    private func armStall(_ current: Job) {
        current.stall?.cancel()
        let work = DispatchWorkItem { [weak self, weak current] in
            guard let self = self, let current = current, self.job === current else { return }
            self.end(current, .failed(L("朗读卡住了", "the voice helper stalled")))
            self.shutdown()   // a stuck helper is replaced on the next reply
        }
        current.stall = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallSeconds, execute: work)
    }

    private func backOff() {
        loadFailedUntil = Date().addingTimeInterval(300); failedInstall = Self.installStamp()
    }
    private static func installStamp() -> Date? {
        let path = NeuralSpeechInstall.root.appendingPathComponent("installation.json").path
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func send(_ next: Job) {
        next.sent = true
        write(["op": "speak", "id": next.id, "text": next.text, "voice": next.voice, "language": next.language])
    }

    private func write(_ message: [String: Any]) {
        guard let input = input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? input.write(contentsOf: data + Data([0x0A]))
    }

    private func scheduleIdleUnload() {
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.job == nil, self.process != nil else { return }
            self.shutdown()
        }
        idleTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleUnloadSeconds, execute: work)
    }

    private func setState(_ value: State) {
        guard state != value else { return }
        state = value; onChange?()
    }

    /// The helper's own messages (library warnings, crashes) go to logs/worker.log, replaced each start.
    private static func logHandle() -> Any {
        let logs = NeuralSpeechInstall.root.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("worker.log")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { return FileHandle.nullDevice }
        return handle
    }
}

/// `DesktopCompanion --tts-check [--audible]`: runs the real helper through this file's code (start, read a
/// sentence, stop one mid-way, switch voice, unload) and prints timings. Muted unless --audible.
func neuralSpeechCheck() -> Bool {
    var checks: [String: Any] = [:], ok = true
    func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }
    func record(_ key: String, _ value: Bool) { checks[key] = value; ok = ok && value }
    let engine = NeuralSpeechEngine()
    engine.muted = !CommandLine.arguments.contains("--audible")
    record("installed", engine.isInstalled)
    guard engine.isInstalled else { print(NeuralSpeechInstall.installHint); return false }
    let t0 = Date()
    engine.prepare()
    record("ready", wait(90) { engine.state == .ready })
    checks["ready_seconds"] = (Date().timeIntervalSince(t0) * 100).rounded() / 100
    func read(_ text: String, _ voice: ReadVoice, stopAfterFirstSound: Bool = false) -> (first: Double?, total: Double?, outcome: NeuralSpeechEngine.Outcome?) {
        let start = Date()
        var first: Double?, total: Double?, outcome: NeuralSpeechEngine.Outcome?
        engine.speak(text, voice: voice, language: .chinese, onStart: { first = Date().timeIntervalSince(start) },
                     onFinish: { outcome = $0; total = Date().timeIntervalSince(start) })
        if stopAfterFirstSound {
            _ = wait(10) { first != nil }
            engine.stop()
            _ = wait(1) { false }
        } else {
            _ = wait(60) { outcome != nil }
        }
        return (first, total, outcome)
    }
    let normal = read("你好，我是小团。今天辛苦了，先喝口水，歇一会儿再说吧。", .companion)
    record("read_finished", normal.outcome == .finished)
    record("first_sound_under_1s", (normal.first ?? 9) < 1)
    checks["first_sound_seconds"] = normal.first.map { ($0 * 1000).rounded() / 1000 }
    checks["playback_seconds"] = normal.total.map { ($0 * 100).rounded() / 100 }
    checks["timing"] = engine.lastTiming
    let stopped = read(String(repeating: "这是一段比较长的话，用来测试中途停下。", count: 4), .companion, stopAfterFirstSound: true)
    record("stop_has_no_callback", stopped.first != nil && stopped.outcome == nil)
    let other = read("8:30 到，那就 7:50 出门。明天见。", .companion)
    record("next_reply_after_stop", other.outcome == .finished && (other.first ?? 9) < 1)
    var none: NeuralSpeechEngine.Outcome?
    engine.speak("”……", voice: .companion, language: .chinese, onStart: {}, onFinish: { none = $0 })
    record("punctuation_only_reads_nothing", wait(10) { none != nil } && none != .finished)
    engine.shutdown()
    record("unloaded", !engine.isRunning && engine.state == .idle)
    let text = try! JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
    print(String(data: text, encoding: .utf8)!)
    return ok
}
