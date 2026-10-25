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
