# Getting Started with TealeSDK

Step-by-step guide to integrating TealeSDK into your app.

## Prerequisites

- macOS 14+ or iOS 17+
- Swift 5.9+
- A Solana wallet address for earnings attribution

## 1. Add the SPM Dependency

Add TealeSDK to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/teale-ai/teale-sdk.git", from: "1.0.0")
]
```

Then add the product to your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "TealeSDK", package: "teale-sdk")
    ]
)
```

## 2. Import TealeSDK

```swift
import TealeSDK
```

## 3. Create a TealeContributor

```swift
let contributor = TealeContributor(
    appID: "com.example.myapp",
    developerWalletID: "your-solana-wallet-address",
    options: ContributionOptions(
        ramLimit: .percent(0.5),
        schedule: .idle,
        requireWiFi: true,
        requirePluggedIn: false
    )
)
```

The `appID` identifies your app in the network. The `developerWalletID` is a Solana wallet address where earnings attribution is tracked.

## 4. Request User Consent

You must obtain explicit user consent before contributing resources. Use the built-in consent view or implement your own:

```swift
// Option A: Use the built-in SwiftUI view
ConsentPromptView(contributor: contributor)

// Option B: Programmatic consent (after showing your own UI)
contributor.grantConsent()
```

Consent is persisted across app launches. Users can revoke at any time.

## 5. Start Contributing

```swift
try await contributor.start()
```

The contributor will:
1. Connect to the Teale relay network
2. Advertise available resources
3. Serve inference requests from the network
4. Track earnings attributed to your developer wallet

## 6. Monitor State

```swift
// Observe state changes
for await state in contributor.$state.values {
    switch state {
    case .idle: print("Not started")
    case .waitingForConsent: print("Needs user consent")
    case .connecting: print("Connecting to network")
    case .contributing: print("Actively contributing")
    case .paused: print("Paused (battery/thermal/schedule)")
    case .error(let msg): print("Error: \(msg)")
    }
}

// Check earnings
print("Earned: \(contributor.earnings)")
```

## Minimal Example

```swift
import SwiftUI
import TealeSDK

@main
struct MyApp: App {
    @State private var contributor = TealeContributor(
        appID: "com.example.myapp",
        developerWalletID: "your-solana-wallet-address"
    )

    var body: some Scene {
        WindowGroup {
            VStack {
                if !contributor.hasUserConsent {
                    ConsentPromptView(contributor: contributor)
                } else {
                    TealeContributionView(contributor: contributor)
                    EarningsDashboardView(contributor: contributor)
                }
            }
            .task {
                if contributor.hasUserConsent {
                    try? await contributor.start()
                }
            }
        }
    }
}
```

## Next Steps

- [TealeContributor API](teale-contributor.md) -- Full API reference
- [Contribution Options](contribution-options.md) -- Configure resource limits
- [Consent Flow](consent-flow.md) -- Consent management details
- [Earnings Reporting](earnings-reporting.md) -- Track user and developer earnings
