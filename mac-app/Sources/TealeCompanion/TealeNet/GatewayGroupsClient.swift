#if os(iOS)
import Foundation

// MARK: - Wire types

struct GwGroupSummary: Decodable, Identifiable, Sendable {
    let groupID: String
    let title: String
    let createdBy: String
    let createdAt: Int64
    let memberCount: Int64
    var id: String { groupID }
}

struct GwGroupMessage: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let groupID: String
    let senderDeviceID: String
    let type: String          // "text" | "ai" | …
    let content: String
    let refMessageID: String?
    let timestamp: Int64
}

struct GwGroupListRes: Decodable { let groups: [GwGroupSummary] }
struct GwMessagesRes: Decodable { let messages: [GwGroupMessage] }
struct GwMemoryEntry: Decodable, Sendable {
    let id: String
    let groupID: String
    let category: String?
    let text: String
    let sourceMessageID: String?
    let createdAt: Int64
}
struct GwMemoryRes: Decodable { let entries: [GwMemoryEntry] }

/// REST client for /v1/groups/*. Mirrors
/// `android-app/.../GroupRepository.kt`.
final class GatewayGroupsClient: @unchecked Sendable {

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

    // MARK: - Membership / listing

    func listMine() async throws -> [GwGroupSummary] {
        let res: GwGroupListRes = try await getJSON("/v1/groups/mine")
        return res.groups
    }

    @discardableResult
    func create(title: String, memberDeviceIDs: [String] = []) async throws -> GwGroupSummary {
        struct Req: Encodable { let title: String; let memberDeviceIDs: [String] }
        return try await postJSON("/v1/groups", body: Req(title: title, memberDeviceIDs: memberDeviceIDs))
    }

    @discardableResult
    func addMember(groupID: String, deviceID: String) async throws -> GwGroupSummary {
        struct Req: Encodable { let deviceID: String }
        return try await postJSON("/v1/groups/\(groupID)/members", body: Req(deviceID: deviceID))
    }

    // MARK: - Messages

    @discardableResult
    func postMessage(groupID: String, content: String, type: String = "text") async throws -> GwGroupMessage {
        struct Req: Encodable { let type: String; let content: String }
        return try await postJSON(
            "/v1/groups/\(groupID)/messages",
            body: Req(type: type, content: content)
        )
    }

    func listMessages(groupID: String, since: Int64 = 0, limit: Int = 200) async throws -> [GwGroupMessage] {
        let res: GwMessagesRes = try await getJSON(
            "/v1/groups/\(groupID)/messages?since=\(since)&limit=\(limit)"
        )
        return res.messages
    }

    // MARK: - Memory (group-scoped notes for the AI)

    @discardableResult
    func remember(groupID: String, text: String, category: String? = nil) async throws -> GwMemoryEntry {
        struct Req: Encodable { let category: String?; let text: String }
        return try await postJSON(
            "/v1/groups/\(groupID)/memory",
            body: Req(category: category, text: text)
        )
    }

    func recall(groupID: String) async throws -> [GwMemoryEntry] {
        let res: GwMemoryRes = try await getJSON("/v1/groups/\(groupID)/memory")
        return res.entries
    }

    // MARK: - HTTP helpers

    private func getJSON<R: Decodable>(_ path: String) async throws -> R {
        let token = try await auth.bearer()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await roundTrip(req)
    }

    private func postJSON<Body: Encodable, R: Decodable>(
        _ path: String, body: Body
    ) async throws -> R {
        let token = try await auth.bearer()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)
        return try await roundTrip(req)
    }

    private func roundTrip<R: Decodable>(_ req: URLRequest) async throws -> R {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GatewayAuthError.network("non-http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GatewayAuthError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw GatewayAuthError.decode("\(error)") }
    }
}
#endif
