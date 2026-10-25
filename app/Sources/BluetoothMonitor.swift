import Foundation

// Main-thread scheduling; all device reads run serially at utility priority.
// This observes system snapshots only while the user is viewing this page.
final class BluetoothBatteryMonitor {
    private let queue = DispatchQueue(label: "io.github.bf190t.desktop-companion.bluetooth-battery", qos: .utility)
    private let reader: () -> BluetoothBatterySnapshot
    private let interval: TimeInterval
    private let cooldown: TimeInterval
    private let clock: () -> TimeInterval
    private var timer: Timer?
    private var lastAttempt: TimeInterval?
    private var generation = 0
    private var inFlight = false
    private(set) var isVisible = false
    private(set) var isSuspended = false
    private(set) var readCount = 0
    private(set) var latest = BluetoothBatterySnapshot()
    var onUpdate: ((BluetoothBatterySnapshot) -> Void)?
    var hasScheduledRead: Bool { timer != nil }

    init(interval: TimeInterval = 60, cooldown: TimeInterval = 3,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         reader: @escaping () -> BluetoothBatterySnapshot = { BluetoothBatteryReader.read() }) {
        self.interval = interval; self.cooldown = cooldown; self.clock = clock; self.reader = reader
    }
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { refresh() } else { cancel() }
    }
    func suspend() {
        isSuspended = true; lastAttempt = nil; cancel()
    }
    func resume() {
        guard isSuspended else { return }
        isSuspended = false; lastAttempt = nil
        if isVisible { refresh() }
    }
    func stop() { isVisible = false; cancel() }
    private func cancel() {
        timer?.invalidate(); timer = nil; generation += 1
    }
    func refresh(manual: Bool = false) {
        guard isVisible, !isSuspended else { return }
        timer?.invalidate(); timer = nil
        if inFlight { return }
        let age = lastAttempt.map { max(0, clock() - $0) } ?? .infinity
        let threshold = manual ? cooldown : interval
        if age < threshold { schedule(after: interval - min(age, interval)); return }
        lastAttempt = clock(); inFlight = true; readCount += 1
        let requestGeneration = generation
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.reader()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.inFlight = false
                guard self.isVisible, !self.isSuspended else { return }
                if requestGeneration == self.generation {
                    self.latest = result; self.onUpdate?(result)
                    self.schedule(after: self.interval)
                } else { self.refresh() }
            }
        }
    }
    private func schedule(after delay: TimeInterval) {
        guard isVisible, !isSuspended else { return }
        timer?.invalidate()
        let next = Timer(timeInterval: max(0.01, delay), repeats: false) { [weak self] _ in
            self?.timer = nil; self?.refresh()
        }
        next.tolerance = min(10, interval / 6)
        timer = next; RunLoop.main.add(next, forMode: .common)
    }
}
