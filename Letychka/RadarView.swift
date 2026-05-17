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

    private func radius(for rssi: Int) -> CGFloat {
        let clamped = max(-95, min(-30, rssi == 0 ? -60 : rssi))
        let t = CGFloat(clamped + 95) / 65.0          // 0 far .. 1 near
        return 0.90 - t * 0.78
    }
    private func angle(for id: String) -> CGFloat {
        CGFloat(abs(id.hashValue) % 360) * .pi / 180
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
                // Cross hairs
                Group {
                    Rectangle().frame(width: side, height: 0.6)
                    Rectangle().frame(width: 0.6, height: side)
                }
                .foregroundStyle(Theme.line(scheme))

                // Outward ping pulse
                Circle()
                    .stroke(Theme.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .scaleEffect(pulse ? 1.0 : 0.06)
                    .opacity(pulse ? 0.0 : 0.7)

                // Rotating sweep: bright leading edge fading into a trail wedge
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: Theme.accent.opacity(0.0),  location: 0.00),
                            .init(color: Theme.accent.opacity(0.0),  location: 0.55),
                            .init(color: Theme.accent.opacity(0.12), location: 0.80),
                            .init(color: Theme.accent.opacity(0.30), location: 0.94),
                            .init(color: Theme.accent.opacity(0.65), location: 1.00)
                        ]),
                        center: .center))
                    .frame(width: side, height: side)
                    .rotationEffect(.radians(sweep))
                Path { p in
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x, y: c.y - side / 2))
                }
                .stroke(Theme.accent, lineWidth: 2)
                .rotationEffect(.radians(sweep), anchor: .center)

                // Center
                Circle().fill(Theme.accent)
                    .frame(width: 12, height: 12)
                    .shadow(color: Theme.accent.opacity(0.8), radius: 8)

                // Peers
                ForEach(ble.peers) { peer in
                    let r = radius(for: peer.rssi) * side / 2
                    let a = angle(for: peer.id)
                    Button { onTapPeer(peer) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Circle().fill(Theme.accent.opacity(0.25))
                                    .frame(width: 26, height: 26)
                                Circle().fill(Theme.accent)
                                    .frame(width: 13, height: 13)
                                    .shadow(color: Theme.accent.opacity(0.9), radius: 7)
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
                    .position(x: c.x + cos(a) * r, y: c.y - sin(a) * r)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                sweep = .pi * 2
            }
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
