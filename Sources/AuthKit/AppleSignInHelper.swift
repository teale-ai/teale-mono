import AuthenticationServices
import CryptoKit
import Foundation

// MARK: - Apple Sign In Helper

/// Handles the Sign in with Apple flow and returns credentials for Supabase auth.
public final class AppleSignInHelper: NSObject, ASAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<AppleSignInResult, Error>?
    private var currentNonce: String?

    public struct AppleSignInResult: Sendable {
        public let idToken: String
        public let nonce: String
        public let fullName: PersonNameComponents?
        public let email: String?
    }

    /// Perform the Sign in with Apple flow.
    @MainActor
    public func signIn() async throws -> AppleSignInResult {
        let nonce = Self.randomNonce()
        currentNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self

        #if os(macOS)
        if let window = NSApp.windows.first(where: { $0.isKeyWindow }) ?? NSApp.windows.first {
            let presentationProvider = WindowPresentationContextProvider(window: window)
            controller.presentationContextProvider = presentationProvider
        }
        #endif

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8),
              let nonce = currentNonce else {
            continuation?.resume(throwing: AppleSignInError.missingCredentials)
            continuation = nil
            return
        }

        let result = AppleSignInResult(
            idToken: idToken,
            nonce: nonce,
            fullName: credential.fullName,
            email: credential.email
        )
        continuation?.resume(returning: result)
        continuation = nil
    }

    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - Nonce Generation

    static func randomNonce(length: Int = 32) -> String {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var random = SystemRandomNumberGenerator()
        for _ in 0..<length {
            let index = Int(random.next(upperBound: UInt64(charset.count)))
            result.append(charset[index])
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

public enum AppleSignInError: LocalizedError {
    case missingCredentials

    public var errorDescription: String? {
        switch self {
        case .missingCredentials: return "Could not get Apple ID credentials"
        }
    }
}

// MARK: - macOS Presentation Context

#if os(macOS)
import AppKit

private final class WindowPresentationContextProvider: NSObject, ASAuthorizationControllerPresentationContextProviding {
    let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        window
    }
}
#endif
