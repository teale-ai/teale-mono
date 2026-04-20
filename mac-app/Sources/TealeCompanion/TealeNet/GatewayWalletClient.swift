#if os(iOS)
import Foundation

struct GwBalance: Decodable, Sendable {
    let deviceID: String
    let balance_credits: Int64
    let total_earned_credits: Int64
    let total_spent_credits: Int64
    let usdc_cents: Int64
}

struct GwLedgerEntry: Decodable, Identifiable, Sendable {
    let id: Int64
    let device_id: String
    let type: String         // BONUS | DIRECT_EARN | AVAILABILITY_EARN | AVAILABILITY_DRIP | SPENT | OPS_FEE
    let amount: Int64
    let timestamp: Int64
    let refRequestID: String?
    let note: String?
}

struct GwTxListRes: Decodable { let transactions: [GwLedgerEntry] }

final class GatewayWalletClient: @unchecked Sendable {

    private let auth: GatewayAuthClient
    private let baseURL: URL
    private let session: URLSession

    init(auth: GatewayAuthClient,
         baseURL: URL = URL(string: "https://gateway.teale.com")!,
         session: URLSession = .shared) {
        self.auth = auth
        self.baseURL = baseURL
        self.session = session
    }

    func balance() async throws -> GwBalance {
        try await getJSON("/v1/wallet/balance")
    }

    func transactions(limit: Int = 50) async throws -> [GwLedgerEntry] {
        let res: GwTxListRes = try await getJSON("/v1/wallet/transactions?limit=\(limit)")
        return res.transactions
    }

    private func getJSON<R: Decodable>(_ path: String) async throws -> R {
        let token = try await auth.bearer()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(R.self, from: data)
    }
}
#endif
