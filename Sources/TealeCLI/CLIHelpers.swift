import Foundation

// MARK: - Logging

func printErr(_ message: String) {
    FileHandle.standardError.write(Data("[\(timestamp())] \(message)\n".utf8))
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

// MARK: - PID File

enum PIDFile {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".teale")
    }

    static var path: URL {
        directory.appending(path: "teale.pid")
    }

    static func write() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "\(ProcessInfo.processInfo.processIdentifier)".write(
            to: path, atomically: true, encoding: .utf8
        )
    }

    static func read() -> pid_t? {
        guard let contents = try? String(contentsOf: path, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        // Verify process is still running
        guard kill(pid, 0) == 0 else {
            remove()
            return nil
        }
        return pid
    }

    static func remove() {
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - Signal Handling

/// Block the current async context until SIGINT or SIGTERM is received.
func awaitShutdownSignal() async {
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var resumed = false
        let resume = {
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
        sigintSource.setEventHandler { resume() }
        sigtermSource.setEventHandler { resume() }
        sigintSource.resume()
        sigtermSource.resume()
    }

    sigintSource.cancel()
    sigtermSource.cancel()
}
