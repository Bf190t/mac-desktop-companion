import Foundation

@main
struct ChatBoundaryTests {
    static func main() throws {
        // Never read or change the app's real preferences. Test results must not
        // depend on the host's preferred language, time zone, or prior app use.
        let domain="io.github.bf190t.desktop-companion.test.boundary."+UUID().uuidString
        let previousDefaults=Language.defaults
        let previousTimeZone=NSTimeZone.default
        let isolatedDefaults=UserDefaults(suiteName:domain)!
        Language.defaults=isolatedDefaults
        Language.current = .chinese
        NSTimeZone.default=TimeZone(secondsFromGMT:0)!
        defer {
            Language.defaults=previousDefaults
            NSTimeZone.default=previousTimeZone
            isolatedDefaults.removePersistentDomain(forName:domain)
        }
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain:"BoundaryTests",code:2,userInfo:[NSLocalizedDescriptionKey:"Expected synthetic fixture JSON path"])
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cases = root["cases"] as! [[String: String]]
        let aliases = ["status": ChatBoundary.statusReply, "bluetooth": ChatBoundary.bluetoothReply,
                       "action": ChatBoundary.actionReply, "unfinished": ChatBoundary.unfinishedReply,
                       "long": ChatBoundary.longReply,"identity":ChatBoundary.identityReply,"model":ChatBoundary.modelReply,
                       "capability":ChatBoundary.capabilityReply,"prompt":ChatBoundary.promptReply,"text_input":ChatBoundary.textInputReply,
                       "weather":ChatBoundary.weatherReply,"clock":ChatBoundary.clockReply]
        var failures = [[String: String]]()
        for item in cases {
            let expected: String? = item["expected"] == "allow" ? nil : (aliases[item["expected"]!] ?? item["expected"]!)
            let actual = item["stage"] == "pre" ? ChatBoundary.replyBeforeInference(item["input"]!) : ChatBoundary.sanitizeReply(item["input"]!)
            if actual != expected || (item["stage"] == "post" && (actual?.count ?? 0) > 120) {
                failures.append(["id": item["id"]!, "expected": expected ?? "nil", "actual": actual ?? "nil"])
            }
        }
        var bilingualChecks=[String:Bool]()
        func check(_ id:String,_ value:Bool) {
            bilingualChecks[id]=value
            if !value {failures.append(["id":id,"expected":"true","actual":"false"])}
        }
        check("chinese_identity_names_original_mascot",ChatBoundary.replyBeforeInference("你叫什么？")?.contains("小团") == true)
        check("chinese_arithmetic_reaches_model",ChatBoundary.replyBeforeInference("计算九乘七") == nil)
        check("chinese_unpunctuated_reply_uses_chinese_period",ChatBoundary.sanitizeReply("慢慢来") == "慢慢来。")
        check("isolated_preferences_are_used",Language.defaults === isolatedDefaults)
        Language.current = .english
        check("english_setting_persisted_in_test_domain",isolatedDefaults.string(forKey:"interfaceLanguage") == "en")
        check("english_identity_routed",ChatBoundary.replyBeforeInference("Who are you?") == ChatBoundary.identityReply)
        check("english_identity_names_original_mascot",ChatBoundary.identityReply.contains("Mochi") && !ChatBoundary.identityReply.contains("小团"))
        check("english_arithmetic_reaches_model",ChatBoundary.replyBeforeInference("What is 9 times 7?") == nil)
        check("english_unpunctuated_reply_uses_period",ChatBoundary.sanitizeReply("Take your time") == "Take your time.")
        check("english_clock_states_limit",ChatBoundary.replyBeforeInference("What time is it?") == ChatBoundary.clockReply)
        check("english_model_identity_routed",ChatBoundary.replyBeforeInference("What model do you use?") == ChatBoundary.modelReply)
        Language.current = .chinese
        check("switching_back_restores_chinese",ChatBoundary.identityReply.contains("小团") && Language.current == .chinese)
        let result: [String: Any] = ["cases": cases.count, "bilingualChecks":bilingualChecks,
            "bilingualChecksPassed":bilingualChecks.values.filter{$0}.count,
            "failures": failures,"isolatedPreferences":true,"timeZone":"UTC"]
        let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        if !failures.isEmpty { exit(1) }
    }
}
