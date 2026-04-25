import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Lightweight updater that checks GitHub Releases for newer versions,
/// downloads them in the background, and can install/relaunch automatically.
@MainActor
@Observable
public final class UpdateChecker {
    private static let repo = "teale-ai/teale-mono"
    private static let checkIntervalKey = "teale.lastUpdateCheck"
    private static let dismissedVersionKey = "teale.dismissedUpdateVersion"
    private static let autoDownloadKey = "teale.macAutoDownloadUpdates"
    private static let autoInstallKey = "teale.macAutoInstallUpdates"
    private static let downloadedTagKey = "teale.macDownloadedUpdateTag"
    private static let downloadedArchivePathKey = "teale.macDownloadedUpdateArchivePath"
    private static let checkInterval: TimeInterval = 4 * 3600
    private static let pollIntervalNanos: UInt64 = 15 * 60 * 1_000_000_000
    private static let releaseTagPrefix = "mac-v"
    private static let releaseAssetName = "Teale.zip"
    private static let updatesDirectoryName = "updates"

    public var autoDownloadEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoDownloadEnabled, forKey: Self.autoDownloadKey)
            guard autoDownloadEnabled, latestTag != nil, downloadURL != nil else { return }
            Task { [weak self] in
                await self?.prepareLatestUpdateIfNeeded(triggerInstall: self?.autoInstallEnabled ?? false)
            }
        }
    }

    public var autoInstallEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoInstallEnabled, forKey: Self.autoInstallKey)
            guard autoInstallEnabled else { return }
            Task { [weak self] in
                _ = await self?.installPreparedUpdateIfPossible(force: false)
            }
        }
    }

    public private(set) var updateAvailable = false
    public private(set) var latestTag: String?
    public private(set) var releaseURL: URL?
    public private(set) var downloadURL: URL?
    public private(set) var checking = false
    public private(set) var downloading = false
    public private(set) var installing = false
    public private(set) var lastError: String?
    public private(set) var downloadedTag: String?

    @ObservationIgnored
    private var automaticCheckTask: Task<Void, Never>?

    @ObservationIgnored
    private var downloadedArchivePath: String?

    public init() {
        autoDownloadEnabled = Self.persistedBool(
            for: Self.autoDownloadKey,
            defaultValue: true
        )
        autoInstallEnabled = Self.persistedBool(
            for: Self.autoInstallKey,
            defaultValue: true
        )
        downloadedTag = Self.persistedString(for: Self.downloadedTagKey)
        downloadedArchivePath = Self.persistedString(for: Self.downloadedArchivePathKey)
        reconcilePreparedUpdateState()
    }

    deinit {
        automaticCheckTask?.cancel()
    }

    public func startAutomaticChecks() {
        reconcilePreparedUpdateState()
        guard automaticCheckTask == nil else { return }

        automaticCheckTask = Task { [weak self] in
            guard let self else { return }
            await self.checkIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
                await self.checkIfNeeded()
            }
        }
    }

    /// Check for updates if enough time has passed since last check.
    public func checkIfNeeded() async {
        let lastCheck = UserDefaults.standard.double(forKey: Self.checkIntervalKey)
        let now = Date().timeIntervalSince1970
        guard now - lastCheck > Self.checkInterval else { return }
        await check()
    }

    /// Force a check regardless of interval.
    public func check() async {
        guard !checking else { return }

        checking = true
        defer { checking = false }

        reconcilePreparedUpdateState()

        guard let release = await fetchLatestRelease() else { return }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkIntervalKey)

        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedVersionKey)
        let remoteIsNewer = isNewer(tag: release.tagName)

        latestTag = release.tagName
        releaseURL = release.htmlURL
        downloadURL = release.asset(named: Self.releaseAssetName)?.browserDownloadURL

        guard remoteIsNewer else {
            clearAvailableUpdate()
            clearPreparedUpdateIfCurrentOrOlder()
            lastError = nil
            return
        }

        updateAvailable = release.tagName != dismissed
        lastError = nil

        guard release.tagName != dismissed else { return }

        if autoDownloadEnabled {
            _ = await prepareLatestUpdateIfNeeded(triggerInstall: autoInstallEnabled)
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

    /// Download if needed and install the update (replace current .app and relaunch).
    public func installUpdate() async -> Bool {
        if downloadedUpdateReady {
            return await installPreparedUpdateIfPossible(force: true)
        }

        let downloaded = await prepareLatestUpdateIfNeeded(triggerInstall: false)
        guard downloaded else { return false }
        return await installPreparedUpdateIfPossible(force: true)
    }

    public var latestVersionLabel: String? {
        guard let latestTag else { return nil }
        return Self.versionLabel(for: latestTag)
    }

    public var currentVersionLabel: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            ?? "current build"
    }

    public var downloadedUpdateReady: Bool {
        guard let downloadedTag,
              let archiveURL = downloadedArchiveURL else { return false }
        return FileManager.default.fileExists(atPath: archiveURL.path) && isNewer(tag: downloadedTag)
    }

    public var statusSummary: String {
        if installing {
            return "Installing the latest macOS build and relaunching Teale."
        }
        if downloading, let version = latestVersionLabel {
            if autoInstallEnabled {
                return "Downloading Teale \(version) in the background. It will relaunch automatically when ready."
            }
            return "Downloading Teale \(version) in the background."
        }
        if downloadedUpdateReady, let downloadedTag {
            let version = Self.versionLabel(for: downloadedTag)
            if autoInstallEnabled {
                return "Teale \(version) is downloaded and will install automatically."
            }
            return "Teale \(version) is downloaded and ready to install."
        }
        if updateAvailable, let version = latestVersionLabel {
            if autoDownloadEnabled && autoInstallEnabled {
                return "Teale \(version) will download and install automatically on this Mac."
            }
            if autoDownloadEnabled {
                return "Teale \(version) will download automatically in the background."
            }
            return "Teale \(version) is available for macOS."
        }
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        if autoDownloadEnabled && autoInstallEnabled {
            return "Automatic macOS downloads and installs are enabled."
        }
        if autoDownloadEnabled {
            return "Automatic macOS downloads are enabled. Install remains manual."
        }
        return "Automatic macOS updates are paused."
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

    private func prepareLatestUpdateIfNeeded(triggerInstall: Bool) async -> Bool {
        reconcilePreparedUpdateState()

        guard let latestTag, let downloadURL else {
            lastError = "The macOS update asset was not published on the release."
            return false
        }

        if downloadedTag == latestTag, downloadedUpdateReady {
            if triggerInstall {
                return await installPreparedUpdateIfPossible(force: false)
            }
            return true
        }

        guard !downloading else { return false }

        downloading = true
        lastError = nil
        defer { downloading = false }

        do {
            let updatesDirectory = try Self.updatesDirectory()
            let archiveURL = updatesDirectory.appendingPathComponent("Teale-\(latestTag).zip")
            let (temporaryURL, response) = try await URLSession.shared.download(from: downloadURL)

            if let http = response as? HTTPURLResponse,
               !(200 ... 299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }

            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)

            downloadedTag = latestTag
            downloadedArchivePath = archiveURL.path
            persistPreparedUpdateState()
            try? cleanupArchivedUpdates(keeping: archiveURL)

            if triggerInstall {
                return await installPreparedUpdateIfPossible(force: false)
            }

            return true
        } catch {
            lastError = "Teale could not download the latest macOS build: \(error.localizedDescription)"
            return false
        }
    }

    private func installPreparedUpdateIfPossible(force: Bool) async -> Bool {
        reconcilePreparedUpdateState()

        guard !installing else { return false }
        guard let downloadedTag, let archiveURL = downloadedArchiveURL else { return false }
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            clearPreparedUpdate(deleteArchive: false)
            lastError = "The downloaded macOS update is no longer on disk."
            return false
        }
        guard isNewer(tag: downloadedTag) else {
            clearPreparedUpdate(deleteArchive: true)
            return false
        }

        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedVersionKey)
        if !force, dismissed == downloadedTag {
            return false
        }

        return await installArchive(at: archiveURL, tag: downloadedTag)
    }

    private func installArchive(at archiveURL: URL, tag: String) async -> Bool {
        installing = true
        lastError = nil
        defer { installing = false }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let unzipDir = tempDir.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", archiveURL.path, unzipDir.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                lastError = "Teale could not unpack the downloaded macOS update."
                try? FileManager.default.removeItem(at: tempDir)
                return false
            }

            let newApp = try extractedAppBundle(in: unzipDir)
            let currentApp = Bundle.main.bundleURL
            let backup = currentApp.deletingLastPathComponent().appendingPathComponent("Teale.app.bak")

            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: currentApp, to: backup)

            do {
                try? FileManager.default.removeItem(at: currentApp)
                try FileManager.default.moveItem(at: newApp, to: currentApp)
            } catch {
                if !FileManager.default.fileExists(atPath: currentApp.path),
                   FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.moveItem(at: backup, to: currentApp)
                }
                throw error
            }

            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", currentApp.path]
            try? xattr.run()
            xattr.waitUntilExit()

            clearPreparedUpdate(deleteArchive: true)
            clearAvailableUpdate()
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.removeItem(at: tempDir)

            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            relaunch.arguments = ["-n", currentApp.path]
            try relaunch.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
#if canImport(AppKit)
                NSApplication.shared.terminate(nil)
#endif
            }
            return true
        } catch {
            if let releaseURL, latestTag == tag {
                updateAvailable = true
                self.releaseURL = releaseURL
            }
            lastError = "Teale could not install the downloaded macOS build: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: tempDir)
            return false
        }
    }

    private func extractedAppBundle(in directory: URL) throws -> URL {
        if let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "app" {
                return fileURL
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        latestTag = nil
        releaseURL = nil
        downloadURL = nil
    }

    private func reconcilePreparedUpdateState() {
        guard let archiveURL = downloadedArchiveURL else {
            clearPreparedUpdate(deleteArchive: false)
            return
        }

        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            clearPreparedUpdate(deleteArchive: false)
            return
        }

        clearPreparedUpdateIfCurrentOrOlder()
    }

    private func clearPreparedUpdateIfCurrentOrOlder() {
        guard let downloadedTag else { return }
        if !isNewer(tag: downloadedTag) {
            clearPreparedUpdate(deleteArchive: true)
        }
    }

    private func clearPreparedUpdate(deleteArchive: Bool) {
        if deleteArchive, let archiveURL = downloadedArchiveURL {
            try? FileManager.default.removeItem(at: archiveURL)
        }
        self.downloadedTag = nil
        self.downloadedArchivePath = nil
        UserDefaults.standard.removeObject(forKey: Self.downloadedTagKey)
        UserDefaults.standard.removeObject(forKey: Self.downloadedArchivePathKey)
    }

    private func persistPreparedUpdateState() {
        if let downloadedTag {
            UserDefaults.standard.set(downloadedTag, forKey: Self.downloadedTagKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.downloadedTagKey)
        }

        if let downloadedArchivePath {
            UserDefaults.standard.set(downloadedArchivePath, forKey: Self.downloadedArchivePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.downloadedArchivePathKey)
        }
    }

    private var downloadedArchiveURL: URL? {
        guard let downloadedArchivePath, !downloadedArchivePath.isEmpty else { return nil }
        return URL(fileURLWithPath: downloadedArchivePath)
    }

    private static func updatesDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let updates = base
            .appendingPathComponent("Teale", isDirectory: true)
            .appendingPathComponent(Self.updatesDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        return updates
    }

    private func cleanupArchivedUpdates(keeping keptArchive: URL) throws {
        let updatesDirectory = try Self.updatesDirectory()
        let archives = try FileManager.default.contentsOfDirectory(
            at: updatesDirectory,
            includingPropertiesForKeys: nil
        )
        for archive in archives where archive != keptArchive {
            try? FileManager.default.removeItem(at: archive)
        }
    }

    private func isNewer(tag: String) -> Bool {
        guard let remote = releaseVersion(for: tag),
              let local = Self.currentVersionNumber() else { return false }
        return remote > local
    }

    private func releaseVersion(for tag: String) -> Int64? {
        let numeric = tag
            .replacingOccurrences(of: Self.releaseTagPrefix, with: "")
            .replacingOccurrences(of: ".", with: "")
        return Int64(numeric)
    }

    private static func currentVersionNumber() -> Int64? {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int64(currentVersion)
    }

    private static func versionLabel(for tag: String) -> String {
        tag.replacingOccurrences(of: Self.releaseTagPrefix, with: "")
    }

    private static func persistedBool(for key: String, defaultValue: Bool) -> Bool {
        if UserDefaults.standard.object(forKey: key) == nil {
            return defaultValue
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func persistedString(for key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}
