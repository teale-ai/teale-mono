import SwiftUI
import SharedTypes

// MARK: - Login View

public struct LoginView: View {
    var authManager: AuthManager

    @State private var email = ""
    @State private var authCode = ""
    @State private var showCodeField = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

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

            // Email code
            VStack(spacing: 12) {
                if !showCodeField {
                    TextField("Email address", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit {
                            guard isValidEmail, !isLoading else { return }
                            Task { await handleSendCode() }
                        }
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    Button {
                        Task { await handleSendCode() }
                    } label: {
                        Text("Send Code")
                            .frame(maxWidth: 300)
                            .frame(height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidEmail || isLoading)
                } else {
                    Text("Enter the code sent to \(email)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("6-digit code", text: $authCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .multilineTextAlignment(.center)
                        .onSubmit {
                            guard authCode.count >= 6, !isLoading else { return }
                            Task { await handleVerifyCode() }
                        }
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        #endif

                    HStack(spacing: 12) {
                        Button("Back") {
                            showCodeField = false
                            authCode = ""
                            errorMessage = nil
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await handleVerifyCode() }
                        } label: {
                            Text("Verify")
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authCode.count < 6 || isLoading)
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

            if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isValidEmail: Bool {
        let normalized = normalizedEmail
        return normalized.contains("@") && normalized.contains(".")
    }

    @MainActor
    private func handleSendCode() async {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        do {
            email = normalizedEmail
            try await authManager.signInWithEmailOTP(email: email)
            showCodeField = true
            statusMessage = "Code request accepted. If no email arrives, check spam and try again."
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func handleVerifyCode() async {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        do {
            try await authManager.verifyEmailOTP(email: email, code: authCode)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
