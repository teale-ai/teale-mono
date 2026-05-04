import ArgumentParser
import Foundation
import LocalAPI

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read or write node settings",
        subcommands: [Get.self, Set.self]
    )

    @Option(name: .long, help: "Port of the running node")
    var port: Int = 11435

    @Option(name: .long, help: "API key for authenticated access")
    var apiKey: String?
}

extension Config {
    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show settings (all or a single key)")

        @OptionGroup var parent: Config

        @Argument(help: "Setting key to read (omit for all)")
        var key: String?

        @Flag(name: .long, help: "Output as JSON")
        var json: Bool = false

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)
            let snapshot = try await client.snapshot()
            let s = snapshot.settings

            if json {
                let data = try JSONEncoder.prettyPrinting.encode(s)
                print(String(data: data, encoding: .utf8) ?? "{}")
                return
            }

            let allSettings: [(String, String)] = [
                ("cluster_enabled", String(s.clusterEnabled)),
                ("wan_enabled", String(s.wanEnabled)),
                ("wan_relay_url", s.wanRelayURL),
                ("max_storage_gb", String(format: "%.0f", s.maxStorageGB)),
                ("org_capacity_reservation", String(format: "%.2f", s.orgCapacityReservation)),
                ("cluster_passcode", s.clusterPasscodeSet ? "(set)" : "(not set)"),
                ("allow_network_access", String(s.allowNetworkAccess)),
                ("electricity_cost", String(format: "%.4f", s.electricityCostPerKWh)),
                ("electricity_currency", s.electricityCurrency),
                ("electricity_margin", String(format: "%.2f", s.electricityMarginMultiplier)),
                ("keep_awake", String(s.keepAwake)),
                ("auto_manage_models", String(s.autoManageModels)),
                ("inference_backend", s.inferenceBackend),
                ("language", s.language),
            ]

            if let key {
                guard let pair = allSettings.first(where: { $0.0 == key }) else {
                    let valid = allSettings.map(\.0).joined(separator: ", ")
                    throw CleanExit.message("Unknown setting '\(key)'. Valid keys: \(valid)")
                }
                print(pair.1)
            } else {
                for (k, v) in allSettings {
                    print("  \(k) = \(v)")
                }
            }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Update a setting")

        @OptionGroup var parent: Config

        @Argument(help: "Setting key")
        var key: String

        @Argument(help: "New value")
        var value: String

        func run() async throws {
            let client = TealeClient(port: parent.port, apiKey: parent.apiKey)

            var update = RemoteSettingsUpdate()

            switch key {
            case "cluster_enabled":
                update.clusterEnabled = parseBool(value)
            case "wan_enabled":
                update.wanEnabled = parseBool(value)
            case "wan_relay_url":
                update.wanRelayURL = value
            case "max_storage_gb":
                guard let v = Double(value) else { throw CleanExit.message("Expected a number") }
                update.maxStorageGB = v
            case "org_capacity_reservation":
                guard let v = Double(value) else { throw CleanExit.message("Expected a number (0-1)") }
                update.orgCapacityReservation = v
            case "cluster_passcode":
                update.clusterPasscode = value
            case "allow_network_access":
                update.allowNetworkAccess = parseBool(value)
            case "electricity_cost":
                guard let v = Double(value) else { throw CleanExit.message("Expected a number") }
                update.electricityCostPerKWh = v
            case "electricity_currency":
                update.electricityCurrency = value
            case "electricity_margin":
                guard let v = Double(value) else { throw CleanExit.message("Expected a number") }
                update.electricityMarginMultiplier = v
            case "keep_awake":
                update.keepAwake = parseBool(value)
            case "auto_manage_models":
                update.autoManageModels = parseBool(value)
            case "inference_backend":
                update.inferenceBackend = value
            case "rapidmlx_model_alias":
                update.rapidMLXModelAlias = value
            case "rapidmlx_manage_subprocess":
                update.rapidMLXManageSubprocess = parseBool(value)
            case "rapidmlx_binary_path":
                update.rapidMLXBinaryPath = value
            case "rapidmlx_port":
                guard let v = Int(value) else { throw CleanExit.message("Expected an integer port") }
                update.rapidMLXPort = v
            case "language":
                update.language = value
            default:
                throw CleanExit.message("Unknown setting '\(key)'")
            }

            _ = try await client.updateSettings(update)
            print("\(key) = \(value)")
        }

        private func parseBool(_ s: String) -> Bool {
            ["true", "1", "yes", "on"].contains(s.lowercased())
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinting: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
