import Foundation

@main
struct ReaderTests {
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            let start = Date()
            let snapshot = BluetoothBatteryReader.read()
            let elapsed = Date().timeIntervalSince(start)
            let rows: [[String: Any]] = snapshot.devices.map { device in
                ["name": device.name, "category": device.category, "connectionStatus": device.connectionStatus,
                 "freshness": device.freshnessText,
                 "levels": device.batteries.map { ["label": $0.label, "percent": $0.percent, "charging": $0.isCharging as Any? ?? NSNull()] }]
            }
            try output(["readSucceeded": snapshot.readSucceeded, "status": snapshot.statusText, "elapsedSeconds": elapsed, "devices": rows])
            return
        }
        let domain="io.github.bf190t.desktop-companion.test.reader."+UUID().uuidString
        let previous=Language.defaults
        let isolated=UserDefaults(suiteName:domain)!
        Language.defaults=isolated
        defer {Language.defaults=previous;isolated.removePersistentDomain(forName:domain)}
        var results=[[String:Any]]()
        for language in Language.allCases {
            Language.current=language
            let checks=runChecks()
            results.append(["language":language.rawValue,"passed":checks.count,"checks":checks])
        }
        try output(["languages":results,"passed":results.reduce(0){$0+($1["passed"] as! Int)},"isolatedPreferences":true])
    }
    static func runChecks()->[String] {
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name); checks.append(name)
        }
        func accessory(_ id: String, _ part: String = "Single", _ capacity: Any = 65, _ name: String = "Same name") -> [String: Any] {
            ["Name": name, "Accessory Identifier": "fixture-" + id + "-" + part, "Group Identifier": id,
             "Part Identifier": part, "Current Capacity": capacity, "Max Capacity": 100,
             "Vendor ID": 76, "Transport Type": "Bluetooth LE", "Accessory Category": "Headset", "Is Present": true]
        }
        let empty = BluetoothBatterySnapshot()
        check(empty.devices.isEmpty && empty.updatedAt == nil && !empty.readSucceeded, "initial state is unknown")
        check(BluetoothBatteryReader.percent(0) == 0, "zero percent valid")
        check(BluetoothBatteryReader.percent(1) == 1, "one percent not inflated to 100")
        check(BluetoothBatteryReader.percent(100) == 100, "100 percent valid")
        for value: Any in [-1, 101, 255, true, "50%", Double.nan, 0.5] {
            check(BluetoothBatteryReader.percent(value) == nil, "reject invalid percent: \(String(describing: value))")
        }
        check(BluetoothBatteryReader.percent(nil) == nil, "missing percent stays unknown")
        var combined = accessory("group-A", "Combined", 42)
        var left = accessory("group-A", "Left", 0); left["Is Charging"] = false
        var right = accessory("group-A", "Right", 85); right["Is Charging"] = true
        combined["Combined Parts"] = [left, right]
        let merged = BluetoothBatteryReader.decodeAccessories([combined, accessory("group-A", "Case", 30), accessory("group-B")])
        check(merged.count == 2, "same names on different identities remain separate")
        let earbuds = merged.first { $0.batteries.count == 3 }!
        check(earbuds.batteries.map(\.label) == [L("左耳", "Left"), L("右耳", "Right"), L("充电盒", "Case")], "group parts merged and sorted")
        check(earbuds.batteries.map(\.percent) == [0, 85, 30], "component values retained including zero")
        check(earbuds.batteries[0].isCharging == false && earbuds.batteries[1].isCharging == true && earbuds.batteries[2].isCharging == nil, "charging unknown kept distinct")
        check(earbuds.connectionStatus.contains(L("未核实", "unverified")) && earbuds.freshnessText.contains(L("未知", "unknown")), "present does not mean connected or fresh")
        check(!earbuds.id.contains("group") && earbuds.id.count == 32, "identity hashed")
        let reordered = BluetoothBatteryReader.decodeAccessories([accessory("group-B"), accessory("group-A", "Case", 30), combined])
        check(reordered.map(\.id) == merged.map(\.id), "stable ordering and identity across source order")
        var offline = accessory("offline", "Case", 22); offline["Is Present"] = false
        let old = BluetoothBatteryReader.decodeAccessories([offline])[0]
        check(old.connectionStatus.contains(L("离线", "Offline")) && old.freshnessText.contains(L("过期", "stale")), "offline values explicitly stale")
        var bad = accessory("invalid", "Left", 255); bad["Combined Parts"] = [accessory("invalid", "Right", -1)]
        check(BluetoothBatteryReader.decodeAccessories([bad])[0].batteries.isEmpty, "unknown parts never become zero")
        var otherVendor = accessory("other"); otherVendor["Vendor ID"] = 12345
        var internalBattery = accessory("internal"); internalBattery["Transport Type"] = "Internal"
        var usb = accessory("usb"); usb["Transport Type"] = "USB"
        check(BluetoothBatteryReader.decodeAccessories([otherVendor, internalBattery, usb]).isEmpty, "exclude non-Apple non-Bluetooth sources")
        var scaled = accessory("scale", "Single", 500); scaled["Max Capacity"] = 1000
        check(BluetoothBatteryReader.decodeAccessories([scaled])[0].batteries[0].percent == 50, "normalize capacity by reported maximum")
        let hid: [[String: Any]] = [
            ["Product": "Magic Keyboard", "DeviceAddress": "01:02:03:04:05:06", "VendorID": 76, "Transport": "Bluetooth", "BatteryPercent": 0],
            ["Product": "Magic Keyboard", "DeviceAddress": "01:02:03:04:05:07", "VendorID": 1452, "Transport": "Bluetooth", "BatteryPercent": 20],
            ["Product": "Magic Keyboard", "DeviceAddress": "01:02:03:04:05:06", "VendorID": 76, "Transport": "Bluetooth", "BatteryPercent": 0]
        ]
        let keyboards = BluetoothBatteryReader.decodeHID(hid)
        check(keyboards.count == 2 && keyboards.allSatisfy { $0.category == L("键盘", "Keyboard") }, "HID dedup by ID not name")
        check(keyboards.contains { $0.batteries[0].percent == 0 }, "HID zero retained")
        var accessoryKeyboard = accessory("unused", "Single", 10, "Different driver name")
        accessoryKeyboard.removeValue(forKey: "Group Identifier")
        accessoryKeyboard["Accessory Identifier"] = "01-02-03-04-05-06"
        accessoryKeyboard["Accessory Category"] = "Keyboard"
        let keyboardSource = BluetoothBatteryReader.decodeAccessories([accessoryKeyboard])
        check(keyboardSource[0].batteries[0].label == L("电量", "Battery"), "generic Single part not labeled as headphones")
        let crossSource = BluetoothBatteryReader.merge(accessories: keyboardSource, hid: keyboards)
        check(crossSource.count == 2, "cross-source identity dedup despite different names and address separators")
        check(crossSource.contains { $0.name == "Different driver name" && $0.batteries[0].percent == 10 }, "accessory source takes precedence over HID duplicate")
        accessoryKeyboard["Current Capacity"] = 255
        let partial = BluetoothBatteryReader.merge(accessories: BluetoothBatteryReader.decodeAccessories([accessoryKeyboard]), hid: keyboards)
        check(partial.contains { $0.name == "Magic Keyboard" && $0.batteries[0].percent == 0 }, "empty accessory record cannot erase valid HID reading")
        var renamedHeadphones = accessory("renamed", "Single", 10, "Custom name")
        renamedHeadphones["Accessory Category"] = "Headphone"
        let renamed = BluetoothBatteryReader.decodeAccessories([renamedHeadphones])[0]
        check(renamed.category == L("耳机", "Headphones") && renamed.batteries[0].label == L("耳机", "Headphones"), "Headphone category recognized independently of custom name")
        var noID = hid[0]; noID.removeValue(forKey: "DeviceAddress")
        check(BluetoothBatteryReader.decodeHID([noID]).isEmpty, "no identity not guessed from name")
        var addressName = hid[0]; addressName["Product"] = "device 01:02:03:04:05:06"
        check(!BluetoothBatteryReader.decodeHID([addressName])[0].name.contains("01:02"), "address-like driver names redacted")
        var trackpad = hid[0]; trackpad["Product"] = "Magic Trackpad"
        check(BluetoothBatteryReader.decodeHID([trackpad])[0].category == L("触控板", "Trackpad"), "trackpad category")
        return checks
    }
    static func output(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
