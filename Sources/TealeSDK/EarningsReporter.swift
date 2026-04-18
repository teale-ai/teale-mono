import Foundation
import SharedTypes
import CreditKit

// MARK: - Earnings Reporter

/// Reports completed inference work to the server-side ledger.
/// Batches reports when offline and syncs when connectivity is restored.
public actor EarningsReporter {
    private let appID: String
    private let developerWalletID: String
    private let deviceID: UUID
    private var pendingReports: [EarningReport] = []

    private let persistenceURL: URL

    public init(appID: String, developerWalletID: String, deviceID: UUID) {
        self.appID = appID
        self.developerWalletID = developerWalletID
        self.deviceID = deviceID

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Teale/sdk")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.persistenceURL = dir.appendingPathComponent("pending_reports_\(appID).json")

        // Load any pending reports from disk
        if let data = try? Data(contentsOf: persistenceURL),
           let reports = try? JSONDecoder().decode([EarningReport].self, from: data) {
            self.pendingReports = reports
        }
    }

    /// Record a completed inference request for later reporting
    public func reportEarning(
        requestID: UUID,
        tokensGenerated: Int,
        modelID: String,
        creditsEarned: USDCAmount,
        peerNodeID: String?
    ) async {
        let report = EarningReport(
            requestID: requestID,
            deviceID: deviceID,
            appID: appID,
            developerWalletID: developerWalletID,
            tokensGenerated: tokensGenerated,
            modelID: modelID,
            creditsEarned: creditsEarned.value,
            peerNodeID: peerNodeID,
            reportedAt: Date()
        )
        pendingReports.append(report)
        savePending()

        // Try to sync immediately
        await syncPendingReports()
    }

    /// Attempt to sync all pending reports to the server
    public func syncPendingReports() async {
        guard !pendingReports.isEmpty else { return }

        // TODO: POST to Supabase credit_reports table
        // For now, reports accumulate locally and will be synced
        // when the Supabase Edge Function endpoint is deployed.
        //
        // The implementation will:
        // 1. Batch POST pending reports to /rest/v1/credit_reports
        // 2. On success, remove synced reports from pendingReports
        // 3. On failure, keep them for next sync attempt
        // 4. Server-side trigger credits developer_wallet_id
    }

    /// Number of reports waiting to be synced
    public var pendingCount: Int {
        pendingReports.count
    }

    // MARK: - Persistence

    private func savePending() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(pendingReports) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }
}

// MARK: - Earning Report

struct EarningReport: Codable, Sendable {
    var requestID: UUID
    var deviceID: UUID
    var appID: String
    var developerWalletID: String
    var tokensGenerated: Int
    var modelID: String
    var creditsEarned: Double
    var peerNodeID: String?
    var reportedAt: Date
}
