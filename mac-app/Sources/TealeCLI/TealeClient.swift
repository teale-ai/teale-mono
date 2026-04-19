import Foundation
import LocalAPI

/// HTTP client for talking to a running Teale node (GUI app or `teale serve`).
struct TealeClient {
    let baseURL: URL
    let apiKey: String?

    init(port: Int, apiKey: String? = nil) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.apiKey = apiKey
    }

    // MARK: - App Snapshot

    func snapshot() async throws -> RemoteAppSnapshot {
        try await get("/v1/app")
    }

    // MARK: - Model Control

    func loadModel(_ model: String, downloadIfNeeded: Bool = false) async throws -> RemoteAppSnapshot {
        let body = RemoteModelControlRequest(model: model, downloadIfNeeded: downloadIfNeeded)
        return try await post("/v1/app/models/load", body: body)
    }

    func downloadModel(_ model: String) async throws -> RemoteAppSnapshot {
        let body = RemoteModelControlRequest(model: model)
        return try await post("/v1/app/models/download", body: body)
    }

    func unloadModel() async throws -> RemoteAppSnapshot {
        try await post("/v1/app/models/unload")
    }

    // MARK: - Settings

    func updateSettings(_ update: RemoteSettingsUpdate) async throws -> RemoteAppSnapshot {
        try await patch("/v1/app/settings", body: update)
    }

    // MARK: - PTN

    func listPTNs() async throws -> [RemotePTNSnapshot] {
        try await get("/v1/app/ptn")
    }

    func createPTN(name: String) async throws -> RemotePTNSnapshot {
        struct Body: Encodable { var name: String }
        return try await post("/v1/app/ptn/create", body: Body(name: name))
    }

    func invitePTN(ptnID: String) async throws -> String {
        struct Body: Encodable { var ptn_id: String }
        struct Resp: Decodable { var invite_code: String }
        let resp: Resp = try await post("/v1/app/ptn/invite", body: Body(ptn_id: ptnID))
        return resp.invite_code
    }

    func leavePTN(ptnID: String) async throws {
        struct Body: Encodable { var ptn_id: String }
        struct Resp: Decodable { var ok: Bool }
        let _: Resp = try await post("/v1/app/ptn/leave", body: Body(ptn_id: ptnID))
    }

    func issuePTNCert(ptnID: String, nodeID: String, role: String) async throws -> String {
        struct Body: Encodable { var ptn_id: String; var node_id: String; var role: String }
        let data = try await postRaw("/v1/app/ptn/issue-cert", body: Body(ptn_id: ptnID, node_id: nodeID, role: role))
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func joinPTNWithCert(certData: String) async throws -> RemotePTNSnapshot {
        guard let data = certData.data(using: .utf8) else {
            throw TealeClientError.invalidResponse
        }
        return try await postRawBody("/v1/app/ptn/join-with-cert", body: data)
    }

    func promoteAdmin(ptnID: String, nodeID: String) async throws -> String {
        struct Body: Encodable { var ptn_id: String; var node_id: String }
        let data = try await postRaw("/v1/app/ptn/promote-admin", body: Body(ptn_id: ptnID, node_id: nodeID))
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    func importCAKey(ptnID: String, caKeyHex: String) async throws -> RemotePTNSnapshot {
        struct Body: Encodable { var ptn_id: String; var ca_key_hex: String }
        return try await post("/v1/app/ptn/import-ca-key", body: Body(ptn_id: ptnID, ca_key_hex: caKeyHex))
    }

    func recoverPTN(ptnID: String) async throws -> RemotePTNSnapshot {
        struct Body: Encodable { var ptn_id: String }
        return try await post("/v1/app/ptn/recover", body: Body(ptn_id: ptnID))
    }

    // MARK: - API Keys

    func listAPIKeys() async throws -> [RemoteAPIKeySnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await get("/v1/app/apikeys", decoder: decoder)
    }

    func generateAPIKey(name: String) async throws -> RemoteAPIKeySnapshot {
        struct Body: Encodable { var name: String }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await post("/v1/app/apikeys", body: Body(name: name), decoder: decoder)
    }

    func revokeAPIKey(id: UUID) async throws {
        struct Body: Encodable { var id: UUID }
        struct Resp: Decodable { var ok: Bool }
        let _: Resp = try await post("/v1/app/apikeys/revoke", body: Body(id: id))
    }

    // MARK: - Wallet

    func walletBalance() async throws -> RemoteWalletSnapshot {
        try await get("/v1/app/wallet")
    }

    func walletTransactions(limit: Int = 20) async throws -> [RemoteTransactionSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await get("/v1/app/wallet/transactions?limit=\(limit)", decoder: decoder)
    }

    func walletSend(amount: Double, peerID: String, memo: String? = nil) async throws -> Bool {
        struct Body: Encodable { var amount: Double; var peer_id: String; var memo: String? }
        struct Resp: Decodable { var success: Bool }
        let resp: Resp = try await post("/v1/app/wallet/send", body: Body(amount: amount, peer_id: peerID, memo: memo))
        return resp.success
    }

    func solanaStatus() async throws -> RemoteSolanaSnapshot {
        try await get("/v1/app/wallet/solana")
    }

    // MARK: - Peers

    func listPeers() async throws -> RemotePeersSnapshot {
        try await get("/v1/app/peers")
    }

    // MARK: - Agent

    func agentProfile() async throws -> RemoteAgentProfileSnapshot? {
        // Returns nil-able — 400 means no profile configured
        do {
            return try await get("/v1/app/agent/profile")
        } catch TealeClientError.httpError(400) {
            return nil
        }
    }

    func agentDirectory() async throws -> [RemoteAgentDirectoryEntry] {
        try await get("/v1/app/agent/directory")
    }

    func agentConversations() async throws -> [RemoteAgentConversationSnapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try await get("/v1/app/agent/conversations", decoder: decoder)
    }

    // MARK: - Chat

    func chatStream(prompt: String, model: String?) async throws -> URLSession.AsyncBytes {
        let url = baseURL.appending(path: "/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        struct ChatBody: Encodable {
            let model: String?
            let messages: [[String: String]]
            let stream: Bool
        }

        let body = ChatBody(
            model: model,
            messages: [["role": "user", "content": prompt]],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let http = response as? HTTPURLResponse
            throw TealeClientError.httpError(http?.statusCode ?? 0)
        }
        return bytes
    }

    // MARK: - Helpers

    private func get<T: Decodable>(_ path: String, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try decoder.decode(T.self, from: data)
    }

    private func patch<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postRaw<B: Encodable>(_ path: String, body: B) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return data
    }

    private func postRawBody<T: Decodable>(_ path: String, body: Data) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TealeClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TealeClientError.httpError(http.statusCode)
        }
    }
}

enum TealeClientError: LocalizedError {
    case connectionRefused
    case httpError(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .connectionRefused:
            return "Cannot connect to Teale node. Is `teale serve` or the Teale app running?"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .invalidResponse:
            return "Invalid response from Teale node"
        }
    }
}
