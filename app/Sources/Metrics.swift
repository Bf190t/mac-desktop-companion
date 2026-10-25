import Foundation
import Dispatch
import Darwin
import IOKit

struct MetricsSnapshot {
    var cpuPercent: Double? = nil
    var gpuPercent: Double? = nil
    var temperatureC: Double? = nil
    var thermalDescription = L("未知", "Unknown")
    var availableMemoryBytes: UInt64? = nil
    var totalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    var pressureCurrent = L("未知", "Unknown")
    var pressureHourSummary = L("统计中", "Measuring")
    var storageAvailableBytes: Int64? = nil
    var storageTotalBytes: Int64? = nil
    var storageUpdatedAt: Date? = nil
    var sampledAt = Date()
    var temperatureDescription = L("CPU温度暂不可读", "CPU temperature unavailable")
    var memoryDescription = L("空闲物理内存（不含可回收缓存）", "Free physical RAM (excludes reclaimable caches)")
    var storageDescription = L("启动卷可用空间（可能含可清理空间）", "Available on startup volume (may include purgeable space)")
    var gpuDescription = L("GPU占用", "GPU usage")
    var pressureObservedSeconds: TimeInterval = 0
    var pressureFractions: [String: Double] = [:]
}

/// All public lifecycle calls may be made from the main thread. State and I/O
/// are serialized on a utility queue; latest and onUpdate are delivered on main.
final class MetricsMonitor {
    private(set) var latest = MetricsSnapshot()
    var onUpdate: ((MetricsSnapshot) -> Void)?
    private let queue = DispatchQueue(label: "io.github.bf190t.desktop-companion.metrics", qos: .utility)
    private var snapshot = MetricsSnapshot()
    private var running = false
    private var suspended = false
    private var panelVisible = false
    private var timer: DispatchSourceTimer?
    private var storageTimer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []
    private var previousCPU: [UInt64]?
    private let hostPort = mach_host_self()
    private var smc: ReadOnlyCPUTemperature?
    private var history: [(start: TimeInterval, end: TimeInterval, level: String)] = []
    private var pressureSince: TimeInterval?
    private var lastStorageAttemptAt: TimeInterval?
    private var pressureLevel = "unknown"

    deinit {
        timer?.cancel(); storageTimer?.cancel(); pressureSource?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        mach_port_deallocate(mach_task_self_, hostPort)
    }

    func start() { queue.async { [weak self] in
        guard let self, !self.running else { return }
        self.running = true; self.suspended = false
        self.installPressureSource(); self.readPressure(); self.readMemory()
        self.updateThermal(); self.refreshStorageIfNeeded(force: false)
        self.installObservers(); self.configureSampling(); self.publish()
    } }
    func stop() { queue.async { [weak self] in
        guard let self else { return }
        self.running = false
        self.cancelSampling(); self.storageTimer?.cancel(); self.storageTimer = nil
        self.pressureSource?.cancel(); self.pressureSource = nil
        self.transitionPressure(to: "unknown"); self.clearVolatileReadings()
        self.observers.forEach(NotificationCenter.default.removeObserver); self.observers.removeAll()
        self.publish()
    } }
    func setPanelVisible(_ visible: Bool) { queue.async { [weak self] in
        guard let self else { return }
        self.panelVisible = visible
        guard self.running, !self.suspended else { return }
        self.configureSampling()
        if visible { self.refreshStorageIfNeeded(force: false) }
        self.publish()
    } }
    func suspend() { queue.async { [weak self] in
        guard let self, self.running, !self.suspended else { return }
        self.suspended = true
        self.cancelSampling(); self.storageTimer?.cancel(); self.storageTimer = nil
        self.pressureSource?.cancel(); self.pressureSource = nil
        self.transitionPressure(to: "unknown"); self.clearVolatileReadings(); self.publish()
    } }
    func resume() { queue.async { [weak self] in
        guard let self, self.running, self.suspended else { return }
        self.suspended = false
        self.installPressureSource(); self.readPressure(); self.updateThermal()
        self.refreshStorageIfNeeded(force: false); self.configureSampling(); self.publish()
    } }
    func refreshStorage() { queue.async { [weak self] in
        guard let self, self.running, !self.suspended else { return }
        self.refreshStorageIfNeeded(force: true); self.publish()
    } }

    private func installObservers() {
        guard observers.isEmpty else { return }
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    guard let self, self.running, !self.suspended else { return }
                    self.updateThermal(); self.configureSampling(); self.publish()
                }
            })
        }
    }
    private func configureSampling() {
        cancelSampling()
        guard running, !suspended, panelVisible else { return }
        smc = ReadOnlyCPUTemperature()
        sample()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let slow = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let interval: Double = slow ? 15 : 5
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source; source.resume()
    }
    private func cancelSampling() {
        timer?.cancel(); timer = nil; previousCPU = nil; smc = nil
    }
    private func clearVolatileReadings() {
        snapshot.cpuPercent = nil; snapshot.gpuPercent = nil; snapshot.temperatureC = nil
    }
    private func sample() {
        guard running, !suspended, panelVisible else { return }
        autoreleasepool {
            readCPU(); readGPU(); readMemory(); readPressure(); updateThermal()
            if let measured = smc?.read() {
                snapshot.temperatureC = measured.value
                snapshot.temperatureDescription = L("CPU传感器均温（\(measured.count)点）", "CPU sensor average (\(measured.count) sensors)")
            } else if snapshot.temperatureC == nil {
                snapshot.temperatureDescription = L("CPU温度暂不可读", "CPU temperature unavailable")
            }
            snapshot.sampledAt = Date(); publish()
        }
    }
    private func readCPU() {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { previousCPU = nil; snapshot.cpuPercent = nil; return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3].map(UInt64.init)
        defer { previousCPU = ticks }
        guard let prior = previousCPU else { snapshot.cpuPercent = nil; return }
        // Reset the baseline on counter rollover or wake rather than inventing a peak.
        guard zip(ticks, prior).allSatisfy({ $0 >= $1 }) else { snapshot.cpuPercent = nil; return }
        let delta = zip(ticks, prior).map { $0 - $1 }; let total = delta.reduce(0,+)
        snapshot.cpuPercent = total > 0 ? 100 * Double(total - delta[Int(CPU_STATE_IDLE)]) / Double(total) : nil
    }
    private func readGPU() {
        snapshot.gpuPercent = nil; snapshot.temperatureC = nil
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var values: [Double] = []
        while true {
            let service = IOIteratorNext(iterator); if service == 0 { break }
            defer { IOObjectRelease(service) }
            guard let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let data = property as? [String: Any] else { continue }
            if let number = (data["Device Utilization %"] ?? data["GPU Activity(%)"]) as? NSNumber {
                let value = number.doubleValue
                if value.isFinite && (0...100).contains(value) { values.append(value) }
            }
            if let value = (data["Temperature(C)"] as? NSNumber)?.doubleValue, (10...120).contains(value) {
                snapshot.temperatureC = value; snapshot.temperatureDescription = L("GPU传感器温度", "GPU sensor temperature")
            }
        }
        snapshot.gpuPercent = values.max()
        snapshot.gpuDescription = values.count > 1 ? L("GPU占用（多卡最高值）", "GPU usage (highest across GPUs)") : L("GPU占用", "GPU usage")
    }
    private func readMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { snapshot.availableMemoryBytes = nil; return }
        // Apple's header says speculative pages are already included in free_count.
        // Report unoccupied physical pages, not an invented total "available RAM".
        let pages = stats.free_count >= stats.speculative_count ? stats.free_count - stats.speculative_count : 0
        snapshot.availableMemoryBytes = UInt64(pages) * UInt64(vm_page_size)
    }
    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: snapshot.thermalDescription = L("正常", "Normal")
        case .fair: snapshot.thermalDescription = L("轻度升温", "Warm")
        case .serious: snapshot.thermalDescription = L("热压力较高", "High thermal pressure")
        case .critical: snapshot.thermalDescription = L("热压力严重", "Critical thermal pressure")
        @unknown default: snapshot.thermalDescription = L("未知", "Unknown")
        }
    }
    private func installPressureSource() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.running, !self.suspended else { return }
            if !self.readPressureSnapshot() {
                let flags = source.data
                if flags.contains(.critical) { self.transitionPressure(to: "red") }
                else if flags.contains(.warning) { self.transitionPressure(to: "yellow") }
                else if flags.contains(.normal) { self.transitionPressure(to: "green") }
            }
            self.publish()
        }
        pressureSource = source; source.resume()
    }
    @discardableResult private func readPressureSnapshot() -> Bool {
        var value: UInt32 = 0; var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0, size == 4 else { return false }
        // This sysctl explicitly converts the internal enum to dispatch masks.
        switch value {
        case 1: transitionPressure(to: "green")
        case 2: transitionPressure(to: "yellow")
        case 4: transitionPressure(to: "red")
        default: return false
        }
        return true
    }
    private static func pressureLabel(_ level:String)->String {
        switch level {case "green":return L("绿", "Green");case "yellow":return L("黄", "Yellow");case "red":return L("红", "Red");default:return L("未知", "Unknown")}
    }
    func refreshLocalization() {
        queue.async { [weak self] in
            guard let self=self else{return}
            self.snapshot.pressureCurrent=Self.pressureLabel(self.pressureLevel)
            self.summarizePressure(at:MetricsClock.now);self.publish()
        }
    }
    private func readPressure() {
        if !readPressureSnapshot() { transitionPressure(to: "unknown") }
    }
    private func transitionPressure(to level: String, at now: TimeInterval = MetricsClock.now) {
        if let since = pressureSince, now < since { history.removeAll(); pressureSince = now }
        if pressureLevel != level || pressureSince == nil {
            if let start = pressureSince, pressureLevel != "unknown", now > start { history.append((start,now,pressureLevel)) }
            pressureLevel = level; pressureSince = level == "unknown" ? nil : now
        }
        let cutoff = now - 3600
        history.removeAll { $0.end < cutoff }
        snapshot.pressureCurrent = Self.pressureLabel(level)
    }
    private func summarizePressure(at now: TimeInterval) {
        let cutoff = now - 3600
        history.removeAll { $0.end < cutoff }
        var totals: [String: Double] = ["green":0,"yellow":0,"red":0]
        for record in history {
            let elapsed = min(now,record.end) - max(cutoff,record.start)
            if elapsed > 0 { totals[record.level, default:0] += elapsed }
        }
        if let since = pressureSince, pressureLevel != "unknown" {
            totals[pressureLevel, default:0] += max(0,now - max(cutoff,since))
        }
        let duration = totals.values.reduce(0,+)
        snapshot.pressureObservedSeconds = duration
        snapshot.pressureFractions = duration > 0 ? totals.mapValues { $0 / duration } : [:]
        if duration < 1 { snapshot.pressureHourSummary = L("统计中 · 尚无有效观察时长", "Measuring · No observed duration yet"); return }
        let text = ["green","yellow","red"].map { "\(Self.pressureLabel($0)) \(Int((totals[$0,default:0] / duration * 100).rounded()))%" }.joined(separator:" · ")
        let observed = duration < 60 ? L("\(Int(duration))秒", "\(Int(duration)) sec") : L("\(Int(duration/60))分钟", "\(Int(duration/60)) min")
        snapshot.pressureHourSummary = L("\(text)\n近1小时已观察\(observed)（应用统计）", "\(text)\nObserved \(observed) in the past hour (app statistics)")
    }
    private func refreshStorageIfNeeded(force: Bool) {
        guard running, !suspended else { return }
        let now = Date()
        let monotonicNow = MetricsClock.now
        if shouldAttemptStorage(force: force, at: monotonicNow) {
            // Both successful and failed automatic reads share this cooldown.
            lastStorageAttemptAt = monotonicNow
            do {
                let url = URL(fileURLWithPath: "/System/Volumes/Data")
                let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,.volumeTotalCapacityKey])
                if let available = values.volumeAvailableCapacityForImportantUsage, let total = values.volumeTotalCapacity, available >= 0, total > 0 {
                    snapshot.storageAvailableBytes = available; snapshot.storageTotalBytes = Int64(total); snapshot.storageUpdatedAt = now
                    snapshot.storageDescription = L("启动卷可用空间（可能含可清理空间）", "Available on startup volume (may include purgeable space)")
                } else { snapshot.storageDescription = L("容量读取失败 · 保留上次读数", "Storage reading failed · Keeping the last value") }
            } catch { snapshot.storageDescription = L("容量读取失败 · 保留上次读数", "Storage reading failed · Keeping the last value") }
        }
        storageTimer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        // A failed read is retried no more than once per hour, not in a tight loop.
        let elapsed = lastStorageAttemptAt.map { max(0, MetricsClock.now - $0) } ?? 0
        let next = max(1, 3600 - elapsed)
        source.schedule(deadline:.now()+next, leeway:.seconds(30))
        source.setEventHandler { [weak self] in
            guard let self, self.running, !self.suspended else { return }
            self.refreshStorageIfNeeded(force:false); self.publish()
        }
        storageTimer = source; source.resume()
    }
    private func shouldAttemptStorage(force: Bool, at now: TimeInterval) -> Bool {
        force || lastStorageAttemptAt == nil || now - lastStorageAttemptAt! >= 3600
    }
    private func publish() {
        summarizePressure(at:MetricsClock.now)
        let value = snapshot
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = value; self.onUpdate?(value)
        }
    }
}


/// Continuous monotonic time is unaffected by date/time-zone edits and advances
/// during sleep. suspend() closes observation before the sleep gap; the trailing
/// one-hour window can therefore age out history without crediting that gap.
private enum MetricsClock {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static var now: TimeInterval { Double(mach_continuous_time()) * secondsPerTick }
}

/// Narrow, read-only AppleSMC client. No key writes, enumeration, helper, fan
/// control, network, or privileged commands. The 80-byte ABI is verified locally.
private final class ReadOnlyCPUTemperature {
    private var connection: io_connect_t = 0
    private var keys: [(key: UInt32, type: UInt32, size: UInt32)] = []
    init?() {
        let brand = Self.stringSysctl("machdep.cpu.brand_string") ?? ""
        let candidates: [String]
        if brand.hasPrefix("Apple M4") {
            candidates = ["Te05","Te0S","Te09","Te0H","Tp01","Tp05","Tp09","Tp0D","Tp0V","Tp0Y","Tp0b","Tp0e"]
        } else if brand.hasPrefix("Apple M3") {
            candidates = ["Te05","Te0L","Te0P","Te0S","Tp01","Tp05","Tp09","Tp0D"]
        } else if brand.hasPrefix("Apple M2") {
            candidates = ["Tp1h","Tp1t","Tp1p","Tp1l","Tp01","Tp05","Tp09","Tp0D","Tp0X","Tp0b","Tp0f","Tp0j"]
        } else if brand.hasPrefix("Apple M1") {
            candidates = ["Tp09","Tp0T","Tp01","Tp05","Tp0D","Tp0H","Tp0L","Tp0P","Tp0X","Tp0b"]
        } else if brand.contains("Intel") { candidates = ["TC0P"] }
        else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let result = IOServiceOpen(service,mach_task_self_,0,&connection); IOObjectRelease(service)
        guard result == KERN_SUCCESS, connection != 0 else { return nil }
        for key in candidates {
            if let info = call(key:Self.four(key),command:9,size:0) {
                let size = Self.u32(info,28), type = Self.u32(info,32)
                if (type == Self.four("flt ") && size == 4) || (type == Self.four("sp78") && size == 2) {
                    keys.append((Self.four(key),type,size))
                }
            }
        }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    func read() -> (value:Double,count:Int)? {
        var values:[Double] = []
        for spec in keys {
            guard let data = call(key:spec.key,command:5,size:spec.size) else { continue }
            let value:Double
            if spec.type == Self.four("flt ") { value = Double(Float(bitPattern:Self.u32(data,48))) }
            else { value = Double(Int16(bitPattern:UInt16(data[48])<<8 | UInt16(data[49]))) / 256 }
            if value.isFinite && (10...120).contains(value) { values.append(value) }
        }
        guard !values.isEmpty else { return nil }
        return (values.reduce(0,+) / Double(values.count), values.count)
    }
    private func call(key:UInt32,command:UInt8,size:UInt32) -> [UInt8]? {
        guard connection != 0, command == 5 || command == 9 else { return nil }
        var input = [UInt8](repeating:0,count:80), output = input
        Self.put(&input,0,key); Self.put(&input,28,size); input[42] = command
        var outputSize = 80
        let result = input.withUnsafeBytes { src in output.withUnsafeMutableBytes { dst in
            IOConnectCallStructMethod(connection,2,src.baseAddress,80,dst.baseAddress,&outputSize)
        } }
        guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else { return nil }
        return output
    }
    private static func four(_ value:String) -> UInt32 { value.utf8.reduce(0){ ($0 << 8) | UInt32($1) } }
    private static func put(_ bytes:inout [UInt8],_ offset:Int,_ value:UInt32) { withUnsafeBytes(of:value){bytes.replaceSubrange(offset..<offset+4,with:$0)} }
    private static func u32(_ bytes:[UInt8],_ offset:Int)->UInt32 { UInt32(bytes[offset]) | UInt32(bytes[offset+1])<<8 | UInt32(bytes[offset+2])<<16 | UInt32(bytes[offset+3])<<24 }
    private static func stringSysctl(_ name:String)->String? {
        var size=0
        guard sysctlbyname(name,nil,&size,nil,0)==0, size>0, size<256 else {return nil}
        var bytes=[CChar](repeating:0,count:size)
        guard sysctlbyname(name,&bytes,&size,nil,0)==0 else {return nil}
        return String(cString:bytes)
    }
}
