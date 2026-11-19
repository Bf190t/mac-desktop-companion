import Foundation
import CryptoKit

/// A 0.2.0 reading-voice installation (previous sample) is never cloned and is switched in place:
/// no download, chimes re-recorded by voice/install.py with a fake runtime that speaks the helper's
/// protocol (no model). Everything lives in a temporary folder; preferences are isolated.
@main struct VoiceSwitchTests {
    static func main() {
        let domain="io.github.bf190t.desktop-companion.test.voice-switch."+UUID().uuidString
        let previous=Language.defaults
        let isolated=UserDefaults(suiteName:domain)!
        Language.defaults=isolated
        let fm=FileManager.default
        let temp=fm.temporaryDirectory.appendingPathComponent("voice-switch-"+UUID().uuidString,isDirectory:true)
        defer {Language.defaults=previous;isolated.removePersistentDomain(forName:domain);try? fm.removeItem(at:temp)}
        var passed=0
        func check(_ condition:@autoclosure ()->Bool,_ name:String) {
            guard condition() else {fatalError("FAIL: \(name)")}
            passed += 1
        }
        func sha(_ url:URL)->String {SHA256.hash(data:try! Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()}
        /// The real Python behind /usr/bin/python3 (that path is only a launcher, which the sandbox would not run).
        func realPython()->String {
            let p=Process(),out=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            p.arguments=["-I","-c","import os,sys;print(os.path.realpath(sys.executable))"];p.standardOutput=out
            try! p.run();p.waitUntilExit()
            return String(decoding:out.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        }
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        // The app bundle's Resources folder.
        let resources=temp.appendingPathComponent("Resources",isDirectory:true),voiceResources=resources.appendingPathComponent("Voice",isDirectory:true)
        try! fm.createDirectory(at:voiceResources,withIntermediateDirectories:true)
        for name in ["install.py","model-manifest.json","runtime-manifest.json","requirements-lock.txt","companion_voice.wav","companion_voice.json"] {
            try! fm.copyItem(at:project.appendingPathComponent("voice/"+name),to:voiceResources.appendingPathComponent(name))
        }
        // The helper runs sandboxed (only programs inside its Python runtime may start), so the fake runtime
        // links to a real Python and the bundled helper script is replaced by a fake that speaks the protocol.
        let worker=voiceResources.appendingPathComponent("tts_worker.py")
        // The installation 0.2.0 left behind.
        let base=temp.appendingPathComponent("Support",isDirectory:true),root=base.appendingPathComponent("Voice",isDirectory:true)
        for folder in ["voices/chimes/zh","model","deps","python-base/bin","logs"] {
            try! fm.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true)
        }
        try! Data("not a model".utf8).write(to:root.appendingPathComponent("model/model.safetensors"))
        let old=Data(("RIFF"+String(repeating:"previous sample",count:64)).utf8)
        try! old.write(to:root.appendingPathComponent("voices/companion_voice.wav"))
        try! Data("old chime".utf8).write(to:root.appendingPathComponent("voices/chimes/zh/chime-09.wav"))
        try! """
        import base64, json, sys
        print(json.dumps({'event': 'ready', 'load_seconds': 0.1}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({'event': 'audio', 'id': request['id'], 'pcm': base64.b64encode(bytes([1, 0]) * 240).decode()}), flush=True)
            print(json.dumps({'event': 'done', 'id': request['id']}), flush=True)
        """.write(to:worker,atomically:true,encoding:.utf8)
        let python=root.appendingPathComponent("python-base/bin/python3.12")
        try! fm.createSymbolicLink(at:python,withDestinationURL:URL(fileURLWithPath:realPython()))
        let marker:[String:Any]=["schema":1,"kind":"voice","model_revision":"50f45ef0047cde7e84c2ef04326acb8ada2436a7",
            "runtime_sha256":"a18cc33862b53bd54a148c710def5375c1b47470cccedf817a19c2d211764584",
            "requirements_sha256":sha(voiceResources.appendingPathComponent("requirements-lock.txt")),
            "voice_sha256":SHA256.hash(data:old).map{String(format:"%02x",$0)}.joined(),"chimes":["zh","en"]]
        try! JSONSerialization.data(withJSONObject:marker).write(to:root.appendingPathComponent("installation.json"))

        ModelInstallation.baseOverride=base
        ModelInstallation.resourcesOverride=resources
        let installation=ModelInstallation.voice
        check(!ModelInstallation.automaticVoiceSwitch,"test builds never start a switch on their own")
        // The sandbox runtime keeps the kernel's /private prefix (URL.resolvingSymlinksInPath would drop it).
        let probe=URL(fileURLWithPath:"/tmp/companion-sandbox-\(UUID().uuidString)/bin/python3.12")
        try! fm.createDirectory(at:probe.deletingLastPathComponent(),withIntermediateDirectories:true)
        try! Data().write(to:probe)
        check(WorkerSandbox.runtime(for:probe).path.hasPrefix("/private/tmp/companion-sandbox-"),"sandbox runtime path keeps /private")
        try? fm.removeItem(at:probe.deletingLastPathComponent().deletingLastPathComponent())
        check(installation.root.path == root.path,"installation uses the temporary folder")
        check(installation.isInstalled && installation.hasOutdatedVoice,"0.2.0 installation is detected as outdated")
        check(NeuralSpeechInstall.load(resources:resources) == nil,"outdated sample is never handed to the helper")
        check(NeuralSpeechInstall.chimeClip(hour:9) == nil,"chimes recorded with the old sample are not played")
        check(installation.voiceSwitchStatus != nil && installation.status == installation.voiceSwitchStatus!,"status explains the switch")
        check(!installation.isBusy,"detection alone starts nothing")

        installation.switchVoice()
        check(installation.isBusy && installation.isSwitchingVoice,"switch runs")
        check(installation.status.contains(L("正在换成新声音", "Switching to the new voice")),"status while switching")
        check(NeuralSpeechInstall.load(resources:resources) == nil,"no neural voice while switching")
        let deadline=Date().addingTimeInterval(60)
        while installation.isBusy && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.05))}
        check(!installation.isBusy,"switch finished in time")
        check(!installation.hasOutdatedVoice && installation.isInstalled,"installation now uses the bundled sample: "+installation.status)
        check(sha(root.appendingPathComponent("voices/companion_voice.wav")) == sha(voiceResources.appendingPathComponent("companion_voice.wav")),"bundled sample installed")
        check(installation.voiceSwitchStatus == nil,"usual status again")
        check(NeuralSpeechInstall.load(resources:resources)?.voice.path == root.appendingPathComponent("voices/companion_voice.wav").path,"neural voice available with the new sample")
        let chime=root.appendingPathComponent("voices/chimes/zh/chime-09.wav")
        check((try? Data(contentsOf:chime)) != Data("old chime".utf8),"chime re-recorded")
        check(((try? fm.contentsOfDirectory(atPath:root.path)) ?? []).allSatisfy{!$0.hasPrefix(".voice-switch.")},"no staging left")
        let data=try! JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("installation.json"))) as! [String:Any]
        check(data["model_revision"] as? String == "50f45ef0047cde7e84c2ef04326acb8ada2436a7","model kept, nothing downloaded")
        ModelInstallation.baseOverride=nil;ModelInstallation.resourcesOverride=nil
        print("{\"voice_switch_checks\":\(passed),\"failed\":0,\"downloads\":0,\"model_loaded\":false}")
    }
}
