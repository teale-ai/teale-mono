import ArgumentParser
import Foundation

/// `teale pin …` — manage Private Inference Networks from the Mac CLI.
/// Same surface as `teale-node pin …` on Windows/Linux; talks to the local
/// app API, which proxies management calls to the gateway with this
/// device's bearer.
struct Pin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: "Manage Private Inference Networks (join, approve, devices, models, usage)",
        subcommands: [
            PinStatus.self, PinCreate.self, PinJoin.self, PinRequests.self,
            PinApprove.self, PinDeny.self, PinDevices.self, PinRenameDevice.self,
            PinRemoveDevice.self, PinRotateCode.self, PinJoinCode.self,
            PinModels.self, PinUsage.self, PinLeave.self,
        ]
    )
}

struct PinOptions: ParsableArguments {
    @Option(name: .long, help: "Local app API port")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?

    @Flag(name: .long, help: "Machine-readable JSON output")
    var json = false
}

private func pinClient(_ options: PinOptions) -> TealeClient {
    TealeClient(port: options.port, apiKey: options.apiKey)
}

private func emit(_ value: Any, json: Bool, human: (Any) -> String) {
    if json,
        let data = try? JSONSerialization.data(
            withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print(human(value))
    }
}

/// Resolve --net (name / id / prefix) or default to the sole network.
private func resolveNet(_ client: TealeClient, _ net: String?) async throws -> String {
    let overview = try await client.pinRequest("GET", "/v1/app/pins") as? [String: Any] ?? [:]
    var nets: [(String, String)] = []  // (id, name)
    for entry in overview["networks"] as? [[String: Any]] ?? [] {
        if let id = entry["pinId"] as? String {
            nets.append((id, entry["name"] as? String ?? id))
        }
    }
    for entry in overview["staff"] as? [[String: Any]] ?? [] {
        if let id = entry["pinId"] as? String, !nets.contains(where: { $0.0 == id }) {
            nets.append((id, entry["name"] as? String ?? id))
        }
    }
    if let net {
        let matches = nets.filter { $0.0 == net || $0.1 == net || $0.0.hasPrefix(net) }
        guard matches.count == 1 else {
            throw ValidationError(
                matches.isEmpty
                    ? "no network matches '\(net)'"
                    : "'\(net)' is ambiguous; use the full network id: \(matches.map { "\($0.1) (\($0.0))" }.joined(separator: ", "))")
        }
        return matches[0].0
    }
    switch nets.count {
    case 1: return nets[0].0
    case 0: throw ValidationError("this device is not in any network — `teale pin join <PIN>`")
    default:
        throw ValidationError(
            "multiple networks; pick one with --net: \(nets.map(\.1).joined(separator: ", "))")
    }
}

private func renderMembers(_ value: Any, onlyStatus: String? = nil) -> String {
    let members = (value as? [[String: Any]] ?? []).filter {
        onlyStatus == nil || ($0["status"] as? String) == onlyStatus
    }
    if members.isEmpty {
        return onlyStatus == "pending" ? "no pending join requests" : "no devices"
    }
    var out = String(
        format: "%-26@ %-10@ %-8@ %-24@ %@\n", "DEVICE" as NSString, "STATUS" as NSString,
        "SERVES" as NSString, "MODELS" as NSString, "ID" as NSString)
    for member in members {
        let models =
            (try? JSONDecoder().decode(
                [String].self, from: Data((member["loadedModels"] as? String ?? "[]").utf8)))
            ?? []
        out += String(
            format: "%-26@ %-10@ %-8@ %-24@ %@\n",
            (member["displayName"] as? String ?? "-") as NSString,
            (member["status"] as? String ?? "?") as NSString,
            ((member["servesModels"] as? Bool ?? false) ? "yes" : "no") as NSString,
            (models.isEmpty ? "-" : models.joined(separator: ",")) as NSString,
            (member["deviceId"] as? String ?? "?") as NSString)
    }
    return out.trimmingCharacters(in: .newlines)
}

struct PinStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show networks this device belongs to")
    @OptionGroup var options: PinOptions

    func run() async throws {
        let overview = try await pinClient(options).pinRequest("GET", "/v1/app/pins")
        emit(overview, json: options.json) { value in
            let top = value as? [String: Any] ?? [:]
            var rows: [String] = []
            for entry in top["networks"] as? [[String: Any]] ?? [] {
                rows.append(String(
                    format: "%-24@ %-14@ %@",
                    (entry["name"] as? String ?? "?") as NSString,
                    (entry["membership"] as? String ?? "?") as NSString,
                    (entry["pinId"] as? String ?? "?") as NSString))
            }
            for entry in top["staff"] as? [[String: Any]] ?? [] {
                let id = entry["pinId"] as? String ?? "?"
                if !rows.contains(where: { $0.contains(id) }) {
                    rows.append(String(
                        format: "%-24@ %-14@ %@",
                        (entry["name"] as? String ?? "?") as NSString,
                        ("staff:" + (entry["role"] as? String ?? "?")) as NSString,
                        id as NSString))
                }
            }
            return rows.isEmpty
                ? "no private networks — join one with `teale pin join <PIN>`"
                : rows.joined(separator: "\n")
        }
    }
}

struct PinCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create", abstract: "Create a network (account-linked device required)")
    @Argument var name: String
    @OptionGroup var options: PinOptions

    func run() async throws {
        let created = try await pinClient(options).pinRequest(
            "POST", "/v1/app/pins/create", body: ["name": name])
        emit(created, json: options.json) { value in
            let top = value as? [String: Any] ?? [:]
            let code = top["joinCode"] as? String ?? "?"
            return "created network '\(top["name"] as? String ?? name)'\njoin PIN: \(code)  (share it; you approve each device)"
        }
    }
}

struct PinJoin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "join", abstract: "Request to join a network with its PIN")
    @Argument var code: String
    @OptionGroup var options: PinOptions

    func run() async throws {
        _ = try await pinClient(options).pinRequest(
            "POST", "/v1/app/pins/join", body: ["code": code])
        print("join request submitted — waiting for admin approval")
    }
}

struct PinRequests: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "requests", abstract: "List pending join requests (staff)")
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        let members = try await client.pinRequest("GET", "/v1/app/pins/\(id)/members")
        emit(members, json: options.json) { renderMembers($0, onlyStatus: "pending") }
    }
}

struct PinApprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve", abstract: "Approve a pending device (admin)")
    @Argument var device: String
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        _ = try await client.pinRequest("POST", "/v1/app/pins/\(id)/members/\(device)/approve")
        print("approved \(device)")
    }
}

struct PinDeny: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deny", abstract: "Deny a pending device (admin)")
    @Argument var device: String
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        _ = try await client.pinRequest("POST", "/v1/app/pins/\(id)/members/\(device)/deny")
        print("denied \(device)")
    }
}

struct PinDevices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices", abstract: "List devices in a network")
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        let members = try await client.pinRequest("GET", "/v1/app/pins/\(id)/members")
        emit(members, json: options.json) { renderMembers($0) }
    }
}

struct PinRenameDevice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename-device", abstract: "Rename a device (staff)")
    @Argument var device: String
    @Argument var name: String
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        _ = try await client.pinRequest(
            "PATCH", "/v1/app/pins/\(id)/members/\(device)", body: ["displayName": name])
        print("renamed \(device)")
    }
}

struct PinRemoveDevice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-device", abstract: "Remove a device from the network (admin)")
    @Argument var device: String
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        _ = try await client.pinRequest("DELETE", "/v1/app/pins/\(id)/members/\(device)")
        print("removed \(device)")
    }
}

struct PinRotateCode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rotate-code", abstract: "Rotate the network join PIN (admin)")
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        let response = try await client.pinRequest("POST", "/v1/app/pins/\(id)/rotate-code")
        emit(response, json: options.json) { value in
            "new join PIN: \(((value as? [String: Any])?["joinCode"] as? String) ?? "?")"
        }
    }
}

struct PinJoinCode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "join-code", abstract: "Show the current join PIN (admin)")
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        let response = try await client.pinRequest("GET", "/v1/app/pins/\(id)/join-code")
        emit(response, json: options.json) { value in
            "join PIN: \(((value as? [String: Any])?["joinCode"] as? String) ?? "?")"
        }
    }
}

struct PinModels: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models", abstract: "Set a device's desired model loadout (staff)")
    @Argument var device: String
    @Argument var models: [String]
    @Option var state: String = "loaded"
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        guard ["loaded", "downloaded", "none"].contains(state) else {
            throw ValidationError("--state must be loaded, downloaded, or none")
        }
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        _ = try await client.pinRequest(
            "PUT", "/v1/app/pins/\(id)/models/\(device)",
            body: ["models": models.map { ["modelId": $0, "desiredState": state] }])
        print("desired loadout set for \(device): \(models.joined(separator: ", ")) → \(state)")
    }
}

struct PinUsage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Usage totals (token counts — no credits)")
    @Option var by: String = "day"
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        let usage = try await client.pinRequest("GET", "/v1/app/pins/\(id)/usage?by=\(by)")
        emit(usage, json: options.json) { value in
            let totals = (value as? [String: Any])?["totals"] as? [[String: Any]] ?? []
            if totals.isEmpty { return "no usage recorded" }
            var out = String(
                format: "%-28@ %10@ %12@ %12@\n", by.uppercased() as NSString,
                "REQS" as NSString, "TOKENS IN" as NSString, "TOKENS OUT" as NSString)
            for row in totals {
                out += String(
                    format: "%-28@ %10d %12d %12d\n",
                    (row["key"] as? String ?? "?") as NSString,
                    row["requests"] as? Int ?? 0,
                    row["tokensIn"] as? Int ?? 0,
                    row["tokensOut"] as? Int ?? 0)
            }
            return out.trimmingCharacters(in: .newlines)
        }
    }
}

struct PinLeave: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leave", abstract: "Leave a network")
    @Option var net: String?
    @OptionGroup var options: PinOptions

    func run() async throws {
        let client = pinClient(options)
        let id = try await resolveNet(client, net)
        _ = try await client.pinRequest("POST", "/v1/app/pins/\(id)/leave")
        print("left the network")
    }
}
