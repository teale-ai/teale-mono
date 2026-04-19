import Foundation

// MARK: - USDCSummary

public struct USDCSummary: Sendable {
    public var dailyEarnings: [DateComponents: USDCAmount]
    public var dailySpending: [DateComponents: USDCAmount]
    public var weeklyEarnings: USDCAmount
    public var weeklySpending: USDCAmount
    public var monthlyEarnings: USDCAmount
    public var monthlySpending: USDCAmount
    public var averageCostPerRequest: USDCAmount
    public var mostUsedModelsBySpend: [(modelID: String, totalSpent: USDCAmount)]
    public var topEarningPeers: [(peerID: String, totalEarned: USDCAmount)]
    public var totalRequests: Int

    public init(
        dailyEarnings: [DateComponents: USDCAmount] = [:],
        dailySpending: [DateComponents: USDCAmount] = [:],
        weeklyEarnings: USDCAmount = .zero,
        weeklySpending: USDCAmount = .zero,
        monthlyEarnings: USDCAmount = .zero,
        monthlySpending: USDCAmount = .zero,
        averageCostPerRequest: USDCAmount = .zero,
        mostUsedModelsBySpend: [(modelID: String, totalSpent: USDCAmount)] = [],
        topEarningPeers: [(peerID: String, totalEarned: USDCAmount)] = [],
        totalRequests: Int = 0
    ) {
        self.dailyEarnings = dailyEarnings
        self.dailySpending = dailySpending
        self.weeklyEarnings = weeklyEarnings
        self.weeklySpending = weeklySpending
        self.monthlyEarnings = monthlyEarnings
        self.monthlySpending = monthlySpending
        self.averageCostPerRequest = averageCostPerRequest
        self.mostUsedModelsBySpend = mostUsedModelsBySpend
        self.topEarningPeers = topEarningPeers
        self.totalRequests = totalRequests
    }
}

// MARK: - USDCAnalytics

public struct USDCAnalytics: Sendable {

    /// Compute a full analytics summary from transaction history.
    public static func computeSummary(from transactions: [USDCTransaction], asOf now: Date = Date()) -> USDCSummary {
        let calendar = Calendar.current

        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!

        // Daily aggregations
        var dailyEarnings: [DateComponents: USDCAmount] = [:]
        var dailySpending: [DateComponents: USDCAmount] = [:]

        // Weekly/monthly totals
        var weeklyEarnings = USDCAmount.zero
        var weeklySpending = USDCAmount.zero
        var monthlyEarnings = USDCAmount.zero
        var monthlySpending = USDCAmount.zero

        // Model spend tracking
        var modelSpend: [String: Double] = [:]

        // Peer earning tracking
        var peerEarnings: [String: Double] = [:]

        // Request counting (spent transactions = requests made)
        var spentCount = 0
        var totalSpentAmount = USDCAmount.zero

        for tx in transactions {
            let dayComponents = calendar.dateComponents([.year, .month, .day], from: tx.timestamp)

            switch tx.type {
            case .earned:
                dailyEarnings[dayComponents, default: .zero] += tx.amount
                if tx.timestamp >= sevenDaysAgo {
                    weeklyEarnings += tx.amount
                }
                if tx.timestamp >= thirtyDaysAgo {
                    monthlyEarnings += tx.amount
                }
                if let peer = tx.peerNodeID {
                    peerEarnings[peer, default: 0] += tx.amount.value
                }

            case .spent:
                dailySpending[dayComponents, default: .zero] += tx.amount
                if tx.timestamp >= sevenDaysAgo {
                    weeklySpending += tx.amount
                }
                if tx.timestamp >= thirtyDaysAgo {
                    monthlySpending += tx.amount
                }
                if let model = tx.modelID {
                    modelSpend[model, default: 0] += tx.amount.value
                }
                spentCount += 1
                totalSpentAmount += tx.amount

            case .sdkEarning:
                dailyEarnings[dayComponents, default: .zero] += tx.amount
                if tx.timestamp >= sevenDaysAgo {
                    weeklyEarnings += tx.amount
                }
                if tx.timestamp >= thirtyDaysAgo {
                    monthlyEarnings += tx.amount
                }
                if let peer = tx.peerNodeID {
                    peerEarnings[peer, default: 0] += tx.amount.value
                }

            case .bonus, .adjustment, .transfer, .platformFee:
                break
            }
        }

        // Average cost per request
        let avgCost = spentCount > 0
            ? USDCAmount(totalSpentAmount.value / Double(spentCount))
            : USDCAmount.zero

        // Sort model spend descending
        let sortedModels = modelSpend
            .sorted { $0.value > $1.value }
            .map { (modelID: $0.key, totalSpent: USDCAmount($0.value)) }

        // Sort peer earnings descending
        let sortedPeers = peerEarnings
            .sorted { $0.value > $1.value }
            .map { (peerID: $0.key, totalEarned: USDCAmount($0.value)) }

        return USDCSummary(
            dailyEarnings: dailyEarnings,
            dailySpending: dailySpending,
            weeklyEarnings: weeklyEarnings,
            weeklySpending: weeklySpending,
            monthlyEarnings: monthlyEarnings,
            monthlySpending: monthlySpending,
            averageCostPerRequest: avgCost,
            mostUsedModelsBySpend: sortedModels,
            topEarningPeers: sortedPeers,
            totalRequests: spentCount
        )
    }
}
