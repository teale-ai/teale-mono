import Foundation
import Network
import SharedTypes

// MARK: - Bonjour Service

/// Advertises this device and discovers peers on the LAN via mDNS/Bonjour
@Observable
public final class BonjourService: @unchecked Sendable {
    public static let serviceType = "_teale._tcp"

    private var listener: NWListener?
    private var browser: NWBrowser?
    private let localDeviceID: UUID
    private let parameters: NWParameters
    private var visiblePeerEndpoints: [UUID: NWEndpoint] = [:]

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
            DispatchQueue.main.async {
                self.discoveredEndpoints = Array(results)
            }

            var currentPeers: [UUID: (endpoint: NWEndpoint, txtDict: [String: String])] = [:]
            for result in results {
                let txtDict = self.parseTXTRecord(result)
                guard
                    let deviceIDString = txtDict["deviceID"],
                    let deviceID = UUID(uuidString: deviceIDString),
                    deviceID != self.localDeviceID
                else {
                    continue
                }

                // Bonjour can report the same peer on multiple interfaces. Keep the
                // first visible endpoint per deviceID and dedupe the rest.
                if currentPeers[deviceID] == nil {
                    currentPeers[deviceID] = (result.endpoint, txtDict)
                }
            }

            let removedPeerIDs = Set(self.visiblePeerEndpoints.keys).subtracting(currentPeers.keys)
            for peerID in removedPeerIDs {
                if let endpoint = self.visiblePeerEndpoints.removeValue(forKey: peerID) {
                    self.onPeerRemoved?(endpoint)
                }
            }

            for (peerID, peer) in currentPeers {
                if self.visiblePeerEndpoints[peerID] == nil {
                    self.onPeerDiscovered?(peer.endpoint, peer.txtDict)
                }
                self.visiblePeerEndpoints[peerID] = peer.endpoint
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
