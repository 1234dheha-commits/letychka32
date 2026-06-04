import SwiftUI
import UIKit

/// Shown when the user taps a person on the radar, BEFORE any one to one chat
/// opens. Guideline 1.2: the app must display identifiable information about the
/// person you are about to connect with, and let you accept, decline or skip the
/// connection first. Letychka is proximity based (you pick a specific visible
/// person near you), never random matchmaking, and this screen makes that clear.
struct PeerIntroView: View {
    @ObservedObject var ble: BLEMessenger
    let peer: Peer
    var onStart: () -> Void
    var onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var proximity: String {
        switch peer.rssi {
        case -56...0:        return L("Very close")
        case -76 ..< -56:    return L("Nearby")
        default:             return L("In Bluetooth range")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Theme.line(scheme))
                .frame(width: 38, height: 5).padding(.top, 10)

            Spacer(minLength: 12)

            ZStack {
                Circle().fill(Theme.accent.opacity(0.16))
                    .frame(width: 116, height: 116)
                if let d = ble.avatars[peer.id], let ui = UIImage(data: d) {
                    Image(uiImage: ui).resizable().scaledToFill()
                        .frame(width: 100, height: 100).clipShape(Circle())
                } else {
                    Text(String(peer.nick.prefix(1)).uppercased())
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 100, height: 100)
                        .background(Theme.accent, in: Circle())
                }
            }

            Text(peer.nick)
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(Theme.text(scheme))
                .padding(.top, 16)

            Text(L("ID %@", peer.id))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.muted(scheme))
                .padding(.top, 3)

            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(proximity)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.top, 10)

            Text(L("You chose this person from the radar. They are physically near you over Bluetooth. Letychka never connects you with random strangers. Start a chat only if you want to."))
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30).padding(.top, 18)

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button(action: onStart) {
                    Text(L("Start chat"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Theme.accent,
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                Button(role: .destructive) {
                    ble.block(peer.id)
                    onCancel()
                } label: {
                    Text(L("Block this person"))
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                Button(action: onCancel) {
                    Text(L("Not now"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.muted(scheme))
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .background(Theme.bg(scheme).ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}
