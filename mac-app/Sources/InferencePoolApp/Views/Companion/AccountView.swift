import SwiftUI
import AppCore
import AuthKit
import SharedTypes

struct CompanionAccountView: View {
    @Environment(AppState.self) private var appState
    @State private var authNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountSection
            detailsSection
            devicesSection
        }
    }

    private var authManager: AuthManager? { appState.authManager }
    private var authState: AuthState { authManager?.authState ?? .signedOut }
    private var isSignedIn: Bool { authState.isAuthenticated }
    private var authIsConfigured: Bool { authManager != nil }

    // MARK: account

    private var accountSection: some View {
        TealeSection(prompt: "account") {
            TealeStats {
                TealeStatRow(
                    label: "Status",
                    value: accountStatus,
                    note: statusNote
                )
            }
            if !isSignedIn {
                HStack(spacing: 10) {
                    TealeActionButton(title: "Sign in", primary: true) {
                        openSignIn()
                    }
                }
                .padding(.top, 6)
            } else {
                HStack {
                    TealeActionButton(title: "Sign out") {
                        Task {
                            await authManager?.signOut()
                        }
                    }
                }
                .padding(.top, 6)
            }
            Text("Sign in to link this machine to a person. Device wallet earnings continue working without human sign-in.")
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)
                .padding(.top, 8)
            if let authNotice, !authNotice.isEmpty {
                Text(authNotice)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.warn)
                    .padding(.top, 6)
            }
        }
    }

    private var userNote: String {
        if let user = authManager?.currentUser {
            return user.email ?? user.phone ?? user.id.uuidString
        }
        return "Not signed in"
    }

    private var accountStatus: String {
        if isSignedIn { return "Signed in" }
        return authIsConfigured ? "Not signed in" : "Auth unavailable"
    }

    private var statusNote: String {
        if let authNotice, !authNotice.isEmpty {
            return authNotice
        }
        if authIsConfigured {
            return userNote
        }
        return "Add mac-app/Supabase.plist or SUPABASE_URL and SUPABASE_ANON_KEY, then rebuild the app bundle."
    }

    private func openSignIn() {
        guard let authManager else {
            authNotice = "This build has no Supabase config, so sign-in cannot open yet."
            return
        }

        authNotice = nil
        appState.showSignIn = true
        LoginWindowController.shared.show(authManager: authManager, appState: appState)
    }

    // MARK: details

    private var detailsSection: some View {
        TealeSection(prompt: "details") {
            TealeStats {
                TealeStatRow(label: "User ID", value: authManager?.currentUser?.id.uuidString ?? "-")
                TealeStatRow(label: "Email", value: authManager?.currentUser?.email ?? "-")
                TealeStatRow(label: "Phone", value: authManager?.currentUser?.phone ?? "-")
                TealeStatRow(label: "Device", value: appState.companionDeviceName)
                TealeStatRow(label: "Hardware", value: appState.companionRAMLabel)
            }
        }
    }

    // MARK: devices

    private var devicesSection: some View {
        TealeSection(prompt: "devices") {
            if !isSignedIn {
                Text("Sign in to view devices on this account.")
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else if let devices = authManager?.devices, !devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(devices, id: \.id) { device in
                        DeviceRow(device: device)
                    }
                }
            } else {
                Text("No linked devices found yet.")
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DeviceRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text(detailLine)
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            Text(device.platform.rawValue)
                .font(TealeDesign.monoTiny)
                .foregroundStyle(TealeDesign.teale)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }

    private var detailLine: String {
        var parts: [String] = []
        if let chip = device.chipName { parts.append(chip) }
        if let ram = device.ramGB { parts.append("\(ram) GB") }
        parts.append(device.id.uuidString.prefix(8).description)
        return parts.joined(separator: " · ")
    }
}
