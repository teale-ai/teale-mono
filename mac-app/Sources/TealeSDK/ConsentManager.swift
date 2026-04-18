import Foundation

// MARK: - Consent Manager

/// Manages user opt-in consent for resource contribution.
/// No SDK activity occurs until consent is granted.
public actor ConsentManager {
    private let appID: String

    private var consentKey: String { "teale_sdk_consent_\(appID)" }
    private var timestampKey: String { "teale_sdk_consent_ts_\(appID)" }

    public init(appID: String) {
        self.appID = appID
    }

    public func hasConsent() -> Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    public func grantConsent() {
        UserDefaults.standard.set(true, forKey: consentKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }

    public func revokeConsent() {
        UserDefaults.standard.set(false, forKey: consentKey)
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }

    public func consentTimestamp() -> Date? {
        let ts = UserDefaults.standard.double(forKey: timestampKey)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
