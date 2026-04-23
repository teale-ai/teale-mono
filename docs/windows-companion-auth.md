# Windows Companion Auth Notes

## Recommendation

Split the problem in two:

1. Keep showing wallet and earnings at the device level with Teale's existing
   device-bound gateway auth.
2. Add Supabase only for human identity: claiming a device, linking multiple
   devices to one person, and unlocking account-level wallet/history views.

That matches the current codebase better than trying to route the wallet
through Supabase first:

- the gateway already issues device bearer tokens from
  `/v1/auth/device/challenge` and `/v1/auth/device/exchange`
- the gateway wallet endpoints are already keyed off that device bearer
- the Windows companion can sync a real machine wallet without waiting for a
  human account system

So:

- immediate wallet visibility does not require Supabase
- Supabase becomes the human sign-in and account-linking layer

## GitHub With Supabase

Supabase's GitHub flow is a straightforward fit for the Windows companion.

What the official docs require:

- create a GitHub OAuth App
- add the GitHub client ID and secret to Supabase Auth
- use the Supabase callback URL:
  `https://<project-ref>.supabase.co/auth/v1/callback`
- local CLI testing uses:
  `http://localhost:54321/auth/v1/callback`
- client entry point:
  `supabase.auth.signInWithOAuth({ provider: 'github' })`

Common failure modes to look for on Windows:

- If the browser lands on `github.com/login/oauth/authorize?...client_id=Teale+App...`,
  the GitHub provider in Supabase is misconfigured. `client_id` must be the
  actual GitHub OAuth Client ID, not the human app name.
- If Google returns `401: invalid_client`, the Supabase Google provider is
  still pointing at the wrong Google OAuth client or secret. The Google client
  must be a Web application, and its Authorized redirect URIs must include
  `https://<project-ref>.supabase.co/auth/v1/callback`.
- `teale://auth/callback` must be present in Supabase Auth → URL Configuration
  as an allowed redirect URL for the companion deep link.

For callback handling, Supabase documents a redirect-based OAuth flow and, for
PKCE/server-side handling, a follow-up code exchange at the callback route.

Recommended Windows implementation:

- use the system browser, not the embedded WebView, for the GitHub OAuth step
- send Supabase back to either:
  - a custom Teale URI deep link, or
  - a loopback callback on `127.0.0.1`
- after Supabase login succeeds, exchange the Supabase session with a Teale
  gateway endpoint that binds the human account to one or more device IDs

Why browser-based:

- it matches the OAuth flow Supabase documents
- it avoids auth state getting trapped in the embedded companion WebView
- it keeps GitHub auth closer to normal desktop OAuth behavior

## Phone / SMS With Supabase

Supabase can also support phone-based sign-in, but it should come after GitHub.

The official docs show:

- enable phone auth on the hosted project's Auth Providers page
- supported SMS providers include:
  - MessageBird
  - Twilio
  - Vonage
  - TextLocal (community-supported)
- passwordless phone flow uses:
  `supabase.auth.signInWithOtp({ phone })`
- OTP verification uses:
  `supabase.auth.verifyOtp({ phone, token, type: 'sms' })`

The docs also warn that using a phone number as the main long-term identifier is
usually discouraged because phone numbers get recycled. Supabase recommends MFA
if phone is being used as an auth identifier.

Recommended Teale stance:

- GitHub first
- phone OTP second
- if phone ships, enable abuse controls from day one:
  - CAPTCHA / bot detection
  - Supabase rate limits
  - SMS spend limits
- if we care about later WhatsApp support, Twilio is the most useful default
  because Supabase's phone MFA docs explicitly note SMS/WhatsApp delivery on
  that shared phone messaging configuration

## Suggested Product Shape

Phase 1:

- keep the Windows companion wallet device-first
- sync the machine wallet directly from the gateway using Teale device auth
- add GitHub sign-in with Supabase for claiming/linking devices

Phase 2:

- add account-level wallet/history views across devices
- add phone OTP after GitHub if we still want lower-friction sign-in

## What Supabase Should Not Replace

Supabase should not replace Teale's device auth.

Teale still needs its own machine identity because:

- the relay already trusts Ed25519 device identity
- wallet earnings accrue to devices
- the gateway auth layer already resolves machine-bound bearer tokens

Supabase is the user identity layer above that, not the machine identity layer
below it.
