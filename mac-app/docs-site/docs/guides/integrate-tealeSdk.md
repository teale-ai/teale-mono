# TealeSDK Integration

Embed Teale's distributed compute into your own Swift app. Users contribute idle resources and earn credits, and you as the developer earn a share of the revenue.

---

## Prerequisites

- Xcode 15 or later
- Swift 5.9 or later
- macOS 14+ or iOS 17+ deployment target
- A Teale developer wallet ID (register at [teale.com/developers](https://teale.com/developers))

## Step 1: Add the dependency

Add TealeSDK to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/teale-ai/teale", from: "1.0.0"),
]
```

Then add `TealeSDK` to your target's dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "TealeSDK", package: "teale"),
    ]
),
```

## Step 2: Import and configure

```swift
import TealeSDK

let contributor = TealeContributor(
    appID: "com.myapp",
    developerWalletID: "your-wallet-id",
    options: ContributionOptions(
        ramLimit: .percent(0.5),
        schedule: .afterHours,
        requireWiFi: true,
        requirePluggedIn: true
    )
)
```

### Configuration options

| Option            | Type       | Description                                             |
|-------------------|------------|---------------------------------------------------------|
| `ramLimit`        | `RAMLimit` | Max RAM for inference. `.percent(0.5)` = 50% of available RAM |
| `schedule`        | `Schedule` | When to contribute. `.always`, `.afterHours`, `.custom(...)` |
| `requireWiFi`     | `Bool`     | Only contribute when connected to Wi-Fi                  |
| `requirePluggedIn`| `Bool`     | Only contribute when on AC power                         |

## Step 3: Request user consent

TealeSDK requires explicit user consent before contributing compute. This is a hard requirement --- the SDK will not start without it.

```swift
contributor.grantConsent()
```

Present your own consent UI explaining what Teale does, then call `grantConsent()` after the user agrees. The consent state persists across app launches.

## Step 4: Start contributing

```swift
contributor.start()
```

This begins background inference contribution. The SDK automatically:

- Downloads and manages models appropriate for the device.
- Connects to the Teale network.
- Serves inference requests when the device is idle.
- Throttles or pauses when the user's app needs resources.

## Step 5: Stop contributing

```swift
contributor.stop()
```

Call this when the user opts out or your app needs to reclaim resources.

## Step 6: Show earnings UI

TealeSDK includes pre-built SwiftUI views for displaying contribution status and earnings:

```swift
// Compact view for settings screens
TealeContributionView(contributor: contributor)

// Full dashboard with transaction history
EarningsDashboardView(contributor: contributor)
```

Both views are customizable with standard SwiftUI modifiers.

## Revenue model

When your app's users contribute compute, the earnings are split:

- **95%** goes to the user (the device owner).
- **5%** is the network fee.

Developer earnings are attributed via `sdkEarning` transactions tied to your `developerWalletID`. The revenue structure incentivizes both user participation and developer integration.

## Resource Governor

TealeSDK includes an adaptive Resource Governor that ensures contributed compute never impacts the user's experience:

- Monitors CPU, GPU, memory pressure, and thermal state.
- Automatically throttles or pauses inference when the user's app is active.
- Resumes at full capacity when the device is idle.
- Respects the `ramLimit`, `schedule`, and power/network constraints you configured.

You do not need to manage resource allocation manually.

---

## Next steps

- [Earn Credits](earn-credits.md) --- how the standalone Teale app handles earning
- [Credit Economy](../concepts/credit-economy.md) --- pricing and revenue details
- [Wallet and Payments](wallet-and-payments.md) --- transaction types including `sdkEarning`
