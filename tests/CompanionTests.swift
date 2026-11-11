import Foundation

/// Companion chat logic without a model: time maths, the "about you" memory, crisis support lines
/// and the prompt assembly, in both interface languages. Preferences are isolated.
@main struct CompanionTests {
    static func main() {
        let domain = "io.github.bf190t.desktop-companion.test.companion." + UUID().uuidString
        let previous = Language.defaults
        let isolated = UserDefaults(suiteName: domain)!
        Language.defaults = isolated
        defer { Language.defaults = previous; isolated.removePersistentDomain(forName: domain) }
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { fatalError("FAIL: \(name)") }
            passed += 1
        }

        // Time maths (language follows the question, not the interface).
        let zh = TimeMath.hint(for: "我8点半要到公司，路上40分钟，几点起床？") ?? ""
        check(zh.contains("7:50") && zh.contains("起床"), "zh deadline minus travel")
        check((TimeMath.hint(for: "11点半睡，要睡8个小时，几点起床") ?? "").contains("7:30"), "zh bedtime plus sleep")
        check(TimeMath.hint(for: "现在几点了？") == nil, "zh plain time question left to the model")
        let en = TimeMath.hint(for: "I need to be at work by 8:30 and the drive takes 40 minutes, when should I leave?") ?? ""
        check(en.contains("7:50") && en.contains("leave"), "en deadline minus travel")
        check((TimeMath.hint(for: "When should I get up if I have to be there at 9am and it takes an hour and a half?") ?? "").contains("7:30"), "en an hour and a half")
        check((TimeMath.hint(for: "What time should I leave? I need to be there by 2:15pm, half an hour away.") ?? "").contains("13:45"), "en pm and half an hour")
        check(TimeMath.hint(for: "What time is it?") == nil, "en plain time question left to the model")

        // The "about you" memory: clear first-person statements only.
        var profile = UserProfile()
        profile.learn(from: "My name is sam, and I like green tea.")
        check(profile.name == "Sam", "en name")
        check(profile.facts.contains("likes green tea"), "en like")
        profile.learn(from: "I don't like green tea anymore.")
        check(profile.facts.contains("doesn't like green tea anymore") || profile.facts.contains("doesn't like green tea"), "en dislike")
        check(!profile.facts.contains("likes green tea"), "dislike replaces like")
        var quiet = UserProfile()
        quiet.learn(from: "I like you."); quiet.learn(from: "Do you like cats?"); quiet.learn(from: "I'm so tired.")
        quiet.learn(from: "I don't want to live anymore."); quiet.learn(from: "I hate myself."); quiet.learn(from: "I hate my life.")
        quiet.learn(from: "I don't know what to do.")
        check(quiet.isEmpty, "no facts from feelings, questions, crisis words or 'I like you'")
        var work = UserProfile()
        work.learn(from: "I work as a nurse and I live in Sydney.")
        check(work.facts.contains("works as a nurse") && work.facts.contains("lives in Sydney"), "en job and place")
        var zhProfile = UserProfile()
        zhProfile.learn(from: "我叫阿杰，我最喜欢绿色。")
        check(zhProfile.name == "阿杰" && zhProfile.facts.contains("喜欢绿色"), "zh name and like")
        check(UserProfile.opposite(of: "likes tea") == "doesn't like tea" && UserProfile.opposite(of: "不喜欢茶") == "喜欢茶", "opposites")

        // Crisis support: real distress matches, hyperbole does not.
        for text in ["I want to kill myself", "I don't want to live anymore", "sometimes I think about suicide", "我不想活了", "活着没意思"] {
            check(ChatBoundary.needsCrisisSupport(text), "crisis: \(text)")
        }
        for text in ["this traffic is killing me", "笑死我了", "累死了", "I could kill for a coffee", "想死你了"] {
            check(!ChatBoundary.needsCrisisSupport(text), "not crisis: \(text)")
        }
        for language in Language.allCases {
            Language.current = language
            check(ChatBoundary.crisisSupport(region: "AU").contains("13 11 14") && ChatBoundary.crisisSupport(region: "AU").contains("000"), "AU line \(language)")
            check(ChatBoundary.crisisSupport(region: "us").contains("988"), "US line, lower-case region \(language)")
            check(ChatBoundary.crisisSupport(region: "CN").contains("12356") && !ChatBoundary.crisisSupport(region: "CN").contains("400-161"), "CN line \(language)")
            check(!ChatBoundary.crisisSupport(region: "CN").contains("24"), "CN line does not claim 24 h \(language)")
            check(ChatBoundary.crisisSupport(region: "ZZ").contains("findahelpline.com"), "fallback \(language)")
            check(ChatBoundary.crisisSupport(region: nil).contains("findahelpline.com"), "no region \(language)")
            for region in ["AU", "NZ", "US", "CA", "GB", "IE", "CN", "HK", "MO", "TW", "SG", "MY", "JP", "KR", "DE", "FR", "NL", "ES", "IT", "IN"] {
                let line = ChatBoundary.crisisSupport(region: region)
                check(!line.contains("findahelpline") && line.count < 230, "\(region) has its own short line \(language)")
            }

            // Prompt assembly.
            let request = CompanionPrompt.request(style: ChatBoundary.defaultPersona,
                                                  history: [["role": "user", "content": "hi"], ["role": "assistant", "content": "hello"], ["role": "user", "content": "how are you"]],
                                                  earlierOmitted: 2, notes: ["NOTE-1"], turnNote: "(calc)")
            check(request.system.contains(CompanionPrompt.capabilities.trimmingCharacters(in: .whitespacesAndNewlines)), "capabilities fixed \(language)")
            check(request.system.contains("NOTE-1"), "notes included \(language)")
            check(request.system.contains(language == .english ? "It is now" : "现在是"), "current time \(language)")
            check(request.system.contains(language == .english ? "left out" : "已省略"), "omission note \(language)")
            check(request.examples.count == 4 && request.examples.allSatisfy { $0.count == 2 }, "four example turns \(language)")
            check(request.messages.count == 3 && request.messages[0]["content"] == "hi", "earlier turns unchanged \(language)")
            check(request.messages[2]["content"] == "how are you\n(calc)" + CompanionPrompt.reminder, "turn note and reminder on the latest message \(language)")
            check(!CompanionPrompt.system(style: "x", omitted: false).contains(language == .english ? "left out" : "已省略"), "no omission note when nothing omitted \(language)")
            check(CompanionPrompt.capabilities.contains(language == .english ? "lover" : "恋人"), "never a lover \(language)")
            check(CompanionPrompt.crisisNote.contains(language == .english ? "earlier topics" : "之前的话题"), "crisis note keeps to the person \(language)")
        }
        let data = try! JSONSerialization.data(withJSONObject: ["passed": passed, "failed": 0], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
