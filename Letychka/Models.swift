import Foundation

/// A nearby person discovered over Bluetooth. Fully anonymous: only a random
/// per-session id and a self-chosen nickname, nothing tied to identity.
struct Peer: Identifiable, Equatable, Hashable {
    let id: String          // random peer id advertised this session
    var nick: String        // self-chosen display name
    var rssi: Int            // signal strength (used for radar distance)
    var lastSeen: Date

    static func == (a: Peer, b: Peer) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// One chat message. Ephemeral: kept only in memory for the session.
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let peerID: String
    let mine: Bool
    let text: String
    let date: Date
}

/// Wire format for a single BLE packet: "nick\u{1}text" (unit separator).
/// Tiny on purpose, BLE throughput is low so messages stay short.
enum Wire {
    static let sep: Character = "\u{1}"
    static func encode(nick: String, text: String) -> Data {
        Data("\(nick)\(sep)\(text)".utf8)
    }
    static func decode(_ data: Data) -> (nick: String, text: String)? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        guard let i = s.firstIndex(of: sep) else { return (nick: "", text: s) }
        return (nick: String(s[s.startIndex..<i]),
                text: String(s[s.index(after: i)...]))
    }
}
