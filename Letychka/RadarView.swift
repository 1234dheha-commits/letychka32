import SwiftUI

/// Sonar radar: you sit in the center, people nearby are glowing blips.
/// Angle is stable per id, distance comes from signal strength (stronger
/// signal = closer to the center). A soft accent-coloured sweep rotates
/// behind everything and a ping pulses outward.
struct RadarView: View {
    @ObservedObject var ble: BLEMessenger
    @Environment(\.colorScheme) private var scheme
    var onTapPeer: (Peer) -> Void

    @State private var sweep = 0.0
    @State private var pulse = false
    @State private var breathe = false

    // 0 = far, 1 = near. Kept inside 0.20...0.84 of the half so a blip and
    // its name label never reach the edge and get clipped.
    private func radius(for rssi: Int) -> CGFloat {
        let clamped = max(-95, min(-30, rssi == 0 ? -60 : rssi))
        let t = CGFloat(clamped + 95) / 65.0
        return 0.84 - t * 0.64
    }
    // Deterministic angle from the id (FNV-1a) so a peer keeps the same
    // bearing across launches and re-renders instead of teleporting.
    private func angle(for id: String) -> CGFloat {
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return CGFloat(h % 360) * .pi / 180
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                // Depth: faint radial wash from the center.
                Circle()
                    .fill(RadialGradient(
                        colors: [Theme.accent.opacity(0.12), .clear],
                        center: .center, startRadius: 0, endRadius: side / 2))
                    .frame(width: side, height: side)

                // Concentric rings, outer ones fainter.
                ForEach(1...4, id: \.self) { i in
                    Circle()
                        .stroke(Theme.accent.opacity(0.06 + 0.05 * Double(5 - i)),
                                lineWidth: 0.8)
                        .frame(width: side * CGFloat(i) / 4,
                               height: side * CGFloat(i) / 4)
                }

                // Outward ping pulse.
                Circle()
                    .stroke(Theme.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .scaleEffect(pulse ? 1.0 : 0.05)
                    .opacity(pulse ? 0.0 : 0.7)

                // Soft rotating sweep (accent-coloured, blurred trail).
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .clear, location: 0.62),
                            .init(color: Theme.accent.opacity(0.10), location: 0.86),
                            .init(color: Theme.accent.opacity(0.42), location: 1.00)
                        ]),
                        center: .center))
                    .frame(width: side, height: side)
                    .blur(radius: 22)
                    .rotationEffect(.radians(sweep))
                    .clipShape(Circle())

                // You, at the center.
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.22))
                        .frame(width: 22, height: 22)
                    Circle().fill(Theme.accent)
                        .frame(width: 9, height: 9)
                        .shadow(color: Theme.accent.opacity(0.9), radius: 6)
                }
                .position(c)

                // Peers.
                ForEach(ble.peers) { peer in
                    let r = radius(for: peer.rssi) * side / 2
                    let a = angle(for: peer.id)
                    Button { onTapPeer(peer) } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle().fill(Theme.accent.opacity(0.18))
                                    .frame(width: 38, height: 38)
                                    .scaleEffect(breathe ? 1.12 : 0.92)
                                Circle().fill(Theme.accent)
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(.white.opacity(0.85),
                                                             lineWidth: 1))
                                    .shadow(color: Theme.accent.opacity(0.9),
                                            radius: 7)
                                Text(String(peer.nick.prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            Text(peer.nick)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text(scheme))
                                .lineLimit(1)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.surface(scheme), in: Capsule())
                                .overlay(Capsule().stroke(Theme.line(scheme),
                                                          lineWidth: 0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { ble.toggleMute(peer.id) } label: {
                            Label(ble.isMuted(peer.id) ? L("Unmute") : L("Mute"),
                                  systemImage: ble.isMuted(peer.id) ? "bell" : "bell.slash")
                        }
                        Button(role: .destructive) { ble.block(peer.id) } label: {
                            Label(L("Block"), systemImage: "hand.raised")
                        }
                    }
                    .position(x: c.x + cos(a) * r, y: c.y - sin(a) * r)
                    .animation(.easeInOut(duration: 0.9), value: r)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeInOut(duration: 0.55), value: ble.peers)
        }
        .onAppear {
            withAnimation(.linear(duration: 3.6).repeatForever(autoreverses: false)) {
                sweep = .pi * 2
            }
            withAnimation(.easeOut(duration: 2.8).repeatForever(autoreverses: false)) {
                pulse = true
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}
