# Letychka

Anonymous, offline, local Bluetooth messenger for iOS. No internet, no servers,
no accounts. Finds people physically near you over Bluetooth LE (Core Bluetooth)
and lets you message them directly, phone to phone. Everything is ephemeral and
disappears when the app is closed. Design language matches Reboard (dark/light,
violet accent, rounded controls, minimalist).

## Honest limitations (Bluetooth LE, by nature)
- Works only between people physically near you (~10-30 m, less through walls).
- Both must have the app open; no internet means no store-and-forward.
- BLE is slow: short text only (no media/voice).
- Background delivery is unreliable (iOS throttles background BLE).
- Niche by design: useful where there is no signal and people are nearby
  (events, flights, transit, hikes), not a WhatsApp replacement.

## Build (cloud, no Mac)
Project is generated with XcodeGen (`project.yml`); the `.xcodeproj` is NOT
committed. `codemagic.yaml` runs `xcodegen generate`, dev-signs and builds an
IPA for Sideloadly.

Needs a one-time wiring (provide / set up):
1. A Git remote (new GitHub repo) for this folder.
2. A Codemagic app pointed at that repo, with the `AppStoreConnect`
   integration (same App Store Connect API key as Reboard works if it has
   access to create bundle id `recode.letychka32`).
