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

enum MsgKind: Equatable { case text, image, audio }

/// One chat message. Ephemeral: kept only in memory for the session.
/// `data` holds the JPEG (image) or m4a (audio) payload when not text.
struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let peerID: String
    let mine: Bool
    let kind: MsgKind
    let text: String
    let data: Data?
    let date: Date

    init(peerID: String, mine: Bool, text: String, date: Date,
         kind: MsgKind = .text, data: Data? = nil) {
        self.peerID = peerID
        self.mine = mine
        self.text = text
        self.date = date
        self.kind = kind
        self.data = data
    }
}

/// Wire format for a single text packet: "nick\u{1}text" (unit separator).
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

/// Tiny framed protocol so larger payloads (small photos, short voice notes)
/// can be split across many small BLE packets and reassembled. BLE is slow,
/// so media is heavily compressed and transfers show progress.
///
///   TEXT  : [0x01][utf8 "nick\u{1}text"]
///   HEAD  : [0x02][4 id][4 total][1 type(1=jpeg,2=m4a)][utf8 nick]
///   CHUNK : [0x03][4 id][4 offset][raw bytes]
///   END   : [0x04][4 id]
enum Frame {
    static let TEXT:  UInt8 = 0x01
    static let HEAD:  UInt8 = 0x02
    static let CHUNK: UInt8 = 0x03
    static let END:   UInt8 = 0x04

    static let typeImage: UInt8 = 1
    static let typeAudio: UInt8 = 2

    /// Raw bytes of media per CHUNK. Kept small so one frame fits the BLE
    /// ATT payload on any modern iPhone (negotiated MTU is >= ~185).
    static let chunkBytes = 160

    static func u32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
              UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
    static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16
             | UInt32(b[i+2]) << 8 | UInt32(b[i+3])
    }

    static func text(nick: String, text: String) -> Data {
        var d = Data([TEXT]); d.append(Wire.encode(nick: nick, text: text)); return d
    }
    static func head(id: UInt32, total: Int, type: UInt8, nick: String) -> Data {
        var d = Data([HEAD])
        d.append(u32(id)); d.append(u32(UInt32(total))); d.append(type)
        d.append(Data(nick.utf8)); return d
    }
    static func chunk(id: UInt32, offset: Int, bytes: Data) -> Data {
        var d = Data([CHUNK]); d.append(u32(id)); d.append(u32(UInt32(offset)))
        d.append(bytes); return d
    }
    static func end(id: UInt32) -> Data {
        var d = Data([END]); d.append(u32(id)); return d
    }

    /// Split a media blob into HEAD + CHUNK* + END frames.
    static func frames(for blob: Data, type: UInt8, nick: String) -> [Data] {
        let id = UInt32.random(in: 1...UInt32.max)
        var out = [head(id: id, total: blob.count, type: type, nick: nick)]
        var off = 0
        while off < blob.count {
            let end = min(off + chunkBytes, blob.count)
            out.append(chunk(id: id, offset: off,
                             bytes: blob.subdata(in: off..<end)))
            off = end
        }
        out.append(self.end(id: id))
        return out
    }
}
