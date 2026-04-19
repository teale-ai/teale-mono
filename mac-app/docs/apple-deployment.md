# Apple Deployment

End-to-end guide for releasing Teale on Apple devices.

- **macOS** (`Teale.app`) — Developer ID signed + Apple-notarized, distributed as a direct `.zip` download via GitHub Releases. No App Store.
- **iOS** (`TealeCompanion`) — TestFlight for beta testers. Public App Store deferred.

Both paths work locally from your Mac and from GitHub Actions CI.

## One-time Apple Developer portal setup

All actions at <https://developer.apple.com/account>.

### 1. Certificates

Certificates, Identifiers & Profiles → Certificates → `+`:

| Certificate | Purpose |
|---|---|
| **Developer ID Application** | Sign `Teale.app` for direct distribution. |
| **Apple Distribution** | Sign `TealeCompanion` for TestFlight/App Store. |
| **Apple Development** | Run `TealeCompanion` on your own iPhone during dev. |

Download each `.cer` → double-click to import into the login Keychain.

Export each as `.p12` (right-click in Keychain → Export) for CI use. Set a strong export password; you'll paste it into GitHub Secrets.

### 2. Identifiers (App IDs)

- `com.teale.app` — macOS. Capabilities: App Sandbox **off**. Enable **Multicast Networking** (restricted — see entitlement note below).
- `com.teale.companion` — iOS. Default capabilities.

### 3. Multicast entitlement request

`com.apple.developer.networking.multicast` is a restricted entitlement. File a request **immediately** — approval takes several days:

<https://developer.apple.com/contact/request/networking-multicast>

Until granted, signed builds will launch but LAN peer discovery will fail at runtime. Ad-hoc local builds (`SIGNING_IDENTITY=-`) skip the entitlement entirely, so local dev is unaffected.

### 4. Devices

Devices → `+` — register your iPhone UDID (get it from Xcode → Window → Devices and Simulators, or Finder when the phone is connected).

### 5. Provisioning profiles

Profiles → `+`:

- **macOS → Developer ID** for `com.teale.app`.
- **iOS → App Store** for `com.teale.companion` (TestFlight uses the App Store profile).
- **iOS → Development** for `com.teale.companion` including your iPhone.

Download each, double-click to install.

### 6. App Store Connect

<https://appstoreconnect.apple.com>

- **Users and Access → Integrations → App Store Connect API** → generate a key with **Developer** role. Download the `.p8` **once** (Apple will not let you redownload). Note the **Key ID** and **Issuer ID**.
- **My Apps → `+` New App** — platform iOS, bundle ID `com.teale.companion`. Creates the TestFlight-capable app record.

## Local workflow

### macOS: build + sign + notarize

One-time per machine:

```bash
# Copy template and fill in SIGNING_IDENTITY, NOTARY_PROFILE, TEAM_ID, etc.
cp .env.signing.example .env.signing
$EDITOR .env.signing

# Confirm your identity is visible in the login keychain:
security find-identity -v -p codesigning

# Store App Store Connect API creds for notarytool (keychain-backed, no plaintext on disk):
xcrun notarytool store-credentials "teale-notary" \
  --key ~/Downloads/AuthKey_XXXXXX.p8 \
  --key-id XXXXXX \
  --issuer 69a6de70-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Then every release:

```bash
./scripts/sign-macos.sh
```

Produces a notarized, stapled `.build/Teale.app` and matching `.build/Teale.zip`. Verify with:

```bash
spctl -a -vvv --type execute .build/Teale.app
# → source=Notarized Developer ID
```

### iOS: upload to TestFlight

Place the `.p8` key somewhere altool searches (e.g. `~/.appstoreconnect/private_keys/AuthKey_XXXXXX.p8`), then:

```bash
./scripts/upload-testflight.sh
```

Within ~10 min the build appears in App Store Connect → TestFlight. Install on your iPhone via the TestFlight app.

If `xcodebuild archive` fails to resolve signing against `Package.swift` alone, the fallback is committing a thin `TealeCompanion.xcodeproj` alongside the Package. Try the SPM path first.

## CI workflow

### GitHub Secrets

Add under Settings → Secrets and variables → Actions:

**Shared**
- `KEYCHAIN_PASSWORD` — any random string; scoped to the ephemeral CI keychain.
- `APPLE_TEAM_ID` — 10-char team ID.

**macOS release** (`.github/workflows/release.yml`)
- `DEVELOPER_ID_P12_BASE64` — `base64 -i DeveloperID.p12` output.
- `DEVELOPER_ID_P12_PASSWORD` — the export password you set.
- `DEVELOPER_ID_IDENTITY` — e.g. `Developer ID Application: Taylor Hou (TEAMID1234)`.
- `APPLE_ID` — your Apple ID email.
- `APPLE_APP_PASSWORD` — app-specific password from <https://appleid.apple.com> (**not** your login password).

**iOS TestFlight** (`.github/workflows/testflight.yml`)
- `IOS_DISTRIBUTION_P12_BASE64`, `IOS_DISTRIBUTION_P12_PASSWORD` — Apple Distribution cert.
- `IOS_APPSTORE_PROFILE_BASE64` — `base64 -i teale-companion.mobileprovision`.
- `APPSTORE_API_KEY_ID`, `APPSTORE_API_ISSUER_ID` — from App Store Connect API key.
- `APPSTORE_API_KEY_P8` — the full contents of the `.p8` file.

### Triggering a release

**macOS** — push a `v*` tag:

```bash
git tag v2026.04.17.0001
git push origin v2026.04.17.0001
```

The `Release` workflow runs: imports cert → signs bundle → notarizes → staples → publishes to GitHub Releases.

**iOS TestFlight** — either push an `ios-v*` tag or manually dispatch `TestFlight` from the Actions tab.

## File map

| Path | Role |
|---|---|
| `bundle.sh` | Build + sign (already parameterized via `SIGNING_IDENTITY`). |
| `scripts/sign-macos.sh` | Local wrapper: bundle → notarize → staple → zip. |
| `scripts/upload-testflight.sh` | Local: archive → export → upload IPA. |
| `scripts/ExportOptions.plist` | Template; `__TEAM_ID__` is substituted at runtime. |
| `.env.signing.example` | Copy to `.env.signing`; gitignored. |
| `.github/workflows/release.yml` | macOS CI: signed + notarized release. |
| `.github/workflows/testflight.yml` | iOS CI: TestFlight upload. |
| `Sources/InferencePoolApp/InferencePool.entitlements` | App Sandbox off, network, multicast. |
| `Sources/TealeCompanion/Info.plist` | `ITSAppUsesNonExemptEncryption=false` to skip the export-compliance prompt. |

## Troubleshooting

- **`spctl` says "rejected"**: the bundle wasn't notarized, or the ticket wasn't stapled. Re-run `scripts/sign-macos.sh` end to end.
- **`notarytool submit` returns "Invalid"**: run `xcrun notarytool log <submission-id> --keychain-profile teale-notary` to see which binary failed. Usually hardened runtime or missing timestamp — `codesign -f -s "$SIGNING_IDENTITY" --timestamp --options runtime` on the offender.
- **Multicast discovery broken in signed release**: the entitlement hasn't been approved yet. See request link above.
- **TestFlight upload succeeds but build never appears**: check the encryption compliance key is present in `Info.plist` (`ITSAppUsesNonExemptEncryption = false`) and that the build number incremented.
