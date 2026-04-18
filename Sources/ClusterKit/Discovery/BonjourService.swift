import Foundation
import Network
import OSLog
import SharedTypes

// MARK: - Bonjour Service

/// Advertises this device and discovers peers on the LAN via mDNS/Bonjour
@Observable
public final class BonjourService: @unchecked Sendable {
    public static let serviceType = "_teale._tcp"
    private static let logger = Logger(subsystem: "com.teale.app", category: "ClusterBonjour")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let localDeviceID: UUID
    private let localServiceNames: Set<String>
    private let parameters: NWParameters
    private var visiblePeerEndpoints: [String: NWEndpoint] = [:]

    public private(set) var isAdvertising: Bool = false
    public private(set) var isBrowsing: Bool = false
    public private(set) var discoveredEndpoints: [NWBrowser.Result] = []

    /// Called when a new peer endpoint is discovered
    public var onPeerDiscovered: ((NWEndpoint, [String: String]) -> Void)?
    /// Called when a peer endpoint is removed
    public var onPeerRemoved: ((NWEndpoint) -> Void)?
    /// Called when an incoming connection is received
    public var onIncomingConnection: ((NWConnection) -> Void)?

    public init(localDeviceID: UUID, parameters: NWParameters = .clusterParameters()) {
        self.localDeviceID = localDeviceID
        self.localServiceNames = Self.makeLocalServiceNames()
        self.parameters = parameters
    }

    // MARK: - Advertise

    public func startAdvertising(deviceInfo: DeviceInfo) throws {
        let listener = try NWListener(using: parameters)

        // Set Bonjour service with TXT record
        let txtRecord = NWTXTRecord.from([
            "deviceID": localDeviceID.uuidString,
            "chip": deviceInfo.hardware.chipName,
            "ram": String(Int(deviceInfo.hardware.totalRAMGB)),
            "version": "1",
        ])

        listener.service = NWListener.Service(
            type: Self.serviceType,
            txtRecord: txtRecord
        )

        listener.stateUpdateHandler = { [weak self] state in
            Self.logger.info("Listener state changed: \(String(describing: state), privacy: .public)")
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isAdvertising = true
                case .failed, .cancelled:
                    self?.isAdvertising = false
                default:
                    break
                }
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.onIncomingConnection?(connection)
        }

        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    // MARK: - Browse

    public func startBrowsing() {
        guard browser == nil else { return }

        let browserDescriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        // NWBrowser must use minimal parameters — TLS and custom framers prevent mDNS discovery.
        // Connection-level parameters (TLS, framer) are applied later when connecting to a peer.
        let browseParams = NWParameters()
        browseParams.includePeerToPeer = true
        let browser = NWBrowser(for: browserDescriptor, using: browseParams)

        browser.stateUpdateHandler = { [weak self] state in
            Self.logger.info("Browser state changed: \(String(describing: state), privacy: .public)")
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed, .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            Self.logger.info("Browse results changed: results=\(results.count) changes=\(changes.count)")
            DispatchQueue.main.async {
                self.discoveredEndpoints = Array(results)
            }

            var currentPeers: [String: (endpoint: NWEndpoint, txtDict: [String: String])] = [:]
            for result in results {
                let txtDict = self.parseTXTRecord(result)
                Self.logger.info("Result endpoint=\(String(describing: result.endpoint), privacy: .public) txt=\(String(describing: txtDict), privacy: .public)")
                let peerKey = self.peerKey(for: result.endpoint, txtDict: txtDict)

                // NWBrowser sometimes omits Bonjour TXT metadata even when the service
                // is advertising it correctly. Fall back to the local service name so
                // we do not waste scans repeatedly connecting to ourselves.
                if self.isLikelySelfEndpoint(result.endpoint, txtDict: txtDict) {
                    Self.logger.info("Skipping self endpoint=\(String(describing: result.endpoint), privacy: .public)")
                    continue
                }

                // Bonjour can report the same peer on multiple interfaces. Keep the
                // first visible endpoint per peer key and dedupe the rest.
                if currentPeers[peerKey] == nil {
                    currentPeers[peerKey] = (result.endpoint, txtDict)
                }
            }

            let removedPeerKeys = Set(self.visiblePeerEndpoints.keys).subtracting(currentPeers.keys)
            for peerKey in removedPeerKeys {
                if let endpoint = self.visiblePeerEndpoints.removeValue(forKey: peerKey) {
                    Self.logger.info("Peer removed from browse set: \(peerKey, privacy: .public) endpoint=\(String(describing: endpoint), privacy: .public)")
                    self.onPeerRemoved?(endpoint)
                }
            }

            for (peerKey, peer) in currentPeers {
                if self.visiblePeerEndpoints[peerKey] == nil {
                    Self.logger.info("Peer discovered from browse set: \(peerKey, privacy: .public) endpoint=\(String(describing: peer.endpoint), privacy: .public)")
                    self.onPeerDiscovered?(peer.endpoint, peer.txtDict)
                }
                self.visiblePeerEndpoints[peerKey] = peer.endpoint
            }
        }

        browser.start(queue: .global(qos: .userInitiated))
        self.browser = browser
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        discoveredEndpoints = []
        visiblePeerEndpoints.removeAll()
    }

    // MARK: - Stop

    public func stop() {
        listener?.cancel()
        listener = nil
        stopBrowsing()
        isAdvertising = false
    }

    // MARK: - Helpers

    private func parseTXTRecord(_ result: NWBrowser.Result) -> [String: String] {
        if case let .bonjour(txtRecord) = result.metadata {
            return txtRecord.toDictionary(knownKeys: ["deviceID", "chip", "ram", "version"])
        }
        return [:]
    }

    private static func makeLocalServiceNames() -> Set<String> {
        var names: Set<String> = []

        #if canImport(Foundation) && os(macOS)
        if let localizedName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !localizedName.isEmpty {
            names.insert(localizedName)
        }
        #endif

        let hostName = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hostName.isEmpty {
            names.insert(hostName)
            names.insert(hostName.replacingOccurrences(of: ".local", with: ""))
        }

        return names
    }

    private func isLikelySelfEndpoint(_ endpoint: NWEndpoint, txtDict: [String: String]) -> Bool {
        if let deviceIDString = txtDict["deviceID"],
           let deviceID = UUID(uuidString: deviceIDString),
           deviceID == localDeviceID {
            return true
        }

        guard let serviceName = serviceName(from: endpoint) else {
            return false
        }

        return localServiceNames.contains(serviceName)
    }

    private func serviceName(from endpoint: NWEndpoint) -> String? {
        guard case let .service(name: name, type: _, domain: _, interface: _) = endpoint else {
            return nil
        }
        return name
    }

    private func peerKey(for endpoint: NWEndpoint, txtDict: [String: String]) -> String {
        if let deviceID = txtDict["deviceID"], !deviceID.isEmpty {
            return "id:\(deviceID)"
        }
        return "endpoint:\(String(describing: endpoint))"
    }
}

// MARK: - NWTXTRecord Helpers

extension NWTXTRecord {
    static func from(_ dict: [String: String]) -> NWTXTRecord {
        var record = NWTXTRecord()
        for (key, value) in dict {
            record[key] = value
        }
        return record
    }

    func getString(key: String) -> String? {
        guard let entry = self.getEntry(for: key) else { return nil }
        if case .string(let value) = entry {
            return value
        }
        return nil
    }

    func toDictionary(knownKeys: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for key in knownKeys {
            if let value = getString(key: key) {
                result[key] = value
            }
        }
        return result
    }
}
