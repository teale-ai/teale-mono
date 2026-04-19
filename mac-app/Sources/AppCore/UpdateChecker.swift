import Foundation
import SharedTypes
#if canImport(AppKit)
import AppKit
#endif

/// Lightweight auto-updater that checks GitHub Releases for newer versions.
@MainActor
public final class UpdateChecker {
    private static let repo = "taylorhou/teale-mac-app"
    private static let checkIntervalKey = "teale.lastUpdateCheck"
    private static let dismissedVersionKey = "teale.dismissedUpdateVersion"
    private static let checkInterval: TimeInterval = 4 * 3600 // 4 hours

    public private(set) var updateAvailable = false
    public private(set) var latestTag: String?
    public private(set) var releaseURL: URL?
    public private(set) var checking = false

    public init() {}

    /// Check for updates if enough time has passed since last check.
    public func checkIfNeeded() async {
        let lastCheck = UserDefaults.standard.double(forKey: Self.checkIntervalKey)
        let now = Date().timeIntervalSince1970
        guard now - lastCheck > Self.checkInterval else { return }
        await check()
    }

    /// Force a check regardless of interval.
    public func check() async {
        checking = true
        defer { checking = false }

        guard let (tag, url) = await fetchLatestRelease() else { return }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkIntervalKey)

        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedVersionKey)
        if tag != dismissed && isNewer(tag: tag) {
            latestTag = tag
            releaseURL = url
            updateAvailable = true
        }
    }

    /// User chose to skip this version.
    public func dismissUpdate() {
        if let tag = latestTag {
            UserDefaults.standard.set(tag, forKey: Self.dismissedVersionKey)
        }
        updateAvailable = false
    }

    /// Download and install the update (replace current .app and relaunch).
    public func installUpdate() async -> Bool {
        guard let tag = latestTag else { return false }

        let downloadURL = URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/Teale.zip")!
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let zipPath = tempDir.appendingPathComponent("Teale.zip")

            // Download
            let (localURL, _) = try await URLSession.shared.download(from: downloadURL)
            try FileManager.default.moveItem(at: localURL, to: zipPath)

            // Unzip using ditto (preserves macOS metadata)
            let unzipDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipPath.path, unzipDir.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }

            // Find the .app in extracted contents
            let extracted = try FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)
            guard let newApp = extracted.first(where: { $0.pathExtension == "app" }) else { return false }

            // Replace current app
            guard let currentApp = Bundle.main.bundleURL as URL? else { return false }
            let backup = currentApp.deletingLastPathComponent().appendingPathComponent("Teale.app.bak")

            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: currentApp, to: backup)
            try FileManager.default.moveItem(at: newApp, to: currentApp)

            // Strip quarantine
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", currentApp.path]
            try? xattr.run()
            xattr.waitUntilExit()

            // Remove backup
            try? FileManager.default.removeItem(at: backup)

            // Relaunch
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", currentApp.path]
            try relaunch.run()

            // Quit current instance
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            return false
        }
    }

    // MARK: - Private

    private func fetchLatestRelease() async -> (tag: String, url: URL)? {
        let apiURL = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String,
              let url = URL(string: htmlURL) else {
            return nil
        }
        return (tag, url)
    }

    private func isNewer(tag: String) -> Bool {
        // Tags use the same YYYY.MM.DD.HHMM format as internal builds.
        // Extract the numeric version from the tag (strip "v" prefix) and
        // compare against the current build's CFBundleVersion (YYYYMMDDHHMM).
        let tagVersion = tag
            .replacingOccurrences(of: "v", with: "")
            .replacingOccurrences(of: ".", with: "")
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"

        // Numeric comparison: higher number = newer build
        guard let remote = Int(tagVersion), let local = Int(currentVersion) else {
            // Fallback: if parsing fails, treat any different tag as newer
            return !tag.contains(BuildVersion.commit)
        }
        return remote > local
    }
}
