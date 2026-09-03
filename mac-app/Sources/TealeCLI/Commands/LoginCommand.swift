import ArgumentParser
import Foundation
import AppCore
import AuthKit

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to Teale for remote device management"
    )

    func run() async throws {
        let authManager = await MainActor.run { AuthManager() }
        await authManager.checkSession()

        let state = await MainActor.run { authManager.authState }
        if state.isAuthenticated {
            let user = await MainActor.run { authManager.currentUser }
            print("Already signed in as \(user?.displayName ?? user?.email ?? user?.phone ?? "unknown").")
            return
        }

        // Prompt for email address.
        print("Sign in with your email to link this device to your account.")
        print("Email: ", terminator: "")
        guard let email = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !email.isEmpty else {
            print("No email entered.")
            throw ExitCode.failure
        }

        guard email.contains("@"), email.contains(".") else {
            print("Invalid email address.")
            throw ExitCode.failure
        }

        // Send auth code.
        do {
            try await authManager.signInWithEmailOTP(email: email)
        } catch {
            print("Failed to send verification code: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Verification code sent. Check your email.")
        print("Code: ", terminator: "")
        guard let code = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            print("No code entered.")
            throw ExitCode.failure
        }

        // Verify auth code.
        do {
            try await authManager.verifyEmailOTP(email: email, code: code)
        } catch {
            print("Verification failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Signed in! This device is now linked to your account.")
        print("You can manage your devices at teale.ai or via the Teale app.")
    }
}
