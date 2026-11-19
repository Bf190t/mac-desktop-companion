import AppKit
import Foundation
import CryptoKit

/// Optional chat and the optional reading voice live outside the signed app bundle. No download
/// happens until the user presses Install. Core desktop and monitoring features need neither.
final class ModelInstallation {
    enum Kind { case chat, voice }
    static let shared = ModelInstallation(.chat)
    static let voice = ModelInstallation(.voice)
    let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }
    /// Test seams: tests point these at temporary folders. The app never sets them.
    static var baseOverride:URL?
    static var resourcesOverride:URL?
    /// An outdated reading voice is switched on its own the first time the voice is needed
    /// (NeuralSpeechInstall.load). Test builds never start it by themselves.
    #if CHAT_SERVICE_TESTING
    static var automaticVoiceSwitch=false
    #else
    static var automaticVoiceSwitch=true
    #endif
    private static var base: URL {
        if let override=baseOverride {return override}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("io.github.bf190t.desktop-companion",isDirectory:true)
    }
    var root: URL { Self.base.appendingPathComponent(kind == .chat ? "Chat":"Voice",isDirectory:true) }
    var python: URL { root.appendingPathComponent("python-base/bin/python3.12") }
    /// The chat installation (kept for existing callers).
    static var root: URL { shared.root }
    static var python: URL { shared.python }
    var onChange: (() -> Void)?
    private(set) var isBusy=false
    private(set) var progress=0.0
    private var phase="not_installed"
    private var errorDetail=""
    private var process:Process?
    private var output:FileHandle?, errors:FileHandle?
    private var generation:UUID?
    private var wasCancelled=false
    /// Switching an installed voice to the bundled sample (switchVoice) rather than installing.
    private(set) var isSwitchingVoice=false
    /// A switch failed or was cancelled during this launch: no automatic retry until the next one.
    private var voiceSwitchHeld=false
    private var resources:URL {(Self.resourcesOverride ?? Bundle.main.resourceURL!).appendingPathComponent(kind == .chat ? "Chat":"Voice",isDirectory:true)}
    private var modelRevision:String { kind == .chat ? "3b1b1768f8f8cf8351c712464f906e86c2b8269e":"50f45ef0047cde7e84c2ef04326acb8ada2436a7" }
    var isInstalled:Bool {
        let fm=FileManager.default
        guard fm.isExecutableFile(atPath:python.path),
              fm.fileExists(atPath:root.appendingPathComponent("model/model.safetensors").path),
              let data=try? Data(contentsOf:root.appendingPathComponent("installation.json")),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              value["schema"] as? Int == 1,
              value["model_revision"] as? String == modelRevision,
              value["runtime_sha256"] as? String == "a18cc33862b53bd54a148c710def5375c1b47470cccedf817a19c2d211764584",
              let lock=try? Data(contentsOf:resources.appendingPathComponent("requirements-lock.txt")) else{return false}
        if kind == .voice {
            guard value["kind"] as? String == "voice",
                  fm.fileExists(atPath:root.appendingPathComponent("voices/companion_voice.wav").path) else{return false}
        }
        let hash=SHA256.hash(data:lock).map{String(format:"%02x",$0)}.joined()
        return value["requirements_sha256"] as? String == hash
    }
    /// SHA-256 of the companion sample bundled with this app; it cannot change while the app runs.
    private lazy var bundledVoiceHash:String? = {
        guard kind == .voice,let sample=try? Data(contentsOf:resources.appendingPathComponent("companion_voice.wav")) else{return nil}
        return SHA256.hash(data:sample).map{String(format:"%02x",$0)}.joined()
    }()
    /// A reading voice installed with a different companion sample than the one in this app (0.2.1
    /// replaced it). It is never used: replies and chimes use the system voice until switchVoice()
    /// has put the bundled sample in place and re-recorded the chimes with it (no download).
    var hasOutdatedVoice:Bool { outdatedVoice(installed:isInstalled) }
    /// Shown instead of the usual status while the voice is outdated or being switched.
    var voiceSwitchStatus:String? {
        guard kind == .voice else{return nil}
        if isBusy && isSwitchingVoice {
            return L("正在换成新声音（不用重新下载，约 1–2 分钟）…换好之前先用系统声音朗读。",
                     "Switching to the new voice (no download, about 1–2 minutes)… The system voice reads until it is done.")
        }
        guard !isBusy,hasOutdatedVoice else{return nil}
        if voiceSwitchHeld {
            return L("没能换成新声音（\(errorDetail)）。先用系统声音朗读；可以点「移除朗读声音」后重新安装。",
                     "Could not switch to the new voice (\(errorDetail)). The system voice reads for now; you can remove the reading voice and install it again.")
        }
        return L("朗读声音还是旧版。下次朗读时会自动换成新声音（不用重新下载）；换好之前用系统声音。",
                 "The reading voice is the previous one. It switches to the new voice the next time something is read (no download); the system voice reads until then.")
    }
    /// Starts switchVoice() once per launch when the installed voice is outdated.
    func switchVoiceIfNeeded() {
        guard kind == .voice,Self.automaticVoiceSwitch,!voiceSwitchHeld,!isBusy,hasOutdatedVoice else{return}
        switchVoice()
    }
    /// 0.2.0 → 0.2.1 kept the model revision and locked packages, so only the sample and the chimes
    /// recorded with it change. install.py --switch-voice copies the bundled sample, re-records the
    /// chimes with the installed model (network denied) and swaps voices/ and installation.json
    /// last; it refuses when anything else differs (then: remove and install again).
    func switchVoice() {
        guard kind == .voice,!isBusy,hasOutdatedVoice else{return}
        launch(python,["-I","-B","-u",resources.appendingPathComponent("install.py").path,"--switch-voice",root.path,resources.path],
               phase:"chimes",switching:true)
    }
    private func outdatedVoice(installed:Bool) -> Bool {
        guard kind == .voice,installed,let hash=bundledVoiceHash,
              let data=try? Data(contentsOf:root.appendingPathComponent("installation.json")),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else{return false}
        return value["voice_sha256"] as? String != hash
    }
    var status:String {
        if let note=voiceSwitchStatus {return note}
        let installed=isInstalled
        if !isBusy && phase != "failed" && phase != "cancelled" && installed {
            if outdatedVoice(installed:installed) {
                return L("朗读声音已安装，但还是旧版声音。小团从 0.2.1 起换了新声音：点「移除朗读声音」后重新安装即可换上（需重新下载约 2.5 GB）。",
                         "Reading voice installed, but with the previous voice. Mochi has a new voice since 0.2.1: remove the reading voice and install it again to switch (downloads about 2.5 GB again).")
            }
            return kind == .chat ? L("已安装。模型只在发送消息时加载。", "Installed. The model loads only when you send a message.")
                : L("朗读声音已安装。开始打字或录音时加载，闲置 5 分钟后释放。", "Reading voice installed. It loads when you start typing or recording and unloads after 5 idle minutes.")
        }
        switch phase {
        case "runtime": return L("正在下载并校验 Python 运行时…", "Downloading and verifying the Python runtime…")
        case "dependencies": return L("正在安装校验过的运行库…", "Installing hash-verified dependencies…")
        case "model": return kind == .chat ? L("正在下载并校验模型（约 984 MB）…", "Downloading and verifying the model (about 984 MB)…")
            : L("正在下载并校验朗读模型（约 2 GB）…", "Downloading and verifying the voice model (about 2 GB)…")
        case "chimes": return L("正在用小团的声音录整点报时（中英各一套）…", "Recording Mochi's hourly chimes (Chinese and English)…")
        case "verified": return L("正在完成安装…", "Finishing installation…")
        case "cancelling": return L("正在取消并清理本次下载…", "Cancelling and cleaning up this download…")
        case "cancelled": return L("已取消，可重新安装。", "Cancelled. You can install again.")
        case "failed": return L("安装未完成：", "Installation incomplete: ")+errorDetail
        default: return kind == .chat ? L("未安装。本功能可选；约需 1.3 GB 下载，至少预留 3 GiB。", "Not installed. Optional; about 1.3 GB download, with at least 3 GiB free.")
            : L("朗读声音未安装。可选；约需 2.5 GB 下载，至少预留 4 GiB。没装时用系统声音朗读。", "Reading voice not installed. Optional; about 2.5 GB download, with at least 4 GiB free. The system voice reads replies until then.")
        }
    }
    func install() {
        guard !isBusy,!isInstalled else{return}
        if kind == .chat, ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26 {
            phase="failed";errorDetail=L("本地聊天需要 macOS 26 或更新版本。", "Local chat requires macOS 26 or later.");onChange?();return
        }
        launch(URL(fileURLWithPath:"/bin/sh"),[resources.appendingPathComponent("install.sh").path,root.path],phase:"runtime")
    }
    private func launch(_ executable:URL,_ arguments:[String],phase first:String,switching:Bool=false) {
        let p=Process(),stdout=Pipe(),stderr=Pipe(),id=UUID()
        p.executableURL=executable
        p.arguments=arguments
        p.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":NSHomeDirectory(),"TMPDIR":NSTemporaryDirectory(),"LC_ALL":"en_US.UTF-8"]
        p.standardOutput=stdout;p.standardError=stderr
        process=p;generation=id;isBusy=true;isSwitchingVoice=switching;wasCancelled=false;progress=0;phase=first;errorDetail=""
        output=stdout.fileHandleForReading;errors=stderr.fileHandleForReading
        let queue=DispatchQueue(label:kind == .chat ? "companion.model.install.output":"companion.voice.install.output");var buffer=Data()
        stdout.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            if data.isEmpty {handle.readabilityHandler=nil;return}
            queue.async {
                buffer.append(data)
                while let newline=buffer.firstIndex(of:10) {
                    let line=buffer.prefix(upTo:newline);buffer.removeSubrange(...newline)
                    guard let event=try? JSONSerialization.jsonObject(with:line) as? [String:Any] else{continue}
                    DispatchQueue.main.async {
                        guard let self=self,self.generation == id,!self.wasCancelled else{return}
                        if let n=event["progress"] as? Double {self.progress=min(1,max(0,n))}
                        if let phase=event["phase"] as? String {self.phase=phase}
                        self.onChange?()
                    }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            if data.isEmpty {handle.readabilityHandler=nil;return}
            DispatchQueue.main.async {
                guard self?.generation == id else{return}
                self?.errorDetail=String(((self?.errorDetail ?? "")+String(decoding:data,as:UTF8.self)).suffix(3000))
            }
        }
        p.terminationHandler={ [weak self] ended in
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
                guard let self=self,self.generation == id else{return}
                self.output?.readabilityHandler=nil;self.errors?.readabilityHandler=nil
                self.output=nil;self.errors=nil;self.process=nil;self.generation=nil;self.isBusy=false
                if self.wasCancelled {self.phase="cancelled"}
                else if ended.terminationStatus == 0 && self.isInstalled && !(switching && self.hasOutdatedVoice) {self.phase="installed";self.progress=1;self.errorDetail=""}
                else {self.phase="failed";self.errorDetail=String(self.errorDetail.split(separator:"\n").last ?? "Unknown installation error").prefix(300).description}
                if switching {
                    self.isSwitchingVoice=false
                    if self.phase != "installed" {
                        self.voiceSwitchHeld=true
                        if self.wasCancelled {self.errorDetail=L("已取消", "cancelled")}
                    }
                }
                self.onChange?()
            }
        }
        do {try p.run()} catch {
            output?.readabilityHandler=nil;errors?.readabilityHandler=nil;process=nil;generation=nil;isBusy=false
            phase="failed";errorDetail=error.localizedDescription
            if switching {isSwitchingVoice=false;voiceSwitchHeld=true}
        }
        onChange?()
    }
    func cancel() {
        guard isBusy,let p=process else{return}
        wasCancelled=true;phase="cancelling";p.terminate();onChange?()
        // install.sh forwards SIGTERM, waits for the Python installer to retire
        // its download/pip process group, and removes only its own staging area.
    }
    /// Caller disables this action while the chat worker is running.
    func uninstall() {
        guard !isBusy else{return}
        do {
            if FileManager.default.fileExists(atPath:root.path) {try FileManager.default.removeItem(at:root)}
            phase="not_installed";progress=0;errorDetail=""
        } catch {phase="failed";errorDetail=error.localizedDescription}
        onChange?()
    }
}
