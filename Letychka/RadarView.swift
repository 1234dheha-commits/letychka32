import SwiftUI

/// Sonar radar: rotating sweep line with a fading trail wedge behind it,
/// outward ping pulses, glowing peer blips. Angle from peer id (stable),
/// distance from signal strength (stronger = closer to center).
struct RadarView: View {
    @ObservedObject var ble: BLEMessenger
    @Environment(\.colorScheme) private var scheme
    var onTapPeer: (Peer) -> Void

    @State private var sweep = 0.0
    @State private var pulse = false
    @State private var hue = 0.0

    private func radius(for rssi: Int) -> CGFloat {
        let clamped = max(-95, min(-30, rssi == 0 ? -60 : rssi))
        let t = CGFloat(clamped + 95) / 65.0          // 0 far .. 1 near
        return 0.90 - t * 0.78
    }
    // Deterministic angle from the id (FNV-1a) so a peer keeps the same
    // bearing across app launches and re-renders, instead of teleporting.
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
                // Rings
                ForEach(1...4, id: \.self) { i in
                    Circle()
                        .stroke(Theme.line(scheme), lineWidth: 0.8)
                        .frame(width: side * CGFloat(i) / 4,
                               height: side * CGFloat(i) / 4)
                }
                // Outward ping pulse
                Circle()
                    .stroke(Theme.accent.opacity(0.40), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .scaleEffect(pulse ? 1.0 : 0.06)
                    .opacity(pulse ? 0.0 : 0.6)

                // Soft fog trail behind the sweep: blurred, colour-shifting
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .clear, location: 0.00),
                            .init(color: .clear, location: 0.60),
                            .init(color: Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.14), location: 0.84),
                            .init(color: Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.40), location: 1.00)
                        ]),
                        center: .center))
                    .frame(width: side, height: side)
                    .blur(radius: 20)
                    .rotationEffect(.radians(sweep))
                    .clipShape(Circle())
                    .hueRotation(.degrees(hue))


                // Peers
                ForEach(ble.peers) { peer in
                    let r = radius(for: peer.rssi) * side / 2
                    let a = angle(for: peer.id)
                    Button { onTapPeer(peer) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle().fill(Theme.accent.opacity(0.22))
                                    .frame(width: 30, height: 30)
                                Circle().fill(Theme.accent)
                                    .frame(width: 24, height: 24)
                                    .shadow(color: Theme.accent.opacity(0.9), radius: 7)
                                Text(String(peer.nick.prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            Text(peer.nick)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text(scheme))
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.surface(scheme),
                                            in: Capsule())
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
                    // Glide to a new distance instead of snapping each tick.
                    .animation(.easeInOut(duration: 0.9), value: r)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Fade/scale peers in and out smoothly when they appear or leave.
            .animation(.easeInOut(duration: 0.55), value: ble.peers)
        }
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                sweep = .pi * 2
            }
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
            withAnimation(.linear(duration: 5).repeatForever(autoreverses: false)) {
                hue = 360
            }
        }
    }
}
