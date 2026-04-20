import XCTest
@testable import CreditKit
import SharedTypes

final class CreditKitTests: XCTestCase {

    // MARK: - USDCAmount

    func testUSDCAmountArithmetic() {
        let a = USDCAmount(10.0)
        let b = USDCAmount(3.5)

        XCTAssertEqual((a + b).value, 13.5, accuracy: 0.0001)
        XCTAssertEqual((a - b).value, 6.5, accuracy: 0.0001)
        XCTAssertEqual((a * 2.0).value, 20.0, accuracy: 0.0001)

        var c = USDCAmount(5.0)
        c += USDCAmount(2.0)
        XCTAssertEqual(c.value, 7.0, accuracy: 0.0001)
        c -= USDCAmount(1.0)
        XCTAssertEqual(c.value, 6.0, accuracy: 0.0001)
    }

    func testUSDCAmountComparable() {
        XCTAssertTrue(USDCAmount(1.0) < USDCAmount(2.0))
        XCTAssertFalse(USDCAmount(5.0) < USDCAmount(3.0))
        XCTAssertEqual(USDCAmount(4.0), USDCAmount(4.0))
    }

    func testUSDCAmountCodable() throws {
        let original = USDCAmount(42.5)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(USDCAmount.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - InferencePricing

    func testModelComplexityFactor() {
        XCTAssertEqual(InferencePricing.modelComplexityFactor(parameterCount: "1B"), 0.1, accuracy: 0.001)
        XCTAssertEqual(InferencePricing.modelComplexityFactor(parameterCount: "3B"), 0.3, accuracy: 0.001)
        XCTAssertEqual(InferencePricing.modelComplexityFactor(parameterCount: "7B"), 0.7, accuracy: 0.001)
        XCTAssertEqual(InferencePricing.modelComplexityFactor(parameterCount: "8B"), 0.8, accuracy: 0.001)
        XCTAssertEqual(InferencePricing.modelComplexityFactor(parameterCount: "14B"), 1.4, accuracy: 0.001)
        XCTAssertEqual(InferencePricing.modelComplexityFactor(parameterCount: "70B"), 7.0, accuracy: 0.001)
    }

    func testQuantizationMultiplier() {
        XCTAssertEqual(InferencePricing.quantizationMultiplier(.q4), 1.0)
        XCTAssertEqual(InferencePricing.quantizationMultiplier(.q8), 1.5)
        XCTAssertEqual(InferencePricing.quantizationMultiplier(.fp16), 2.0)
    }

    /// cost_usd = (tokens/1000) * complexity * quant / 10_000
    func testCostCalculation_1B_q4() {
        let cost = InferencePricing.cost(tokenCount: 1000, parameterCount: "1B", quantization: .q4)
        // (1000/1000) * 0.1 * 1.0 / 10_000 = 0.00001
        XCTAssertEqual(cost.value, 0.00001, accuracy: 0.0000001)
    }

    func testCostCalculation_8B_q8() {
        let cost = InferencePricing.cost(tokenCount: 1000, parameterCount: "8B", quantization: .q8)
        // (1000/1000) * 0.8 * 1.5 / 10_000 = 0.00012
        XCTAssertEqual(cost.value, 0.00012, accuracy: 0.0000001)
    }

    func testCostCalculation_70B_fp16() {
        let cost = InferencePricing.cost(tokenCount: 500, parameterCount: "70B", quantization: .fp16)
        // (500/1000) * 7.0 * 2.0 / 10_000 = 0.0007
        XCTAssertEqual(cost.value, 0.0007, accuracy: 0.0000001)
    }

    /// Earning = cost × (1 − platformFeeRate). platformFeeRate = 0.018.
    func testEarningIsNetOfPlatformFee() {
        let cost = InferencePricing.cost(tokenCount: 1000, parameterCount: "8B", quantization: .q4)
        let earning = InferencePricing.earning(tokenCount: 1000, parameterCount: "8B", quantization: .q4)
        XCTAssertEqual(
            earning.value,
            cost.value * (1.0 - InferencePricing.platformFeeRate),
            accuracy: 0.0000001
        )
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
        let cost = InferencePricing.cost(tokenCount: 2000, model: model)
        // (2000/1000) * 0.8 * 1.0 / 10_000 = 0.00016
        XCTAssertEqual(cost.value, 0.00016, accuracy: 0.0000001)
    }

    func testWelcomeBonus() {
        // Welcome bonus is a flat $0.01 — matches WalletKit's peg of USDC = USD.
        XCTAssertEqual(InferencePricing.welcomeBonus.value, 0.01, accuracy: 0.0001)
    }

    // MARK: - USDCLedger

    func testLedgerCreditDebit() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger = await USDCLedger(directoryURL: tempDir)
        await ledger.applyWelcomeBonusIfNeeded()

        // Welcome bonus = $0.01
        var balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 0.01, accuracy: 0.0001)
        XCTAssertEqual(balance.transactionCount, 1)

        // Credit 10.0
        let earnTx = USDCTransaction(
            type: .earned,
            amount: USDCAmount(10.0),
            description: "Test earning"
        )
        await ledger.credit(amount: USDCAmount(10.0), transaction: earnTx)

        balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 10.01, accuracy: 0.0001)
        XCTAssertEqual(balance.totalEarned.value, 10.0, accuracy: 0.0001)

        // Debit 5.0
        let spendTx = USDCTransaction(
            type: .spent,
            amount: USDCAmount(5.0),
            description: "Test spending"
        )
        await ledger.debit(amount: USDCAmount(5.0), transaction: spendTx)

        balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 5.01, accuracy: 0.0001)
        XCTAssertEqual(balance.totalSpent.value, 5.0, accuracy: 0.0001)
        XCTAssertEqual(balance.transactionCount, 3)
    }

    func testWelcomeBonusAppliedOnce() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger = await USDCLedger(directoryURL: tempDir)
        await ledger.applyWelcomeBonusIfNeeded()

        let balance = await ledger.getBalance()
        XCTAssertEqual(balance.currentBalance.value, InferencePricing.welcomeBonus.value, accuracy: 0.0001)

        let history = await ledger.getHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.type, .bonus)
        XCTAssertEqual(
            history.first?.amount.value ?? 0,
            InferencePricing.welcomeBonus.value,
            accuracy: 0.0001
        )
    }

    func testTransactionHistoryOrdering() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger = await USDCLedger(directoryURL: tempDir)

        let tx1 = USDCTransaction(
            timestamp: Date(timeIntervalSince1970: 1000),
            type: .earned,
            amount: USDCAmount(1.0),
            description: "First"
        )
        let tx2 = USDCTransaction(
            timestamp: Date(timeIntervalSince1970: 3000),
            type: .earned,
            amount: USDCAmount(2.0),
            description: "Third"
        )
        let tx3 = USDCTransaction(
            timestamp: Date(timeIntervalSince1970: 2000),
            type: .earned,
            amount: USDCAmount(3.0),
            description: "Second"
        )

        await ledger.credit(amount: tx1.amount, transaction: tx1)
        await ledger.credit(amount: tx2.amount, transaction: tx2)
        await ledger.credit(amount: tx3.amount, transaction: tx3)

        let history = await ledger.getHistory()
        // Most recent timestamp first
        XCTAssertEqual(history[0].description, "Third")
        XCTAssertEqual(history[1].description, "Second")
        XCTAssertEqual(history[2].description, "First")
    }

    func testLedgerPersistence() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ledger1 = await USDCLedger(directoryURL: tempDir)
        await ledger1.applyWelcomeBonusIfNeeded()

        let tx = USDCTransaction(
            type: .earned,
            amount: USDCAmount(0.25),
            description: "Persistence test"
        )
        await ledger1.credit(amount: USDCAmount(0.25), transaction: tx)

        // Reopen from the same directory — persisted state should load, and the
        // welcome bonus should NOT be applied a second time.
        let ledger2 = await USDCLedger(directoryURL: tempDir)
        await ledger2.applyWelcomeBonusIfNeeded()

        let balance = await ledger2.getBalance()
        XCTAssertEqual(balance.currentBalance.value, 0.01 + 0.25, accuracy: 0.0001)
        XCTAssertEqual(balance.transactionCount, 2)
    }

    // MARK: - USDCAnalytics

    func testAnalyticsSummary() {
        let now = Date()
        let transactions: [USDCTransaction] = [
            USDCTransaction(
                timestamp: now,
                type: .spent,
                amount: USDCAmount(5.0),
                description: "Spent",
                modelID: "model-a"
            ),
            USDCTransaction(
                timestamp: now,
                type: .earned,
                amount: USDCAmount(3.0),
                description: "Earned",
                peerNodeID: "peer-1"
            ),
            USDCTransaction(
                timestamp: now,
                type: .spent,
                amount: USDCAmount(10.0),
                description: "Spent more",
                modelID: "model-a"
            ),
        ]

        let summary = USDCAnalytics.computeSummary(from: transactions, asOf: now)
        XCTAssertEqual(summary.totalRequests, 2)
        XCTAssertEqual(summary.averageCostPerRequest.value, 7.5, accuracy: 0.0001)
        XCTAssertEqual(summary.weeklyEarnings.value, 3.0, accuracy: 0.0001)
        XCTAssertEqual(summary.weeklySpending.value, 15.0, accuracy: 0.0001)
        XCTAssertEqual(summary.mostUsedModelsBySpend.first?.modelID, "model-a")
        XCTAssertEqual(summary.mostUsedModelsBySpend.first?.totalSpent.value ?? 0, 15.0, accuracy: 0.0001)
        XCTAssertEqual(summary.topEarningPeers.first?.peerID, "peer-1")
    }
}
