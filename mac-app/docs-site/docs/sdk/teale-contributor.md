# TealeContributor

The main entry point for TealeSDK integration.

## Overview

`TealeContributor` manages the lifecycle of contributing device resources to the Teale network. It handles relay connection, inference serving, consent management, and earnings tracking.

## Initialization

```swift
let contributor = TealeContributor(
    appID: String,
    developerWalletID: String,
    options: ContributionOptions = .default
)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `appID` | `String` | Bundle identifier or unique app ID for attribution |
| `developerWalletID` | `String` | Solana wallet address for earnings attribution |
| `options` | `ContributionOptions` | Resource limits and scheduling (see [Contribution Options](contribution-options.md)) |

## States

`TealeContributor` exposes a `state` property that reflects its current lifecycle stage.

| State | Description |
|-------|-------------|
| `idle` | Not started. Call `start()` to begin. |
| `waitingForConsent` | `start()` was called but user consent has not been granted. |
| `connecting` | Connecting to the Teale relay network. |
| `contributing` | Actively serving inference requests. |
| `paused` | Temporarily paused due to battery, thermal state, schedule, or network conditions. |
| `error(String)` | An error occurred. The message describes the issue. |

## Methods

### `grantConsent()`

Record that the user has consented to contribute resources. This is persisted across app launches.

```swift
contributor.grantConsent()
```

Must be called before `start()` will proceed. If `start()` is called without consent, the state moves to `waitingForConsent`.

### `revokeConsent()`

Revoke the user's consent and stop contributing immediately.

```swift
contributor.revokeConsent()
```

This stops the contributor, disconnects from the network, and clears the persisted consent flag.

### `start()`

Begin contributing to the network. Requires prior consent.

```swift
try await contributor.start()
```

If consent has been granted, this connects to the relay, advertises capabilities, and begins serving inference requests according to the configured options.

If consent has not been granted, the state moves to `waitingForConsent` and the contributor waits for `grantConsent()` to be called.

### `stop()`

Stop contributing and disconnect from the network. Does not revoke consent.

```swift
await contributor.stop()
```

The contributor can be restarted with `start()` without re-requesting consent.

## Observable Properties

All properties use `@Observable` for reactive SwiftUI integration.

| Property | Type | Description |
|----------|------|-------------|
| `state` | `ContributorState` | Current lifecycle state |
| `isContributing` | `Bool` | Whether actively serving requests (`state == .contributing`) |
| `hasUserConsent` | `Bool` | Whether user consent has been granted |
| `earnings` | `EarningsReport` | Accumulated earnings for this session (see [Earnings Reporting](earnings-reporting.md)) |

## Example

```swift
import TealeSDK

let contributor = TealeContributor(
    appID: "com.example.myapp",
    developerWalletID: "wallet-address",
    options: ContributionOptions(
        ramLimit: .absoluteGB(8),
        schedule: .afterHours,
        requireWiFi: true,
        requirePluggedIn: true
    )
)

// Show consent UI, then:
contributor.grantConsent()

// Start in a task
Task {
    try await contributor.start()

    // Monitor
    while contributor.isContributing {
        print("Earnings: \(contributor.earnings)")
        try await Task.sleep(for: .seconds(60))
    }
}
```
