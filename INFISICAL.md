# INFISICAL.md — CodeCaps

Infisical is the sole source of truth for CodeCaps' app-level settings: secrets, environment config, and tunable settings knobs.  Per-user settings stay in the app's own store and never go in Infisical.  This file is the contract; `AGENTS.md` points here and every future change to settings follows it.

## Project

- Infisical project: **CodeCaps** (`cd278860-c3bc-466f-9256-22385e64551b`), environments `dev` / `staging` / `prod`.
- Release builds read `prod`; `.dev` builds read `dev` (`InfisicalSettings.defaultEnvironment`, mirroring how `TokenStore` scopes Keychain items per build).
- REST surface used: universal-auth login → `GET /api/v3/secrets/raw` (bulk list) → `PATCH` / `POST /api/v3/secrets/raw/{name}` (write-through; the `/raw/` write path accepts a plaintext `secretValue`, validated against the live API — the non-raw path demands client-side E2EE fields).  Implemented with zero new dependencies in `Sources/QuotaCore/InfisicalSettings.swift` (`URLSession` only).

## Key Inventory

| Key | Env | Sensitivity | Default | Notes |
|---|---|---|---|---|
| `PULL_ENDPOINT` | dev/prod | Non-sensitive (service URL) | `https://usage.jays.services/api/quota-windows` (dev seeded) | Service URL the Mac app pulls other machines' quota windows from.  Migrated from the `endpoint` UserDefaults key. |
| `PUSH_ENDPOINT` | dev/prod | Non-sensitive (service URL) | Empty — to be filled by the admin | Service URL the Mac app pushes this Mac's quota windows to.  Migrated from the `syncEndpoint` UserDefaults key. |
| `SETTINGS_REFRESH_SECONDS` | dev/prod | Non-sensitive (knob) | `300` (dev seeded) | Background refresh cadence for this cache, tunable via Infisical itself.  Clamped to a 60-second floor so a typo cannot hot-loop the timer. |

Non-sensitive defaults above are seeded in the `dev` environment only.  `prod` values are set by the admin and never invented.  Secret keys are documented as "to be filled by admin" and left empty — no secret value is ever invented, guessed, or copied into the project.

## What Lives Here Versus What Does Not

**In Infisical (app-level):** the two fleet endpoint URLs and the refresh cadence above.  Future app-level knobs (thresholds, intervals, feature flags) go here too.

**Explicitly out — per-user settings stay in the app's own store:**
- Every display preference (`displayMode`, `menuBarStyle`, mark styles, `appearance`, `glanceView`, platform order, source ranking, disabled sources, high contrast) → `UserDefaults`.
- Reset alarms (sound, cadence, message), anomaly multipliers, burn-rate alert toggles → `UserDefaults`.
- The Read Token and Ingest Token → the Keychain (`TokenStore`), never Infisical.  They are the owner's per-server credentials; the Keychain is their correct home and Infisical only ever sees service URLs.
- The Infisical client identity itself (universal-auth client ID + secret) → the Keychain (`InfisicalIdentityStore`), provisioned once by the owner under Settings → Infisical Sync.  A shipped app cannot embed a client secret, so there is no fallback identity.

**Explicitly out — build-time constants:** `SUFeedURL` / `SUPublicEDKey` (Sparkle, baked into the signed bundle — do not move these), provider API endpoints (`api.anthropic.com`, etc.), bundle identifiers, local credential file paths.

**iOS companion:** the companion cannot safely hold a client secret, so it never talks to Infisical.  The Mac app owns the Infisical read; the companion keeps reading quota data through its existing API (`https://usage.jays.services/api/quota-windows` with its read token).  No companion code changed for this rollout.

## The Runtime Contract

1. **Load at startup.**  `AppDelegate.startInfisicalSync` runs on a background task at launch when an identity is provisioned: configure → `refresh()` → adopt endpoints.  A failure never blocks launch or the main thread; the app keeps its local values.
2. **Never fetch per-request.**  All runtime reads go through `InfisicalSettings.value(for:)`, a synchronous memory-only read.  The only network calls are the startup load, the refresh timer, `applicationDidBecomeActive`, and explicit admin Save actions.
3. **Background refresh.**  A one-shot timer rescheduled after every fire (so a cadence change in Infisical takes effect next cycle), plus a refresh on `applicationDidBecomeActive`.  A failed refresh is recorded on `lastError` (visible under Settings → Infisical Sync) and the last-known-good cache keeps serving — staleness is safer than an outage.
4. **Write-through on admin save.**  Saving the pull/push endpoint in Settings, or any managed key under Settings → Infisical Sync, writes to Infisical FIRST via `InfisicalSettings.set` and only then updates the local cache.  A failed Infisical write throws and the save is rejected with the error shown inline — the cache and Infisical never diverge silently.
5. **Adoption, not clobbering.**  After a load/refresh, `MonitorModel.adoptInfisicalEndpointsIfUnset` fills in an endpoint only when the owner never set one locally (key absent).  A deliberately cleared field (stored as `""`) is never overridden.

## Admin Gating

CodeCaps is a single-user local app: the owner is the only user and therefore the admin.  The gate is a deliberate no-op, documented here rather than implemented as a parallel auth system.  The settings surfaces (Settings → Sources & Fleet, Settings → Infisical Sync) are reachable only on his own Mac.

## Provisioning

1. In Infisical, create a machine identity with read/write on the CodeCaps project (dev for `.dev` builds, prod for release) and copy its client ID and secret.
2. Open Settings → Infisical Sync, paste both, press Save Identity.  The app verifies the identity against Infisical immediately and reports success or the exact failure.
3. Set `PULL_ENDPOINT` / `PUSH_ENDPOINT` / `SETTINGS_REFRESH_SECONDS` under Managed Keys (or directly in Infisical); the app picks them up on the next refresh.

## Rotating A Value

Edit the key in Infisical (dashboard or API) — the app picks it up within one refresh interval, or press Reload Now under Settings → Infisical Sync.  To rotate the client identity itself: save the new identity under Settings → Infisical Sync (old Keychain items are overwritten), then revoke the old identity in Infisical.  Tokens in the Keychain rotate through the existing Re-Authorize / Forget flows and are unaffected by this file.

## Hard Rules

- No secret values in code, logs, PR bodies, or chat — names and metadata only.
- No per-request Infisical fetches anywhere in the refresh, render, or event paths.
- No per-user settings migrated into Infisical, ever.
- The local user is the admin; there is no separate admin role to invent.
