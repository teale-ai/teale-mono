# SwiftUI Integration

Pre-built views for consent, earnings, and contribution settings.

## Overview

TealeSDK includes ready-to-use SwiftUI views that handle the common UI patterns for resource contribution. All views use `@Observable` for reactive updates and follow platform design conventions.

## ConsentPromptView

Asks the user for permission to contribute resources. Displays a clear explanation of what will be shared and the impact on device performance.

```swift
ConsentPromptView(contributor: contributor)
```

**Displays:**
- Resource usage summary (RAM, compute)
- Battery and performance impact disclosure
- "Allow" button (calls `grantConsent()`)
- "Not Now" dismissal

**When to show:** When `contributor.hasUserConsent` is `false`.

```swift
struct ContentView: View {
    let contributor: TealeContributor

    var body: some View {
        if !contributor.hasUserConsent {
            ConsentPromptView(contributor: contributor)
        } else {
            MainAppView()
        }
    }
}
```

## EarningsDashboardView

Displays real-time earnings information.

```swift
EarningsDashboardView(contributor: contributor)
```

**Displays:**
- Current session earnings
- Total accumulated earnings
- Earnings rate (USDC per hour)
- Recent transactions list

The view updates in real time as the device serves inference requests.

## TealeContributionView

Settings interface for managing contribution options.

```swift
TealeContributionView(contributor: contributor)
```

**Displays:**
- On/off toggle for contributions
- RAM limit slider
- Schedule picker (always, idle, after hours, custom)
- Wi-Fi requirement toggle
- Plugged-in requirement toggle
- Model family filter
- Current contribution status

Changes are applied immediately to the contributor's options.

## Combining Views

A typical integration uses all three views:

```swift
import SwiftUI
import TealeSDK

struct TealeSettingsTab: View {
    let contributor: TealeContributor

    var body: some View {
        NavigationStack {
            List {
                Section("Contribution") {
                    TealeContributionView(contributor: contributor)
                }

                Section("Earnings") {
                    EarningsDashboardView(contributor: contributor)
                }
            }
            .navigationTitle("Teale Network")
        }
    }
}
```

## Reactive Updates

All views observe the `TealeContributor` instance using Swift's `@Observable` macro. State changes, earnings updates, and option modifications are reflected immediately in the UI without manual refresh.

```swift
// Views automatically update when these change:
contributor.state          // ContributorState
contributor.isContributing // Bool
contributor.hasUserConsent // Bool
contributor.earnings       // EarningsReport
```
