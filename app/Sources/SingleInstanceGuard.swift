import AppKit
import Darwin

// Retain the acquired guard for the full normal application lifetime. QA command
// modes bypass acquisition in the caller. Never unlink a held lock file: doing
// so could let another process lock a different inode at the same pathname.
final class SingleInstanceGuard {
    enum Acquisition {
        case acquired(SingleInstanceGuard)
        case alreadyRunning(pid: pid_t?)
        case failed(message: String)
    }
    struct RunningApp {
        let bundleID: String?
        let pid: pid_t
        let terminated: Bool
        let finishedLaunching: Bool
    }
    private let descriptor: Int32
    let lockPath: String
    var closeOnExec: Bool { fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0 }

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor; lockPath = path
    }

    static func existingPID(bundleID: String, ownPID: pid_t, apps: [RunningApp]) -> pid_t? {
        apps.first { !$0.terminated && $0.finishedLaunching && $0.pid != ownPID && $0.bundleID == bundleID }?.pid
    }

    static func acquire(bundleID: String) -> Acquisition {
        // Older releases did not have a file lock. Do not run a second pet on
        // top of them and do not send activation/quit events to the other app.
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningApp(bundleID: $0.bundleIdentifier, pid: $0.processIdentifier, terminated: $0.isTerminated, finishedLaunching: $0.isFinishedLaunching)
        }
        if let pid = existingPID(bundleID: bundleID, ownPID: getpid(), apps: apps) {
            return .alreadyRunning(pid: pid)
        }
        let directory = URL(fileURLWithPath: "/private/tmp/desktop-companion-locks-\(getuid())", isDirectory: true)
        return acquireLock(bundleID: bundleID, directory: directory)
    }

    // Internal entry point permits subprocess-only QA in a fresh fixture
    // directory without touching the real app's lock or looking at its state.
    static func acquireLock(bundleID: String, directory: URL) -> Acquisition {
        let valid = !bundleID.isEmpty && bundleID.utf8.count <= 180 && bundleID.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        }
        guard valid, directory.isFileURL else { return .failed(message: L("单实例标识或锁目录不合法。", "Invalid instance identifier or lock directory.")) }
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            return .failed(message: L("无法创建单实例锁目录。", "Cannot create the instance lock directory."))
        }
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return .failed(message: L("无法安全打开单实例锁目录。", "Cannot securely open the instance lock directory.")) }
        defer { close(dir) }
        var directoryInfo = stat()
        guard fstat(dir, &directoryInfo) == 0,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_mode & 0o777 == 0o700 else {
            return .failed(message: L("单实例锁目录的所有者或权限不正确。", "Unexpected owner or permissions on the instance lock directory."))
        }
        let filename = bundleID + ".lock"
        // Separate exclusive creation from opening an existing inode. On this
        // macOS filesystem concurrent O_CREAT/openat calls can transiently fail
        // with ENOENT; O_EXCL gives the losers an unambiguous EEXIST to follow.
        var fd = openat(dir, filename, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0, errno == EEXIST { fd = openat(dir, filename, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { return .failed(message: L("无法安全打开单实例锁文件（系统错误 \(errno)）。", "Cannot securely open the instance lock file (system error \(errno)).")) }
        var keep = false
        defer { if !keep { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1 else {
            return .failed(message: L("单实例锁文件的类型、所有者或权限不正确。", "Unexpected file type, owner or permissions on the instance lock file."))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { return .alreadyRunning(pid: readPID(fd)) }
            return .failed(message: L("无法获取单实例锁。", "Cannot acquire the instance lock."))
        }
        let bytes = Array("\(getpid())\n".utf8)
        guard ftruncate(fd, 0) == 0 else { return .failed(message: L("无法更新单实例锁记录。", "Cannot update the instance lock record.")) }
        let written = bytes.withUnsafeBytes { pointer in
            pwrite(fd, pointer.baseAddress, pointer.count, 0)
        }
        guard written == bytes.count else { return .failed(message: L("无法写入单实例锁记录。", "Cannot write the instance lock record.")) }
        keep = true
        return .acquired(SingleInstanceGuard(descriptor: fd, path: directory.appendingPathComponent(filename).path))
    }

    private static func readPID(_ fd: Int32) -> pid_t? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &bytes, bytes.count, 0)
        guard count > 0,
              let pid = Int32(String(decoding: bytes.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
