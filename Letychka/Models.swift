import Foundation

/// A nearby person discovered over Bluetooth. Fully anonymous: only a random
/// per-install id and a self-chosen nickname, nothing tied to identity.
struct Peer: Identifiable, Equatable, Hashable {
    let id: String          // stable per-install id of that person
    var nick: String        // self-chosen display name
    var rssi: Int            // signal strength (used for radar distance)
    var lastSeen: Date

    static func == (a: Peer, b: Peer) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum MsgKind: String, Codable { case text, image, audio }

/// One chat message. Persisted on the device, keyed by the peer's stable id,
/// so a conversation survives leaving and coming back later.
struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    let peerID: String
    let mine: Bool
    let kind: MsgKind
    var text: String
    let data: Data?
    let date: Date
    let wireID: UInt32
    /// Single emoji reaction set by either side (nil = none).
    var reaction: String?
    /// wireID of the message this one replies to (0/nil = not a reply).
    var replyTo: UInt32?
    /// Our outgoing message was actually received by the other phone (ACK).
    /// Optional so an older saved chats.json (no such key) still decodes
    /// instead of wiping the user's history.
    var delivered: Bool?

    init(peerID: String, mine: Bool, text: String, date: Date,
         kind: MsgKind = .text, data: Data? = nil, wireID: UInt32 = 0,
         replyTo: UInt32? = nil) {
        self.peerID = peerID
        self.mine = mine
        self.text = text
        self.date = date
        self.kind = kind
        self.data = data
        self.wireID = wireID
        self.replyTo = (replyTo ?? 0) == 0 ? nil : replyTo
    }
}

/// Stable, anonymous, per-install id. Random, generated once, kept on the
/// device. Not tied to Apple ID, phone number or anything personal. It only
/// lets the same person stay one dot and keep their chat across reconnects.
enum Ident {
    static let me: String = {
        let k = "myID"
        if let s = UserDefaults.standard.string(forKey: k), s.count == 8 {
            return s
        }
        let s = String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
        UserDefaults.standard.set(s, forKey: k)
        return s
    }()
}

/// Wire format for a single text payload: "nick\u{1}text" (unit separator).
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

/// Framed BLE protocol. Every frame is [kind][8-byte ascii senderID][payload]
/// so the receiver always knows which person it came from, independent of the
/// volatile CoreBluetooth identifiers. Pre-release, both phones run the same
/// build, so no back-compat shim is needed.
///
///   TEXT    1 : [4 msgID][4 replyTo][utf8 "nick\u{1}text"]
///   HEAD    2 : [4 xfer][4 total][1 type(1=jpeg,2=m4a)][4 msgID][utf8 nick]
///   CHUNK   3 : [4 xfer][4 offset][raw bytes]
///   END     4 : [4 xfer]
///   DEL     5 : [4 msgID]
///   EDIT    6 : [4 msgID][utf8 newText]
///   TYPING  7 : (empty)
///   PROFILE 8 : [utf8 nick]              (live rename)
///   REACT   9 : [4 msgID][utf8 emoji]    (emoji "" clears it)
///   SEEN   10 : [4 lastWireID]           (read receipt up to that id)
///   ROOM   11 : [utf8 "nick\u{1}text"]   (shared nearby room broadcast)
///   ACK    12 : [4 wireID]               (this message actually arrived)
enum Frame {
    static let TEXT:    UInt8 = 0x01
    static let HEAD:    UInt8 = 0x02
    static let CHUNK:   UInt8 = 0x03
    static let END:     UInt8 = 0x04
    static let DEL:     UInt8 = 0x05
    static let EDIT:    UInt8 = 0x06
    static let TYPING:  UInt8 = 0x07
    static let PROFILE: UInt8 = 0x08
    static let REACT:   UInt8 = 0x09
    static let SEEN:    UInt8 = 0x0A
    static let ROOM:    UInt8 = 0x0B
    static let ACK:     UInt8 = 0x0C

    static let typeImage: UInt8 = 1
    static let typeAudio: UInt8 = 2
    static let typeAvatar: UInt8 = 3   // tiny profile photo, not a chat message

    /// Header is 1 (kind) + 8 (senderID). Keep a chunk small enough that a
    /// whole frame still fits a modern iPhone BLE ATT payload (>= ~185).
    static let header = 9
    static let chunkBytes = 150

    static func u32(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
              UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
    static func readU32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i+1]) << 16
             | UInt32(b[i+2]) << 8 | UInt32(b[i+3])
    }
    static func newID() -> UInt32 { UInt32.random(in: 1...UInt32.max) }

    /// [kind][8 ascii senderID][payload]
    private static func wrap(_ kind: UInt8, _ payload: Data) -> Data {
        var d = Data([kind])
        d.append(Data(Ident.me.utf8))     // exactly 8 bytes
        d.append(payload)
        return d
    }

    static func text(nick: String, text: String, msgID: UInt32,
                     replyTo: UInt32 = 0) -> Data {
        wrap(TEXT, u32(msgID) + u32(replyTo) + Wire.encode(nick: nick, text: text))
    }
    static func react(msgID: UInt32, emoji: String) -> Data {
        wrap(REACT, u32(msgID) + Data(emoji.utf8))
    }
    static func seen(lastWireID: UInt32) -> Data {
        wrap(SEEN, u32(lastWireID))
    }
    static func room(nick: String, text: String) -> Data {
        wrap(ROOM, Wire.encode(nick: nick, text: text))
    }
    static func ack(wireID: UInt32) -> Data { wrap(ACK, u32(wireID)) }
    static func head(xfer: UInt32, total: Int, type: UInt8,
                     msgID: UInt32, nick: String) -> Data {
        var p = u32(xfer); p.append(u32(UInt32(total))); p.append(type)
        p.append(u32(msgID)); p.append(Data(nick.utf8))
        return wrap(HEAD, p)
    }
    static func chunk(xfer: UInt32, offset: Int, bytes: Data) -> Data {
        var p = u32(xfer); p.append(u32(UInt32(offset))); p.append(bytes)
        return wrap(CHUNK, p)
    }
    static func end(xfer: UInt32) -> Data { wrap(END, u32(xfer)) }
    static func del(msgID: UInt32) -> Data { wrap(DEL, u32(msgID)) }
    static func edit(msgID: UInt32, text: String) -> Data {
        wrap(EDIT, u32(msgID) + Data(text.utf8))
    }
    static func typingFrame() -> Data { wrap(TYPING, Data()) }
    static func profile(nick: String) -> Data { wrap(PROFILE, Data(nick.utf8)) }

    /// Split a media blob into HEAD + CHUNK* + END frames.
    static func frames(for blob: Data, type: UInt8,
                       msgID: UInt32, nick: String) -> [Data] {
        let xfer = newID()
        var out = [head(xfer: xfer, total: blob.count, type: type,
                        msgID: msgID, nick: nick)]
        var off = 0
        while off < blob.count {
            let e = min(off + chunkBytes, blob.count)
            out.append(chunk(xfer: xfer, offset: off,
                             bytes: blob.subdata(in: off..<e)))
            off = e
        }
        out.append(end(xfer: xfer))
        return out
    }
}
