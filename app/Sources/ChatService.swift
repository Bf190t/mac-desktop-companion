import AppKit
import Foundation
import Darwin

struct PetChatLine {
    let role: String
    let text: String
    var eligible = true
}

/// Owns stdin handles on one queue. A retired destination remains distinct from
/// its replacement, so queued output can never be redirected to a new worker.
final class PetChatInputWriter {
    private final class Destination {
        let token: UUID
        let handle: FileHandle
        init(_ token: UUID, _ handle: FileHandle) { self.token=token;self.handle=handle }
    }
    private let queue = DispatchQueue(label:"pet.chat.input",qos:.userInitiated)
    private let lock = NSLock()
    private var destination: Destination?

    func install(_ handle:FileHandle, token:UUID) throws {
        let fd=handle.fileDescriptor, flags=fcntl(handle.fileDescriptor,F_GETFL)
        guard flags >= 0,fcntl(fd,F_SETFL,flags | O_NONBLOCK) >= 0,fcntl(fd,F_SETNOSIGPIPE,1) >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        lock.lock();let previous=destination;destination=Destination(token,handle);lock.unlock()
        if let previous=previous {queue.async {try? previous.handle.close()}}
    }
    func invalidate(_ token:UUID? = nil) {
        lock.lock()
        let previous=destination
        if token == nil || previous?.token == token {destination=nil}
        else {lock.unlock();return}
        lock.unlock()
        if let previous=previous {queue.async {try? previous.handle.close()}}
    }
    private func isCurrent(_ target:Destination)->Bool {
        lock.lock();defer{lock.unlock()};return destination === target
    }
    func enqueue(_ data:Data, token:UUID, onFailure:@escaping (Error)->Void) {
        lock.lock();let target=destination;lock.unlock()
        guard let target=target,target.token == token else{return}
        queue.async { [weak self] in
            guard let self=self,self.isCurrent(target) else{return}
            do {try self.write(data,to:target)}
            catch {
                guard self.isCurrent(target) else{return}
                DispatchQueue.main.async { [weak self] in
                    guard self?.isCurrent(target) == true else{return};onFailure(error)
                }
            }
        }
    }
    private func write(_ data:Data,to target:Destination) throws {
        let fd=target.handle.fileDescriptor
        let deadline=ProcessInfo.processInfo.systemUptime+15
        try data.withUnsafeBytes { bytes in
            guard let base=bytes.baseAddress else{return}
            var offset=0
            while offset < bytes.count {
                guard isCurrent(target) else{return}
                let count=Darwin.write(fd,base.advanced(by:offset),bytes.count-offset)
                if count>0 {offset += count;continue}
                let code=count == 0 ? EPIPE:errno
                if code == EINTR {continue}
                guard code == EAGAIN || code == EWOULDBLOCK else {
                    throw POSIXError(POSIXErrorCode(rawValue:code) ?? .EIO)
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {throw POSIXError(.ETIMEDOUT)}
                // Only this background queue waits, and retirement is observed
                // within 50ms even if the worker never starts reading stdin.
                var pollState=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
                let result=Darwin.poll(&pollState,1,50)
                if result<0 && errno != EINTR {throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
            }
        }
    }
}

// One model process and one in-memory conversation shared by the pet and inspector.
final class PetChatService {
    var onChange: (() -> Void)?
    var onReply: ((String) -> Void)?
    private(set) var lines: [PetChatLine] = []
    private(set) var status = L("模型未加载，发送消息时启动。", "Model not loaded. It starts when you send a message.")
    private(set) var lastRelease = L("尚未发生卸载", "No unload yet")
    private(set) var memory = L("未加载", "Not loaded")
    private(set) var cpu = "—"
    private(set) var timing = L("首字：— · 本轮：—", "First token: — · Total: —")
    private(set) var context = L("尚未发送消息", "No messages sent")
    private(set) var draft = ""
    private(set) var currentID: String?
    private(set) var stopping = false
    private(set) var loaded = false
    private(set) var idleRemaining: Double?
    private(set) var memoryPressureBlocked = false
    var canSend: Bool { currentID == nil && !stopping && !suspended && !memoryPressureBlocked && (worker == nil || worker?.isRunning == true) }
    var hasWorker: Bool { worker != nil }
    var isBusy: Bool { currentID != nil }
    var suspended = false
    var inspecting = false { didSet { updateStatsTimer() } }
    var longResidency = false {
        didSet {
            if oldValue != longResidency, worker != nil { write(["action":"configure", "idle_seconds":idleSeconds]) }
            changed()
        }
    }
    var idleSeconds: Int { longResidency ? 1800 : 120 }
    var customPersona = ""
    var persona: String { customPersona.isEmpty ? ChatBoundary.defaultPersona : customPersona }
    private var omitted = 0
    private var worker: Process?
    private var token: UUID?
    private let inputWriter=PetChatInputWriter()
    private var stdout: FileHandle?, stderr: FileHandle?
    private var statsTimer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    private var pendingRender: DispatchWorkItem?
    private var started: TimeInterval = 0
    private var firstDelta: TimeInterval?
    private var cancelled = false
    private var intentionalExit: String?
    private var diagnostics = ""
    private var root:URL {ModelInstallation.root}
    private let source = Bundle.main.resourceURL!.appendingPathComponent("Chat", isDirectory:true)
    init() {
        // The callback includes its reason in the inspector; it is independent
        // of the normal residency timeout and applies to the long mode too.
        let p = DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical], queue:.main)
        p.setEventHandler { [weak self] in
            guard let self=self,let events=self.pressure?.data else {return}
            self.applyMemoryPressure(events)
        }
        p.resume(); pressure=p
    }
    deinit { pressure?.cancel(); statsTimer?.invalidate();inputWriter.invalidate() }
    private func applyMemoryPressure(_ events:DispatchSource.MemoryPressureEvent) {
        if events.contains(.critical) || events.contains(.warning) {
            memoryPressureBlocked=true
            let reason=events.contains(.critical) ? "memory_pressure_critical":"memory_pressure_warning"
            if hasWorker {release(reason)}
            else {status=L("系统内存压力较高，恢复正常后才能继续聊天。", "Memory pressure is high. Chat can continue when it returns to normal.");changed()}
        } else if events.contains(.normal),memoryPressureBlocked {
            memoryPressureBlocked=false
            if !hasWorker {status=L("内存压力已恢复正常。下次发送消息时再加载模型。", "Memory pressure is normal again. The model reloads on your next message.")}
            changed()
        }
    }
    func changed() { onChange?() }
    func send(_ raw: String) -> Bool {
        guard canSend else {return false}
        let text=raw.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= 5000 else {
            status=L("请发送 1–5000 字的消息。", "Please send a message of 1–5000 characters."); changed(); return false
        }
        append(PetChatLine(role:"user",text:text))
        if let fixed=ChatBoundary.replyBeforeInference(text) {
            append(PetChatLine(role:"assistant",text:fixed))
            status=L("这条由应用直接说明，未请求模型。", "This is an app-provided explanation, without a model request.")
            if worker != nil { write(["action":"activity","kind":"user_input"]) }
            onReply?(fixed); changed(); return true
        }
        guard #available(macOS 26.0, *) else {
            status=L("此聊天组件需要 macOS 26 或更新版本；其他桌宠功能可继续使用。", "Local chat requires macOS 26 or later. Other companion features remain available.");onReply?(status);changed();return true
        }
        guard ModelInstallation.shared.isInstalled else {
            status=L("尚未安装可选模型。请从「本地模型」窗口点击「安装本地聊天」。", "Optional model not installed. Open Local Model and choose Install Local Chat.");onReply?(status);changed();return true
        }
        let history=lines.filter{$0.eligible}.map{["role":$0.role,"content":$0.text]}
        let id=UUID().uuidString
        let request:[String:Any]=["action":"chat","id":id,"mode":"companion","messages":history,"history_omitted_messages":omitted,"persona_override":persona]
        guard let data=try? JSONSerialization.data(withJSONObject:request),data.count < 1000000 else {
            status=L("对话过长，请先清空对话。", "The conversation is too long. Please clear it first.");changed();return true
        }
        currentID=id;draft="";cancelled=false;started=ProcessInfo.processInfo.systemUptime;firstDelta=nil
        context=L("发送 \(history.count) 条 · 等待模型确认 · 跳过 \(lines.filter{!$0.eligible}.count) 条未完成回复", "Sending \(history.count) messages · Awaiting model · Skipped \(lines.filter{!$0.eligible}.count) incomplete replies")
        timing=L("首字：等待 · 本轮：回复中", "First token: waiting · Total: generating");idleRemaining=nil
        if worker == nil { startWorker() }
        if worker?.isRunning == true {write(request)}
        changed();return true
    }
    private func append(_ line:PetChatLine) {
        lines.append(line)
        while lines.count>80 {lines.removeFirst();omitted += 1}
        while lines.first?.role == "assistant" {lines.removeFirst();omitted += 1}
    }
    private func startWorker() {
        let p=Process(), id=UUID(), pin=Pipe(), pout=Pipe(), perr=Pipe()
        p.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        // Isolated Python ignores environment injection; a tiny owned launcher
        // adds only our bundled dependency directory. No server or network.
        p.arguments=["-p","(version 1)(allow default)(deny network*)",root.appendingPathComponent("python-base/bin/python3.12").path,"-I","-B","-u",source.appendingPathComponent("launch.py").path,root.path,"--idle-seconds",String(idleSeconds)]
        p.currentDirectoryURL=root
        p.environment=["PATH":"/usr/bin:/bin","HOME":NSHomeDirectory(),"TMPDIR":NSTemporaryDirectory(),"HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1","HF_HUB_DISABLE_TELEMETRY":"1","PYTHONDONTWRITEBYTECODE":"1","PYTHONUNBUFFERED":"1"]
        p.standardInput=pin;p.standardOutput=pout;p.standardError=perr
        worker=p;token=id;stdout=pout.fileHandleForReading;stderr=perr.fileHandleForReading
        intentionalExit=nil;diagnostics="";stopping=false
        let parseQueue=DispatchQueue(label:"pet.chat.output.\(id)");var buffer=Data()
        pout.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            if data.isEmpty {handle.readabilityHandler=nil;return}
            parseQueue.async {
                buffer.append(data)
                while let n=buffer.firstIndex(of:10) {
                    let line=buffer.prefix(upTo:n);buffer.removeSubrange(...n)
                    guard let event=try? JSONSerialization.jsonObject(with:line) as? [String:Any] else {continue}
                    DispatchQueue.main.async { [weak self] in guard self?.token == id else{return};self?.handle(event) }
                }
            }
        }
        perr.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData
            if data.isEmpty {handle.readabilityHandler=nil;return}
            DispatchQueue.main.async {guard self?.token == id else{return};self?.diagnostics=String(((self?.diagnostics ?? "") + String(decoding:data,as:UTF8.self)).suffix(1200))}
        }
        p.terminationHandler={ [weak self] ended in
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) {
                guard let self=self,self.token == id else{return}
                self.stdout?.readabilityHandler=nil;self.stderr?.readabilityHandler=nil
                self.inputWriter.invalidate(id);self.stdout=nil;self.stderr=nil
                self.worker=nil;self.token=nil;self.stopping=false;self.loaded=false;self.idleRemaining=nil
                self.statsTimer?.invalidate();self.statsTimer=nil;self.memory=L("已卸载", "Unloaded");self.cpu=L("进程已退出", "Process exited")
                let hadPending = self.currentID != nil
                if hadPending {self.finishIncomplete();self.currentID=nil}
                let reason=self.intentionalExit ?? (ended.terminationStatus == 0 ? "process_exit" : "process_error")
                self.lastRelease=Self.reasonLabel(reason)
                self.status=Self.releasedStatus(self.lastRelease,pressureBlocked:self.memoryPressureBlocked)
                if self.intentionalExit == nil && ended.terminationStatus != 0 {
                    let detail=String(self.diagnostics.split(separator:"\n").last.map(String.init)?.prefix(180) ?? "")
                    self.status += L("\n退出码 \(ended.terminationStatus)", "\nExit code \(ended.terminationStatus)") + (detail.isEmpty ? "":"："+detail)
                }
                if hadPending && self.intentionalExit == nil {self.onReply?(L("这次模型意外停下了。请打开本地模型状态查看原因，再试一次。", "The model stopped unexpectedly. Check Local Model status, then try again."))}
                self.changed()
            }
        }
        do {try inputWriter.install(pin.fileHandleForWriting,token:id);try p.run();status=L("正在启动本地模型…", "Starting the local model…");updateStatsTimer()}
        catch {
            stdout?.readabilityHandler=nil;stderr?.readabilityHandler=nil
            inputWriter.invalidate(id);worker=nil;token=nil;stdout=nil;stderr=nil;currentID=nil
            status=L("模型启动失败：\(error.localizedDescription)", "Could not start model: \(error.localizedDescription)");lastRelease=L("启动失败", "Startup failed");onReply?(L("模型暂时没有启动。请从菜单栏打开本地模型状态查看原因。", "The model did not start. Open Local Model status from the menu to see why."))
        }
    }
    private func write(_ payload:[String:Any]) {
        guard let id=token,worker?.isRunning == true,let data=try? JSONSerialization.data(withJSONObject:payload) else{return}
        inputWriter.enqueue(data+Data([10]),token:id) { [weak self] error in
            guard let self=self,self.token == id,!self.stopping else{return}
            self.diagnostics=L("写入推理进程失败：\(error.localizedDescription)", "Could not write to inference process: \(error.localizedDescription)")
            self.inputWriter.invalidate(id);self.release("pipe_closed")
        }
    }
    private func handle(_ e:[String:Any]) {
        guard let kind=e["type"] as? String else{return}
        if let id=e["id"] as? String,kind != "stats",id != currentID {return}
        if let residency=e["residency"] as? [String:Any],let n=residency["idle_remaining_seconds"] as? Double {idleRemaining=n}
        switch kind {
        case "starting","ready":status=L("本地推理组件已准备。", "Local inference is ready.")
        case "loading":status=L("正在校验并加载本地模型…", "Verifying and loading the local model…")
        case "loaded":loaded=true;updateMetrics(e);status=L("模型已加载。", "Model loaded.")
        case "generating":
            let used=e["context_used_messages"] as? Int ?? 0
            let drop=e["dropped_messages"] as? Int ?? 0
            context=L("实际使用 \(used) 条 · 较早 \(omitted+drop) 条未带入 · 跳过 \(lines.filter{!$0.eligible}.count) 条未完成回复", "Using \(used) messages · Omitted \(omitted+drop) older messages · Skipped \(lines.filter{!$0.eligible}.count) incomplete replies")
            status=L("正在想一句简短的回复…", "Thinking of a short reply…")
        case "delta":
            let t=e["text"] as? String ?? ""
            if firstDelta == nil,!t.isEmpty {firstDelta=ProcessInfo.processInfo.systemUptime-started}
            draft += t
            if pendingRender == nil {
                let work=DispatchWorkItem{[weak self] in self?.pendingRender=nil;self?.changed()}
                pendingRender=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.12,execute:work)
            }
            return
        case "stats":updateMetrics(e)
        case "done":
            pendingRender?.cancel();pendingRender=nil
            if let t=e["text"] as? String {draft=t}
            let reason=e["finish_reason"] as? String ?? "unknown"
            let isComplete = reason == "stop" && !cancelled
            let reply:String
            if isComplete {
                reply=ChatBoundary.sanitizeReply(draft)
                append(PetChatLine(role:"assistant",text:reply))
            } else {finishIncomplete();reply=cancelled ? L("先停在这里。你可以继续发消息。", "Stopped here. You can send another message."):L("这句话没说完整，换个短一点的问题试试吧。", "That reply was incomplete. Try a shorter question.")}
            draft="";currentID=nil;idleRemaining=Double(idleSeconds)
            let total=ProcessInfo.processInfo.systemUptime-started
            timing=String(format:L("首字：%@ · 本轮：%.2f 秒", "First token: %@ · Total: %.2f s"),firstDelta.map{String(format:L("%.2f 秒", "%.2f s"),$0)} ?? "—",total)
            if let metrics=e["metrics"] as? [String:Any] {updateMetrics(metrics)}
            status=isComplete ? L("回复完成。闲置 \(idleSeconds) 秒后释放模型。", "Reply complete. The model unloads after \(idleSeconds) idle seconds.") : L("本轮未完成，半截回复不会用于后续对话。", "Incomplete reply. It will not be included in later context.")
            // Raw worker resource reason always wins over the display cancel state.
            if reason == "memory_limit" {release("memory_limit")}
            // All previous-request mutation must finish before callbacks: a
            // callback may synchronously submit the next request or start TTS.
            onReply?(reply);changed();return
        case "error":
            finishIncomplete();currentID=nil;status=e["message"] as? String ?? L("本轮没有完成。", "This reply did not complete.");onReply?(L("这次没能完成回复。可以在本地模型状态中查看原因，再试一次。", "The reply could not complete. Check Local Model status, then try again."))
        case "idle_exit":intentionalExit="idle_timeout";stopping=true;status=L("闲置时间已到，正在释放模型。", "Idle timeout reached. Unloading the model.")
        case "configured","activity_ack":break
        case "exiting":
            if intentionalExit == nil {intentionalExit=e["reason"] as? String};stopping=true
        default:break
        }
        changed()
    }
    private func finishIncomplete() {
        pendingRender?.cancel();pendingRender=nil
        if !draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {append(PetChatLine(role:"assistant",text:draft,eligible:false))}
        draft=""
    }
    private func updateMetrics(_ e:[String:Any]) {
        if let n=e["footprint_mib"] as? Double {memory=String(format:"%.0f MiB",n)}
        if let n=e["cpu_percent"] as? Double {cpu=String(format:"%.1f%%",n)}
        if let value=e["model_loaded"] as? Bool {loaded=value}
    }
    private func updateStatsTimer() {
        statsTimer?.invalidate();statsTimer=nil
        guard inspecting,worker != nil else{return}
        let t=Timer(timeInterval:3,repeats:true){[weak self] _ in guard let self=self,!self.isBusy else{return};self.write(["action":"stats"])}
        t.tolerance=1;RunLoop.main.add(t,forMode:.common);statsTimer=t
        write(["action":"stats"])
    }
    private var lastTyping:TimeInterval=0
    func userTyped() {
        guard hasWorker,!stopping else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now-lastTyping >= 2 else{return}
        lastTyping=now;write(["action":"activity","kind":"user_input"])
    }
    func stopReply() {
        guard let id=currentID else{return}
        cancelled=true;write(["action":"stop","id":id]);status=L("正在停止回复…", "Stopping the reply…");changed()
        DispatchQueue.main.asyncAfter(deadline:.now()+2){[weak self] in guard self?.currentID == id else{return};self?.release("cancel_timeout")}
    }
    func release(_ reason:String) {
        guard let p=worker else {return}
        intentionalExit=reason;lastRelease=Self.reasonLabel(reason);stopping=true
        let hadPending=currentID != nil
        if hadPending {finishIncomplete();currentID=nil}
        if hadPending && ["memory_pressure_warning","memory_pressure_critical","memory_limit","pipe_closed"].contains(reason) {
            onReply?(L("这次回复暂停了，模型正在释放。可以在本地模型状态里查看原因。", "Reply paused while the model unloads. Check Local Model status for the reason."))
        }
        statsTimer?.invalidate();statsTimer=nil
        status=L("正在释放模型：\(lastRelease)", "Unloading model: \(lastRelease)");write(["action":"quit","reason":reason]);changed()
        let id=token
        // Allow normal cleanup briefly, then bound shutdown even during loading.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35){[weak self,weak p] in
            guard self?.token == id,let p=p,p.isRunning else{return};p.terminate()
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+1.5){[weak self,weak p] in
            guard self?.token == id,let p=p,p.isRunning else{return};kill(p.processIdentifier,SIGKILL)
        }
    }
    func terminateSynchronously() {
        guard let p=worker,p.isRunning else{inputWriter.invalidate();return}
        write(["action":"quit","reason":"app_exit"]);p.terminate()
        // No child inference remains after the app quits.
        if p.isRunning {kill(p.processIdentifier,SIGKILL)}
        inputWriter.invalidate(token)
    }
    func clear() {guard canSend else{return};lines.removeAll();omitted=0;context=L("新对话，尚未发送消息", "New conversation. No messages sent.");draft="";changed()}
    func setPersona(_ value:String) {guard canSend else{return};customPersona=value;clear()}
    static func releasedStatus(_ label:String,pressureBlocked:Bool)->String {
        L("模型已释放：\(label)。", "Model unloaded: \(label). ") + (pressureBlocked ? L("内存压力仍较高，恢复正常后可继续聊天。", "Memory pressure remains high. Chat can continue when it is normal."):L("下次发送时重新加载。", "It reloads on your next message."))
    }
    static func reasonLabel(_ code:String)->String {
        ["idle_timeout":L("达到闲置时限", "Idle timeout"),"memory_pressure_warning":L("系统内存压力警告", "Memory pressure warning"),"memory_pressure_critical":L("系统内存压力严重", "Critical memory pressure"),"memory_limit":L("推理内存达到上限", "Inference memory limit"),"user_unload":L("你手动卸载", "Manually unloaded"),"chat_disabled":L("聊天开关已关闭", "Chat disabled"),"pet_hidden":L("角色已隐藏", "Companion hidden"),"sleep":L("系统休眠", "System sleep"),"screen":L("屏幕熄灭", "Display sleep"),"session":L("离开当前用户会话", "User session inactive"),"lock":L("屏幕锁定", "Screen locked"),"app_exit":L("应用退出", "App exited"),"cancel_timeout":L("停止等待超时", "Stop timeout"),"pipe_closed":L("进程连接已关闭", "Process connection closed"),"process_error":L("推理进程异常退出", "Inference process error"),"process_exit":L("推理进程退出", "Inference process exited"),"no_chat_client":L("所有聊天窗口已关闭", "All chat windows closed"),"system_suspended":L("系统暂时暂停交互", "System interaction suspended")][code] ?? code
    }

    #if CHAT_SERVICE_TESTING
    // Compiled only into the headless protocol regression executable.
    func testingPressure(_ value:DispatchSource.MemoryPressureEvent) {applyMemoryPressure(value)}
    func testingBeginRequest(_ id:String,draft:String="",cancelled:Bool=false) {
        currentID=id;self.draft=draft;self.cancelled=cancelled
        started=ProcessInfo.processInfo.systemUptime;firstDelta=nil
        append(PetChatLine(role:"user",text:id))
    }
    func testingEvent(_ event:[String:Any]) {handle(event)}
    #endif
}
