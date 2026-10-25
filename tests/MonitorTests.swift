import Foundation

@main
struct MonitorTests {
    static func pump(_ seconds: TimeInterval) {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    static func wait(_ timeout: TimeInterval = 5, until predicate: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { pump(0.005) }
        return predicate()
    }

    /// Only the main thread advances policy time. Queue or CI latency cannot
    /// accidentally consume the refresh cooldown under test.
    final class Clock {
        var now: TimeInterval = 1000
        func read() -> TimeInterval { now }
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    /// Reads finish only when the test releases them. This makes close/reopen
    /// and suspend races explicit instead of depending on a 100 ms sleep.
    final class Probe {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var started = 0
        private var finished = 0
        private var timeouts = 0
        var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
        var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finished }
        var timeoutCount: Int { lock.lock(); defer { lock.unlock() }; return timeouts }
        func completeOne() { gate.signal() }
        func read() -> BluetoothBatterySnapshot {
            lock.lock(); started += 1; let value = started; lock.unlock()
            let outcome = gate.wait(timeout: .now() + 10)
            lock.lock()
            if outcome == .timedOut { timeouts += 1 }
            finished += 1
            lock.unlock()
            return BluetoothBatterySnapshot(updatedAt: Date(), statusText: "read-\(value)", readSucceeded: true)
        }
    }

    static func main() throws {
        let started = ProcessInfo.processInfo.systemUptime
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks.append(message)
        }

        let clock = Clock(), probe = Probe()
        // A long real timer keeps the manual-policy checks independent of timer
        // scheduling. A separate short-timer test below verifies automatic reads.
        let monitor = BluetoothBatteryMonitor(interval: 60, cooldown: 3, clock: clock.read, reader: probe.read)
        var updates: [String] = []
        var allCallbacksOnMain = true
        monitor.onUpdate = { value in
            allCallbacksOnMain = allCallbacksOnMain && Thread.isMainThread
            updates.append(value.statusText)
        }

        monitor.refresh(manual: true)
        check(monitor.readCount == 0 && updates.isEmpty && !monitor.hasScheduledRead,
              "hidden monitor schedules and performs no reads")
        monitor.setVisible(true)
        check(wait { probe.startedCount == 1 }, "opening page starts one background read")
        probe.completeOne()
        check(wait { updates == ["read-1"] }, "opening page delivers first snapshot")
        check(monitor.readCount == 1 && monitor.hasScheduledRead, "one read on open followed by scheduled refresh")
        monitor.refresh(manual: true); monitor.refresh(manual: true)
        check(monitor.readCount == 1, "repeated immediate manual refresh is throttled")
        clock.advance(2.9); monitor.refresh(manual: true)
        check(monitor.readCount == 1 && monitor.hasScheduledRead, "manual refresh remains throttled before cooldown")
        clock.advance(0.2); monitor.refresh(manual: true)
        check(monitor.readCount == 2, "manual refresh starts when logical cooldown has elapsed")
        monitor.refresh(manual: true); monitor.refresh(manual: true)
        check(monitor.readCount == 2, "manual refresh does not start parallel duplicate reads")
        probe.completeOne()
        check(wait { updates == ["read-1", "read-2"] }, "manual refresh after cooldown delivers another snapshot")
        monitor.setVisible(false)
        let closedCount = monitor.readCount; let closedUpdates = updates.count
        clock.advance(120); monitor.refresh(manual: true); pump(0.02)
        check(monitor.readCount == closedCount && updates.count == closedUpdates && !monitor.hasScheduledRead,
              "closing page cancels future reads and callbacks")
        monitor.setVisible(true); probe.completeOne()
        check(wait { updates.count == closedUpdates + 1 }, "reopening page resumes reading")
        monitor.suspend()
        let suspendedCount = monitor.readCount; let suspendedUpdates = updates.count
        clock.advance(120); monitor.refresh(manual: true); pump(0.02)
        check(monitor.readCount == suspendedCount && updates.count == suspendedUpdates && !monitor.hasScheduledRead,
              "suspension blocks automatic and manual reads")
        monitor.resume()
        check(monitor.readCount == suspendedCount + 1, "resume starts immediately without waiting a full interval")
        probe.completeOne()
        check(wait { updates.count == suspendedUpdates + 1 }, "resume delivers a fresh snapshot")
        monitor.stop()
        let stoppedCount = monitor.readCount
        clock.advance(120); monitor.refresh(manual: true); pump(0.02)
        check(monitor.readCount == stoppedCount && !monitor.hasScheduledRead, "stop leaves no timer or further reads")
        check(allCallbacksOnMain, "all updates delivered on main thread")

        let automaticClock = Clock(), automaticProbe = Probe()
        let automatic = BluetoothBatteryMonitor(interval: 0.05, cooldown: 0.01, clock: automaticClock.read, reader: automaticProbe.read)
        var automaticResults = [String]()
        automatic.onUpdate = { automaticResults.append($0.statusText) }
        automatic.setVisible(true); automaticProbe.completeOne()
        check(wait { automaticResults == ["read-1"] }, "automatic test delivers its initial snapshot")
        automaticClock.advance(1)
        // No refresh() call: the actual RunLoop timer must initiate this read.
        check(wait { automatic.readCount == 2 && automaticProbe.startedCount == 2 }, "visible page refreshes automatically")
        automatic.stop(); automaticProbe.completeOne()
        check(wait { automaticProbe.finishedCount == 2 }, "automatic test retires its pending reader")
        pump(0.02)
        check(automaticResults == ["read-1"] && !automatic.hasScheduledRead, "stopping automatic refresh discards its in-flight result")

        let closedClock = Clock(), closedProbe = Probe()
        let closed = BluetoothBatteryMonitor(interval: 60, cooldown: 3, clock: closedClock.read, reader: closedProbe.read)
        var closedResults: [String] = []
        closed.onUpdate = { closedResults.append($0.statusText) }
        closed.setVisible(true)
        check(wait { closedProbe.startedCount == 1 }, "close-race reader is explicitly in flight")
        closed.setVisible(false); closedProbe.completeOne()
        check(wait { closedProbe.finishedCount == 1 }, "close-race reader returns")
        pump(0.02)
        check(closed.readCount == 1 && closedResults.isEmpty && !closed.hasScheduledRead,
              "closing during an in-flight read discards its result and does not reschedule")
        closed.stop()

        let reopenedClock = Clock(), reopenedProbe = Probe()
        let reopened = BluetoothBatteryMonitor(interval: 60, cooldown: 3, clock: reopenedClock.read, reader: reopenedProbe.read)
        var reopenedResults: [String] = []
        reopened.onUpdate = { reopenedResults.append($0.statusText) }
        reopened.setVisible(true)
        check(wait { reopenedProbe.startedCount == 1 }, "reopen-race reader is explicitly in flight")
        reopened.setVisible(false); reopenedClock.advance(61); reopened.setVisible(true)
        reopenedProbe.completeOne()
        check(wait { reopened.readCount == 2 && reopenedProbe.startedCount == 2 }, "reopened page recovers after an older read finishes")
        check(reopenedResults.isEmpty, "generation change rejects the old snapshot before replacement finishes")
        reopenedProbe.completeOne()
        check(wait { reopenedResults == ["read-2"] }, "generation change delivers only the new request")
        reopened.stop()

        let suspendedClock = Clock(), suspendedProbe = Probe()
        let suspended = BluetoothBatteryMonitor(interval: 60, cooldown: 3, clock: suspendedClock.read, reader: suspendedProbe.read)
        var suspendedResults: [String] = []
        suspended.onUpdate = { suspendedResults.append($0.statusText) }
        suspended.setVisible(true)
        check(wait { suspendedProbe.startedCount == 1 }, "suspend-race reader is explicitly in flight")
        suspended.suspend(); suspendedProbe.completeOne()
        check(wait { suspendedProbe.finishedCount == 1 }, "suspend-race reader returns")
        pump(0.02)
        check(suspendedResults.isEmpty && suspended.readCount == 1 && !suspended.hasScheduledRead,
              "suspension during an in-flight read suppresses its result and timer")
        suspended.resume(); suspendedProbe.completeOne()
        check(wait { suspendedResults == ["read-2"] }, "resume after an in-flight suspension obtains a new snapshot")
        suspended.stop()
        check([probe, automaticProbe, closedProbe, reopenedProbe, suspendedProbe].allSatisfy { $0.timeoutCount == 0 },
              "all synthetic readers were explicitly completed without timeout")

        let result: [String: Any] = ["passed": checks.count, "checks": checks,
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
            "policyClock": "injected", "readerCompletion": "explicit semaphore", "automaticTimerTested": true]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
