import ArgumentParser
import Foundation
import GatewayKit

struct GatewayToken: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gateway-token",
        abstract: "Print a valid device bearer token for gateway.teale.com"
    )

    @Flag(name: .long, help: "Also print the deviceID")
    var verbose: Bool = false

    func run() async throws {
        let auth = GatewayAuthClient()
        if verbose {
            print("deviceID: \(await auth.deviceID)")
        }
        do {
            let token = try await auth.exchange()
            print(token)
        } catch {
            var err = "error: \(error)\n"
            FileHandle.standardError.write(Data(err.utf8))
            throw ExitCode.failure
        }
    }
}
