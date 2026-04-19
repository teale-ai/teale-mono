# Contribution Options

Configure resource limits, scheduling, and constraints for TealeSDK contributions.

## Overview

`ContributionOptions` controls how much of the device's resources are made available and when contributions are active. All options can be changed at runtime.

## Options

```swift
let options = ContributionOptions(
    ramLimit: .percent(0.5),
    schedule: .idle,
    requireWiFi: true,
    requirePluggedIn: false,
    maxConcurrentRequests: 2,
    allowedModelFamilies: ["Llama", "Qwen"]
)
```

### `ramLimit`

Controls how much RAM can be used for model loading and inference.

| Value | Description |
|-------|-------------|
| `.percent(Double)` | Fraction of total RAM (e.g., `.percent(0.5)` = 50% of total RAM) |
| `.absoluteGB(Double)` | Fixed GB limit (e.g., `.absoluteGB(8)` = 8 GB maximum) |

Default: `.percent(0.5)`

The SDK will not load models that would exceed this limit. The 4 GB OS reservation is applied on top of this limit.

### `schedule`

Controls when the device contributes to the network.

| Value | Description |
|-------|-------------|
| `.always` | Contribute whenever the app is running |
| `.idle` | Contribute only when the device is idle (no user activity) |
| `.afterHours` | Contribute only between 10 PM and 6 AM local time |
| `.custom(TimeRange)` | Contribute during a custom time range |

Default: `.idle`

### `requireWiFi`

When `true`, contributions pause when the device is on cellular data.

Default: `true`

### `requirePluggedIn`

When `true`, contributions pause when the device is on battery power.

Default: `false`

### `maxConcurrentRequests`

Maximum number of inference requests to serve simultaneously.

Default: `2`

Higher values increase throughput but also increase memory and CPU usage. For most devices, 1-3 is appropriate.

### `allowedModelFamilies`

Restrict which model families can be loaded. An empty array means all families are allowed.

```swift
// Only serve Llama and Qwen models
allowedModelFamilies: ["Llama", "Qwen"]

// Allow all models
allowedModelFamilies: []
```

Default: `[]` (all families)

## Runtime Updates

Options can be updated after initialization:

```swift
contributor.options.ramLimit = .absoluteGB(16)
contributor.options.schedule = .always
contributor.options.requirePluggedIn = true
```

Changes take effect immediately. If the new options are more restrictive (e.g., lower RAM limit), currently loaded models that exceed the limit will be unloaded.

## Automatic Pausing

The SDK automatically pauses contributions when:

1. **Thermal throttling** -- device thermal state reaches `serious` or `critical`
2. **Low battery** -- battery drops below 20% (when `requirePluggedIn` is false)
3. **Schedule** -- outside the configured schedule window
4. **Network** -- on cellular when `requireWiFi` is true

When conditions improve, contributions resume automatically. The contributor state changes to `paused` during these periods.
