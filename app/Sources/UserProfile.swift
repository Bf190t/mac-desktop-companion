import Foundation

/// A small "about you" note the companion keeps on this Mac. It is filled from clear self-statements
/// in chat ("我叫阿杰", "我最喜欢绿色", "my name is Sam", "remember …") and can be edited or cleared in the
/// chat window. It is sent with every request so the model remembers across restarts without a long history.
struct UserProfile: Codable, Equatable {
    var name = ""
    var facts: [String] = []
    static let maxFacts = 10

    var isEmpty: Bool { name.isEmpty && facts.isEmpty }

    /// One line for the system prompt, or nil when nothing is known.
    var promptText: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []
        if !name.isEmpty { parts.append(L("称呼：\(name)", "Name: \(name)")) }
        parts += facts
        return L("你记得的关于用户的事（相关时自然提起，不要每句都提）：" + parts.joined(separator: "；") + "。",
                 "Things you remember about the user (mention them naturally when relevant, not in every reply): " + parts.joined(separator: "; ") + ".")
    }

    /// Applies what `text` says about the user. Returns short descriptions of what changed.
    @discardableResult mutating func learn(from text: String) -> [String] {
        let found = Self.extract(from: text)
        var changed: [String] = []
        if let name = found.name, name != self.name { self.name = name; changed.append(L("称呼 \(name)", "name \(name)")) }
        for fact in found.facts where !facts.contains(fact) {
            // A new like replaces the opposite dislike and vice versa.
            facts.removeAll { $0 == Self.opposite(of: fact) }
            facts.append(fact)
            changed.append(fact)
        }
        if facts.count > Self.maxFacts { facts.removeFirst(facts.count - Self.maxFacts) }
        return changed
    }

    static func opposite(of fact: String) -> String {
        if fact.hasPrefix("不喜欢") { return String(fact.dropFirst()) }
        if fact.hasPrefix("喜欢") { return "不" + fact }
        if fact.hasPrefix("doesn't like ") { return "likes " + fact.dropFirst("doesn't like ".count) }
        if fact.hasPrefix("likes ") { return "doesn't like " + fact.dropFirst("likes ".count) }
        return fact
    }

    /// Only clear first-person statements count. Speech-to-text filler (啊、那个、就是) is tolerated.
    static func extract(from raw: String) -> (name: String?, facts: [String]) {
        let english = extractEnglish(from: raw)
        let chinese = extractChinese(from: raw)
        return (chinese.name ?? english.name, chinese.facts + english.facts.filter { !chinese.facts.contains($0) })
    }

    /// English self-statements. Conservative: "I'm tired" or "I like you" never become facts.
    static func extractEnglish(from raw: String) -> (name: String?, facts: [String]) {
        let text = raw.replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "[A-Za-z]", options: .regularExpression) != nil, !text.hasSuffix("?") else { return (nil, []) }
        let notName = "not|a|an|the|so|very|just|really|going|back|later|when|if|tomorrow|tonight|now|soon|maybe|please|sometime|anytime|again"
        var name: String?
        for pattern in [#"(?i)\bmy name is\s+([A-Za-z][A-Za-z'-]{0,15})\b"#, #"(?i)\b(?:please\s+)?call me\s+([A-Za-z][A-Za-z'-]{0,15})\b"#, #"(?i)\bi'?m called\s+([A-Za-z][A-Za-z'-]{0,15})\b"#] {
            if let value = capture(pattern, in: text), value.range(of: "^(?i:\(notName))$", options: .regularExpression) == nil {
                name = value.prefix(1).uppercased() + value.dropFirst(); break
            }
        }
        var facts: [String] = []
        // "I don't like tea anymore" is about tea; the trailing word would block replacing "likes tea".
        func thing(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: #"\s+(any ?more|at all|now|either|too|so much|very much|a lot)$"#, with: "", options: .regularExpression)
        }
        let end = #"\s*(?=[.,!;]|\band\b|\bbut\b|$)"#
        // Feelings about oneself or life are never "likes" ("I hate my life" belongs to crisis support).
        let notThing = #"^(?i:you|it|that|this|him|her|them|mochi|to|when|it when|myself|me|my life|my self|life|living|being alive|everything|everyone|people|the world)\b"#
        if let value = capture(#"(?i)\bi\s+(?:really\s+|absolutely\s+)?(?:(?:don't|do not)\s+(?:really\s+)?(?:like|enjoy)|hate|dislike|can't stand)\s+([a-z][a-z0-9 '-]{1,30}?)"# + end, in: text),
           value.range(of: notThing, options: .regularExpression) == nil {
            facts.append("doesn't like " + thing(value))
        } else if let value = capture(#"(?i)\bi\s+(?:really\s+|absolutely\s+|also\s+)?(?:like|love|enjoy)\s+([a-z][a-z0-9 '-]{1,30}?)"# + end, in: text),
                  value.range(of: notThing, options: .regularExpression) == nil {
            facts.append("likes " + thing(value))
        }
        if let value = capture(#"(?i)\bi\s+work\s+as\s+(an?\s+[a-z][a-z -]{1,24}?)"# + end, in: text) { facts.append("works as " + value.lowercased()) }
        if let value = capture(#"(?i)\bi\s+(?:study|am studying|'m studying)\s+([a-z][a-z -]{1,24}?)"# + end, in: text) { facts.append("studies " + value.lowercased()) }
        if let match = captures(#"(?i)\bi\s+(work|study|live)\s+(?:in|at)\s+([A-Z][A-Za-z&' -]{1,30}?)"# + end, in: text) {
            facts.append("\(match[0].lowercased())s in \(match[1])")
        }
        if let value = capture(#"(?i)^(?:please\s+)?remember(?:\s+that)?[:,]?\s+(.{2,60}?)[.!]?$"#, in: text) {
            facts.append(value.replacingOccurrences(of: #"^(?i)i\s+"#, with: "", options: .regularExpression))
        }
        return (name, facts)
    }

    static func extractChinese(from raw: String) -> (name: String?, facts: [String]) {
        let text = raw.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let stop = #"(?=啊|呀|呢|吧|哦|啦|嘛|哈|就|然后|而且|，|,|。|！|!|？|\?|、|$|我|是|在|今年|做|你)"#
        let nameWord = #"([\x{4e00}-\x{9fa5}]{1,4}?|[A-Za-z]{1,12})"#
        let notName = #"(?!了|车|外卖|醒|人|你|他|她|它|做|啥|什么|谁|哪|起来|上)"#
        var name: String?
        for pattern in [#"我(?:的名字)?叫"# + notName + nameWord + stop,
                        #"我的名字是"# + notName + nameWord + stop,
                        #"叫我"# + notName + nameWord + #"(?=就行|就好|吧|好了|啊|呀|，|,|。|！|!|$)"#] {
            if let value = capture(pattern, in: text) { name = value; break }
        }
        var facts: [String] = []
        // Questions about oneself ("我喜欢啥颜色来着") are not statements.
        func statement(_ value: String) -> Bool { value.range(of: #"啥|什么|哪|谁|几|吗|来着|的是"#, options: .regularExpression) == nil }
        let likeStop = #"(?=啊|呀|呢|吧|哦|啦|嘛|和|还有|但|不过|你|，|,|。|！|!|？|\?|、|$)"#
        let thing = #"((?:吃|喝|看|听|玩)?[\x{4e00}-\x{9fa5}A-Za-z0-9]{1,8}?)"#
        if let value = capture(#"我(?:最|特别|超|很|真)?不喜欢"# + thing + likeStop, in: text), statement(value) {
            facts.append("不喜欢" + value)
        } else if let value = capture(#"我(?:最|特别|超|很|真)?喜欢"# + thing + likeStop, in: text), statement(value),
                  !["你", "您", "小团", "Mochi", "它", "他", "她"].contains(value) {
            facts.append("喜欢" + value)
        }
        if let match = captures(#"我是(做|搞|学)([\x{4e00}-\x{9fa5}A-Za-z]{1,6}?)的"#, in: text), statement(match[1]) { facts.append("\(match[0])\(match[1])的") }
        // "我在杭州上班" or "我叫小林，在杭州上班" — but not "我老婆在北京上班".
        if let match = captures(#"(?:我|^|[，,])(?:现在)?在([\x{4e00}-\x{9fa5}]{1,8}?)(上班|工作|上学|读书|念书)"#, in: text), statement(match[0]) {
            facts.append("在\(match[0])\(match[1])")
        }
        if let value = capture(#"^(?:嗯|那个|就是)*(?:请|帮我)?记(?:住|一下)[：:，,]?(.{2,30}?)[。！!]?$"#, in: text),
           !value.hasPrefix("了"), statement(value) {
            facts.append(value.hasPrefix("我") ? String(value.dropFirst()) : value)
        }
        return (name, facts)
    }

    private static func capture(_ pattern: String, in text: String) -> String? { captures(pattern, in: text)?.first }
    private static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1 else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
