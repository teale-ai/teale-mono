import Foundation
import SharedTypes

// MARK: - WWTN Reverse Auction

/// Implements Akash-style reverse auction for WWTN inference pricing.
/// Requestor posts a max bid, providers auto-bid their floor price,
/// lowest bid wins the inference job.
public struct WWTNAuction: Sendable {

    /// A bid from a provider offering inference capacity.
    public struct ProviderBid: Codable, Sendable, Comparable {
        public var providerNodeID: String
        public var modelID: String
        public var bidPerKToken: Double       // USDC per 1K tokens
        public var floorPerKToken: Double     // Electricity floor (can't go below this)
        public var tokensPerSecond: Double    // Provider's measured speed
        public var hardwareWatts: Double      // Provider's power draw
        public var qualityScore: Double       // 0-100 from WANManager
        public var timestamp: Date

        public init(
            providerNodeID: String,
            modelID: String,
            bidPerKToken: Double,
            floorPerKToken: Double,
            tokensPerSecond: Double,
            hardwareWatts: Double,
            qualityScore: Double
        ) {
            self.providerNodeID = providerNodeID
            self.modelID = modelID
            self.bidPerKToken = bidPerKToken
            self.floorPerKToken = floorPerKToken
            self.tokensPerSecond = tokensPerSecond
            self.hardwareWatts = hardwareWatts
            self.qualityScore = qualityScore
            self.timestamp = Date()
        }

        // Sort by bid amount (lowest first), then by quality (highest first)
        public static func < (lhs: ProviderBid, rhs: ProviderBid) -> Bool {
            if lhs.bidPerKToken != rhs.bidPerKToken {
                return lhs.bidPerKToken < rhs.bidPerKToken
            }
            return lhs.qualityScore > rhs.qualityScore
        }
    }

    /// A requestor's inference job posting.
    public struct JobPosting: Codable, Sendable {
        public var requestorNodeID: String
        public var modelID: String?           // nil = any model
        public var maxBidPerKToken: Double     // Maximum USDC per 1K tokens willing to pay
        public var estimatedTokens: Int        // Estimated total tokens for the job
        public var expiresAt: Date

        public init(
            requestorNodeID: String,
            modelID: String? = nil,
            maxBidPerKToken: Double,
            estimatedTokens: Int = 1000,
            validForSeconds: TimeInterval = 30
        ) {
            self.requestorNodeID = requestorNodeID
            self.modelID = modelID
            self.maxBidPerKToken = maxBidPerKToken
            self.estimatedTokens = estimatedTokens
            self.expiresAt = Date().addingTimeInterval(validForSeconds)
        }

        public var isExpired: Bool {
            Date() > expiresAt
        }
    }

    /// Calculate a provider's automatic bid based on their electricity cost floor.
    /// The bid is the floor price + a small margin based on demand.
    public static func autoBid(
        floorPerKToken: Double,
        demandMultiplier: Double = 1.0  // 1.0 = normal, >1.0 = high demand
    ) -> Double {
        // Bid at floor + 10% margin, scaled by demand
        floorPerKToken * 1.1 * demandMultiplier
    }

    /// Calculate a provider's floor price per 1K tokens from their electricity cost.
    public static func floorPricePerKToken(
        tokensPerSecond: Double,
        hardwareWatts: Double,
        costPerKWh: Double,
        marginMultiplier: Double = 1.2
    ) -> Double {
        guard tokensPerSecond > 0 else { return 0 }
        let secondsPer1KTokens = 1000.0 / tokensPerSecond
        let kWhPer1KTokens = (hardwareWatts * secondsPer1KTokens) / 3_600_000.0
        return kWhPer1KTokens * costPerKWh * marginMultiplier
    }

    /// Select the winning bid for a job posting.
    /// Returns the best bid that's under the requestor's max, or nil if no valid bids.
    public static func selectWinner(posting: JobPosting, bids: [ProviderBid]) -> ProviderBid? {
        bids
            .filter { $0.bidPerKToken <= posting.maxBidPerKToken }
            .sorted()
            .first
    }
}
