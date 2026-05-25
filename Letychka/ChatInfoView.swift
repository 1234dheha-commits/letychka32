import SwiftUI

/// Per-chat security info. Shows the Signal-style safety code derived
/// from BOTH parties' persistent identity public keys. If both phones
/// see the same 4-4-4 hex code, they have a genuine end-to-end
/// channel; if not, someone is in the middle.
struct ChatInfoView: View {
    @ObservedObject var ble: BLEMessenger
    @Environment(\.colorScheme) private var scheme
    let peer: Peer

    private var verified: Bool {
        ble.peerVerified[peer.id] ?? false
    }

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            Form {
                Section(L("Safety code")) {
                    if let theirID = ble.peerIdentity[peer.id] {
                        HStack(spacing: 6) {
                            Image(systemName: verified
                                  ? "checkmark.seal.fill"
                                  : "exclamationmark.triangle.fill")
                                .foregroundStyle(verified
                                                 ? Theme.accent : .yellow)
                            Text(verified
                                 ? L("Verified handshake")
                                 : L("Unverified handshake (old build?)"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(verified
                                                 ? Theme.accent : .yellow)
                        }
                        Text(Crypto.safetyCode(
                            myID: Crypto.identityPub,
                            theirID: theirID))
                            .font(.system(size: 22, weight: .heavy,
                                          design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                            .textSelection(.enabled)
                        Text(L("Compare this code out loud or over a different channel. If the other person sees the same 12 characters, your chat has no man in the middle. A different code means someone might be relaying the conversation."))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted(scheme))
                    } else {
                        Text(L("Waiting for the other phone to share its identity key… reopen the chat once you see them on the radar."))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
                Section(L("How it works")) {
                    bullet(L("Every message is end-to-end encrypted with AES-256-GCM. Keys are derived per BLE connection from a fresh X25519 handshake."))
                    bullet(L("A monotonic counter inside every encrypted frame stops captured messages from being replayed at you."))
                    bullet(L("Your identity key is a persistent X25519 keypair stored in the iOS Keychain on this phone only. It never leaves the device."))
                    bullet(L("Group room messages are broadcast in plaintext over Bluetooth - by design, everyone nearby has to be able to read them."))
                }
            }
        }
        .navigationTitle(L("Chat info"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text(scheme))
        }
    }
}
