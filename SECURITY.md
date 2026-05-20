# Letychka — Security review (self-audit)

This is an honest self-review of what Letychka protects, what it does
not, and the known weaknesses of the current crypto. It is written from
an attacker's point of view by the author. It is NOT a substitute for
an independent professional audit, and it should not be treated as one.

Updated: 2026-05-20

## Threat model

Letychka claims to be:

- Anonymous (no account by default, optional Sign in with Apple).
- Offline (Bluetooth LE only, no servers, no internet).
- Local (everything is on the user's phone).

Targets we try to defend against:

1. Passive Bluetooth sniffer in range reading 1-to-1 chats.
2. A stolen / lost phone read after the fact without the passcode.
3. Stray BLE advertisements faking phantom devices on the radar.
4. Replays of old frames within the same session.

Targets we explicitly do NOT defend against:

1. Active "man in the middle" between two phones during the first
   handshake. There is no identity / fingerprint verification UI yet,
   so this is TOFU (trust on first use). A capable attacker who sits
   between two specific phones at the moment they meet can substitute
   keys.
2. The Room (group chat). It is broadcast to every phone in BLE range
   by design and there is no shared secret with strangers.
3. Compromise of a user's Apple ID, device passcode, or a malicious
   profile/MDM on the device.
4. Attacks on the phone itself (root, jailbreak, malware).
5. Targeted attacks by well-funded actors (nation states). This app
   has no formal audit, no bug bounty, no incident response team.

## What is implemented

- **1-to-1 frame encryption (BLE).** X25519 ephemeral key agreement +
  HKDF-SHA256 (salt `letychka.v1`) -> 256-bit symmetric key.
  AES-256-GCM (`CryptoKit`) for every TEXT/HEAD/CHUNK/END/DEL/EDIT/
  TYPING/REACT/SEEN/ACK/CHATCL frame. Nonce is the 96-bit random
  nonce CryptoKit generates per `seal`. Plain frames are limited to
  KEYEX (the handshake itself), PROFILE (nick is broadcast anyway),
  ROOM/RREACT (group broadcast, by design).
- **At-rest encryption.** `chats.json`, `room.json`, `avatars.json`,
  and the avatar JPEG are written with `.completeFileProtection` so
  iOS encrypts them while the device is locked. A stolen phone with
  the passcode unknown cannot be read.
- **Phantom-peer filter.** A new BLE id has to be seen at least twice
  within ~6 seconds before it appears on the radar; RSSI must be
  between -100 and 0 dBm (Apple's 127 "no value" sentinel is
  rejected). Stray single-shot advertisements no longer pop blips.
- **De-dup by wireID.** A replayed TEXT or media frame from the same
  sender with the same wireID is dropped on the receiver (re-ACKed so
  the sender stops resending).
- **iOS transport-level security.** ITSAppUsesNonExemptEncryption=false
  in Info.plist is wrong in spirit (we DO use non-exempt encryption),
  but currently true because Apple exempts standard CryptoKit usage
  for messaging within the app. To be checked again before each
  submission.

## Known weaknesses (honest list)

### 1. No identity authentication on the handshake (TOFU)
KEYEX carries our raw public key with no signature. An attacker who
proxies BLE traffic between two phones during the FIRST connect can
present their own key to both sides and silently MITM. Recovery: a
side-channel fingerprint compare (e.g. show a 4-word safety code,
ask users to confirm out-of-band). Not implemented.

### 2. One ephemeral key shared across all peers per session
`myEphemeral` is created once per app launch and reused for handshakes
with every peer. Each pair still derives a unique session key
(because the OTHER side's public key differs), so cross-pair
isolation is fine. But if our process memory is compromised, every
session of this launch is decryptable. Fix: per-peer ephemeral. Will
be addressed by moving 1-to-1 to the Signal Protocol (libsignal).

### 3. Replay of non-wireID encrypted frames
DEL/EDIT/REACT/SEEN/ACK/TYPING have no replay counter. Within an
active session an attacker who captured an old encrypted frame could
re-inject it; AES-GCM accepts it as authentic and the receiver
processes it again. Impact is mostly cosmetic (re-mark as read,
re-toggle a reaction, re-attempt a no-op DEL). Fix in the next wire
break: include a monotonic counter inside the encrypted payload and
have the receiver drop frames with `counter <= last seen`.

### 4. No forward secrecy across app launches for stored messages
Sessions reset on disconnect (good), but messages already saved to
`chats.json` are at the mercy of iOS file protection. If the device
has no passcode, `.completeFileProtection` degrades to readable. We
cannot enforce a passcode. Mitigation: documentation in the privacy
text.

### 5. Group ("Room") messages are plaintext over BLE
By design. Anyone in BLE range can read. The app is honest about it
in the UI text ("This is a shared room"). Do not put secrets here.

### 6. Profile broadcast (nick + stable id)
The 8-hex stable id and the nick are sent in the BLE advertisement
local name. Anyone scanning Bluetooth in range can collect them. By
design, since they're the only handle people use to chat with you.

### 7. UserDefaults stable id
`Ident.me` lives in NSUserDefaults plaintext. Not a key, just an id,
but anyone with file-system access to a backup also gets it. Future:
move to Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).

### 8. No certificate pinning
We do not make HTTPS calls yet. When the optional Global mode lands,
the Supabase domain should be pinned to defend against rogue CAs.
Pinning complicates server cert rotation; an acceptable mitigation
is to pin to the public key (`SubjectPublicKeyInfo`) and rotate it
during planned maintenance only.

### 9. ITSAppUsesNonExemptEncryption
Set to `false` in Info.plist. This is correct as long as we only use
Apple-standard CryptoKit AES-GCM (it is exempt under EAR 5D002 and
Apple's documentation). If we add libsignal or our own crypto, this
must be revisited. The full ITSEncryptionExportComplianceCode answer
must match what we actually do.

### 10. No bug bounty / no penetration test
This is a one-person + AI build. We rely on industry-standard
libraries (CryptoKit, X25519, AES-GCM) used correctly, not on any
formal verification.

## Online mode (Global) — current state and what is missing

Global mode is now shipping as an opt-in beta. It is OFF by default;
turning it on in Settings > Network mode is what hands the app over
to the server. Bluetooth mode is unaffected and stays exactly as
described above.

What v1 of Global ships with:
- Supabase Auth: anonymous session created on first launch, optional
  Sign in with Apple (the Apple identity token is exchanged for a
  Supabase session via `signInWithIdToken`).
- TLS to Supabase (Apple App Transport Security default).
- Direct chats (1-to-1) and groups (multi-member) backed by
  Postgres tables with Row-Level Security. RLS rules require the
  caller to be a member to read or insert messages.
- Username search by prefix against the `profiles` table.

What v1 of Global does NOT yet do:
- **End-to-end encryption.** Messages are stored as plain text on
  Supabase. The Supabase operator and anyone who compromises the
  database can read message bodies. The Settings hint says so
  plainly. Bluetooth chats are still E2E encrypted, only Global is
  server-readable in v1.
- **APNs push.** No `devices` token registration yet, no Edge
  Function fan-out. New messages only appear while the app is open
  and on the chat view.
- **SPKI pinning.** We rely on the OS trust store; a malicious CA
  could MITM the Supabase domain.
- **Forward secrecy / post-compromise security.** Comes with E2EE.
- **Group keys.** Same as above — no encryption means no key
  management yet.

Plan for v2 (post-TestFlight):
- Encrypt 1-to-1 messages with the **Signal Protocol** via the
  official `libsignal` Swift bindings, or a hand-rolled Double
  Ratchet on `CryptoKit` if libsignal SPM stays broken in our setup.
- Publish prekey bundles to Supabase, fetch the recipient's bundle
  before sending the first message in a session.
- Store on the server only encrypted ciphertext + minimal metadata.
- Add SPKI pinning before public launch.
- APNs push for offline delivery; payload is generic ("New
  message") and the iOS app decrypts after waking.
- Group encryption: v2 ships **Sender Keys**, v3 looks at MLS
  (RFC 9420) if it stabilises in Swift.

## What you should NOT use Letychka for

- Trafficking in evidence that would put you in physical danger
  if read. Use Signal.
- Bank credentials, recovery codes, private keys.
- Any communication where you need to PROVE the other side is who
  they claim to be (TOFU is not enough).

If your threat is a curious neighbour or a noisy network: Letychka
is fine. If your threat is a national intelligence agency: use
Signal.

## How to report a vulnerability

Open an issue on the GitHub repo or email support@anonimniyov.xyz.
No bug bounty yet. We will respond as time allows and credit the
finder unless asked otherwise.
