import Foundation
import CoreBluetooth
import Combine

/// Anonymous, server-less, internet-less messaging over Bluetooth LE.
/// Every device both advertises (peripheral) and scans (central). To chat,
/// the initiator (central) connects to the target (peripheral); data flows
/// via a single write+notify characteristic. Text plus heavily compressed
/// small media (tiny photos, short voice notes) sent as reassembled frames.
final class BLEMessenger: NSObject, ObservableObject {

    // Valid 128-bit UUIDs: 8-4-4-4-12 hex (32 digits total). A malformed
    // string makes CBUUID throw and crashes the app on Bluetooth start.
    static let serviceUUID = CBUUID(string: "4C455459-3332-4D53-4731-000000000001")
    static let charUUID    = CBUUID(string: "4C455459-3332-4D53-4731-000000000002")

    enum BTStatus { case unknown, off, unauthorized, unsupported, on }

    @Published var peers: [Peer] = []
    @Published var messages: [ChatMessage] = []
    @Published var status: BTStatus = .unknown
    @Published var nick: String = UserDefaults.standard.string(forKey: "nick") ?? "Anon"
    /// Pinned conversations (peer ids). Session-scoped like everything else.
    @Published var pinned: Set<String> = []
    /// Last known nickname per peer id, so the chat list keeps a name even
    /// after that person walks out of Bluetooth range.
    @Published var names: [String: String] = [:]
    /// peerID -> percent of an incoming media transfer (nil when idle).
    @Published var incoming: [String: Int] = [:]

    var poweredOn: Bool { status == .on }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!

    // Central side
    private var discovered: [String: CBPeripheral] = [:]   // peerID -> peripheral
    private var connected: [String: CBPeripheral] = [:]
    private var outChar: [String: CBCharacteristic] = [:]   // peerID -> writable char
    // Peripheral side
    private var localChar: CBMutableCharacteristic?
    private var subscribers: [CBCentral] = []

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            peripheral = CBPeripheralManager(delegate: self, queue: .main)
        }
    }

    func setNick(_ n: String) {
        let v = n.trimmingCharacters(in: .whitespacesAndNewlines)
        nick = v.isEmpty ? "Anon" : String(v.prefix(20))
        UserDefaults.standard.set(nick, forKey: "nick")
        restartAdvertising()
    }

    func messages(with peerID: String) -> [ChatMessage] {
        messages.filter { $0.peerID == peerID }
    }

    /// One row per peer that has any message: newest first, pinned on top.
    struct Convo: Identifiable {
        let id: String
        let nick: String
        let last: ChatMessage
        let online: Bool
    }

    func conversations() -> [Convo] {
        let groups = Dictionary(grouping: messages, by: { $0.peerID })
        let online = Set(peers.map { $0.id })
        let list = groups.compactMap { (pid, msgs) -> Convo? in
            guard let last = msgs.max(by: { $0.date < $1.date }) else { return nil }
            let nm = names[pid] ?? peers.first(where: { $0.id == pid })?.nick ?? "Anon"
            return Convo(id: pid, nick: nm, last: last,
                         online: online.contains(pid))
        }
        return list.sorted {
            let pa = pinned.contains($0.id), pb = pinned.contains($1.id)
            if pa != pb { return pa }
            return $0.last.date > $1.last.date
        }
    }

    func togglePin(_ peerID: String) {
        if pinned.contains(peerID) { pinned.remove(peerID) }
        else { pinned.insert(peerID) }
    }

    func deleteConversation(_ peerID: String) {
        messages.removeAll { $0.peerID == peerID }
        pinned.remove(peerID)
        names[peerID] = nil
    }

    /// Wipe everything kept on this device: chats, names, pins, and reset the
    /// nickname. There are no accounts or servers, so this IS the full
    /// "delete my data". The avatar file is cleared by the caller.
    func clearAll() {
        messages.removeAll()
        pinned.removeAll()
        names.removeAll()
        setNick("")
    }

    // MARK: Sending (framed, flow-controlled, role-aware)

    private var sendQueues: [String: [Data]] = [:]   // peerID -> frames FIFO
    private var inflight: Set<String> = []            // central write outstanding

    func send(_ text: String, to peerID: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        enqueue([Frame.text(nick: nick, text: String(t.prefix(240)))], to: peerID)
        append(ChatMessage(peerID: peerID, mine: true, text: t, date: Date()))
    }

    /// Send a compressed blob (small JPEG or short m4a) split into frames.
    func sendMedia(_ blob: Data, image: Bool, to peerID: String) {
        guard !blob.isEmpty else { return }
        let type = image ? Frame.typeImage : Frame.typeAudio
        enqueue(Frame.frames(for: blob, type: type, nick: nick), to: peerID)
        append(ChatMessage(peerID: peerID, mine: true, text: "", date: Date(),
                           kind: image ? .image : .audio, data: blob))
    }

    private func enqueue(_ frames: [Data], to peerID: String) {
        sendQueues[peerID, default: []].append(contentsOf: frames)
        if connected[peerID] == nil, let p = discovered[peerID] {
            central.connect(p, options: nil)
        }
        pump(peerID)
    }

    private func pump(_ peerID: String) {
        guard var q = sendQueues[peerID], !q.isEmpty else { return }

        // Central on this link: ordered writes, one outstanding at a time.
        if let p = connected[peerID], let c = outChar[peerID] {
            if inflight.contains(peerID) { return }
            let frame = q.removeFirst()
            sendQueues[peerID] = q
            inflight.insert(peerID)
            p.writeValue(frame, for: c, type: .withResponse)
            return
        }

        // Peripheral: notify subscribers until the transmit queue is full.
        if let c = localChar, !subscribers.isEmpty {
            while !q.isEmpty {
                if peripheral.updateValue(q[0], for: c, onSubscribedCentrals: nil) {
                    q.removeFirst()
                } else {
                    break   // resumes in peripheralManagerIsReady
                }
            }
            sendQueues[peerID] = q
            return
        }
        // Neither link yet: frames stay queued, flushed on connect/subscribe.
    }

    func connect(_ peerID: String) {
        guard let p = discovered[peerID] else { return }
        central.connect(p, options: nil)
    }

    private func append(_ m: ChatMessage) {
        DispatchQueue.main.async { self.messages.append(m) }
    }

    // MARK: Receiving (reassembly)

    private struct Inbox {
        let type: UInt8
        let total: Int
        var buf: [UInt8]
        var received: Int
        let peer: String
    }
    private var inbox: [UInt32: Inbox] = [:]

    private func handleFrame(_ data: Data, from peerID: String) {
        guard let kind = data.first else { return }
        let body = [UInt8](data.dropFirst())
        switch kind {
        case Frame.TEXT:
            guard let msg = Wire.decode(Data(body)) else { return }
            if !msg.nick.isEmpty { upsertPeer(id: peerID, nick: msg.nick, rssi: 0) }
            append(ChatMessage(peerID: peerID, mine: false,
                               text: msg.text, date: Date()))
        case Frame.HEAD:
            guard body.count >= 9 else { return }
            let id = Frame.readU32(body, 0)
            let total = Int(Frame.readU32(body, 4))
            let mtype = body[8]
            let nm = String(bytes: body[9...], encoding: .utf8) ?? ""
            if !nm.isEmpty { upsertPeer(id: peerID, nick: nm, rssi: 0) }
            guard total > 0, total <= 3_000_000 else { return }   // sanity cap
            inbox[id] = Inbox(type: mtype, total: total,
                              buf: [UInt8](repeating: 0, count: total),
                              received: 0, peer: peerID)
            setIncoming(peerID, 0)
        case Frame.CHUNK:
            guard body.count >= 8, var box = inbox[Frame.readU32(body, 0)] else { return }
            let id = Frame.readU32(body, 0)
            let off = Int(Frame.readU32(body, 4))
            let payload = body[8...]
            let n = payload.count
            guard n > 0, off >= 0, off + n <= box.total else { return }
            box.buf.replaceSubrange(off..<off+n, with: payload)
            box.received += n
            inbox[id] = box
            setIncoming(peerID, min(100, box.received * 100 / max(1, box.total)))
        case Frame.END:
            guard body.count >= 4 else { return }
            let id = Frame.readU32(body, 0)
            guard let box = inbox[id] else { return }
            inbox[id] = nil
            clearIncoming(peerID)
            append(ChatMessage(peerID: box.peer, mine: false, text: "",
                               date: Date(),
                               kind: box.type == Frame.typeImage ? .image : .audio,
                               data: Data(box.buf)))
        default:
            return
        }
    }

    private func setIncoming(_ peer: String, _ pct: Int) {
        DispatchQueue.main.async { self.incoming[peer] = pct }
    }
    private func clearIncoming(_ peer: String) {
        DispatchQueue.main.async { self.incoming[peer] = nil }
    }

    private func upsertPeer(id: String, nick: String, rssi: Int) {
        DispatchQueue.main.async {
            if !nick.isEmpty { self.names[id] = nick }
            if let i = self.peers.firstIndex(where: { $0.id == id }) {
                self.peers[i].rssi = rssi
                self.peers[i].lastSeen = Date()
                if !nick.isEmpty { self.peers[i].nick = nick }
            } else {
                self.peers.append(Peer(id: id, nick: nick.isEmpty ? "Anon" : nick,
                                       rssi: rssi, lastSeen: Date()))
            }
            // Drop peers not seen for a while.
            let cutoff = Date().addingTimeInterval(-20)
            self.peers.removeAll { $0.lastSeen < cutoff && self.connected[$0.id] == nil }
        }
    }

    private func restartAdvertising() {
        guard peripheral?.state == .poweredOn else { return }
        peripheral.stopAdvertising()
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: nick
        ])
    }
}

// MARK: - Central (scanning + connecting)

extension BLEMessenger: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ m: CBCentralManager) {
        let s: BTStatus
        switch m.state {
        case .poweredOn:     s = .on
        case .poweredOff:    s = .off
        case .unauthorized:  s = .unauthorized
        case .unsupported:   s = .unsupported
        default:             s = .unknown
        }
        DispatchQueue.main.async { self.status = s }
        if m.state == .poweredOn {
            m.scanForPeripherals(withServices: [Self.serviceUUID],
                                 options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ m: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = p.identifier.uuidString
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        discovered[id] = p
        upsertPeer(id: id, nick: name, rssi: RSSI.intValue)
    }

    func centralManager(_ m: CBCentralManager, didConnect p: CBPeripheral) {
        connected[p.identifier.uuidString] = p
        p.delegate = self
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ m: CBCentralManager, didDisconnectPeripheral p: CBPeripheral,
                        error: Error?) {
        let id = p.identifier.uuidString
        connected[id] = nil
        outChar[id] = nil
        inflight.remove(id)
    }
}

// MARK: - Central peripheral callbacks

extension BLEMessenger: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] where s.uuid == Self.serviceUUID {
            p.discoverCharacteristics([Self.charUUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService,
                    error: Error?) {
        for c in s.characteristics ?? [] where c.uuid == Self.charUUID {
            let id = p.identifier.uuidString
            outChar[id] = c
            p.setNotifyValue(true, for: c)
            pump(id)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic,
                    error: Error?) {
        guard let data = c.value else { return }
        handleFrame(data, from: p.identifier.uuidString)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic,
                    error: Error?) {
        let id = p.identifier.uuidString
        inflight.remove(id)
        pump(id)   // send the next queued frame
    }
}

// MARK: - Peripheral (advertising + receiving)

extension BLEMessenger: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn else { return }
        let c = CBMutableCharacteristic(
            type: Self.charUUID,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable])
        let svc = CBMutableService(type: Self.serviceUUID, primary: true)
        svc.characteristics = [c]
        localChar = c
        pm.removeAllServices()
        pm.add(svc)   // advertising starts in didAdd, once the service exists
    }

    func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService,
                           error: Error?) {
        guard error == nil else { return }
        restartAdvertising()
    }

    func peripheralManager(_ pm: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if let data = r.value {
                handleFrame(data, from: r.central.identifier.uuidString)
            }
            pm.respond(to: r, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        for peerID in sendQueues.keys { pump(peerID) }
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo c: CBCharacteristic) {
        if !subscribers.contains(where: { $0.identifier == central.identifier }) {
            subscribers.append(central)
        }
        pump(central.identifier.uuidString)
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom c: CBCharacteristic) {
        subscribers.removeAll { $0.identifier == central.identifier }
    }
}
