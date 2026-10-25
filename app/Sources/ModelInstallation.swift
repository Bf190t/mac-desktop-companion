import AppKit
import Foundation
import CryptoKit

/// Optional chat lives outside the signed app bundle. No download happens until
/// the user presses Install. Core desktop and monitoring features need none of it.
final class ModelInstallation {
    static let shared = ModelInstallation()
    static var root: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("io.github.bf190t.desktop-companion",isDirectory:true)
            .appendingPathComponent("Chat",isDirectory:true)
    }
    static var python: URL { root.appendingPathComponent("python-base/bin/python3.12") }
    var onChange: (() -> Void)?
    private(set) var isBusy=false
    private(set) var progress=0.0
    private var phase="not_installed"
    private var errorDetail=""
    private var process:Process?
    private var output:FileHandle?, errors:FileHandle?
    private var generation:UUID?
    private var wasCancelled=false
    private var resources:URL {Bundle.main.resourceURL!.appendingPathComponent("Chat",isDirectory:true)}
    var isInstalled:Bool {
        guard FileManager.default.isExecutableFile(atPath:Self.python.path),
              FileManager.default.fileExists(atPath:Self.root.appendingPathComponent("model/model.safetensors").path),
              let data=try? Data(contentsOf:Self.root.appendingPathComponent("installation.json")),
              let value=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              value["schema"] as? Int == 1,
              value["model_revision"] as? String == "3b1b1768f8f8cf8351c712464f906e86c2b8269e",
              value["runtime_sha256"] as? String == "a18cc33862b53bd54a148c710def5375c1b47470cccedf817a19c2d211764584",
              let lock=try? Data(contentsOf:resources.appendingPathComponent("requirements-lock.txt")) else{return false}
        let hash=SHA256.hash(data:lock).map{String(format:"%02x",$0)}.joined()
        return value["requirements_sha256"] as? String == hash
    }
    var status:String {
        if !isBusy && phase != "failed" && phase != "cancelled" && isInstalled {
            return L("已安装。模型只在发送消息时加载。", "Installed. The model loads only when you send a message.")
        }
        switch phase {
        case "runtime": return L("正在下载并校验 Python 运行时…", "Downloading and verifying the Python runtime…")
        case "dependencies": return L("正在安装校验过的运行库…", "Installing hash-verified dependencies…")
        case "model": return L("正在下载并校验模型（约 984 MB）…", "Downloading and verifying the model (about 984 MB)…")
        case "verified": return L("正在完成安装…", "Finishing installation…")
        case "cancelling": return L("正在取消并清理本次下载…", "Cancelling and cleaning up this download…")
        case "cancelled": return L("已取消，可重新安装。", "Cancelled. You can install again.")
        case "failed": return L("安装未完成：", "Installation incomplete: ")+errorDetail
        default: return L("未安装。本功能可选；约需 1.3 GB 下载，至少预留 3 GiB。", "Not installed. Optional; about 1.3 GB download, with at least 3 GiB free.")
        }
    }
    func install() {
        guard !isBusy,!isInstalled else{return}
        guard #available(macOS 26.0, *) else {
            phase="failed";errorDetail=L("本地聊天需要 macOS 26 或更新版本。", "Local chat requires macOS 26 or later.");onChange?();return
        }
        let p=Process(),stdout=Pipe(),stderr=Pipe(),id=UUID()
        p.executableURL=URL(fileURLWithPath:"/bin/sh")
        p.arguments=[resources.appendingPathComponent("install.sh").path,Self.root.path]
        p.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":NSHomeDirectory(),"TMPDIR":NSTemporaryDirectory(),"LC_ALL":"en_US.UTF-8"]
        p.standardOutput=stdout;p.standardError=stderr
        process=p;generation=id;isBusy=true;wasCancelled=false;progress=0;phase="runtime";errorDetail=""
        output=stdout.fileHandleForReading;errors=stderr.fileHandleForReading
        let queue=DispatchQueue(label:"companion.model.install.output");var buffer=Data()
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
                else if ended.terminationStatus == 0 && self.isInstalled {self.phase="installed";self.progress=1;self.errorDetail=""}
                else {self.phase="failed";self.errorDetail=String(self.errorDetail.split(separator:"\n").last ?? "Unknown installation error").prefix(300).description}
                self.onChange?()
            }
        }
        do {try p.run()} catch {
            output?.readabilityHandler=nil;errors?.readabilityHandler=nil;process=nil;generation=nil;isBusy=false
            phase="failed";errorDetail=error.localizedDescription
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
            if FileManager.default.fileExists(atPath:Self.root.path) {try FileManager.default.removeItem(at:Self.root)}
            phase="not_installed";progress=0;errorDetail=""
        } catch {phase="failed";errorDetail=error.localizedDescription}
        onChange?()
    }
}
