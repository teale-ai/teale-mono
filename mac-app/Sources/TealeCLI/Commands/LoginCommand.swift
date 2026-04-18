import ArgumentParser
import Foundation
import AppCore
import AuthKit

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign in to Teale for remote device management"
    )

    func run() async throws {
        guard let config = SupabaseConfig.default else {
            print("Auth not configured. You can still use `teale up` without an account.")
            throw ExitCode.failure
        }

        let authManager = await MainActor.run { AuthManager(config: config) }
        await authManager.checkSession()

        let state = await MainActor.run { authManager.authState }
        if state.isAuthenticated {
            let user = await MainActor.run { authManager.currentUser }
            print("Already signed in as \(user?.displayName ?? user?.phone ?? "unknown").")
            return
        }

        // Prompt for phone number
        print("Sign in with your phone number to link this device to your account.")
        print("Phone number (e.g. +14155551234): ", terminator: "")
        guard let phone = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phone.isEmpty else {
            print("No phone number entered.")
            throw ExitCode.failure
        }

        guard phone.hasPrefix("+"), phone.count >= 10 else {
            print("Invalid phone number. Use international format: +14155551234")
            throw ExitCode.failure
        }

        // Send OTP
        do {
            try await authManager.signInWithPhoneOTP(phone: phone)
        } catch {
            print("Failed to send verification code: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Verification code sent! Check your SMS.")
        print("Code: ", terminator: "")
        guard let code = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            print("No code entered.")
            throw ExitCode.failure
        }

        // Verify OTP
        do {
            try await authManager.verifyPhoneOTP(phone: phone, code: code)
        } catch {
            print("Verification failed: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        print("Signed in! This device is now linked to your account.")
        print("You can manage your devices at teale.ai or via the Teale app.")
    }
}
