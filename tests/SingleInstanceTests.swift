import Foundation
import Darwin

@main struct SingleInstanceTests {
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--lock-child" {
            let result = SingleInstanceGuard.acquireLock(bundleID: CommandLine.arguments[3], directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            switch result {
            case .acquired(let guardObject):
                FileHandle.standardOutput.write(Data("acquired\n".utf8))
                _ = FileHandle.standardInput.readDataToEndOfFile()
                withExtendedLifetime(guardObject) {}
            case .alreadyRunning: FileHandle.standardOutput.write(Data("busy\n".utf8))
            case .failed(let message): FileHandle.standardOutput.write(Data("failed:\(message)\n".utf8))
            }
            return
        }
        var passed = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fatalError("FAIL: \(label)") }; passed += 1
        }
        func acquire(_ id: String, _ directory: URL) -> SingleInstanceGuard? {
            if case .acquired(let lock) = SingleInstanceGuard.acquireLock(bundleID: id, directory: directory) { return lock }
            return nil
        }
        func fails(_ id: String, _ directory: URL) -> Bool {
            if case .failed = SingleInstanceGuard.acquireLock(bundleID: id, directory: directory) { return true }; return false
        }
        let fixture = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("companion-lock-qa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = fixture.appendingPathComponent("locks", isDirectory: true)
        let id = "local.companion.test"
        var lease = acquire(id, directory)
        check(lease != nil, "first acquisition")
        check(lease!.closeOnExec, "lock fd cannot leak across exec")
        var st = stat()
        check(stat(lease!.lockPath, &st) == 0 && st.st_mode & 0o777 == 0o600 && st.st_uid == getuid(), "private 0600 owned lock")
        check(stat(directory.path, &st) == 0 && st.st_mode & 0o777 == 0o700, "private 0700 owned directory")
        if case .alreadyRunning(let pid) = SingleInstanceGuard.acquireLock(bundleID: id, directory: directory) {
            check(pid == getpid(), "busy lock reports owning pid")
        } else { fatalError("FAIL: second acquisition must fail") }
        let stable = lease!.lockPath
        lease = nil
        check(FileManager.default.fileExists(atPath: stable), "release does not unlink stable lock inode")
        lease = acquire(id, directory)
        check(lease != nil, "stale pid record does not block unlocked file")
        lease = nil
        check(fails("../escape", directory), "path traversal id rejected")
        check(fails(String(repeating: "a", count: 181), directory), "oversized filename rejected")
        check(fails("", directory), "empty id rejected")
        let linkPath = directory.appendingPathComponent("symlink.lock")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: URL(fileURLWithPath: stable))
        check(fails("symlink", directory), "symlink lock rejected")
        try FileManager.default.linkItem(at: URL(fileURLWithPath: stable), to: directory.appendingPathComponent("hardlink.lock"))
        check(fails("hardlink", directory), "hardlinked lock rejected")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hardlink.lock"))
        chmod(stable, 0o644)
        check(fails(id, directory), "insecure lock permissions rejected")
        chmod(stable, 0o600)
        chmod(directory.path, 0o755)
        check(fails(id, directory), "insecure directory permissions rejected")
        chmod(directory.path, 0o700)
        let dirLink = fixture.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: directory)
        check(fails(id, dirLink), "symlink directory rejected")
        let apps: [SingleInstanceGuard.RunningApp] = [
            .init(bundleID: id, pid: 101, terminated: false, finishedLaunching: true),
            .init(bundleID: id, pid: 102, terminated: true, finishedLaunching: true),
            .init(bundleID: "different", pid: 103, terminated: false, finishedLaunching: true),
            .init(bundleID: id, pid: 105, terminated: false, finishedLaunching: false),
            .init(bundleID: id, pid: 104, terminated: false, finishedLaunching: true)
        ]
        check(SingleInstanceGuard.existingPID(bundleID: id, ownPID: 101, apps: apps) == 104, "legacy bundle instance detected without file lock")
        check(SingleInstanceGuard.existingPID(bundleID: "different", ownPID: 103, apps: apps) == nil, "own app excluded")
        check(SingleInstanceGuard.existingPID(bundleID: "absent", ownPID: 101, apps: apps) == nil, "other bundle unaffected")
        check(SingleInstanceGuard.existingPID(bundleID: id, ownPID: 101, apps: Array(apps.dropLast())) == nil, "launching copy ignored so file lock elects winner")
        // Four CLI-only children contend for the same fresh fixture lock. The
        // winner is held until every result is received, avoiding timing luck.
        var children: [(Process, Pipe, Pipe)] = []
        for _ in 0..<4 {
            let child = Process(), input = Pipe(), output = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--lock-child", directory.path, "race"]
            child.standardInput = input; child.standardOutput = output
            try child.run(); children.append((child, input, output))
        }
        var outputs: [String] = []
        for (_, _, output) in children {
            outputs.append(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for (child, input, _) in children { try input.fileHandleForWriting.close(); child.waitUntilExit() }
        FileHandle.standardError.write(Data("Concurrent lock results: \(outputs)\n".utf8))
        check(outputs.filter { $0 == "acquired" }.count == 1 && outputs.filter { $0 == "busy" }.count == 3, "four concurrent processes produce exactly one owner")
        check(children.allSatisfy { $0.0.terminationStatus == 0 }, "test children exit cleanly")
        let after = acquire("race", directory)
        check(after != nil, "child exit releases OS lock")
        withExtendedLifetime(after) {}
        print("{\"passed\":\(passed),\"failed\":0,\"user_apps_started_or_stopped\":false,\"real_app_lock_touched\":false}")
    }
}
