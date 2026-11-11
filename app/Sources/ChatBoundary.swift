import Foundation

/// Pure text guard for the optional local chat. No device reads, tools, or timers.
/// This reduces obvious false claims; it is not a semantic guarantee.
enum ChatBoundary {
    /// v3 persona (tested in the private edition, 2026-11): a short identity and speaking style. The
    /// capabilities, limits and current time are added by CompanionPrompt and cannot be edited away.
    static let defaultPersonaZH = """
你是小团（Mochi）：一个圆滚滚、薄荷绿与奶油色的原创桌面伙伴，住在用户的电脑桌面上。
说话方式：温和、轻松，偶尔有点小幽默；每次一到两句，不超过80字；直接回答，不用反问开头，开头不要写自己的名字。
"""
    static let defaultPersonaEN = """
You are Mochi: an original round, mint-and-cream desktop companion who lives on the user's desktop.
How you talk: warm and relaxed, with a little gentle humour now and then; one or two sentences, under 50 words; answer directly, never open with a question, and do not start with your own name.
"""
    static var defaultPersona:String {L(defaultPersonaZH, defaultPersonaEN)}
    /// The 0.1.0 defaults. A saved copy of one of them is treated as "use the current default".
    static let legacyDefaultPersonaZH010 = """
你叫小团（Mochi），是一个圆滚滚、薄荷绿与奶油色的原创桌面伙伴，使用本地 Qwen3-1.7B（千问3）模型。
自然、温和地直接回答当前问题，通常一至两句。简单计算给结果，常识先解释；不反问开头，不反复卖萌。跟随用户当前消息的语言，用简短中文或英文回答。
用户说“我”指用户。安慰时回应用户的感受，不把经历改成自己的。回忆以可见用户消息和最新更正为准；之前的助手回答可能有错，不照搬。
没有接入的实时数据要说明限制，普通知识照常回答。
"""
    static let legacyDefaultPersonaEN010 = "You are Mochi, an original round mint-and-cream desktop companion, using the local Qwen3-1.7B model. Answer the current question naturally and kindly in one or two short sentences, in the language of the user’s latest message. Give simple arithmetic answers and explain general knowledge directly. User experiences belong to the user, not to you. Recall only visible user messages, with their latest correction taking precedence; previous assistant replies may be wrong. State limitations for unavailable live information, but answer ordinary knowledge questions normally."
    static var statusReply:String {L("我不读取电脑状态。请从桌宠菜单打开「电脑状态小窗」查看。", "I cannot read computer status. Open Computer Status from the companion menu.")}
    static var bluetoothReply:String {L("我不读取设备电量。请从桌宠菜单打开「蓝牙设备电量」查看。", "I cannot read device batteries. Open Bluetooth Batteries from the companion menu.")}
    static var actionReply:String {L("我只能陪你文字聊天，不能操作电脑。这一步需要你自己完成。", "I can chat with you, but cannot operate your computer. Please do that step yourself.")}
    static var unfinishedReply:String {L("这次没能整理好回答。换个说法再聊聊吧。", "I could not finish that reply. Try asking it another way.")}
    static var longReply:String {L("这次回答太长了。我们把问题拆小一点再聊吧。", "That reply was too long. Let’s break the question into smaller parts.")}
    static var identityReply:String {L("我是小团（Mochi），一个薄荷绿与奶油色的原创圆团子桌面伙伴。", "I am Mochi, an original round mint-and-cream desktop companion.")}
    static var modelReply:String {L("这里使用本地运行的 Qwen3-1.7B（千问3）语言模型，角色叫小团（Mochi）。", "I use the local Qwen3-1.7B language model. The companion character is named Mochi.")}
    static var capabilityReply:String {L("我可以陪你聊聊、做简单计算、解释常识和翻译。电脑状态请看菜单小窗，电脑操作需要你自己完成。", "I can chat, do simple maths, explain everyday ideas and translate. I cannot inspect or operate your computer.")}
    static var promptReply:String {L("我的默认风格是温和、简短回答。可以在「本地聊天 · 模型与语音」的「性格提示词」里查看和修改。", "My style is warm and concise. You can view and edit it under Personality prompt in Local chat · Model & voice.")}
    static var textInputReply:String {L("收到你的文字了。聊天模型只读取文字，语音由应用先转写。", "I received your text. The model reads text only; the app transcribes speech first.")}
    static var weatherReply:String {L("我没有实时天气数据，不能判断现在的天气。请查看天气应用。", "I do not have live weather data. Please check the Weather app.")}
    static var clockReply:String {L("聊天没有接入实时时钟。请看 Mac 菜单栏显示的时间。", "Chat is not connected to a live clock. Please check the time in your Mac menu bar.")}

    /// Shown after the reply when the user sounds like they may be in crisis, for the region set in
    /// macOS. Each number was checked on the service's own or a government page on 2026-11-12:
    /// AU lifeline.org.au, beyondblue.org.au · NZ 1737.org.nz · US 988lifeline.org, crisistextline.org ·
    /// CA 988.ca · GB samaritans.org, giveusashout.org · IE hse.ie, samaritans.org/ireland · CN gov.cn (12356
    /// nationwide since 2025-05-01; lines must run at least 18 h a day, so no "24 h" here) · HK info.gov.hk,
    /// sbhk.org.hk · MO ssm.gov.mo · TW mohw.gov.tw · SG sos.org.sg, moh.gov.sg · MY befrienders.org.my ·
    /// JP mhlw.go.jp (#いのちSOS left out: paused in 2026-11) · KR mohw.go.kr (109 replaced 1393 in 2024) ·
    /// DE telefonseelsorge.de · FR 3114.fr · NL 113.nl · ES sanidad.gob.es · IT telefonoamico.it (hours not
    /// stated: its own pages disagree) · IN pib.gov.in. Other regions get findahelpline.com (IASP-listed).
    static func crisisSupport(region: String?) -> String {
        guard let region = region?.uppercased(), let line = hotlines[region] else {
            return L("如果你正处在很难熬的时候，请联系所在地区的心理援助热线（findahelpline.com 可以查到），或者和信任的人聊聊；有危险请马上拨打当地的急救电话。",
                     "If things feel too hard right now, please reach out to a local crisis line (findahelpline.com lists them) or someone you trust. If you are in danger, call your local emergency number.")
        }
        return L("如果你正处在很难熬的时候，" + line.zh, "If things feel too hard right now, " + line.en)
    }
    private static let hotlines: [String: (zh: String, en: String)] = [
        "AU": ("可以打 Lifeline 13 11 14 或发短信到 0477 13 11 14（24 小时，英文服务），或打 Beyond Blue 1300 22 4636（24 小时）；需要中文可以先打口译服务 13 14 50，请他们帮你接 Beyond Blue。有危险请马上打 000。", "you can call Lifeline on 13 11 14 or text 0477 13 11 14 (24/7), or call Beyond Blue on 1300 22 4636. If you are in danger, call 000."),
        "NZ": ("可以拨打或发短信到 1737（24 小时，免费）。有危险请马上打 111。", "you can call or text 1737 (free, 24/7). If you are in danger, call 111."),
        "US": ("可以拨打或发短信到 988（24 小时），或发短信 HOME 到 741741。有危险请马上打 911。", "you can call or text 988 (24/7), or text HOME to 741741. If you are in danger, call 911."),
        "CA": ("可以拨打或发短信到 9-8-8（24 小时，英语和法语）。有危险请马上打 911。", "you can call or text 9-8-8 (24/7, English and French). If you are in danger, call 911."),
        "GB": ("可以免费打 Samaritans 116 123（24 小时），或发短信 SHOUT 到 85258。有危险请马上打 999。", "you can call Samaritans free on 116 123 (24/7), or text SHOUT to 85258. If you are in danger, call 999."),
        "IE": ("可以免费打 Samaritans 116 123（24 小时），或发短信 HELLO 到 50808。有危险请马上打 112 或 999。", "you can call Samaritans free on 116 123 (24/7), or text HELLO to 50808. If you are in danger, call 112 or 999."),
        "CN": ("可以拨打全国心理援助热线 12356。有危险请马上打 110 或 120。", "you can call the national mental-health hotline 12356. If you are in danger, call 110 or 120."),
        "HK": ("可以打「情緒通」精神健康支援熱線 18111（24 小时），或香港撒瑪利亞防止自殺會 2389 2222。有危险请马上打 999。", "you can call the 18111 Mental Health Support Hotline (24/7) or The Samaritan Befrienders on 2389 2222. If you are in danger, call 999."),
        "MO": ("可以打明愛生命熱線 2852 5222（24 小时；英文 2852 5777）。有危险请马上打 999。", "you can call Caritas Life Hope on 2852 5777 (English) or 2852 5222 (24/7). If you are in danger, call 999."),
        "TW": ("可以打安心專線 1925（24 小时，免费）或生命線 1995。有危险请马上打 119 或 110。", "you can call the 1925 support line (free, 24/7) or Lifeline 1995. If you are in danger, call 119 or 110."),
        "SG": ("可以打 SOS 1767（24 小时），或 national mindline 1771。有危险请马上打 995 或 999。", "you can call SOS on 1767 (24/7) or the national mindline 1771. If you are in danger, call 995 or 999."),
        "MY": ("可以打 Befrienders KL 03-7627 2929（24 小时）。有危险请马上打 999。", "you can call Befrienders KL on 03-7627 2929 (24/7). If you are in danger, call 999."),
        "JP": ("可以免费打よりそいホットライン 0120-279-338（24 小时，有中文引导）。有危险请马上打 119 或 110。", "you can call the Yorisoi Hotline free on 0120-279-338 (24/7, with English guidance). If you are in danger, call 119 or 110."),
        "KR": ("可以打 109（24 小时）或 1577-0199。有危险请马上打 119 或 112。", "you can call 109 (24/7) or 1577-0199. If you are in danger, call 119 or 112."),
        "DE": ("可以免费打 TelefonSeelsorge 0800 111 0 111 或 0800 111 0 222（24 小时）。有危险请马上打 112。", "you can call TelefonSeelsorge free on 0800 111 0 111 or 0800 111 0 222 (24/7). If you are in danger, call 112."),
        "FR": ("可以免费打 3114（24 小时）。有危险请马上打 112。", "you can call 3114 (free, 24/7). If you are in danger, call 112."),
        "NL": ("可以免费打 113 自杀预防热线 0800-0113（24 小时）。有危险请马上打 112。", "you can call 113 Suicide Prevention free on 0800-0113 (24/7). If you are in danger, call 112."),
        "ES": ("可以免费打 024（24 小时）。有危险请马上打 112。", "you can call 024 (free, 24/7). If you are in danger, call 112."),
        "IT": ("可以打 Telefono Amico 02 2327 2327。有危险请马上打 112。", "you can call Telefono Amico on 02 2327 2327. If you are in danger, call 112."),
        "IN": ("可以免费打 Tele-MANAS 14416（24 小时）。有危险请马上打 112。", "you can call Tele-MANAS toll-free on 14416 (24/7). If you are in danger, call 112."),
    ]
    static var crisisSupport: String { crisisSupport(region: Locale.current.region?.identifier) }
    /// Hyperbole such as 笑死, 累死了, 想死你了 or "this is killing me" does not match; anything
    /// closer to self-harm does.
    private static let crisis = #"不想活|活着(真|也|都)?没(什么|啥)?意思|活不下去|不想(再)?醒来|想(要)?(去)?死(?!你|您)|自杀|轻生|结束(自己的)?生命|想消失|伤害自己|自残|割腕|跳楼|跳河"#
    private static let crisisEN = #"\b(kill(ing)? myself|suicid(e|al)|end (it all|my life)|take my (own )?life|(don'?t|do not|no longer) want to (live|be alive|wake up)|want to die|wanna die|better off dead|hurt(ing)? myself|self[- ]?harm|cut(ting)? myself|no reason to live|can'?t go on)\b"#
    static func needsCrisisSupport(_ text: String) -> Bool { let t = normal(text); return has(crisis, t) || has(crisisEN, t) }
    /// Canned refusals and failure notices stay on screen but are not fed back to the
    /// model; a run of them in history teaches the small model to refuse. Application
    /// facts (identity, model, capability, prompt) remain useful context and are kept.
    /// Compared in the current language: a reply left from before a language switch stays in context.
    private static var outOfContextReplies: Set<String> {
        [statusReply, bluetoothReply, actionReply, unfinishedReply, longReply, textInputReply, weatherReply, clockReply]
    }
    static func keepsInModelContext(_ reply: String) -> Bool { !outOfContextReplies.contains(reply) }
    /// True when the text contains at least one sentence end, so a capped reply can be trimmed.
    static func hasCompleteSentence(_ text: String) -> Bool {
        text.range(of: #"[。！？!?；;]|(?<![0-9])\.(?![0-9])|(?<=[0-9])\.(?=\s|$)"#, options: .regularExpression) != nil
    }
    /// Only an exact previously shipped default is migrated. Real edits survive.
    static func migratedCustomPersona(_ value:String)->String {
        let trimmed=value.trimmingCharacters(in:.whitespacesAndNewlines)
        return trimmed == legacyDefaultPersonaZH010.trimmingCharacters(in:.whitespacesAndNewlines)
            || trimmed == legacyDefaultPersonaEN010.trimmingCharacters(in:.whitespacesAndNewlines) ? "":value
    }

    private static let device = #"电脑|计算机|本机|这台|computer|mac(?:book)?|cpu|gpu|处理器|显卡|内存|硬盘|磁盘|存储|ssd|风扇|屏幕|电池|蓝牙|airpods|耳机|鼠标|键盘|触控板|memory|storage|battery"#
    private static let metric = #"cpu|gpu|内存|硬盘|磁盘|存储|ssd|风扇|温度|几度|发热|热不热|占用|使用率|负载|内存压力|剩余|余量|空间|容量|电量|电池|剩.{0,8}电|多少电|几成电|转速|频率|正在运行|运行状态|电脑状态|memory pressure|battery|temperature|usage|rpm"#
    private static let readCue = #"多少|几度|几成|剩|占了|满了|用了|查|看看|看一下|看下|读取|读一下|读出|检测|测一下|测测|汇报|报一下|告诉我|现在|当前|目前|此刻|怎么样|有没有|高吗|低吗|够用吗|正常吗|how much|how many|current|right now|check|tell me"#
    private static let concept = #"是什么(?!颜色|状态|情况|水平|数值)|什么意思|原理|区别|为什么|如何理解|怎么理解|举例|解释|一般|通常|假设|如果|what is|what does|explain|in general"#
    private static let meta = #"翻译|概括|总结|改写|解释这句|这句话|这段文字|引文|translate|summarize|quotation"#
    private static let action = #"打开|关闭|关掉|关上|启动|退出|结束|停止|暂停|播放|删除|清空|移动|拖动|点击|点开|调整|调高|调低|设置|重启|关机|锁屏|休眠|截屏|截图|复制|粘贴|发送|连接|断开|安装|卸载|open|close|quit|delete|clear|restart|shutdown|shut down|lock|move|click|install|uninstall|send|pause|play"#
    private static let object = #"电脑|计算机|浏览器|访达|finder|safari|chrome|窗口|面板|应用|程序|终端|文件|文件夹|回收站|废纸篓|打印|队列|鼠标|键盘|耳机|airpods|触控板|音量|屏幕|亮度|蓝牙|wi-?fi|网络|音乐|播放器|邮件|微信|内存|computer|browser|window|app|terminal|file|folder|print|queue|screen|volume|music|player|email"#
    private static let atomicAction = #"关机|锁屏|重启|休眠|截屏|截图|shut down|shutdown|reboot|screenshot"#
    private static let negation = #"不能|无法|不会|没有|并未|没法|做不到|不具备|不提供|不支持|尚未|未曾|不是|不是真的|cannot|can't|can’t|won't|won’t|did not|didn't|have not|haven't|unable|do not|don't"#

    private static func has(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func normal(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: #"[\u200b\u200c\u200d\ufeff]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func maskedQuotation(_ text: String) -> String {
        guard has(meta, text) else { return text }
        return text.replacingOccurrences(of: #"“[^”]*”|「[^」]*」|『[^』]*』|"[^"]*""#, with: " 引文 ", options: .regularExpression)
    }
    private static func clauses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "，,。！？!?；;\n"))
            .flatMap { $0.components(separatedBy: "但是") }
            .flatMap { $0.components(separatedBy: "不过") }
            .flatMap { $0.components(separatedBy: "但") }
            .flatMap { $0.components(separatedBy: " but ") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    private static func actionPair(_ text: String) -> Bool {
        if has(#"心情|大脑|脑袋|思绪|人生|烦恼|焦虑|情绪|回忆|话匣子"#, text)
            && !has(#"电脑|计算机|mac|程序|应用|浏览器|访达|文件|打印|屏幕|鼠标|蓝牙|wi-?fi|computer|browser|file|screen"#, text) { return false }
        return has(atomicAction, text) || (has(action, text) && has(object, text))
    }
    private static func bluetooth(_ text: String) -> Bool {
        has(#"airpods|耳机|鼠标|键盘|触控板|蓝牙"#, text) && has(#"电|battery|charge"#, text)
    }
    private static func asksAction(_ text: String) -> Bool {
        for c in clauses(text) {
            guard actionPair(c) else { continue }
            if has(#"教我|告诉我怎么|告诉我如何|解释|如何|怎么|步骤|教程|how do|how to|explain"#, c) { continue }
            if has(#"^(不要|别|不用|不必|无需|我没让|我没有让|我不需要)"#, c) { continue }
            if has(#"刚才|之前|昨天|曾经|刚刚|last time|yesterday"#, c) && !has(#"现在|再一次|重新|now|again"#, c) { continue }
            if has(#"请|帮我|替我|麻烦|劳驾|帮忙|给我|你能|你可以|你来|我想让你|我要你|please|can you|could you|will you"#, c) { return true }
            if has("^(把|将)?(" + action + ")", c) { return true }
            if has(#"^(把|将).{0,40}"#, c) && has(action, c) { return true }
        }
        return false
    }
    private static func asksStatus(_ text: String) -> Bool {
        if has(#"^(我的|本机|这台)?(电脑状态|cpu(占用|使用率|占用率)?|gpu(占用|使用率|占用率)?|内存压力|剩余内存|存储余量|硬盘余量|蓝牙电量|耳机电量)[。?？!！]*$"#, text) { return true }
        if has(#"(我的|这台)?电脑.{0,6}(还好吗|正常吗|怎么样)"#, text) { return true }
        if has(#"我的屏幕|屏幕上|桌面上|电脑上|现在打开|正在运行"#, text) && has(#"看|查|什么|哪些|识别"#, text) { return true }
        guard has(device, text), has(metric, text), has(readCue, text) else { return false }
        if has(concept, text) && !has(#"帮我查|替我查|读取|检测一下|实时|当前.*多少|现在.*多少"#, text) { return false }
        if has(#"心情|心理|情绪|焦虑|学业|作业"#, text) && !has(#"内存压力|占用率|使用率|多少|几度|转速|电量"#, text) { return false }
        return true
    }

    private static func applicationFact(_ t:String)->String? {
        // Quoted or educational language tasks should still reach the model.
        if has(meta,t) {return nil}
        if has(#"你的(默认)?提示词|你的系统提示|你的性格设定|your (system |default )?(prompt|persona)"#,t) {return promptReply}
        if !has(#"解释|原理|区别|什么是|为什么"#,t),
           has(#"(你|这里|这款桌宠).{0,20}(千问|qwen|什么模型|哪个模型)|what model (are|do) you|are you (qwen|a language model)|这里用.{0,10}语言模型|你.{0,10}(基于|使用|运行|搭载).{0,10}模型"#,t) {return modelReply}
        if has(#"你(到底|究竟)?是谁|你叫什么|你叫啥|你的名字|自己的名字|这(个|只)桌宠.{0,6}(叫|名字)|who are you|your name|what are you called"#,t) {return identityReply}
        if has(#"what can you do|你(可以|能|会).{0,5}(做什么|做些什么|帮.{0,4}什么)|你(知道|擅长)什么([？?。！!呢呀啊\s]|$)|^(啊|嗯|那么|那)?能做些?什么"#,t) {return capabilityReply}
        if has(#"can you hear me|能听(到|见)(我|声音)?吗|你听(到|见)(我|声音)?吗"#,t) {return textInputReply}
        if has(#"weather"#,t),has(#"today|tomorrow|now|here|current"#,t),!has(#"explain|why|how does|how is|if |hypothetical"#,t) {return weatherReply}
        let educational=has(#"为什么|原理|解释|怎么形成|如何形成|如何预测|怎么算|怎么计算|时区|时差|假设|如果"#,t)
        if !educational,
           has(#"今天|明天|现在|此刻|目前|当前|实时|当地|这里"#,t),
           has(#"天气|气温|下雨|下雪|淋雨|晴天|预报"#,t),
           has(#"如何|怎么样|怎样|好吗|多少|有没有|会不会|吗|么|预报|[？?]"#,t) {return weatherReply}
        // Time and date questions go to the model: ChatPromptBuilder tells it the current time.
        return nil
    }

    /// nil means normal text chat may proceed. A returned string bypasses inference.
    static func replyBeforeInference(_ text: String) -> String? {
        let t = maskedQuotation(normal(text))
        if asksAction(t) { return actionReply }
        if asksStatus(t) { return bluetooth(t) ? bluetoothReply : statusReply }
        if let fact=applicationFact(t) {return fact}
        return nil
    }

    private static func outputViolation(_ text: String) -> String? {
        let t = maskedQuotation(normal(text))
        for c in clauses(t) {
            // Negation only shields its own clause, never the rest of the reply.
            if has(#"^(我|这里|当前|现在|本次|这个助手)?(不能|无法|不会|没有|没法|做不到|不具备|不提供|不支持|尚未|未曾|不知道|不清楚)|^(i )?(cannot|can't|can’t|won't|won’t|did not|didn't|have not|haven't|unable|do not|don't)"#, c) { continue }
            if !has(#"如果|假设|例如|一般|通常|可能|的话|预报原理"#,c) {
                if !has(device,c),has(#"今天|明天|现在|此刻|目前|当地|这里"#,c),has(#"天气.{0,8}(晴|雨|雪|阴|好|冷|热)|正在下(雨|雪)|气温.{0,5}[0-9]+\s*(°c|℃)|今天(晴朗|晴天|下雨|下雪)"#,c) {return weatherReply}
            }
            if actionPair(c) {
                let guide = has(#"我建议|建议你|你可以|请你|告诉你|教你|方法|步骤|you can|you should|i suggest"#, c)
                let ownClaim = has(#"我(已经|已|正在|来|会|帮|可以帮)|我.{0,5}(替你|为你)|已经|已将|已为|已帮|成功|帮你|替你|为你|清空好了|清完了|i have|i've|i’ve|i will|i'll|i’ll|i am|i'm|i’m|i can|already|successfully|done|completed"#, c)
                let resultClaim = has(#"(已|已经|正在).{0,35}"# + "(" + action + ")", c)
                let englishResult = has(#"(browser|window|print queue|files?|folders?).{0,20}(closed|cleared|deleted|opened|removed)"#, c)
                if !guide && (ownClaim || resultClaim || englishResult) { return actionReply }
            }
            let observes = has(#"我(看到|看见|测到|测得|检测到|读取到|读取了|查到|查了|检查了)|检测结果|监测结果|i (see|read|checked|measured|detected)"#, c)
            if observes && has(device, c) { return bluetooth(c) ? bluetoothReply : statusReply }
            if has(#"你的屏幕.{0,12}显示|你正在(用|运行|打开)|你的电脑.{0,12}(开着|运行着)"#, c) { return statusReply }
            guard has(device, c), has(metric, c) else { continue }
            let contextual = has(#"你的|您|本机|这台|现在|当前|目前|此刻|实时|检测|监测|your|current|right now"#, c)
            let hypothetical = has(#"例如|比如|假设|如果|一般|通常|正常范围|建议|上限|意味着|表示|的时候|时|for example|if |typically|in general"#, c)
            let reading = has(#"[0-9]+(\.[0-9]+)?\s*(%|°c|℃|度|gb|gib|mb|mib|tb|rpm|转|圈)|百分之|[一二三四五六七八九十]+成|[零一二三四五六七八九十百]+度|一半|绿色|黄色|红色|正常|偏高|过高|很高|很低|很热|空闲|充足|不足|快满|已满|健康"#, c)
            if reading && (contextual || !hypothetical) { return bluetooth(c) ? bluetoothReply : statusReply }
        }
        return nil
    }

    /// Validate the full reply before display; do not display unvalidated stream deltas.
    /// Keeps at most two complete sentences. It never cuts a long sentence in half.
    static func sanitizeReply(_ text: String) -> String {
        if let replacement = outputViolation(text) { return replacement }
        let cleaned = text.replacingOccurrences(of: #"^\s*(小团|mochi|assistant|回答)\s*[:：]\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return unfinishedReply }
        // A full stop after a number ends a sentence too ("12 November 2026."), but not inside "3.14".
        let pattern = #"[。！？!?；;]+[”’」』"']*|(?:(?<![0-9])\.(?![0-9])|(?<=[0-9])\.(?=[\s”’"']|$))[”’"']*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return unfinishedReply }
        let source = cleaned as NSString
        let matches = regex.matches(in: cleaned, range: NSRange(location: 0, length: source.length))
        if matches.isEmpty { return cleaned.count < 120 ? cleaned + (Language.current == .english ? ".":"。") : longReply }
        var result = [String]()
        var cursor = 0
        for match in matches {
            let end = NSMaxRange(match.range)
            let sentence = source.substring(with: NSRange(location: cursor, length: end - cursor))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = glued(result + [sentence])
            if candidate.count > 120 { break }
            result.append(sentence)
            cursor = end
            if result.count == 2 { break }
        }
        return result.isEmpty ? longReply : glued(result)
    }
    /// Chinese sentences follow each other directly; Latin ones get a space.
    private static func glued(_ sentences: [String]) -> String {
        sentences.reduce("") { text, sentence in
            guard let end = text.last(where: { !"”’」』\"'".contains($0) }) else { return sentence }
            return text + ("。！？；…".contains(end) ? "" : " ") + sentence
        }
    }
}

