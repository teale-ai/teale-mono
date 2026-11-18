import Foundation
import Network

// MARK: - Cluster Message Framer

/// NWProtocolFramer implementation for length-prefixed JSON messages.
/// Wire format: [4 bytes: UInt32 big-endian length][N bytes: JSON-encoded ClusterMessage]
public class ClusterMessageFramer: NWProtocolFramerImplementation {
    public static let label = "ClusterMessage"

    public static let definition = NWProtocolFramer.Definition(implementation: ClusterMessageFramer.self)

    /// Largest frame accepted or sent (8 MiB). A 1 MiB model-transfer chunk
    /// is ~1.4 MiB once base64-encoded in JSON; prompts are far smaller.
    public static let maxMessageLength: UInt32 = 8 * 1024 * 1024

    static func isAcceptableLength(_ length: UInt32) -> Bool {
        length <= maxMessageLength
    }

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

            // The length is peer-supplied: never buffer more than the cap
            // (a forged 4 GiB header would otherwise be held in memory).
            guard Self.isAcceptableLength(messageLength) else {
                framer.markFailed(error: .posix(.EMSGSIZE))
                return 0
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
        guard messageLength >= 0, messageLength <= Int(Self.maxMessageLength) else {
            framer.markFailed(error: .posix(.EMSGSIZE))
            return
        }
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
    /// Create parameters configured with the ClusterMessage framer.
    ///
    /// - With a cluster passcode: TLS 1.2 with a pre-shared key derived from
    ///   the passcode (HMAC-SHA256, see `ClusterSecurity.preSharedKey`). The
    ///   handshake only completes when both sides hold the same passcode, and
    ///   everything after it (Hello, heartbeats, prompts, model chunks) is
    ///   encrypted. No certificate identity is needed, which is what broke the
    ///   earlier certificate-based TLS attempt (NO_CERTIFICATE_SET).
    /// - Without a passcode: plain TCP, as before. An open cluster has no
    ///   secret to authenticate with; set a passcode to protect traffic.
    public static func clusterParameters(passcode: String? = nil) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10

        let tlsOptions = passcode
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { ClusterSecurity.pskTLSOptions(passcode: $0) }
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)

        let framerOptions = NWProtocolFramer.Options(definition: ClusterMessageFramer.definition)
        params.defaultProtocolStack.applicationProtocols.insert(framerOptions, at: 0)

        return params
    }
}
