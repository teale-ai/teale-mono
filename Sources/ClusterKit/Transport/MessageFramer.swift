import Foundation
import Network

// MARK: - Cluster Message Framer

/// NWProtocolFramer implementation for length-prefixed JSON messages.
/// Wire format: [4 bytes: UInt32 big-endian length][N bytes: JSON-encoded ClusterMessage]
public class ClusterMessageFramer: NWProtocolFramerImplementation {
    public static let label = "ClusterMessage"

    public static let definition = NWProtocolFramer.Definition(implementation: ClusterMessageFramer.self)

    public required init(framer: NWProtocolFramer.Instance) {}

    public func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        .ready
    }

    public func stop(framer: NWProtocolFramer.Instance) -> Bool {
        true
    }

    public func wakeup(framer: NWProtocolFramer.Instance) {}

    public func cleanup(framer: NWProtocolFramer.Instance) {}

    // MARK: - Input (reading)

    public func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var tempHeader = Data()
            // Read 4-byte length prefix
            let headerParsed = framer.parseInput(minimumIncompleteLength: 4, maximumLength: 4) { buffer, isComplete in
                if let buffer = buffer, buffer.count >= 4 {
                    tempHeader = Data(buffer.prefix(4))
                    return 4
                }
                return 0
            }

            guard headerParsed, tempHeader.count == 4 else {
                return 4  // Need at least 4 bytes
            }

            let messageLength = tempHeader.withUnsafeBytes { ptr in
                ptr.load(as: UInt32.self).bigEndian
            }

            // Read message body
            let message = NWProtocolFramer.Message(definition: Self.definition)
            if !framer.deliverInputNoCopy(length: Int(messageLength), message: message, isComplete: true) {
                return 0
            }
        }
    }

    // MARK: - Output (writing)

    public func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        // Write 4-byte length prefix
        var length = UInt32(messageLength).bigEndian
        let header = Data(bytes: &length, count: 4)
        framer.writeOutput(data: header)

        // Write message body (passed by the caller)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            // Failed to write
        }
    }
}

// MARK: - NWParameters Extension

extension NWParameters {
    /// Create parameters configured with the ClusterMessage framer and TLS
    public static func clusterParameters(passcode: String? = nil, tlsManager: ClusterTLSManager? = nil) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10

        // Always use TLS — passcode is a separate auth layer verified during Hello handshake
        let tlsOptions: NWProtocolTLS.Options
        tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, _, completionHandler in
                // Accept all certs — TOFU trust managed at application layer after Hello handshake
                completionHandler(true)
            },
            DispatchQueue.global(qos: .userInitiated)
        )
        if tlsManager != nil {
            sec_protocol_options_set_min_tls_protocol_version(
                tlsOptions.securityProtocolOptions,
                .TLSv12
            )
        }

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let framerOptions = NWProtocolFramer.Options(definition: ClusterMessageFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        return params
    }
}
