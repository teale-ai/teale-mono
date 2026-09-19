import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide, per-user ownership guard for the Teale app.
///
/// LaunchServices' `LSMultipleInstancesProhibited` covers normal Finder/Dock
/// launches, but it does not serialize a login item against a LaunchAgent or
/// a direct executable launch. `flock` does, and the kernel releases it after
/// a crash or SIGKILL, so no stale PID file can strand the app.
public final class AppInstanceLock: @unchecked Sendable {
    public static let shared = AppInstanceLock()

    private let lockURL: URL
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1

    public init(lockURL: URL? = nil) {
        if let lockURL {
            self.lockURL = lockURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            self.lockURL = support
                .appendingPathComponent("Teale", isDirectory: true)
                .appendingPathComponent("app-instance.lock")
        }
    }

    deinit { release() }

    /// Returns true only for the one live Teale process that owns the lock.
    public func acquire() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if descriptor >= 0 { return true }

        let directory = lockURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }

        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }

        descriptor = fd
        let pidText = "\(getpid())\n"
        _ = ftruncate(fd, 0)
        _ = pidText.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        return true
    }

    /// Release immediately before the in-app updater launches its replacement.
    public func release() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
