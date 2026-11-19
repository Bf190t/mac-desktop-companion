import Foundation

/// Sandbox for the optional model helpers (local chat and reading voice).
///
/// Network access is denied. Since 0.2.2 the helper also cannot start any program other than its own
/// Python runtime, ask macOS to open an app or a link, or send Apple events: with network denial alone,
/// code running in the helper could run /usr/bin/open and let an app outside the sandbox go online
/// (security review, 2026-11-19). It also cannot use the microphone or camera, change any app's preferences
/// or use the pasteboard, and it can write only to its own folder in this user's private temporary folder.
/// voice/install.py keeps a copy of the same profile; a test checks both match.
enum WorkerSandbox {
    static let profile = "(version 1)(allow default)(deny network*)(deny lsopen)(deny appleevent-send)"
        + "(deny mach-lookup (global-name \"com.apple.coreservices.launchservicesd\") (global-name-prefix \"com.apple.lsd.\")"
        + " (global-name \"com.apple.pasteboard.1\") (global-name-prefix \"com.apple.backgroundtaskmanagement\")"
        + " (global-name-prefix \"com.apple.coreservices.sharedfilelistd\") (global-name \"com.apple.dock.server\")"
        + " (global-name \"com.apple.securityd.xpc\") (global-name \"com.apple.SecurityServer\"))"
        + "(deny signal)(allow signal (target same-sandbox))"
        + "(deny process-exec*)(allow process-exec (subpath (param \"RUNTIME\")))"
        + "(deny device-microphone)(deny device-camera)(deny user-preference-write)"
        + "(deny file-write*)(allow file-write* (subpath (param \"USERDIR\")) (literal \"/dev/null\") (literal \"/dev/zero\")"
        + " (literal \"/dev/dtracehelper\") (subpath \"/dev/fd\"))"

    /// The runtime folder that may be executed: two levels above the real Python binary (…/python-base).
    /// realpath(3), not URL.resolvingSymlinksInPath: the latter drops a leading /private (/private/tmp → /tmp),
    /// while the sandbox sees the kernel's path with /private.
    static func runtime(for python: URL) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(python.path, &buffer) != nil ? String(cString: buffer) : python.path
        return URL(fileURLWithPath: real).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The only place a helper may write (besides /dev/null and a few other /dev nodes): its own owner-only folder
    /// inside this user's private temporary folder, …/T/desktop-companion-helpers; the helper's TMPDIR points there too.
    /// Not T itself, which also holds the installers' downloads and the single-instance lock, and not T's parent,
    /// which holds other apps' caches (C/) and system data (0/) (security review 2026-11-19, third round).
    /// Nothing written there runs later outside the sandbox, unlike ~/Library/LaunchAgents or shell start-up files.
    static let helperFolderName = "desktop-companion-helpers"

    static func userDirectory() -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        let temp = length > 0 && length <= buffer.count ? String(cString: buffer) : NSTemporaryDirectory()
        var real = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = realpath(temp, &real) != nil ? String(cString: real) : temp
        let folder = URL(fileURLWithPath: resolved, isDirectory: true).appendingPathComponent(helperFolderName, isDirectory: true)
        // Create it owner-only; tighten an existing folder of ours. Anything else in the way (a link, a file) is left
        // alone: the sandbox checks resolved paths, so the helper then simply cannot write.
        _ = mkdir(folder.path, 0o700)
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)   // never follow a planted link
        if fd >= 0 {
            var info = stat()
            if fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 != 0 { _ = fchmod(fd, 0o700) }
            close(fd)
        }
        return folder
    }

    /// Arguments for /usr/bin/sandbox-exec that run `python` under the profile; append Python's own arguments.
    static func arguments(python: URL) -> [String] {
        ["-D", "RUNTIME=" + runtime(for: python).path, "-D", "USERDIR=" + userDirectory().path, "-p", profile, python.path]
    }

    /// Environment for a helper: nothing inherited from the app, offline switches for the model libraries.
    static func environment() -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "TMPDIR": userDirectory().path + "/", "HF_HUB_OFFLINE": "1",
         "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1"]
    }
}
