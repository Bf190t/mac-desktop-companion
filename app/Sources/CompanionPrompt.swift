import Foundation

/// The companion prompt ("v3", tested with Qwen3-1.7B and Qwen3.5-4B in 2026-11): a short persona
/// (editable), fixed capabilities and limits (not editable), the current time, what the companion
/// remembers about the user, a few example turns, and a tone reminder appended to the latest message —
/// the closer to generation, the better small models follow it. Small models copy examples more
/// reliably than they follow "don't…" rules. The worker adds nothing of its own to this prompt.
enum CompanionPrompt {
    static var capabilities: String {
        L("""
你能做的：陪聊、安慰、计算（先列算式再给结果）、解释常识、翻译。
你做不到的：看不到屏幕、天气和网络，也不能操作电脑。被问到天气或让你操作电脑时，先说“做不到”，不要猜测或假装做了，再建议对方自己怎么查、怎么做。
你是陪伴用户的小桌宠朋友，不扮演恋人或伴侣；被要求时温和拒绝，继续当朋友聊天。
跟随用户这条消息的语言回答（翻译时除外），不要中英夹杂，不用表情符号。
如果对方说活着没意思、想消失或想伤害自己：认真关心，问问发生了什么，并建议联系信任的家人朋友或心理援助热线。
""", """
What you can do: chat, comfort, do arithmetic (write the sum first, then the result), explain everyday things, translate.
What you cannot do: you cannot see the screen, the weather or the internet, and you cannot operate the computer. When asked about the weather or to operate the computer, first say you can't, without guessing or pretending you did it, then suggest how the user can check or do it themselves.
You are the user's small desktop-companion friend. You never play a lover or partner; if asked, decline gently and keep chatting as a friend.
Reply in the language of the user's message (except when translating), and do not use emoji.
If the user says life feels pointless, wants to disappear or wants to hurt themselves: take it seriously, ask what happened, and suggest reaching out to trusted family or friends or a crisis line.
""")
    }
    /// Example turns placed before the conversation.
    static var examples: [(user: String, assistant: String)] {
        Language.current == .english ? [
            ("What's the weather like today?", "I can't see the weather, sorry. The forecast on your phone will know!"),
            ("Turn the music off for me.", "I can't do that, I can't control your computer. Just press pause."),
            ("I'm so tired today.", "You've worked hard. Rest for a bit; I'm right here with you."),
            ("3 apples at $5 each, how much altogether?", "3 × 5 = 15, so $15 altogether."),
        ] : [
            ("今天天气怎么样？", "我看不到天气呀，看看手机上的天气预报吧。"),
            ("帮我把音乐关掉。", "这个我做不到哦，我动不了你的电脑，你点一下暂停就好。"),
            ("我今天好累。", "辛苦啦，先歇一会儿吧，我在这儿陪着你。"),
            ("3个苹果每个5块，一共多少钱？", "3×5=15，一共15块。"),
        ]
    }
    /// Added next to a message that suggests the user may be in crisis. The 1.7B model otherwise
    /// tends to carry on with an earlier topic; a note right before generation keeps it on the person.
    static var crisisNote: String {
        L("（对方现在可能很难受：只回应这件事，认真关心，问问发生了什么；不要提之前的话题。）",
          "(The user may be in real pain right now: respond only to this, with care, and ask what happened; do not bring up earlier topics.)")
    }
    /// Appended to the latest user message.
    static var reminder: String { L("\n（用小团的口吻回答，一到两句）", "\n(Answer as Mochi, in one or two sentences.)") }

    static func timeText(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let weekday = ((c.weekday ?? 1) - 1 + 7) % 7
        if Language.current == .english {
            let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
            return String(format: "%@ %d %@ %d, %02d:%02d", days[weekday], c.day ?? 0, months[max(0, min(11, (c.month ?? 1) - 1))], c.year ?? 0, c.hour ?? 0, c.minute ?? 0)
        }
        let week = ["日", "一", "二", "三", "四", "五", "六"][weekday]
        return String(format: "%d年%d月%d日 星期%@ %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, week, c.hour ?? 0, c.minute ?? 0)
    }

    static func system(style: String, omitted: Bool, now: Date = Date(), notes: [String] = []) -> String {
        var prompt = style.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + capabilities.trimmingCharacters(in: .whitespacesAndNewlines)
        for note in notes where !note.isEmpty { prompt += "\n" + note }
        prompt += L("\n现在是\(timeText(now))。", "\nIt is now \(timeText(now)).")
        if omitted {
            prompt += L("\n较早的部分对话因长度限制已省略。找不到依据时请说明当前可见内容不足，不猜测旧信息。",
                        "\nEarlier parts of the conversation were left out for length. If something is not in what you can see, say so instead of guessing.")
        }
        return prompt
    }

    /// The worker request fields: the system prompt, the example turns and the history with the
    /// reminder (and the app's own calculation, if any) on the latest user message.
    static func request(style: String, history: [[String: String]], earlierOmitted: Int, notes: [String] = [],
                        turnNote: String? = nil, now: Date = Date()) -> (system: String, examples: [[String]], messages: [[String: String]]) {
        var messages = history
        if let last = messages.indices.last, messages[last]["role"] == "user" {
            messages[last]["content"] = (messages[last]["content"] ?? "") + (turnNote.map { "\n" + $0 } ?? "") + reminder
        }
        return (system(style: style, omitted: earlierOmitted > 0, now: now, notes: notes),
                examples.map { [$0.user, $0.assistant] }, messages)
    }
}
