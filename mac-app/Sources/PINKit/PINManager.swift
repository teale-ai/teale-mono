import Foundation
import CryptoKit

// MARK: - Private Inference Network (PIN) — wire types
// Mirrors protocol/src/pin.rs (camelCase). The netmap is the gateway-signed
// membership snapshot devices cache and use to authenticate peers; verify
// against a pinned gateway Ed25519 key over canonical (recursively
// key-sorted, compact) JSON.

public struct PinEndpoint: Codable, Sendable, Equatable {
    public let kind: String  // "lan" | "reflexive" | "relay"
    public let addr: String
    public init(kind: String, addr: String) {
        self.kind = kind
        self.addr = addr
    }
}

public struct PinNetmapMember: Codable, Sendable, Equatable {
    public let deviceId: String
    public let nodePubkey: String
    public let wgPubkey: String
    public let displayName: String?
    public let servesModels: Bool
    public let disabled: Bool
    public let endpoints: [PinEndpoint]
    public let loadedModels: [String]
    public let lastSeen: Int64?
}

public struct PinNetmap: Codable, Sendable, Equatable {
    public let pinId: String
    public let name: String
    public let generation: Int64
    public let issuedAt: Int64
    public let members: [PinNetmapMember]
}

/// Decoded + raw form of a signed netmap. Signature verification runs over
/// the RAW wire bytes of the `netmap` subtree (canonicalized), never over a
/// Codable re-encoding — re-encoding cannot be trusted to reproduce bytes.
public struct SignedPinNetmap: @unchecked Sendable, Equatable {
    public let netmap: PinNetmap
    public let gatewayPubkey: String
    public let signature: String
    /// The raw JSON object for the `netmap` field, as received.
    public let rawNetmapObject: [String: Any]

    public static func == (lhs: SignedPinNetmap, rhs: SignedPinNetmap) -> Bool {
        lhs.netmap == rhs.netmap && lhs.gatewayPubkey == rhs.gatewayPubkey
            && lhs.signature == rhs.signature
    }
}

public enum PINError: Error, CustomStringConvertible {
    case decode(String)
    case verification(String)
    case http(Int, String)

    public var description: String {
        switch self {
        case .decode(let m): return "pin decode: \(m)"
        case .verification(let m): return "pin netmap verification failed: \(m)"
        case .http(let code, let m): return "pin http \(code): \(m.prefix(200))"
        }
    }
}

public enum PINNetmap {
    public static let maxAgeSeconds: Int64 = 24 * 60 * 60

    /// Parse the wire JSON of a SignedPinNetmap keeping the raw subtree.
    public static func parse(_ data: Data) throws -> SignedPinNetmap {
        guard
            let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawNetmap = top["netmap"] as? [String: Any],
            let gatewayPubkey = top["gatewayPubkey"] as? String,
            let signature = top["signature"] as? String
        else {
            throw PINError.decode("signed netmap shape")
        }
        let netmapData = try JSONSerialization.data(withJSONObject: rawNetmap)
        let netmap = try JSONDecoder().decode(PinNetmap.self, from: netmapData)
        return SignedPinNetmap(
            netmap: netmap,
            gatewayPubkey: gatewayPubkey,
            signature: signature,
            rawNetmapObject: rawNetmap
        )
    }

    /// Canonical JSON: recursively key-sorted, compact — byte-compatible
    /// with Rust's `teale_protocol::canonical_json`.
    public static func canonicalJSON(_ object: Any) throws -> Data {
        func canonicalize(_ value: Any) -> String {
            switch value {
            case let dict as [String: Any]:
                let inner = dict.keys.sorted().map { key in
                    "\(encodeString(key)):\(canonicalize(dict[key]!))"
                }
                return "{\(inner.joined(separator: ","))}"
            case let array as [Any]:
                return "[\(array.map(canonicalize).joined(separator: ","))]"
            case let string as String:
                return encodeString(string)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    return number.boolValue ? "true" : "false"
                }
                // Netmap numbers are integers (timestamps, generations).
                return "\(number.int64Value)"
            case is NSNull:
                return "null"
            default:
                return "null"
            }
        }
        func encodeString(_ s: String) -> String {
            // serde_json-compatible minimal escaping.
            var out = "\""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }
        return Data(canonicalize(object).utf8)
    }

    /// Verify against the pinned gateway key (hex). The embedded key must
    /// match the pinned key — otherwise any keypair could sign a forgery.
    public static func verify(_ signed: SignedPinNetmap, pinnedGatewayKey: String) -> Bool {
        guard signed.gatewayPubkey.lowercased() == pinnedGatewayKey.lowercased(),
            let keyBytes = Data(hexString: signed.gatewayPubkey), keyBytes.count == 32,
            let sigBytes = Data(hexString: signed.signature), sigBytes.count == 64,
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
            let message = try? canonicalJSON(signed.rawNetmapObject)
        else {
            return false
        }
        return publicKey.isValidSignature(sigBytes, for: message)
    }

    public static func isStale(_ signed: SignedPinNetmap, now: Int64) -> Bool {
        now - signed.netmap.issuedAt > maxAgeSeconds
    }
}

extension Data {
    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else {
                return nil
            }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    public var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Local device settings (device-sovereign; never set remotely)

public struct LocalPinSettings: Codable, Sendable, Equatable {
    public var allowRemoteModels: Bool
    public var dinPriorityEqual: Bool
    public var dinContribute: Bool

    public init(allowRemoteModels: Bool = true, dinPriorityEqual: Bool = false, dinContribute: Bool = true) {
        self.allowRemoteModels = allowRemoteModels
        self.dinPriorityEqual = dinPriorityEqual
        self.dinContribute = dinContribute
    }

    enum CodingKeys: String, CodingKey {
        case allowRemoteModels, dinPriorityEqual, dinContribute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowRemoteModels = try c.decodeIfPresent(Bool.self, forKey: .allowRemoteModels) ?? true
        dinPriorityEqual = try c.decodeIfPresent(Bool.self, forKey: .dinPriorityEqual) ?? false
        dinContribute = try c.decodeIfPresent(Bool.self, forKey: .dinContribute) ?? true
    }
}

// MARK: - Membership state

public struct PinMembershipState: @unchecked Sendable {
    public let pinId: String
    public let name: String
    public var membership: String  // pending | active | disabled | none
    public var netmap: SignedPinNetmap?
    public var settings: [String: Any]?
    public var modelPolicy: [[String: Any]]
}

/// Auth surface PINManager needs from GatewayKit (kept as a protocol so
/// tests can stub it).
public protocol PINGatewayAuth: Sendable {
    var deviceID: String { get }
    func bearer() async throws -> String
}

// MARK: - PINManager

/// Control-plane client: memberships, sync, signed-netmap TOFU cache, usage
/// batching, generic authenticated proxy. Mirrors node/src/pin/manager.rs.
public actor PINManager {
    public nonisolated let gatewayBaseURL: URL
    public nonisolated let dataDir: URL
    /// X25519 static pubkey advertised for data-plane auth (hex).
    public nonisolated let wgPubkeyHex: String

    private let auth: any PINGatewayAuth
    private let session: URLSession
    private var pinnedGatewayKey: String?
    private var state: [String: PinMembershipState] = [:]
    private var settingsValue: LocalPinSettings
    /// Latest policy reconciliation rows: (pinId, modelId, appliedState, error)
    private var policyStatus: [(String, String, String, String?)] = []
    /// Pending usage records (persisted as JSONL alongside outbox batches).
    private var usagePendingCount = 0

    public init(
        gatewayBaseURL: URL = URL(string: "https://gateway.teale.com")!,
        auth: any PINGatewayAuth,
        wgPubkeyHex: String,
        dataDir: URL,
        configuredGatewayKey: String? = nil,
        session: URLSession = .shared
    ) {
        self.gatewayBaseURL = gatewayBaseURL
        self.auth = auth
        self.wgPubkeyHex = wgPubkeyHex
        self.dataDir = dataDir
        self.session = session
        try? FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent("usage/outbox"),
            withIntermediateDirectories: true
        )
        if let configured = configuredGatewayKey {
            pinnedGatewayKey = configured
        } else if let persisted = try? String(
            contentsOf: dataDir.appendingPathComponent("gateway.pub"), encoding: .utf8
        ) {
            let trimmed = persisted.trimmingCharacters(in: .whitespacesAndNewlines)
            pinnedGatewayKey = trimmed.isEmpty ? nil : trimmed
        }
        settingsValue =
            (try? JSONDecoder().decode(
                LocalPinSettings.self,
                from: Data(contentsOf: dataDir.appendingPathComponent("local-settings.json"))
            )) ?? LocalPinSettings()
        usagePendingCount = Self.countLines(dataDir.appendingPathComponent("usage/records.jsonl"))
        state = Self.loadCachedNetmaps(dataDir: dataDir, pinnedGatewayKey: pinnedGatewayKey)
    }

    // MARK: HTTP

    private func request(
        _ method: String, _ path: String, body: [String: Any]? = nil
    ) async throws -> (Int, Data) {
        var req = URLRequest(url: gatewayBaseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("Bearer \(try await auth.bearer())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    private func requireOK(_ result: (Int, Data)) throws -> Data {
        guard (200..<300).contains(result.0) else {
            throw PINError.http(result.0, String(data: result.1, encoding: .utf8) ?? "")
        }
        return result.1
    }

    /// Generic authenticated passthrough for the local app API.
    public func proxy(method: String, path: String, body: [String: Any]?) async throws -> (Int, Data) {
        try await request(method, path, body: body)
    }

    // MARK: Membership + sync

    public func join(code: String, displayName: String?) async throws {
        _ = try requireOK(
            try await request(
                "POST", "/v1/pins/join",
                body: [
                    "joinCode": code,
                    "displayName": displayName as Any,
                    "nodePubkey": auth.deviceID,
                ]
            ))
    }

    public struct Membership: Decodable {
        public let pinId: String
        public let name: String
        public let status: String
    }

    public func fetchMemberships() async throws -> [Membership] {
        struct ListResponse: Decodable { let memberships: [Membership]? }
        let data = try requireOK(try await request("GET", "/v1/pins"))
        return (try JSONDecoder().decode(ListResponse.self, from: data)).memberships ?? []
    }

    public func fetchStaffSummaries() async -> [[String: Any]] {
        guard let (status, data) = try? await request("GET", "/v1/pins"), status == 200,
            let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let staff = top["staff"] as? [[String: Any]]
        else { return [] }
        return staff
    }

    /// One sync round for every membership. Advertises endpoints + loaded
    /// models + policy status; verifies and caches any returned netmap.
    public func syncOnce(endpoints: [PinEndpoint], loadedModels: [String]) async throws -> Int {
        let memberships = try await fetchMemberships()
        let known = Set(memberships.map(\.pinId))
        state = state.filter { known.contains($0.key) }

        var synced = 0
        for membership in memberships {
            let knownGeneration = state[membership.pinId]?.netmap?.netmap.generation
            let statusRows = policyStatus
                .filter { $0.0 == membership.pinId }
                .map { ["modelId": $0.1, "appliedState": $0.2, "error": $0.3 as Any] }
            let body: [String: Any] = [
                "endpoints": endpoints.map { ["kind": $0.kind, "addr": $0.addr] },
                "wgPubkey": wgPubkeyHex,
                "loadedModels": loadedModels,
                "knownGeneration": knownGeneration as Any,
                "modelPolicyStatus": statusRows,
            ]
            let data = try requireOK(
                try await request("POST", "/v1/pins/\(membership.pinId)/sync", body: body))
            guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let membershipStatus = top["membership"] as? String
            else { throw PINError.decode("sync response") }

            var entry = state[membership.pinId]
                ?? PinMembershipState(
                    pinId: membership.pinId, name: membership.name,
                    membership: membershipStatus, netmap: nil, settings: nil, modelPolicy: [])
            entry.membership = membershipStatus
            entry.settings = top["settings"] as? [String: Any]
            entry.modelPolicy = (top["modelPolicy"] as? [[String: Any]]) ?? []
            // `netmap` on the sync response is a full SignedPinNetmap
            // object ({netmap, gatewayPubkey, signature}).
            if let netmapValue = top["netmap"] {
                let signedData = try JSONSerialization.data(withJSONObject: netmapValue)
                let signed = try PINNetmap.parse(signedData)
                try acceptNetmap(pinId: membership.pinId, signed: signed)
                entry.netmap = state[membership.pinId]?.netmap ?? signed
            }
            state[membership.pinId] = entry
            synced += 1
        }
        return synced
    }

    private func acceptNetmap(pinId: String, signed: SignedPinNetmap) throws {
        let pinned: String
        if let existing = pinnedGatewayKey {
            pinned = existing
        } else {
            // Trust on first use; persist.
            pinned = signed.gatewayPubkey
            pinnedGatewayKey = pinned
            try? pinned.write(
                to: dataDir.appendingPathComponent("gateway.pub"), atomically: true, encoding: .utf8)
        }
        guard PINNetmap.verify(signed, pinnedGatewayKey: pinned) else {
            throw PINError.verification("signature mismatch for network \(pinId)")
        }
        guard !PINNetmap.isStale(signed, now: Int64(Date().timeIntervalSince1970)) else {
            throw PINError.verification("netmap stale for network \(pinId)")
        }
        let dir = dataDir.appendingPathComponent(pinId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let persisted: [String: Any] = [
            "netmap": signed.rawNetmapObject,
            "gatewayPubkey": signed.gatewayPubkey,
            "signature": signed.signature,
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: persisted) {
            try? bytes.write(to: dir.appendingPathComponent("netmap.json"))
        }
        state[pinId]?.netmap = signed
    }

    private static func loadCachedNetmaps(
        dataDir: URL, pinnedGatewayKey: String?
    ) -> [String: PinMembershipState] {
        guard let pinned = pinnedGatewayKey,
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dataDir, includingPropertiesForKeys: nil)
        else { return [:] }
        let now = Int64(Date().timeIntervalSince1970)
        var loaded: [String: PinMembershipState] = [:]
        for entry in entries {
            let file = entry.appendingPathComponent("netmap.json")
            guard let bytes = try? Data(contentsOf: file),
                let signed = try? PINNetmap.parse(bytes),
                PINNetmap.verify(signed, pinnedGatewayKey: pinned),
                !PINNetmap.isStale(signed, now: now)
            else { continue }
            loaded[signed.netmap.pinId] = PinMembershipState(
                pinId: signed.netmap.pinId, name: signed.netmap.name,
                membership: "active", netmap: signed, settings: nil, modelPolicy: [])
        }
        return loaded
    }

    // MARK: Queries

    public func snapshot() -> [PinMembershipState] {
        state.values.sorted { $0.name < $1.name }
    }

    public func memberForWgKey(_ wgKeyHex: String) -> (String, PinNetmapMember)? {
        for pin in state.values where pin.membership == "active" {
            guard let netmap = pin.netmap?.netmap else { continue }
            if let member = netmap.members.first(where: {
                !$0.disabled && $0.wgPubkey.lowercased() == wgKeyHex.lowercased()
            }) {
                return (pin.pinId, member)
            }
        }
        return nil
    }

    public func memberForNodePubkey(_ nodeId: String) -> (String, PinNetmapMember)? {
        for pin in state.values where pin.membership == "active" {
            guard let netmap = pin.netmap?.netmap else { continue }
            if let member = netmap.members.first(where: {
                !$0.disabled && $0.nodePubkey.lowercased() == nodeId.lowercased()
            }) {
                return (pin.pinId, member)
            }
        }
        return nil
    }

    public func servingPeersForModel(_ modelId: String) -> [(String, PinNetmapMember)] {
        var peers: [(String, PinNetmapMember)] = []
        for pin in state.values where pin.membership == "active" {
            guard let netmap = pin.netmap?.netmap else { continue }
            for member in netmap.members
            where !member.disabled && member.servesModels
                && member.wgPubkey.lowercased() != wgPubkeyHex.lowercased()
                && member.loadedModels.contains(modelId) {
                peers.append((pin.pinId, member))
            }
        }
        return peers
    }

    public struct ScheduleChoice: Decodable {
        public let deviceId: String
        public let nodePubkey: String
    }

    public func schedule(pinId: String, model: String, exclude: [String]) async throws -> ScheduleChoice {
        let data = try requireOK(
            try await request(
                "POST", "/v1/pins/\(pinId)/schedule",
                body: ["model": model, "exclude": exclude]
            ))
        return try JSONDecoder().decode(ScheduleChoice.self, from: data)
    }

    // MARK: Settings

    public func settings() -> LocalPinSettings { settingsValue }

    @discardableResult
    public func updateSettings(_ mutate: (inout LocalPinSettings) -> Void) -> LocalPinSettings {
        mutate(&settingsValue)
        if let bytes = try? JSONEncoder().encode(settingsValue) {
            try? bytes.write(to: dataDir.appendingPathComponent("local-settings.json"))
        }
        return settingsValue
    }

    public func recordPolicyStatus(_ rows: [(String, String, String, String?)]) {
        policyStatus = rows
    }

    public func modelPolicy(for pinId: String) -> [[String: Any]] {
        state[pinId]?.modelPolicy ?? []
    }

    // MARK: Usage (token counts only — never credits)

    public struct UsageRecord: Codable {
        public let pinId: String
        public let day: String
        public let consumerDeviceId: String
        public let modelId: String
        public let tokensIn: Int64
        public let tokensOut: Int64
        public init(pinId: String, day: String, consumerDeviceId: String, modelId: String, tokensIn: Int64, tokensOut: Int64) {
            self.pinId = pinId
            self.day = day
            self.consumerDeviceId = consumerDeviceId
            self.modelId = modelId
            self.tokensIn = tokensIn
            self.tokensOut = tokensOut
        }
    }

    public static func todayUTC() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    public func recordUsage(_ record: UsageRecord) {
        let file = dataDir.appendingPathComponent("usage/records.jsonl")
        guard let line = try? JSONEncoder().encode(record) else { return }
        var payload = Data(line)
        payload.append(0x0A)
        if let handle = FileHandle(forWritingAtPath: file.path) {
            handle.seekToEndOfFile()
            handle.write(payload)
            try? handle.close()
        } else {
            try? payload.write(to: file)
        }
        usagePendingCount += 1
        if usagePendingCount >= 50 {
            Task { await self.flushUsage() }
        }
    }

    public func pendingUsageBatches() -> Int {
        let outbox = dataDir.appendingPathComponent("usage/outbox")
        return (try? FileManager.default.contentsOfDirectory(atPath: outbox.path).count) ?? 0
    }

    /// Seal records into per-network batches, push outbox; batchId dedup on
    /// the gateway makes retries safe. Mirrors node/src/pin/usage.rs.
    public func flushUsage() async {
        sealBatches()
        let outbox = dataDir.appendingPathComponent("usage/outbox")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: outbox, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard let bytes = try? Data(contentsOf: file),
                let batch = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                let pinId = batch["pinId"] as? String
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let (status, _) = try? await request(
                "POST", "/v1/pins/\(pinId)/usage-report",
                body: ["batchId": batch["batchId"] as Any, "entries": batch["entries"] as Any])
            else { continue }
            if (200..<300).contains(status) || status == 404 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func sealBatches() {
        let file = dataDir.appendingPathComponent("usage/records.jsonl")
        guard let contents = try? String(contentsOf: file, encoding: .utf8), !contents.isEmpty
        else { return }
        var byPin: [String: [String: [String: Any]]] = [:]  // pin → aggKey → entry
        for line in contents.split(separator: "\n") {
            guard let record = try? JSONDecoder().decode(UsageRecord.self, from: Data(line.utf8))
            else { continue }
            let key = "\(record.day)|\(record.consumerDeviceId)|\(record.modelId)"
            var entry = byPin[record.pinId]?[key] ?? [
                "day": record.day,
                "consumerDeviceId": record.consumerDeviceId,
                "modelId": record.modelId,
                "requests": 0, "tokensIn": 0, "tokensOut": 0,
            ]
            entry["requests"] = (entry["requests"] as! Int) + 1
            entry["tokensIn"] = (entry["tokensIn"] as! Int) + Int(record.tokensIn)
            entry["tokensOut"] = (entry["tokensOut"] as! Int) + Int(record.tokensOut)
            byPin[record.pinId, default: [:]][key] = entry
        }
        for (pinId, entries) in byPin {
            let batch: [String: Any] = [
                "pinId": pinId,
                "batchId": UUID().uuidString.lowercased(),
                "entries": Array(entries.values),
            ]
            if let bytes = try? JSONSerialization.data(withJSONObject: batch) {
                let path = dataDir.appendingPathComponent(
                    "usage/outbox/\(batch["batchId"] as! String).json")
                try? bytes.write(to: path)
            }
        }
        try? "".write(to: file, atomically: true, encoding: .utf8)
        usagePendingCount = 0
    }

    private static func countLines(_ url: URL) -> Int {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return contents.split(separator: "\n").count
    }
}
