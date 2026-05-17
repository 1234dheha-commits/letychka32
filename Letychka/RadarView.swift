import SwiftUI

/// Sonar-style radar. Each nearby person is a blip; angle is derived from
/// their id (stable), distance from signal strength (closer = stronger).
struct RadarView: View {
    @ObservedObject var ble: BLEMessenger
    @Environment(\.colorScheme) private var scheme
    var onTapPeer: (Peer) -> Void

    @State private var sweep = 0.0

    private func radius(for rssi: Int) -> CGFloat {
        // RSSI roughly -30 (very close) .. -95 (far). Map to 0.12 .. 0.92.
        let clamped = max(-95, min(-30, rssi == 0 ? -60 : rssi))
        let t = CGFloat(clamped + 95) / 65.0          // 0 far .. 1 near
        return 0.92 - t * 0.80
    }
    private func angle(for id: String) -> CGFloat {
        CGFloat(abs(id.hashValue) % 360) * .pi / 180
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(1...4, id: \.self) { i in
                    Circle()
                        .stroke(Theme.line(scheme), lineWidth: 0.8)
                        .frame(width: side * CGFloat(i) / 4,
                               height: side * CGFloat(i) / 4)
                }
                Path { p in
                    p.move(to: c)
                    p.addLine(to: CGPoint(x: c.x, y: c.y - side / 2))
                }
                .stroke(Theme.accent.opacity(0.7), lineWidth: 2)
                .rotationEffect(.radians(sweep), anchor: .center)

                Circle().fill(Theme.accent).frame(width: 10, height: 10)

                ForEach(ble.peers) { peer in
                    let r = radius(for: peer.rssi) * side / 2
                    let a = angle(for: peer.id)
                    Button { onTapPeer(peer) } label: {
                        VStack(spacing: 3) {
                            Circle().fill(Theme.accent)
                                .frame(width: 14, height: 14)
                                .shadow(color: Theme.accent.opacity(0.7), radius: 6)
                            Text(peer.nick)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.text(scheme))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .position(x: c.x + cos(a) * r, y: c.y - sin(a) * r)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                sweep = .pi * 2
            }
        }
    }
}
