# monetization — Delta Spec

## ADDED Requirements

### Requirement: Saving is never paywalled
Every tier, including free, SHALL have full document saving, autosave, session recovery, and document versioning. No purchase state SHALL ever cause loss of user work.

#### Scenario: Free-tier work retention
- **WHEN** a free-tier user works across multiple sessions over weeks
- **THEN** all documents SHALL persist and reopen with full fidelity at no cost

### Requirement: Tier structure
The app SHALL offer one-time (non-subscription) purchases: a **Free** tier with the full toolset and saving but gated export/bake output; a **Core** tier (target ≈ $29.99) unlocking standard export and baking; and a **Studio** tier (target ≈ $59.99) adding live-link, full bake map set, UDIMs, and advanced solver capacity. Upgrade pricing SHALL equal the difference between tiers (no upgrade penalty). Purchases SHALL be universal across iPad and Mac.

#### Scenario: Upgrade path
- **WHEN** a Core owner upgrades to Studio
- **THEN** the price SHALL be the Studio–Core difference and all Studio features SHALL unlock on both platforms

### Requirement: Offline entitlement checks
Purchase entitlements SHALL be verified via StoreKit with local receipt validation; feature gating SHALL work fully offline after purchase and SHALL fail open to the last known entitlement state on transient StoreKit errors (never mid-session lockout).

#### Scenario: Airplane-mode session
- **WHEN** a Studio owner uses the app with no connectivity
- **THEN** all purchased features SHALL remain available

### Requirement: No accounts, no telemetry
The app SHALL require no account and collect no analytics or telemetry; the App Store privacy label SHALL be "Data Not Collected".

#### Scenario: Network audit
- **WHEN** app traffic is audited during normal use with live-link disabled
- **THEN** the app SHALL make no network connections other than StoreKit.
