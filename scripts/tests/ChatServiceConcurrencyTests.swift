import AppKit
import Foundation
import Darwin

@main
struct ChatServiceConcurrencyTests {
    static func main() throws {
        let domain="io.github.bf190t.desktop-companion.test.chat."+UUID().uuidString
        let previous=Language.defaults
        let isolated=UserDefaults(suiteName:domain)!
        Language.defaults=isolated
        defer {Language.defaults=previous;isolated.removePersistentDomain(forName:domain)}
        var results=[[String:Any]](), failures=[String](), checks=0
        for language in Language.allCases {
            Language.current=language
            let result=try runChecks()
            results.append(["language":language.rawValue,"checks":result.checks,"failures":result.failures])
            checks += result.checks
            failures += result.failures.map{language.rawValue+": "+$0}
        }
        let data=try JSONSerialization.data(withJSONObject:["languages":results,"checks":checks,"failures":failures,"isolatedPreferences":true],options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
        if !failures.isEmpty {throw NSError(domain:"ChatServiceConcurrencyTests",code:1,userInfo:[NSLocalizedDescriptionKey:failures.joined(separator:"; ")])}
    }
    static func runChecks() throws -> (checks:Int,failures:[String]) {
        var failures=[String](),checks=0
        func check(_ name:String,_ value:@autoclosure ()->Bool) {
            checks += 1;if !value(){failures.append(name)}
        }
        func wait(_ condition:()->Bool,timeout:Double=1)->Bool {
            let end=ProcessInfo.processInfo.systemUptime+timeout
            while !condition() && ProcessInfo.processInfo.systemUptime<end {
                RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))
            }
            return condition()
        }
        func read(_ handle:FileHandle,minimum:Int,timeout:Double=1)->Data {
            let fd=handle.fileDescriptor
            _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) | O_NONBLOCK)
            var data=Data(),bytes=[UInt8](repeating:0,count:8192)
            _=wait({
                let n=Darwin.read(fd,&bytes,bytes.count)
                if n>0 {data.append(contentsOf:bytes.prefix(n))}
                return data.count>=minimum
            },timeout:timeout)
            return data
        }

        // No worker is started. Pressure events are delivered directly.
        let pressure=PetChatService()
        check("initial service is not pressure-blocked", !pressure.memoryPressureBlocked && pressure.canSend)
        pressure.testingPressure(.warning)
        check("warning latches without worker", pressure.memoryPressureBlocked && !pressure.canSend && !pressure.hasWorker)
        check("blocked send does not change history", !pressure.send("你好") && pressure.lines.isEmpty)
        pressure.testingPressure([])
        check("empty event does not clear warning", pressure.memoryPressureBlocked)
        pressure.testingPressure([.warning,.normal])
        check("coalesced warning is conservative", pressure.memoryPressureBlocked)
        pressure.testingPressure(.normal)
        check("normal clears latch without auto-start", !pressure.memoryPressureBlocked && pressure.canSend && !pressure.hasWorker)
        pressure.testingPressure(.critical);pressure.suspended=true;pressure.testingPressure(.normal)
        check("normal never overrides system suspension", !pressure.memoryPressureBlocked && !pressure.canSend)
        let blockedStatus=PetChatService.releasedStatus("系统内存压力警告",pressureBlocked:true)
        check("exit status explains persistent pressure block", blockedStatus.contains(L("恢复正常后可继续聊天", "Chat can continue when it is normal")) && !blockedStatus.contains(L("下次发送时重新加载", "It reloads on your next message")))
        check("normal exit remains reloadable", PetChatService.releasedStatus("你手动卸载",pressureBlocked:false).contains(L("下次发送时重新加载", "It reloads on your next message")))
        check("new release reasons are readable", PetChatService.reasonLabel("no_chat_client") == L("所有聊天窗口已关闭", "All chat windows closed") && PetChatService.reasonLabel("system_suspended") == L("系统暂时暂停交互", "System interaction suspended"))

        let reply=PetChatService();reply.testingBeginRequest("old",draft:"草稿")
        var delivered="",busyAtReply=true
        reply.onReply={ text in
            delivered=text;busyAtReply=reply.isBusy
            reply.testingBeginRequest("new",draft:"新请求不能丢")
        }
        reply.testingEvent(["type":"done","id":"old","text":"我在这里。","finish_reason":"stop"])
        check("reply callback sees completed service", !busyAtReply && delivered == "我在这里。")
        check("reply callback can start next turn safely", reply.currentID == "new" && reply.draft == "新请求不能丢")
        let count=reply.lines.count
        reply.testingEvent(["type":"delta","id":"old","text":"不应出现"])
        reply.testingEvent(["type":"done","id":"old","text":"旧回复","finish_reason":"stop"])
        check("old request packets cannot erase new request", reply.currentID == "new" && reply.draft == "新请求不能丢" && reply.lines.count == count)
        reply.onReply=nil

        let change=PetChatService();change.testingBeginRequest("first")
        var changedStartedNext=false
        change.onChange={
            if !changedStartedNext {changedStartedNext=true;change.testingBeginRequest("second",draft:"第二轮")}
        }
        change.testingEvent(["type":"done","id":"first","text":"收到。","finish_reason":"stop"])
        check("synchronous change callback preserves next turn", change.currentID == "second" && change.draft == "第二轮")
        change.onChange=nil

        let cancel=PetChatService();cancel.testingBeginRequest("cancel",draft:"未完",cancelled:true)
        var cancelledReply="";cancel.onReply={cancelledReply=$0}
        cancel.testingEvent(["type":"done","id":"cancel","text":"这句不应作为完成回复。","finish_reason":"stop"])
        check("cancel wins over late normal stop", !cancel.isBusy && cancelledReply.hasPrefix(L("先停在这里", "Stopped here")))
        check("cancelled draft is ineligible", cancel.lines.last?.eligible == false)

        // Review 2026-11: an interrupted reply to crisis wording still gets the support line, and the
        // line is shown apart in the chat window but never sent back to the model.
        let crisisDone=PetChatService();var crisisText="";crisisDone.onReply={crisisText=$0}
        crisisDone.testingBeginRequest("活著沒意思")
        crisisDone.testingEvent(["type":"done","id":"活著沒意思","text":"抱抱你。","finish_reason":"stop"])
        check("support line shown apart and kept out of model context", crisisText.hasSuffix(ChatBoundary.crisisSupport) && crisisDone.lines.last?.role == "support" && crisisDone.lines.last?.inModelContext == false && crisisDone.lines.last(where:{$0.role == "assistant"})?.text == "抱抱你。" && ChatBoundary.bubbleText(crisisText).hasSuffix(ChatBoundary.crisisSupport))
        // Round 2 (2026-11-19): a message over 5000 characters is refused, but crisis wording anywhere in it
        // still gets the hotlines (in the status line and as a reply), and nothing is added to the history.
        let longCrisis=PetChatService();var longReplies:[String]=[];longCrisis.onReply={longReplies.append($0)}
        let pasted=String(repeating:"今天去超市买了牛奶和面包，路上堵车。",count:400)+"其实我有时候真的不想活了。"+String(repeating:"明天还要早起。",count:200)
        check("long crisis message refused with hotline", !longCrisis.send(pasted) && longCrisis.lines.isEmpty && longCrisis.status.contains("5000") && longCrisis.status.hasSuffix(ChatBoundary.crisisSupport) && longReplies == [ChatBoundary.crisisOnlyReply])
        let longPlain=PetChatService();var plainReplies:[String]=[];longPlain.onReply={plainReplies.append($0)}
        check("long ordinary message refused without hotline", !longPlain.send(String(repeating:"今天去超市买了牛奶和面包。",count:500)) && longPlain.lines.isEmpty && !longPlain.status.contains(ChatBoundary.crisisSupport) && plainReplies.isEmpty)
        check("crisis wording found across a piece boundary", PetChatService.longTextNeedsCrisisSupport(String(repeating:"好",count:3998)+"自杀"+String(repeating:"好",count:6000)) && !PetChatService.longTextNeedsCrisisSupport(String(repeating:"好",count:12000)) && PetChatService.longTextNeedsCrisisSupport(String(repeating:"好",count:90000)+"我不想活了") && PetChatService.longTextNeedsCrisisSupport("我不想活了"+String(repeating:"好",count:90000)))
        var dummies:[Process]=[]
        for (text,expectHotline,reason) in [("我不想活了",true,"memory_pressure_warning"),("I want to die",true,"memory_pressure_critical"),("今天好累",false,"memory_pressure_warning"),("自-杀",true,"lock"),("s u i c i d e",true,"chat_disabled"),("today was long",false,"lock"),("活着好没意思",true,"cancel_timeout")] {
            let s=PetChatService();var got:[String]=[];s.onReply={got.append($0)}
            let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/sleep");p.arguments=["5"];try p.run();dummies.append(p)
            s.testingAttachWorker(p);s.testingBeginRequest(text)
            if reason == "lock" {s.suspended=true}
            if reason.hasPrefix("memory") {s.testingPressure(reason.hasSuffix("critical") ? .critical:.warning)} else {s.release(reason)}
            let hot=got.contains{$0.contains(ChatBoundary.crisisSupport)}
            check("interrupt (\(reason)) and hotline: \(text)", hot == expectHotline && !s.isBusy && (s.lines.last?.role == "support") == expectHotline)
            if reason == "lock" {
                s.suspended=false
                let expected=expectHotline ? 2:0
                check("resume repeats the hotline bubble only after crisis: \(text)", wait({got.count == expected},timeout:0.3) && got.count == expected && s.lines.filter{$0.role == "support"}.count == (expectHotline ? 1:0))
            }
        }
        for p in dummies where p.isRunning {p.terminate()}

        // Real anonymous pipes exercise full-buffer cancellation and EPIPE;
        // no subprocess, GUI, inference, recording, or system event is needed.
        let writer=PetChatInputWriter(),first=Pipe(),second=Pipe()
        let oldToken=UUID(),newToken=UUID()
        var errors=[String]()
        try writer.install(first.fileHandleForWriting,token:oldToken)
        let began=ProcessInfo.processInfo.systemUptime
        writer.enqueue(Data(repeating:65,count:2*1024*1024),token:oldToken){errors.append($0.localizedDescription)}
        check("full pipe enqueue does not block caller", ProcessInfo.processInfo.systemUptime-began < 0.1)
        var mainQueueRan=false
        DispatchQueue.main.async{mainQueueRan=true}
        check("main queue responsive during backpressure", wait({mainQueueRan},timeout:0.3))
        try writer.install(second.fileHandleForWriting,token:newToken)
        writer.enqueue(Data("STALE\n".utf8),token:oldToken){errors.append($0.localizedDescription)}
        writer.enqueue(Data("new-1\n".utf8),token:newToken){errors.append($0.localizedDescription)}
        writer.enqueue(Data("new-2\n".utf8),token:newToken){errors.append($0.localizedDescription)}
        let fresh=read(second.fileHandleForReading,minimum:12)
        check("retirement unblocks next destination", String(data:fresh,encoding:.utf8) == "new-1\nnew-2\n")
        check("retired writer never fails new generation", errors.isEmpty)
        writer.invalidate(oldToken)
        writer.enqueue(Data("kept\n".utf8),token:newToken){errors.append($0.localizedDescription)}
        check("stale invalidate does not close replacement", String(data:read(second.fileHandleForReading,minimum:5),encoding:.utf8) == "kept\n")
        writer.invalidate(newToken)

        let broken=PetChatInputWriter(),pipe=Pipe(),brokenToken=UUID()
        try broken.install(pipe.fileHandleForWriting,token:brokenToken)
        try pipe.fileHandleForReading.close()
        var failed=false,onMain=false
        broken.enqueue(Data("closed\n".utf8),token:brokenToken){_ in failed=true;onMain=Thread.isMainThread}
        check("broken pipe produces failure not SIGPIPE", wait({failed}))
        check("writer failure returns on main thread", onMain)
        broken.invalidate()
        try? first.fileHandleForReading.close();try? second.fileHandleForReading.close()

        return (checks,failures)
    }
}
