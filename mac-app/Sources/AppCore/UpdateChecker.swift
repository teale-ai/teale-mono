import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Lightweight auto-updater that checks GitHub Releases for newer versions.
@MainActor
@Observable
public final class UpdateChecker {
    private static let repo = "teale-ai/teale-mono"
    private static let checkIntervalKey = "teale.lastUpdateCheck"
    private static let dismissedVersionKey = "teale.dismissedUpdateVersion"
    private static let checkInterval: TimeInterval = 4 * 3600 // 4 hours
    private static let releaseTagPrefix = "mac-v"
    private static let releaseAssetName = "Teale.zip"

    public private(set) var updateAvailable = false
    public private(set) var latestTag: String?
    public private(set) var releaseURL: URL?
    public private(set) var downloadURL: URL?
    public private(set) var checking = false
    public private(set) var installing = false
    public private(set) var lastError: String?

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

        guard let release = await fetchLatestRelease() else { return }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkIntervalKey)

        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedVersionKey)
        if release.tagName != dismissed && isNewer(tag: release.tagName) {
            latestTag = release.tagName
            releaseURL = release.htmlURL
            downloadURL = release.asset(named: Self.releaseAssetName)?.browserDownloadURL
            updateAvailable = true
            lastError = nil
        } else {
            clearAvailableUpdate()
        }
    }

    /// User chose to skip this version.
    public func dismissUpdate() {
        if let tag = latestTag {
            UserDefaults.standard.set(tag, forKey: Self.dismissedVersionKey)
        }
        lastError = nil
        clearAvailableUpdate()
    }

    /// Download and install the update (replace current .app and relaunch).
    public func installUpdate() async -> Bool {
        guard let downloadURL else {
            lastError = "The macOS update asset was not published on the release."
            return false
        }

        installing = true
        lastError = nil
        defer { installing = false }

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
            guard process.terminationStatus == 0 else {
                lastError = "Teale could not unpack the downloaded macOS update."
                try? FileManager.default.removeItem(at: tempDir)
                return false
            }

            // Find the .app in extracted contents
            let extracted = try FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)
            guard let newApp = extracted.first(where: { $0.pathExtension == "app" }) else {
                lastError = "The downloaded macOS release did not contain a Teale app bundle."
                try? FileManager.default.removeItem(at: tempDir)
                return false
            }

            // Replace current app
            let currentApp = Bundle.main.bundleURL
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
            try? FileManager.default.removeItem(at: tempDir)
            clearAvailableUpdate()

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
            lastError = error.localizedDescription
            try? FileManager.default.removeItem(at: tempDir)
            return false
        }
    }

    public var latestVersionLabel: String? {
        guard let latestTag else { return nil }
        return latestTag.replacingOccurrences(of: Self.releaseTagPrefix, with: "")
    }

    // MARK: - Private

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }

        func asset(named name: String) -> Asset? {
            assets.first(where: { $0.name == name })
        }
    }

    private func fetchLatestRelease() async -> GitHubRelease? {
        let apiURL = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=20")!
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let releases = try? JSONDecoder().decode([GitHubRelease].self, from: data) else {
            return nil
        }

        return releases
            .filter {
                !$0.draft &&
                !$0.prerelease &&
                $0.tagName.hasPrefix(Self.releaseTagPrefix) &&
                $0.asset(named: Self.releaseAssetName) != nil
            }
            .max { lhs, rhs in
                (releaseVersion(for: lhs.tagName) ?? 0) < (releaseVersion(for: rhs.tagName) ?? 0)
            }
    }

    private func isNewer(tag: String) -> Bool {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        guard let remote = releaseVersion(for: tag),
              let local = Int64(currentVersion) else { return false }
        return remote > local
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        latestTag = nil
        releaseURL = nil
        downloadURL = nil
    }

    private func releaseVersion(for tag: String) -> Int64? {
        let numeric = tag
            .replacingOccurrences(of: Self.releaseTagPrefix, with: "")
            .replacingOccurrences(of: ".", with: "")
        return Int64(numeric)
    }
}
