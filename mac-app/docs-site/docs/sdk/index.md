# TealeSDK

Let third-party apps contribute idle device resources to the Teale network.

## Overview

TealeSDK allows any app to participate in the Teale inference network. When users opt in, their device contributes idle compute resources to serve AI inference requests. Users earn USDC for their contributions, and developers get attribution for the resources their app's users provide.

The SDK handles:

- **User consent** -- persistent opt-in/opt-out with a standard consent UI
- **Resource management** -- RAM limits, scheduling, battery awareness
- **Network participation** -- relay connection, peer discovery, inference serving
- **Earnings tracking** -- per-developer attribution and real-time earnings reporting

## Design Principles

1. **User consent is mandatory.** The SDK will not contribute resources until the user explicitly grants consent via `grantConsent()`. Users can revoke consent at any time.
2. **Respect device resources.** Configurable RAM limits, Wi-Fi requirements, power requirements, and scheduling ensure the host app's performance is never degraded.
3. **Battery-aware.** Contribution automatically pauses on low battery, high thermal state, or when the device is on cellular.

## Quick Start

```swift
import TealeSDK

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

// Must get user consent before starting
contributor.grantConsent()
try await contributor.start()
```

## Pages

- [Getting Started](getting-started.md) -- Step-by-step integration guide
- [TealeContributor](teale-contributor.md) -- Main API reference
- [Contribution Options](contribution-options.md) -- Resource limits and scheduling
- [Consent Flow](consent-flow.md) -- User consent management
- [Earnings Reporting](earnings-reporting.md) -- Revenue tracking and attribution
- [SwiftUI Integration](swiftui-integration.md) -- Pre-built views for consent, earnings, and settings
