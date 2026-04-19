# Earnings Reporting

Track earnings attributed to your app's contributions.

## Overview

When a device running your app serves inference requests, the provider earns USDC. The `EarningsReporter` tracks these earnings and attributes them to the developer's wallet address. This allows developers to see how much value their app's user base is generating on the network.

## How Earnings Work

1. A user's device serves an inference request
2. The requester pays the [token-based price](../protocol/pricing-protocol.md) in USDC
3. The provider (user's device) receives 95% of the cost
4. The transaction is tagged with `sdkEarning` type and attributed to the developer's wallet

## Accessing Earnings

The `TealeContributor` exposes an `earnings` property:

```swift
let earnings = contributor.earnings

print("Total earned: \(earnings)")
```

This property is `@Observable` and updates in real time as the device serves requests.

## Transaction Attribution

Each SDK-originated inference earning creates a `USDCTransaction` with:

| Field | Value |
|-------|-------|
| `type` | `sdkEarning` |
| `amount` | USDC earned for the request |
| `modelID` | Model that served the request |
| `tokenCount` | Number of tokens generated |
| `peerNodeID` | Requester's node ID |

The `sdkEarning` type distinguishes SDK-contributed earnings from direct provider earnings, allowing the network to track developer attribution.

## Revenue Model

- **Users earn** the provider share (95% of inference cost) for compute they contribute
- **Developers get attribution** for the aggregate earnings of their app's users
- Developer attribution is tracked on-chain and can be used for revenue sharing, grants, or ecosystem incentives

The SDK does not take a cut from user earnings. Attribution is informational and can be used by the developer for their own reward programs.

## SwiftUI Integration

Use `EarningsDashboardView` to display earnings in your app:

```swift
import TealeSDK

struct MyEarningsView: View {
    let contributor: TealeContributor

    var body: some View {
        EarningsDashboardView(contributor: contributor)
    }
}
```

See [SwiftUI Integration](swiftui-integration.md) for details on all pre-built views.
