# Consent Flow

Managing user opt-in for resource contribution.

## Overview

TealeSDK requires explicit user consent before contributing any device resources to the network. Consent is persistent across app launches and can be revoked at any time. The SDK provides both programmatic consent management and a pre-built SwiftUI consent view.

## Requirements

1. **Consent must be granted before `start()` proceeds.** If `start()` is called without consent, the contributor moves to `waitingForConsent` state and waits.
2. **Users must be able to revoke consent at any time.** Revoking consent immediately stops all contributions and disconnects from the network.
3. **Consent persists across launches.** Once granted, the user does not need to re-consent on each launch.

## ConsentManager

The SDK's internal `ConsentManager` handles persistence. You interact with it through `TealeContributor`:

```swift
// Check current consent status
if contributor.hasUserConsent {
    print("User has consented")
}

// Grant consent (after showing your own UI or using ConsentPromptView)
contributor.grantConsent()

// Revoke consent
contributor.revokeConsent()
```

## ConsentPromptView

The SDK provides a standard SwiftUI view that explains what resource contribution means and asks for permission.

```swift
import TealeSDK

struct MyView: View {
    let contributor: TealeContributor

    var body: some View {
        if !contributor.hasUserConsent {
            ConsentPromptView(contributor: contributor)
        } else {
            Text("Contributing to the Teale network")
        }
    }
}
```

The `ConsentPromptView` displays:

- What resources will be shared (RAM, CPU/GPU compute)
- Impact on device performance and battery
- How the user can revoke consent later
- An "Allow" button that calls `grantConsent()`
- A "Not Now" button that dismisses the prompt

## Custom Consent UI

If you prefer your own consent UI, call `grantConsent()` programmatically after the user agrees:

```swift
Button("I agree to contribute resources") {
    contributor.grantConsent()
    Task {
        try await contributor.start()
    }
}
```

Ensure your custom UI clearly discloses:

1. That device resources (RAM, compute) will be used for AI inference
2. That contribution can be stopped at any time
3. That the device may use more power during contribution
4. How to access settings to revoke consent later

## Consent State Flow

```
grantConsent()                    revokeConsent()
     |                                 |
     v                                 v
[waitingForConsent] --> [connecting] --> [idle]
                            |
                            v
                     [contributing]
```

1. Before consent: state is `idle` or `waitingForConsent`
2. After `grantConsent()` + `start()`: state moves to `connecting`, then `contributing`
3. After `revokeConsent()`: state returns to `idle`, network disconnected, consent flag cleared
