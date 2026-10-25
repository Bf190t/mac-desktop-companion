import Foundation
import CryptoKit
import IOKit
import IOKit.ps
import Darwin

struct BluetoothBatteryLevel {
    var label: String
    var percent: Int
    var isCharging: Bool? = nil
}

struct BluetoothBatteryDevice {
    var id: String
    var name: String
    var category: String
    var connectionStatus: String
    var batteries: [BluetoothBatteryLevel]
    var freshnessText: String
}

struct BluetoothBatterySnapshot {
    var devices: [BluetoothBatteryDevice] = []
    var updatedAt: Date? = nil
    var statusText = L("打开蓝牙电量页后读取", "Open the Bluetooth page to read battery records")
    var readSucceeded = false
}

/// Passive snapshots only: no CoreBluetooth, IOBluetooth, processes, network,
/// discovery, pairing, connection requests, or power assertions. The caller owns
/// scheduling and must stop reading while the page is closed or Mac is asleep.
enum BluetoothBatteryReader {
    static func read() -> BluetoothBatterySnapshot {
        let now = Date()
        let accessory = accessoryProperties()
        let hid = hidProperties()
        let devices = merge(accessories: decodeAccessories(accessory.rows), hid: decodeHID(hid.rows))
        if !devices.isEmpty {
            return BluetoothBatterySnapshot(devices: devices, updatedAt: now,
                statusText: L("系统电量记录 · 不主动连接设备", "System battery records · Never connects to devices"), readSucceeded: true)
        }
        let succeeded = accessory.succeeded || hid.succeeded
        return BluetoothBatterySnapshot(updatedAt: succeeded ? now : nil,
            statusText: L("暂无系统可用电量；设备休眠或系统限制时可能无法读取", "No battery record available; sleeping devices or system restrictions may limit access"),
            readSucceeded: succeeded)
    }

    static func merge(accessories: [BluetoothBatteryDevice], hid: [BluetoothBatteryDevice]) -> [BluetoothBatteryDevice] {
        // Both sources use the same hash when they report a standard Bluetooth
        // address. Never assume matching names or product models identify one
        // physical device. More detailed accessory data takes precedence.
        var merged = Dictionary(hid.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for device in accessories {
            if device.batteries.isEmpty, let existing = merged[device.id], !existing.batteries.isEmpty { continue }
            merged[device.id] = device
        }
        return merged.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apple exposes the accessory-source selector in its open-source private
    /// header, not the public SDK. Resolve the existing OS symbol defensively;
    /// do not link third-party code or assume it exists on future macOS versions.
    private static func accessoryProperties() -> (rows: [[String: Any]], succeeded: Bool) {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL) else {
            return ([], false)
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "IOPSCopyPowerSourcesByType") else { return ([], false) }
        typealias CopySources = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        let copy = unsafeBitCast(symbol, to: CopySources.self)
        // kIOPSSourceForAccessories = 4. Copy ownership is released by ARC.
        guard let blob = copy(4)?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return ([], false)
        }
        let rows = list.prefix(128).compactMap { item in
            IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any]
        }
        // Empty snapshots are inconclusive: Apple's implementation may also
        // return an empty array when its daemon cannot supply data.
        return (rows, !rows.isEmpty)
    }

    private static func hidProperties() -> (rows: [[String: Any]], succeeded: Bool) {
        var rows: [[String: Any]] = []
        var succeeded = false
        for serviceClass in ["AppleDeviceManagementHIDEventService", "AppleBluetoothHIDKeyboard", "BNBMouseDevice", "BNBTrackpadDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(serviceClass), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var count = 0
            while count < 128 {
                let entry = IOIteratorNext(iterator)
                guard entry != 0 else { break }
                defer { IOObjectRelease(entry) }
                count += 1
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      var dict = properties?.takeRetainedValue() as? [String: Any] else { continue }
                succeeded = true
                var registryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(entry, &registryID) == KERN_SUCCESS {
                    dict["_RegistryID"] = String(registryID)
                }
                rows.append(dict)
            }
        }
        return (rows, succeeded)
    }

    /// Pure parsers are kept internal for offline fixtures. Neither decoder
    /// retains raw addresses or exposes them through the returned model.
    static func decodeAccessories(_ rows: [[String: Any]]) -> [BluetoothBatteryDevice] {
        var groups: [String: [[String: Any]]] = [:]
        for row in rows.prefix(128) {
            let transport = (row["Transport Type"] as? String ?? "").lowercased()
            guard transport.contains("bluetooth"), isApple(row, vendorKey: "Vendor ID") else { continue }
            guard let identity = text(row["Group Identifier"]) ?? text(row["Accessory Identifier"]) else { continue }
            groups[identity.lowercased(), default: []].append(row)
        }
        return groups.map { identity, group in
            let main = group.first { ($0["Part Identifier"] as? String) == "Combined" }
                ?? group.first { ($0["Part Identifier"] as? String) != "Case" }
                ?? group[0]
            var levels: [String: BluetoothBatteryLevel] = [:]
            for row in group {
                if let parts = row["Combined Parts"] as? [[String: Any]] {
                    for part in parts.prefix(16) {
                        if let level = accessoryLevel(part) { levels[level.label] = level }
                    }
                }
                if let level = accessoryLevel(row) { levels[level.label] = level }
            }
            if levels[L("左耳", "Left")] != nil || levels[L("右耳", "Right")] != nil { levels.removeValue(forKey: L("耳机", "Headphones")) }
            let absent = group.allSatisfy { bool($0["Is Present"]) == false || ($0["Power Source State"] as? String) == "Off Line" }
            return BluetoothBatteryDevice(id: deviceID(identity, source: "accessory"),
                name: safeName(main["Name"] as? String, fallback: L("Apple 蓝牙设备", "Apple Bluetooth device")),
                category: category(main),
                connectionStatus: absent ? L("离线（系统旧记录）", "Offline (older system record)") : L("连接状态未核实", "Connection unverified"),
                batteries: sortedLevels(Array(levels.values)),
                freshnessText: absent ? L("离线缓存，电量可能过期", "Offline cache; battery values may be stale") : L("系统最近记录；采样时间未知，未列出部件暂无读数", "Latest system record; sample time unknown. Missing parts have no reading."))
        }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func decodeHID(_ rows: [[String: Any]]) -> [BluetoothBatteryDevice] {
        var devices: [String: BluetoothBatteryDevice] = [:]
        for row in rows.prefix(512) {
            guard (row["Transport"] as? String ?? "").lowercased().contains("bluetooth"),
                  isApple(row, vendorKey: "VendorID"), let battery = percent(row["BatteryPercent"]) else { continue }
            // Address/serial are identity only. Registry ID is a session fallback;
            // it can change after reconnect, unlike a persistent device ID.
            let raw = text(row["DeviceAddress"]) ?? text(row["SerialNumber"])
                ?? text(row["BD_ADDR"]) ?? text(row["_RegistryID"])
            guard let raw else { continue }
            let identity = deviceID(raw, source: "hid")
            devices[identity] = BluetoothBatteryDevice(id: identity,
                name: safeName(row["Product"] as? String, fallback: L("Apple 蓝牙配件", "Apple Bluetooth accessory")),
                category: category(row), connectionStatus: L("系统已登记（连接未核实）", "Registered by macOS (connection unverified)"),
                batteries: [BluetoothBatteryLevel(label: L("电量", "Battery"), percent: battery)],
                freshnessText: L("系统 HID 最近记录；采样时间未知", "Latest HID record; sample time unknown"))
        }
        return devices.values.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func accessoryLevel(_ row: [String: Any]) -> BluetoothBatteryLevel? {
        guard let current = number(row["Current Capacity"]) else { return nil }
        let maximum = number(row["Max Capacity"]) ?? 100
        guard current >= 0, current != 255, maximum > 0, current <= maximum else { return nil }
        let value = Int((current / maximum * 100).rounded())
        guard (0...100).contains(value) else { return nil }
        let label: String
        switch row["Part Identifier"] as? String {
        case "Left": label = L("左耳", "Left")
        case "Right": label = L("右耳", "Right")
        case "Case": label = L("充电盒", "Case")
        case "Combined", "Single": label = category(row) == L("耳机", "Headphones") ? L("耳机", "Headphones") : L("电量", "Battery")
        default: label = L("电量", "Battery")
        }
        return BluetoothBatteryLevel(label: label, percent: value, isCharging: bool(row["Is Charging"]))
    }

    static func percent(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded() == value, (0...100).contains(value) else { return nil }
        return Int(value)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite ? v : nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    private static func text(_ value: Any?) -> String? {
        let raw: String?
        if let string = value as? String { raw = string }
        else if let data = value as? Data { raw = String(data: data, encoding: .utf8) }
        else { raw = nil }
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return String(s.prefix(256))
    }

    private static func isApple(_ row: [String: Any], vendorKey: String) -> Bool {
        // Bluetooth SIG Apple company ID = 76; USB Apple vendor ID = 1452.
        guard let vendor = number(row[vendorKey]) else { return false }
        return vendor == 76 || vendor == 1452
    }

    private static func category(_ row: [String: Any]) -> String {
        let value = ((row["Accessory Category"] as? String ?? "") + " " + (row["Product"] as? String ?? "") + " " + (row["Name"] as? String ?? "")).lowercased()
        if value.contains("mouse") || value.contains(L("鼠标", "Mouse")) { return L("鼠标", "Mouse") }
        if value.contains("keyboard") || value.contains(L("键盘", "Keyboard")) { return L("键盘", "Keyboard") }
        if value.contains("trackpad") || value.contains(L("触控板", "Trackpad")) { return L("触控板", "Trackpad") }
        if value.contains("headset") || value.contains("headphone") || value.contains("airpod") || value.contains("audio battery") || value.contains("beats") { return L("耳机", "Headphones") }
        return L("蓝牙配件", "Bluetooth accessory")
    }

    private static func safeName(_ raw: String?, fallback: String) -> String {
        guard let raw else { return fallback }
        let clean = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(80))
        guard !clean.isEmpty else { return fallback }
        // Some driver entries use the Bluetooth address as their product name.
        return clean.replacingOccurrences(of: "(?i)(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}", with: L("Apple 蓝牙设备", "Apple Bluetooth device"), options: .regularExpression)
    }

    private static func sortedLevels(_ levels: [BluetoothBatteryLevel]) -> [BluetoothBatteryLevel] {
        let order = [L("左耳", "Left"), L("右耳", "Right"), L("充电盒", "Case"), L("耳机", "Headphones"), L("电量", "Battery")]
        return levels.sorted { (order.firstIndex(of: $0.label) ?? 9) < (order.firstIndex(of: $1.label) ?? 9) }
    }

    private static func stableID(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func deviceID(_ raw: String, source: String) -> String {
        let canonical = raw.lowercased().replacingOccurrences(of: "-", with: ":")
        if canonical.range(of: "^(?:[0-9a-f]{2}:){5}[0-9a-f]{2}$", options: .regularExpression) != nil {
            return stableID("bluetooth:" + canonical)
        }
        return stableID(source + ":" + raw.lowercased())
    }
}
