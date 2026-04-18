import ArgumentParser
import Foundation

struct Down: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the running Teale node"
    )

    func run() async throws {
        guard let pid = PIDFile.read() else {
            print("Teale node is not running.")
            return
        }

        kill(pid, SIGTERM)

        // Wait up to 5 seconds for process to exit
        for _ in 0..<50 {
            if kill(pid, 0) != 0 {
                PIDFile.remove()
                print("Teale node stopped.")
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        print("Sent shutdown signal to Teale (PID \(pid)). It may still be cleaning up.")
    }
}
