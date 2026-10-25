import Foundation

@main
struct MonitorTests {
    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
    }

    static func wait(_ timeout: TimeInterval = 1.2, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline { pump(0.005) }
        return predicate()
    }

    final class Probe {
        private let lock = NSLock()
        private var count = 0
        let delay: TimeInterval
        init(delay: TimeInterval = 0.006) { self.delay = delay }
        func read() -> BluetoothBatterySnapshot {
            lock.lock(); count += 1; let value = count; lock.unlock()
            Thread.sleep(forTimeInterval: delay)
            return BluetoothBatterySnapshot(updatedAt: Date(), statusText: "read-\(value)", readSucceeded: true)
        }
    }

    static func main() throws {
        let started = Date()
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks.append(message)
        }

        let probe = Probe()
        let monitor = BluetoothBatteryMonitor(interval: 0.12, cooldown: 0.04, reader: probe.read)
        var updates: [String] = []
        var allCallbacksOnMain = true
        monitor.onUpdate = { value in
            allCallbacksOnMain = allCallbacksOnMain && Thread.isMainThread
            updates.append(value.statusText)
        }

        monitor.refresh(manual: true); pump(0.15)
        check(monitor.readCount == 0 && updates.isEmpty && !monitor.hasScheduledRead,
              "hidden monitor schedules and performs no reads")
        monitor.setVisible(true)
        check(wait { updates.count == 1 }, "opening page delivers first snapshot")
        check(monitor.readCount == 1 && monitor.hasScheduledRead, "one read on open followed by scheduled refresh")
        monitor.refresh(manual: true); pump(0.012)
        check(monitor.readCount == 1, "repeated immediate manual refresh is throttled")
        pump(0.045); monitor.refresh(manual: true)
        check(wait { updates.count == 2 }, "manual refresh after cooldown delivers another snapshot")
        check(monitor.readCount == 2, "manual refresh does not start parallel duplicate reads")
        check(wait { updates.count >= 3 }, "visible page refreshes automatically")
        monitor.setVisible(false)
        let closedCount = monitor.readCount; let closedUpdates = updates.count
        pump(0.18)
        check(monitor.readCount == closedCount && updates.count == closedUpdates && !monitor.hasScheduledRead,
              "closing page cancels future reads and callbacks")
        monitor.setVisible(true)
        check(wait { updates.count > closedUpdates }, "reopening page resumes reading")
        monitor.suspend()
        let suspendedCount = monitor.readCount; let suspendedUpdates = updates.count
        monitor.refresh(manual: true); pump(0.18)
        check(monitor.readCount == suspendedCount && updates.count == suspendedUpdates && !monitor.hasScheduledRead,
              "suspension blocks automatic and manual reads")
        monitor.resume()
        check(wait { updates.count > suspendedUpdates }, "resume delivers a fresh read without waiting a full interval")
        monitor.stop()
        let stoppedCount = monitor.readCount; pump(0.18)
        check(monitor.readCount == stoppedCount && !monitor.hasScheduledRead, "stop leaves no timer or further reads")
        check(allCallbacksOnMain, "all updates delivered on main thread")

        let closedProbe = Probe(delay: 0.10)
        let closed = BluetoothBatteryMonitor(interval: 0.12, cooldown: 0.04, reader: closedProbe.read)
        var closedResults: [String] = []
        closed.onUpdate = { closedResults.append($0.statusText) }
        closed.setVisible(true); closed.setVisible(false); pump(0.17)
        check(closed.readCount == 1 && closedResults.isEmpty && !closed.hasScheduledRead,
              "closing during an in-flight read discards its result and does not reschedule")
        closed.stop()

        let reopenedProbe = Probe(delay: 0.10)
        let reopened = BluetoothBatteryMonitor(interval: 0.12, cooldown: 0.04, reader: reopenedProbe.read)
        var reopenedResults: [String] = []
        reopened.onUpdate = { reopenedResults.append($0.statusText) }
        reopened.setVisible(true); reopened.setVisible(false); reopened.setVisible(true)
        check(wait { !reopenedResults.isEmpty }, "reopened page recovers after an older read finishes")
        check(reopenedResults == ["read-2"] && reopened.readCount == 2,
              "generation change rejects the old snapshot and delivers only the new request")
        reopened.stop()

        let suspendedProbe = Probe(delay: 0.10)
        let suspended = BluetoothBatteryMonitor(interval: 0.12, cooldown: 0.04, reader: suspendedProbe.read)
        var suspendedResults: [String] = []
        suspended.onUpdate = { suspendedResults.append($0.statusText) }
        suspended.setVisible(true); suspended.suspend(); pump(0.16)
        check(suspendedResults.isEmpty && suspended.readCount == 1 && !suspended.hasScheduledRead,
              "suspension during an in-flight read suppresses its result and timer")
        suspended.resume()
        check(wait { suspendedResults == ["read-2"] }, "resume after an in-flight suspension obtains a new snapshot")
        suspended.stop()

        let result: [String: Any] = ["passed": checks.count, "checks": checks,
                                     "elapsedSeconds": Date().timeIntervalSince(started)]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
