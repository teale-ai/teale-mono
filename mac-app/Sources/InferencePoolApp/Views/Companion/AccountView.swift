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
        TealeSection(prompt: appState.companionText("account.account", fallback: "account")) {
            TealeStats {
                TealeStatRow(
                    label: appState.companionText("account.status", fallback: "Status"),
                    value: accountStatus,
                    note: statusNote
                )
            }
            if authIsConfigured {
                if !isSignedIn {
                    HStack(spacing: 10) {
                        TealeActionButton(title: appState.companionText("account.signIn", fallback: "Sign in"), primary: true) {
                            openSignIn()
                        }
                    }
                    .padding(.top, 6)
                } else {
                    HStack {
                        TealeActionButton(title: appState.companionText("account.signOut", fallback: "Sign out")) {
                            Task {
                                await authManager?.signOut()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
            Text(appState.companionText("account.linkNote", fallback: "Sign in to link this machine to a person. Device wallet earnings continue working without human sign-in."))
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
        return appState.companionText("account.notSignedIn", fallback: "Not signed in")
    }

    private var accountStatus: String {
        if isSignedIn { return appState.companionText("account.signedIn", fallback: "Signed in") }
        return authIsConfigured
            ? appState.companionText("account.notSignedIn", fallback: "Not signed in")
            : appState.companionText("account.authUnavailable", fallback: "Auth unavailable")
    }

    private var statusNote: String {
        if let authNotice, !authNotice.isEmpty {
            return authNotice
        }
        if authIsConfigured {
            return userNote
        }
        return appState.companionText("account.authUnavailableDetail", fallback: "Sign-in is unavailable in this build.")
    }

    private func openSignIn() {
        guard let authManager else {
            authNotice = appState.companionText("account.authUnavailableDetail", fallback: "Sign-in is unavailable in this build.")
            return
        }

        authNotice = nil
        appState.showSignIn = true
        LoginWindowController.shared.show(authManager: authManager, appState: appState)
    }

    // MARK: details

    private var detailsSection: some View {
        TealeSection(prompt: appState.companionText("account.details", fallback: "details")) {
            TealeStats {
                TealeStatRow(label: appState.companionText("account.userID", fallback: "User ID"), value: authManager?.currentUser?.id.uuidString ?? "-")
                TealeStatRow(label: appState.companionText("account.email", fallback: "Email"), value: authManager?.currentUser?.email ?? "-")
                TealeStatRow(label: appState.companionText("account.phone", fallback: "Phone"), value: authManager?.currentUser?.phone ?? "-")
                TealeStatRow(label: appState.companionText("account.device", fallback: "Device"), value: appState.companionDeviceName)
                TealeStatRow(label: appState.companionText("account.hardware", fallback: "Hardware"), value: appState.companionRAMLabel)
            }
        }
    }

    // MARK: devices

    private var devicesSection: some View {
        TealeSection(prompt: appState.companionText("account.devices", fallback: "devices")) {
            if !isSignedIn {
                Text(appState.companionText("account.viewDevicesSignedOut", fallback: "Sign in to view devices on this account."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else if let devices = authManager?.devices, !devices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(devices, id: \.id) { device in
                        DeviceRow(device: device)
                    }
                }
            } else {
                Text(appState.companionText("account.noDevices", fallback: "No linked devices found yet."))
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
