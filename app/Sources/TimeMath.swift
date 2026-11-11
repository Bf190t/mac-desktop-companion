import Foundation

/// Small models get spoken multi-step time sums wrong ("8 点半到、路上 40 分钟、洗漱 20 分钟，几点起床" /
/// "I need to be at work by 8:30 and the drive is 40 minutes, when should I leave?"). For that shape of
/// question the app computes the answer and appends it to the user's turn — next to generation, where
/// small models follow it more reliably than in the system prompt. Anything else returns nil and the
/// model answers on its own.
enum TimeMath {
    static func hint(for raw: String) -> String? {
        raw.range(of: #"[\x{4e00}-\x{9fff}]"#, options: .regularExpression) != nil ? chineseHint(for: raw) : englishHint(for: raw)
    }

    /// "be at work by 8:30 … 40 minutes … when should I leave / get up". Conservative on purpose.
    static func englishHint(for raw: String) -> String? {
        let text = raw.lowercased().replacingOccurrences(of: "’", with: "'")
        guard let action = firstCapture(#"(?:when|what time)\s+(?:should|do|must|shall)\s+i\s+(get up|wake up|leave|set off|head out|go|start)"#, in: text) else { return nil }
        let clock = #"(?:by|at|before|for)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#
        guard let regex = try? NSRegularExpression(pattern: clock),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(m.range(at: 1), in: text), var hour = Int(text[hourRange]), (0...24).contains(hour),
              let whole = Range(m.range, in: text) else { return nil }
        let minute = Range(m.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        let period = Range(m.range(at: 3), in: text).map { String(text[$0]) } ?? ""
        if period.hasPrefix("p"), hour < 12 { hour += 12 }
        if period.hasPrefix("a"), hour == 12 { hour = 0 }
        guard minute < 60 else { return nil }
        // Spoken fractions first, so "an hour and a half" is 90 minutes, not one hour.
        var rest = text.replacingCharacters(in: whole, with: ", ")
        for (pattern, replacement) in [(#"\b(?:an|one)\s+hour\s+and\s+a\s+half\b"#, "90 minutes"),
                                       (#"\b(\d+)\s+hours?\s+and\s+a\s+half\b"#, "$1.5 hours"),
                                       (#"\b(\d+)\s+and\s+a\s+half\s+hours?\b"#, "$1.5 hours"),
                                       (#"\bhalf\s+an\s+hour\b"#, "30 minutes"),
                                       (#"\ba\s+quarter\s+of\s+an\s+hour\b"#, "15 minutes")] {
            rest = rest.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        guard let dRegex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?|an?)\s*(?:-\s*)?(hours?|hrs?|minutes?|mins?)\b"#) else { return nil }
        var durations: [Int] = []
        for d in dRegex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
            guard let countRange = Range(d.range(at: 1), in: rest), let unitRange = Range(d.range(at: 2), in: rest) else { continue }
            let word = String(rest[countRange]), unit = String(rest[unitRange])
            let count = (word == "a" || word == "an") ? 1 : Double(word) ?? 0
            let minutes = Int((unit.hasPrefix("h") ? count * 60 : count).rounded())
            if minutes > 0 && minutes <= 12 * 60 { durations.append(minutes) }
        }
        guard !durations.isEmpty else { return nil }
        let total = durations.reduce(0, +)
        func wrap(_ m: Int) -> Int { (m % (24 * 60) + 24 * 60) % (24 * 60) }
        func clockText(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }
        let anchor = hour * 60 + minute
        let parts = durations.map { $0 < 60 ? "\($0) minutes" : $0 % 60 == 0 ? "\($0 / 60) hours" : "\($0 / 60) h \($0 % 60) min" }.joined(separator: ", ")
        return "(Already worked out by the app: to be there by \(clockText(wrap(anchor))), subtract \(parts), \(total) minutes in total, so \(action) by \(clockText(wrap(anchor - total))) at the latest. Use this time in your answer; do not recalculate.)"
    }

    static func chineseHint(for raw: String) -> String? {
        let text = raw.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard let action = firstCapture(#"(?:几点|什么时候)(起床|出门|出发|动身|走|醒|开始|准备|下楼)"#, in: text) else { return nil }
        let clock = #"(早上|上午|中午|下午|晚上|傍晚)?([0-9]{1,2}|[零〇一二两三四五六七八九十]{1,3})[点:：]((?:[0-9]{1,2}|[零〇一二三四五六七八九十]{1,3})分?|半|一刻|三刻)?"#
        guard let regex = try? NSRegularExpression(pattern: clock),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(m.range(at: 2), in: text), var hour = number(String(text[hourRange])), hour <= 24 else { return nil }
        let period = Range(m.range(at: 1), in: text).map { String(text[$0]) } ?? ""
        if ["下午", "晚上", "傍晚"].contains(period), hour < 12 { hour += 12 }
        var minute = 0
        if let r = Range(m.range(at: 3), in: text) {
            let part = String(text[r]).replacingOccurrences(of: "分", with: "")
            minute = part == "半" ? 30 : part == "一刻" ? 15 : part == "三刻" ? 45 : (number(part) ?? 0)
        }
        guard minute < 60, let whole = Range(m.range, in: text) else { return nil }
        // Is the clock a deadline ("8点半要到公司", "3点开会") or a start ("10点睡觉")? Otherwise stay out.
        let after = String(text[whole.upperBound...].prefix(8))
        let isDeadline = after.range(of: #"^(?:要|得|必须)?(?:前|之前)?(?:到|赶到|上班|开会|上课|集合|开始|的(?:高铁|火车|飞机|航班|车|会|课))"#, options: .regularExpression) != nil
        let isStart = after.range(of: #"^(?:就|才)?(?:睡|上床|躺)"#, options: .regularExpression) != nil
        guard isDeadline || isStart else { return nil }
        // A bedtime without 上午/下午 ("11点半睡") means the evening.
        if isStart, period.isEmpty, (6...12).contains(hour) { hour += 12 }
        // Durations are read from the rest of the sentence, so "8点20分" is not counted as 20 minutes.
        let rest = text.replacingCharacters(in: whole, with: "，")
        var durations: [Int] = []
        let durationPattern = #"([0-9]+|[零〇一二两三四五六七八九十百]+)?(个)?(半)?(个)?(小时|钟头|分钟|分(?![钟到]))"#
        guard let dRegex = try? NSRegularExpression(pattern: durationPattern) else { return nil }
        for d in dRegex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
            let count = Range(d.range(at: 1), in: rest).flatMap { number(String(rest[$0])) }
            let half = d.range(at: 3).location != NSNotFound
            let unit = Range(d.range(at: 5), in: rest).map { String(rest[$0]) } ?? ""
            let hourUnit = unit == "小时" || unit == "钟头"
            if count == nil && !half { continue }
            let minutes = hourUnit ? (count ?? 0) * 60 + (half ? 30 : 0) : (count ?? 0)
            if minutes > 0 && minutes <= 12 * 60 { durations.append(minutes) }
        }
        guard !durations.isEmpty else { return nil }
        let total = durations.reduce(0, +)
        let anchor = hour * 60 + minute
        func wrap(_ m: Int) -> Int { (m % (24 * 60) + 24 * 60) % (24 * 60) }
        func clockText(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }
        func span(_ m: Int) -> String { m < 60 ? "\(m) 分钟" : m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分钟" }
        let parts = durations.map(span).joined(separator: "、")
        if isStart {
            return "（程序已经算好：从 \(clockText(wrap(anchor))) 开始，往后加 \(parts)，所以大约 \(clockText(wrap(anchor + total))) \(action)。回答时直接用这个时间，不要自己重新计算。）"
        }
        return "（程序已经算好：要在 \(clockText(wrap(anchor))) 前到，往前减去 \(parts)，一共 \(total) 分钟，所以最晚 \(clockText(wrap(anchor - total))) \(action)。回答时直接用这个时间，不要自己重新计算。）"
    }

    /// Arabic digits or simple Chinese numerals up to 99 (十, 二十, 四十五, 两).
    static func number(_ s: String) -> Int? {
        if let v = Int(s) { return v }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if s == "十" { return 10 }
        if s.hasSuffix("百"), s.count == 2, let d = digits[s.first!] { return d * 100 }
        if let ten = s.firstIndex(of: "十") {
            let before = s[..<ten], after = s[s.index(after: ten)...]
            let tens = before.isEmpty ? 1 : (before.count == 1 ? digits[before.first!] : nil)
            let ones = after.isEmpty ? 0 : (after.count == 1 ? digits[after.first!] : nil)
            guard let t = tens, let o = ones else { return nil }
            return t * 10 + o
        }
        guard s.count == 1, let d = digits[s.first!] else { return nil }
        return d
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
