import SwiftUI
import SharedTypes
import Auth

// MARK: - Login View

public struct LoginView: View {
    var authManager: AuthManager

    @State private var phoneNumber = ""
    @State private var otpCode = ""
    @State private var showOTPField = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    public init(authManager: AuthManager) {
        self.authManager = authManager
    }

    public var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo & Title
            VStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue)

                Text("Teale")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Decentralized AI on Apple Silicon")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)

            // Sign in with Google
            Button {
                Task { await handleOAuth(provider: .google) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.title3)
                    Text("Sign in with Google")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: 300)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(isLoading)

            // Sign in with GitHub
            Button {
                Task { await handleOAuth(provider: .github) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.title3)
                    Text("Sign in with GitHub")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: 300)
                .frame(height: 50)
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
            .padding(.top, 6)

            // Divider
            HStack {
                Rectangle().fill(.tertiary).frame(height: 1)
                Text("or")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                Rectangle().fill(.tertiary).frame(height: 1)
            }
            .frame(maxWidth: 300)
            .padding(.vertical, 20)

            // Phone OTP
            VStack(spacing: 12) {
                if !showOTPField {
                    TextField("Phone number (+1...)", text: $phoneNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit {
                            guard !phoneNumber.isEmpty, !isLoading else { return }
                            Task { await handleSendOTP() }
                        }
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        #endif

                    Button {
                        Task { await handleSendOTP() }
                    } label: {
                        Text("Send Code")
                            .frame(maxWidth: 300)
                            .frame(height: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(phoneNumber.isEmpty || isLoading)
                } else {
                    Text("Enter the code sent to \(phoneNumber)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("6-digit code", text: $otpCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .multilineTextAlignment(.center)
                        .onSubmit {
                            guard otpCode.count >= 6, !isLoading else { return }
                            Task { await handleVerifyOTP() }
                        }
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        #endif

                    HStack(spacing: 12) {
                        Button("Back") {
                            showOTPField = false
                            otpCode = ""
                            errorMessage = nil
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await handleVerifyOTP() }
                        } label: {
                            Text("Verify")
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(otpCode.count < 6 || isLoading)
                    }
                    .frame(maxWidth: 300)
                }
            }

            // Error
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
                    .frame(maxWidth: 300)
            }

            // Loading
            if isLoading {
                ProgressView()
                    .padding(.top, 12)
            }

            Spacer()

            // Continue without account
            Button {
                authManager.continueAnonymously()
            } label: {
                Text("Continue without account")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)

            Text("Your credits stay on this device only")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    @MainActor
    private func handleOAuth(provider: Auth.Provider) async {
        isLoading = true
        errorMessage = nil
        do {
            try await authManager.signInWithOAuth(provider: provider)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func handleSendOTP() async {
        isLoading = true
        errorMessage = nil
        do {
            try await authManager.signInWithPhoneOTP(phone: phoneNumber)
            showOTPField = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func handleVerifyOTP() async {
        isLoading = true
        errorMessage = nil
        do {
            try await authManager.verifyPhoneOTP(phone: phoneNumber, code: otpCode)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
