import XCTest
@testable import CreditKit
import SharedTypes

final class CreditKitTests: XCTestCase {

    // MARK: - CreditAmount Tests

    func testCreditAmountArithmetic() {
        let a = CreditAmount(10.0)
        let b = CreditAmount(3.5)

        XCTAssertEqual((a + b).value, 13.5)
        XCTAssertEqual((a - b).value, 6.5)
        XCTAssertEqual((a * 2.0).value, 20.0)

        var c = CreditAmount(5.0)
        c += CreditAmount(2.0)
        XCTAssertEqual(c.value, 7.0)
        c -= CreditAmount(1.0)
        XCTAssertEqual(c.value, 6.0)
    }

    func testCreditAmountComparable() {
        XCTAssertTrue(CreditAmount(1.0) < CreditAmount(2.0))
        XCTAssertFalse(CreditAmount(5.0) < CreditAmount(3.0))
        XCTAssertEqual(CreditAmount(4.0), CreditAmount(4.0))
    }

    func testCreditAmountCodable() throws {
        let original = CreditAmount(42.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CreditAmount.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - CreditPricing Tests

    func testModelComplexityFactor() {
        XCTAssertEqual(CreditPricing.modelComplexityFactor(parameterCount: "1B"), 0.1, accuracy: 0.001)
        XCTAssertEqual(CreditPricing.modelComplexityFactor(parameterCount: "3B"), 0.3, accuracy: 0.001)
        XCTAssertEqual(CreditPricing.modelComplexityFactor(parameterCount: "7B"), 0.7, accuracy: 0.001)
        XCTAssertEqual(CreditPricing.modelComplexityFactor(parameterCount: "8B"), 0.8, accuracy: 0.001)
        XCTAssertEqual(CreditPricing.modelComplexityFactor(parameterCount: "14B"), 1.4, accuracy: 0.001)
        XCTAssertEqual(CreditPricing.modelComplexityFactor(parameterCount: "70B"), 7.0, accuracy: 0.001)
    }

    func testQuantizationMultiplier() {
        XCTAssertEqual(CreditPricing.quantizationMultiplier(.q4), 1.0)
        XCTAssertEqual(CreditPricing.quantizationMultiplier(.q8), 1.5)
        XCTAssertEqual(CreditPricing.quantizationMultiplier(.fp16), 2.0)
    }

    func testCostCalculation_1B_q4() {
        // 1000 tokens on 1B q4: (1000/1000) * 0.1 * 1.0 = 0.1 credits
        let cost = CreditPricing.cost(tokenCount: 1000, parameterCount: "1B", quantization: .q4)
        XCTAssertEqual(cost.value, 0.1, accuracy: 0.001)
    }

    func testCostCalculation_8B_q8() {
        // 1000 tokens on 8B q8: (1000/1000) * 0.8 * 1.5 = 1.2 credits
        let cost = CreditPricing.cost(tokenCount: 1000, parameterCount: "8B", quantization: .q8)
        XCTAssertEqual(cost.value, 1.2, accuracy: 0.001)
    }

    func testCostCalculation_70B_fp16() {
        // 500 tokens on 70B fp16: (500/1000) * 7.0 * 2.0 = 7.0 credits
        let cost = CreditPricing.cost(tokenCount: 500, parameterCount: "70B", quantization: .fp16)
        XCTAssertEqual(cost.value, 7.0, accuracy: 0.001)
    }

    func testEarningIs80PercentOfCost() {
        let cost = CreditPricing.cost(tokenCount: 1000, parameterCount: "8B", quantization: .q4)
        let earning = CreditPricing.earning(tokenCount: 1000, parameterCount: "8B", quantization: .q4)
        XCTAssertEqual(earning.value, cost.value * 0.8, accuracy: 0.001)
    }

    func testCostWithModelDescriptor() {
        let model = ModelDescriptor(
            id: "test-8b-q4",
            name: "Test 8B",
            huggingFaceRepo: "test/model",
            parameterCount: "8B",
            quantization: .q4,
            estimatedSizeGB: 4.0,
            requiredRAMGB: 6.0,
            family: "Test",
            description: "Test model"
        )
        let cost = CreditPricing.cost(tokenCount: 2000, model: model)
        // (2000/1000) * 0.8 * 1.0 = 1.6
        XCTAssertEqual(cost.value, 1.6, accuracy: 0.001)
    }

    // MARK: - CreditLedger Tests

    func testLedgerCreditDebit() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger = await CreditLedger(directoryURL: tempDir)
        await ledger.applyWelcomeBonusIfNeeded()

        // Welcome bonus should be 100
        var balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 100.0, accuracy: 0.001)
        XCTAssertEqual(balance.transactionCount, 1)

        // Credit 10
        let earnTx = CreditTransaction(
            type: .earned,
            amount: CreditAmount(10.0),
            description: "Test earning"
        )
        await ledger.credit(amount: CreditAmount(10.0), transaction: earnTx)

        balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 110.0, accuracy: 0.001)
        XCTAssertEqual(balance.totalEarned.value, 10.0, accuracy: 0.001)

        // Debit 5
        let spendTx = CreditTransaction(
            type: .spent,
            amount: CreditAmount(5.0),
            description: "Test spending"
        )
        await ledger.debit(amount: CreditAmount(5.0), transaction: spendTx)

        balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 105.0, accuracy: 0.001)
        XCTAssertEqual(balance.totalSpent.value, 5.0, accuracy: 0.001)
        XCTAssertEqual(balance.transactionCount, 3)
    }

    func testWelcomeBonus() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger = await CreditLedger(directoryURL: tempDir)
        await ledger.applyWelcomeBonusIfNeeded()

        let balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 100.0, accuracy: 0.001)

        let history = await ledger.getHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.type, .bonus)
        XCTAssertEqual(history.first?.amount.value ?? 0, 100.0, accuracy: 0.001)
    }

    func testTransactionHistoryOrdering() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger = await CreditLedger(directoryURL: tempDir)

        // Add transactions with different timestamps
        let tx1 = CreditTransaction(
            timestamp: Date(timeIntervalSince1970: 1000),
            type: .earned,
            amount: CreditAmount(1.0),
            description: "First"
        )
        let tx2 = CreditTransaction(
            timestamp: Date(timeIntervalSince1970: 3000),
            type: .earned,
            amount: CreditAmount(2.0),
            description: "Third"
        )
        let tx3 = CreditTransaction(
            timestamp: Date(timeIntervalSince1970: 2000),
            type: .earned,
            amount: CreditAmount(3.0),
            description: "Second"
        )

        await ledger.credit(amount: tx1.amount, transaction: tx1)
        await ledger.credit(amount: tx2.amount, transaction: tx2)
        await ledger.credit(amount: tx3.amount, transaction: tx3)

        let history = await ledger.getHistory()
        // Should be most recent first
        XCTAssertEqual(history[0].description, "Third")
        XCTAssertEqual(history[1].description, "Second")
        XCTAssertEqual(history[2].description, "First")
    }

    func testLedgerPersistence() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create ledger and add data
        let ledger1 = await CreditLedger(directoryURL: tempDir)
        await ledger1.applyWelcomeBonusIfNeeded()

        let tx = CreditTransaction(
            type: .earned,
            amount: CreditAmount(25.0),
            description: "Persistence test"
        )
        await ledger1.credit(amount: CreditAmount(25.0), transaction: tx)

        // Create a new ledger from same directory — should load persisted data
        let ledger2 = await CreditLedger(directoryURL: tempDir)
        // Should NOT apply welcome bonus again (data exists)
        await ledger2.applyWelcomeBonusIfNeeded()

        let balance = await ledger2.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 125.0, accuracy: 0.001)
        XCTAssertEqual(balance.transactionCount, 2)
    }

    // MARK: - CreditAnalytics Tests

    func testAnalyticsSummary() {
        let now = Date()
        let transactions: [CreditTransaction] = [
            CreditTransaction(
                timestamp: now,
                type: .spent,
                amount: CreditAmount(5.0),
                description: "Spent",
                modelID: "model-a"
            ),
            CreditTransaction(
                timestamp: now,
                type: .earned,
                amount: CreditAmount(3.0),
                description: "Earned",
                peerNodeID: "peer-1"
            ),
            CreditTransaction(
                timestamp: now,
                type: .spent,
                amount: CreditAmount(10.0),
                description: "Spent more",
                modelID: "model-a"
            ),
        ]

        let summary = CreditAnalytics.computeSummary(from: transactions, asOf: now)
        XCTAssertEqual(summary.totalRequests, 2)
        XCTAssertEqual(summary.averageCostPerRequest.value, 7.5, accuracy: 0.001)
        XCTAssertEqual(summary.weeklyEarnings.value, 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.weeklySpending.value, 15.0, accuracy: 0.001)
        XCTAssertEqual(summary.mostUsedModelsBySpend.first?.modelID, "model-a")
        XCTAssertEqual(summary.mostUsedModelsBySpend.first?.totalSpent.value ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(summary.topEarningPeers.first?.peerID, "peer-1")
    }
}
