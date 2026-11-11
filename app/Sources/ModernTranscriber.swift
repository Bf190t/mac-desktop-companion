import Foundation
import AVFoundation
import Speech

/// macOS 26+ on-device transcription (SpeechAnalyzer + SpeechTranscriber).
/// Unlike SFSpeechRecognizer it does not need Siri/Dictation switched on (that was error 201), it kept
/// every word in tests where the old recognizer dropped some, and it finishes in well under a second.
/// Microphone buffers are fed from the audio thread; the analyzer runs in its own task.
enum ModernSpeechReadiness { case unknown, ready, needsDownload, downloading, unavailable }

// SpeechAnalyzer exists only in the macOS 26 SDK (Swift 6.2 toolchains). Building with an older SDK
// (the 15.4 SDK on the MacBook Air) gets the stub at the end, so the app still uses the old recognizer.
#if compiler(>=6.2)
@available(macOS 26.0, *)
final class ModernTranscriber: @unchecked Sendable {
    /// Follows the interface language (zh-CN, or the Mac's English variant).
    static var locale: Locale { VoicePolicy.recognitionLocale }
    private static func makeModule() -> SpeechTranscriber { SpeechTranscriber(locale: locale, preset: .transcription) }

    /// Whether the system model for the current language is installed, can be downloaded, or is not offered here.
    static func readiness() async -> ModernSpeechReadiness {
        guard SpeechTranscriber.isAvailable, await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil else { return .unavailable }
        // The installed list is the reliable answer: status(forModules:) reported "supported" for
        // zh_CN on a Mac where the same model was installed (and "installed" for zh-Hans-CN).
        if await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return .ready }
        switch await AssetInventory.status(forModules: [makeModule()]) {
        case .installed: return .ready
        case .supported, .downloading: return .needsDownload
        default: return .unavailable
        }
    }
    /// Downloads the system model for the current language (one time, started by the user's click).
    static func install() async -> ModernSpeechReadiness {
        do {
            // nil means there is nothing to download.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) { try await request.downloadAndInstall() }
            else { return .ready }
        } catch { return .unavailable }
        return await readiness()
    }

    private let lock = NSLock()
    private var raw: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var task: Task<String, Error>?

    /// Starts accepting audio immediately; the analyzer is set up in the background and catches up,
    /// so nothing said in the first moments is lost.
    init() {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        raw = continuation
        task = Task { try await Self.run(stream) }
    }

    /// Called from the audio tap thread. The buffer is copied because the engine reuses it.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let target = raw; lock.unlock()
        guard let target, let copy = Self.copy(buffer) else { return }
        target.yield(copy)
    }

    /// No more audio; the transcript is still being finished.
    func endAudio() {
        lock.lock(); let target = raw; raw = nil; lock.unlock()
        target?.finish()
    }

    /// Ends the audio and returns the full transcript.
    func finish() async throws -> String {
        endAudio()
        return try await task?.value ?? ""
    }

    func cancel() { endAudio(); task?.cancel() }

    /// Whole-file transcription (used by the "试转写示例" button).
    static func transcribe(file url: URL) async throws -> String {
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        async let text = collect(module)
        let audio = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: audio) { try await analyzer.finalizeAndFinish(through: last) }
        else { await analyzer.cancelAndFinishNow() }
        return try await text
    }

    private static func run(_ stream: AsyncStream<AVAudioPCMBuffer>) async throws -> String {
        let module = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        async let text = collect(module)
        try await analyzer.start(inputSequence: input)
        var converter: AVAudioConverter?
        for await buffer in stream {
            try Task.checkCancellation()
            guard let format, buffer.format != format else { feed.yield(AnalyzerInput(buffer: buffer)); continue }
            if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
            if let converter, let converted = convert(buffer, with: converter, to: format) { feed.yield(AnalyzerInput(buffer: converted)) }
        }
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await text
    }

    /// Final results joined into one line, with the spaces the transcriber puts around punctuation removed.
    private static func collect(_ module: SpeechTranscriber) async throws -> String {
        var transcript = ""
        for try await result in module.results where result.isFinal {
            transcript = VoiceTranscript.join(transcript, VoicePolicy.tidyTranscript(String(result.text.characters)))
        }
        return transcript
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = out.floatChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
        } else if let src = buffer.int16ChannelData, let dst = out.int16ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
        } else if let src = buffer.int32ChannelData, let dst = out.int32ChannelData {
            for c in 0..<channels { dst[c].update(from: src[c], count: frames) }
        } else { return nil }
        return out
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false, error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
#else
@available(macOS 26.0, *)
final class ModernTranscriber {
    static func readiness() async -> ModernSpeechReadiness { .unavailable }
    static func install() async -> ModernSpeechReadiness { .unavailable }
    static func transcribe(file url: URL) async throws -> String { "" }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func endAudio() {}
    func finish() async throws -> String { "" }
    func cancel() {}
}
#endif
