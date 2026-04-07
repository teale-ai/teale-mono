import Foundation

// MARK: - CreditSummary

public struct CreditSummary: Sendable {
    public var dailyEarnings: [DateComponents: CreditAmount]
    public var dailySpending: [DateComponents: CreditAmount]
    public var weeklyEarnings: CreditAmount
    public var weeklySpending: CreditAmount
    public var monthlyEarnings: CreditAmount
    public var monthlySpending: CreditAmount
    public var averageCostPerRequest: CreditAmount
    public var mostUsedModelsBySpend: [(modelID: String, totalSpent: CreditAmount)]
    public var topEarningPeers: [(peerID: String, totalEarned: CreditAmount)]
    public var totalRequests: Int

    public init(
        dailyEarnings: [DateComponents: CreditAmount] = [:],
        dailySpending: [DateComponents: CreditAmount] = [:],
        weeklyEarnings: CreditAmount = .zero,
        weeklySpending: CreditAmount = .zero,
        monthlyEarnings: CreditAmount = .zero,
        monthlySpending: CreditAmount = .zero,
        averageCostPerRequest: CreditAmount = .zero,
        mostUsedModelsBySpend: [(modelID: String, totalSpent: CreditAmount)] = [],
        topEarningPeers: [(peerID: String, totalEarned: CreditAmount)] = [],
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

// MARK: - CreditAnalytics

public struct CreditAnalytics: Sendable {

    /// Compute a full analytics summary from transaction history.
    public static func computeSummary(from transactions: [CreditTransaction], asOf now: Date = Date()) -> CreditSummary {
        let calendar = Calendar.current

        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!

        // Daily aggregations
        var dailyEarnings: [DateComponents: CreditAmount] = [:]
        var dailySpending: [DateComponents: CreditAmount] = [:]

        // Weekly/monthly totals
        var weeklyEarnings = CreditAmount.zero
        var weeklySpending = CreditAmount.zero
        var monthlyEarnings = CreditAmount.zero
        var monthlySpending = CreditAmount.zero

        // Model spend tracking
        var modelSpend: [String: Double] = [:]

        // Peer earning tracking
        var peerEarnings: [String: Double] = [:]

        // Request counting (spent transactions = requests made)
        var spentCount = 0
        var totalSpentAmount = CreditAmount.zero

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

            case .deposit:
                dailyEarnings[dayComponents, default: .zero] += tx.amount
                if tx.timestamp >= sevenDaysAgo { weeklyEarnings += tx.amount }
                if tx.timestamp >= thirtyDaysAgo { monthlyEarnings += tx.amount }

            case .withdrawal:
                dailySpending[dayComponents, default: .zero] += tx.amount
                if tx.timestamp >= sevenDaysAgo { weeklySpending += tx.amount }
                if tx.timestamp >= thirtyDaysAgo { monthlySpending += tx.amount }

            case .bonus, .adjustment, .transfer:
                break
            }
        }

        // Average cost per request
        let avgCost = spentCount > 0
            ? CreditAmount(totalSpentAmount.value / Double(spentCount))
            : CreditAmount.zero

        // Sort model spend descending
        let sortedModels = modelSpend
            .sorted { $0.value > $1.value }
            .map { (modelID: $0.key, totalSpent: CreditAmount($0.value)) }

        // Sort peer earnings descending
        let sortedPeers = peerEarnings
            .sorted { $0.value > $1.value }
            .map { (peerID: $0.key, totalEarned: CreditAmount($0.value)) }

        return CreditSummary(
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
