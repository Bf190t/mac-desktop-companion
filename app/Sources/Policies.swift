import Foundation
import AppKit

struct ActivityPolicy {
    var petHidden = false
    var userPaused = false
    var suspended = false
    var energySaving = false
    var idleEnabled = true
    var canAnimate: Bool { !petHidden && !userPaused && !suspended && !energySaving }
    var canChime: Bool { !petHidden && !suspended }
}

struct HourlyPolicy {
    var enabled = true
    var firstHour = 9
    var lastHour = 22
    func permits(_ hour: Int) -> Bool {
        if firstHour <= lastHour { return hour >= firstHour && hour <= lastHour }
        return hour >= firstHour || hour <= lastHour
    }
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        var components = DateComponents(); components.minute = 0; components.second = 0
        var cursor = date
        for _ in 0..<26 {
            guard let value = calendar.nextDate(after: cursor, matching: components, matchingPolicy: .nextTime) else { return nil }
            if permits(calendar.component(.hour, from: value)) { return value }
            cursor = value.addingTimeInterval(1)
        }
        return nil
    }
    func isFresh(target: Date, now: Date) -> Bool {
        let delay = now.timeIntervalSince(target)
        return delay >= -0.5 && delay <= 30
    }
}

func clampedOrigin(_ origin: NSPoint, size: NSSize, visible: NSRect) -> NSPoint {
    NSPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX-size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY-size.height)))
}

final class Preferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["petHeight":320.0,"blueberryHeight":200.0,"chibiHeight":220.0,"chibiRoamMode":"horizontal","character":"chibi","companionHeight":220.0,"blueberryHopEnabled":false,"idleEnabled":true,
            "voiceEnabled":false,"readChatReplies":false,"clickThrough":false,"chatEnabled":false,"chatLongResidency":false,"hourlyEnabled":true,"speechEnabled":false,
            "firstHour":9,"lastHour":22,"petHidden":false,"userPaused":false])
    }
    var chibiRoamMode: PetRoamMode { get { PetRoamMode(rawValue:defaults.string(forKey:"chibiRoamMode") ?? "") ?? .horizontal } set { defaults.set(newValue.rawValue,forKey:"chibiRoamMode") } }
    var voiceEnabled: Bool { get { defaults.bool(forKey:"voiceEnabled") } set { defaults.set(newValue,forKey:"voiceEnabled") } }
    var readChatReplies: Bool { get { defaults.bool(forKey:"readChatReplies") } set { defaults.set(newValue,forKey:"readChatReplies") } }
    var chatEnabled: Bool { get { defaults.bool(forKey:"chatEnabled") } set { defaults.set(newValue,forKey:"chatEnabled") } }
    var chatLongResidency: Bool { get { defaults.bool(forKey:"chatLongResidency") } set { defaults.set(newValue,forKey:"chatLongResidency") } }
    var chatPersona: String { get { defaults.string(forKey:"chatPersona") ?? "" } set { defaults.set(newValue,forKey:"chatPersona") } }
    var character: PetCharacter { get { PetCharacter(rawValue:defaults.string(forKey:"character") ?? "") ?? .chibi } set { defaults.set(newValue.rawValue,forKey:"character") } }
    var height: CGFloat { get { character.clampedHeight(CGFloat(defaults.double(forKey:character.heightKey))) } set { defaults.set(Double(character.clampedHeight(newValue)),forKey:character.heightKey) } }
    var blueberryHopEnabled: Bool { get { defaults.bool(forKey:"blueberryHopEnabled") } set { defaults.set(newValue,forKey:"blueberryHopEnabled") } }
    var idleEnabled: Bool { get { defaults.bool(forKey:"idleEnabled") } set { defaults.set(newValue,forKey:"idleEnabled") } }
    var clickThrough: Bool { get { defaults.bool(forKey:"clickThrough") } set { defaults.set(newValue,forKey:"clickThrough") } }
    var hourlyEnabled: Bool { get { defaults.bool(forKey:"hourlyEnabled") } set { defaults.set(newValue,forKey:"hourlyEnabled") } }
    var speechEnabled: Bool { get { defaults.bool(forKey:"speechEnabled") } set { defaults.set(newValue,forKey:"speechEnabled") } }
    var firstHour: Int { get { defaults.integer(forKey:"firstHour") } set { defaults.set(newValue,forKey:"firstHour") } }
    var lastHour: Int { get { defaults.integer(forKey:"lastHour") } set { defaults.set(newValue,forKey:"lastHour") } }
    var petHidden: Bool { get { defaults.bool(forKey:"petHidden") } set { defaults.set(newValue,forKey:"petHidden") } }
    var userPaused: Bool { get { defaults.bool(forKey:"userPaused") } set { defaults.set(newValue,forKey:"userPaused") } }
    var position: NSPoint? {
        get { guard defaults.object(forKey:"petX") != nil else { return nil }; return NSPoint(x:defaults.double(forKey:"petX"),y:defaults.double(forKey:"petY")) }
        set { if let p = newValue { defaults.set(p.x,forKey:"petX");defaults.set(p.y,forKey:"petY") } }
    }
}
