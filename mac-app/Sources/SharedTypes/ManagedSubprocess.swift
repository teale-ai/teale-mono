import Foundation

/// Distinguishes "the client went away" from "the backend failed" in the
/// HTTP-proxying providers, so a cancelled request does not mark the
/// engine as errored.
public enum HTTPProviderCancellation {
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }
}

#if os(macOS)
import Darwin

/// Shared lifecycle helpers for the backend subprocesses Teale spawns
/// (llama-server, ds4-server, rapid-mlx, the privacy-filter helper):
/// private log files, bounded SIGTERM→SIGKILL shutdown, and killing
/// children when the app exits normally.
public enum ManagedSubprocess {

    // MARK: Logs

    /// `~/Library/Logs/Teale`, created with 0700 permissions.
    public static func logsDirectory() -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let dir = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Teale", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    /// Open (truncating) `~/Library/Logs/Teale/<name>` for a child's
    /// stdout/stderr. The file is created 0600 and opened with O_NOFOLLOW so
    /// a planted symlink cannot redirect the write. Falls back to the null
    /// device, never to a shared world-writable path, and never to a pipe
    /// nobody drains.
    public static func openLogFile(named name: String) -> FileHandle {
        guard SafePathComponent.isValid(name) else { return FileHandle.nullDevice }
        let url = logsDirectory().appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return FileHandle.nullDevice }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: Shutdown

    /// SIGTERM, wait up to `grace` without blocking a thread, then SIGKILL.
    public static func terminate(_ process: Process, grace: TimeInterval = 5) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        if await waitForExit(process, timeout: grace) { return }
        kill(pid, SIGKILL)
        _ = await waitForExit(process, timeout: 2)
    }

    /// Polls `isRunning` until the process exits or `timeout` elapses.
    /// Returns true when it exited.
    @discardableResult
    public static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            // A cancelled task makes Task.sleep throw immediately; fall back
            // to a short blocking sleep so the bounded wait still waits.
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                usleep(100_000)
            }
        }
        return !process.isRunning
    }

    // MARK: Exit cleanup

    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var pids: Set<pid_t> = []
        var installed = false
    }

    private static let registry = Registry()

    /// Track a running child so it is sent SIGTERM when this process exits
    /// normally (`exit()`, NSApplication terminate). Children cannot be
    /// reaped if Teale itself is SIGKILLed; providers additionally verify
    /// the identity of whatever answers on their port.
    public static func register(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        registry.lock.lock()
        registry.pids.insert(pid)
        let needsInstall = !registry.installed
        registry.installed = true
        registry.lock.unlock()
        if needsInstall {
            atexit {
                ManagedSubprocess.terminateRegisteredChildren()
            }
        }
    }

    public static func unregister(_ process: Process) {
        let pid = process.processIdentifier
        registry.lock.lock()
        registry.pids.remove(pid)
        registry.lock.unlock()
    }

    static func terminateRegisteredChildren() {
        registry.lock.lock()
        let pids = registry.pids
        registry.pids.removeAll()
        registry.lock.unlock()
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }
}
#endif
