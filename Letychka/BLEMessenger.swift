import Foundation
import CoreBluetooth
import Combine
import UserNotifications

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
    /// peerID -> count of unseen incoming messages.
    @Published var unread: [String: Int] = [:]
    /// peerID -> time we last heard "typing" from them (pruned after 5s).
    @Published var typing: [String: Date] = [:]
    /// When false the device neither advertises nor scans: invisible + radar
    /// cleared. Lets the user disconnect from the map.
    @Published var visible = true

    /// The chat currently on screen, so its messages are not counted unread.
    var activeChat: String?
    private var typingPrune: Timer?
    private var pruneTimer: Timer?
    private var notifOK = false

    var poweredOn: Bool { status == .on }
    var unreadTotal: Int { unread.values.reduce(0, +) }

    func isTyping(_ peerID: String) -> Bool {
        guard let t = typing[peerID] else { return false }
        return Date().timeIntervalSince(t) < 5
    }

    func openChat(_ peerID: String) {
        activeChat = peerID
        if unread[peerID] != nil { unread[peerID] = nil; refreshBadge() }
    }
    func closeChat() { activeChat = nil }

    private func refreshBadge() {
        let n = unreadTotal
        UNUserNotificationCenter.current().setBadgeCount(n)
    }

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
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
                    DispatchQueue.main.async { self.notifOK = ok }
                }
            // Drop people who walked away / turned Bluetooth off even when no
            // new scan callbacks arrive, so the radar does not keep ghosts.
            pruneTimer = Timer.scheduledTimer(withTimeInterval: 3,
                                              repeats: true) { [weak self] _ in
                guard let self else { return }
                let cutoff = Date().addingTimeInterval(-9)
                let before = self.peers.count
                self.peers.removeAll { $0.lastSeen < cutoff }
                if self.peers.count != before {
                    self.discovered = self.discovered.filter { k, _ in
                        self.peers.contains { $0.id == k }
                    }
                }
            }
        }
    }

    /// Disconnect from / reconnect to the map. Off = invisible to others and
    /// radar cleared; on = advertise + scan again.
    func setVisible(_ on: Bool) {
        visible = on
        guard central != nil else { return }
        if on {
            if central.state == .poweredOn {
                central.scanForPeripherals(
                    withServices: [Self.serviceUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            restartAdvertising()
        } else {
            if central.state == .poweredOn { central.stopScan() }
            peripheral?.stopAdvertising()
            peers.removeAll()
            discovered.removeAll()
        }
    }

    func sendTyping(to peerID: String) {
        enqueue([Frame.typingFrame()], to: peerID)
    }

    private func startTypingPrune() {
        guard typingPrune == nil else { return }
        typingPrune = Timer.scheduledTimer(withTimeInterval: 1,
                                           repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.typing = self.typing.filter { now.timeIntervalSince($0.value) < 5 }
            if self.typing.isEmpty {
                self.typingPrune?.invalidate(); self.typingPrune = nil
            }
        }
    }

    private func notify(_ m: ChatMessage) {
        guard notifOK else { return }
        let c = UNMutableNotificationContent()
        c.title = names[m.peerID] ?? "Letychka"
        switch m.kind {
        case .text:  c.body = m.text
        case .image: c.body = "Photo"
        case .audio: c.body = "Voice message"
        }
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: c, trigger: nil))
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
        let mid = Frame.newID()
        enqueue([Frame.text(nick: nick, text: String(t.prefix(240)), msgID: mid)],
                to: peerID)
        append(ChatMessage(peerID: peerID, mine: true, text: t, date: Date(),
                           wireID: mid))
    }

    /// Send a compressed blob (small JPEG or short m4a) split into frames.
    func sendMedia(_ blob: Data, image: Bool, to peerID: String) {
        guard !blob.isEmpty else { return }
        let type = image ? Frame.typeImage : Frame.typeAudio
        let mid = Frame.newID()
        enqueue(Frame.frames(for: blob, type: type, msgID: mid, nick: nick),
                to: peerID)
        append(ChatMessage(peerID: peerID, mine: true, text: "", date: Date(),
                           kind: image ? .image : .audio, data: blob, wireID: mid))
    }

    /// Delete locally; if it is our message, also tell the other phone.
    func deleteMessage(_ m: ChatMessage) {
        DispatchQueue.main.async { self.messages.removeAll { $0.id == m.id } }
        if m.mine, m.wireID != 0 {
            enqueue([Frame.del(msgID: m.wireID)], to: m.peerID)
        }
    }

    /// Edit our own text message and propagate the new text to the other phone.
    func editMessage(_ m: ChatMessage, newText: String) {
        let t = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard m.mine, m.kind == .text, !t.isEmpty else { return }
        let nt = String(t.prefix(240))
        DispatchQueue.main.async {
            if let i = self.messages.firstIndex(where: { $0.id == m.id }) {
                self.messages[i].text = nt
            }
        }
        if m.wireID != 0 {
            enqueue([Frame.edit(msgID: m.wireID, text: nt)], to: m.peerID)
        }
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
        DispatchQueue.main.async {
            self.messages.append(m)
            guard !m.mine, m.peerID != self.activeChat else { return }
            self.unread[m.peerID, default: 0] += 1
            UNUserNotificationCenter.current().setBadgeCount(self.unreadTotal)
            self.notify(m)
        }
    }

    // MARK: Receiving (reassembly)

    private struct Inbox {
        let type: UInt8
        let total: Int
        var buf: [UInt8]
        var received: Int
        let peer: String
        let msgID: UInt32
    }
    private var inbox: [UInt32: Inbox] = [:]

    private func handleFrame(_ data: Data, from peerID: String) {
        guard let kind = data.first else { return }
        let body = [UInt8](data.dropFirst())
        switch kind {
        case Frame.TEXT:
            guard body.count >= 4 else { return }
            let mid = Frame.readU32(body, 0)
            guard let msg = Wire.decode(Data(body[4...])) else { return }
            if !msg.nick.isEmpty { upsertPeer(id: peerID, nick: msg.nick, rssi: 0) }
            append(ChatMessage(peerID: peerID, mine: false,
                               text: msg.text, date: Date(), wireID: mid))
        case Frame.HEAD:
            guard body.count >= 13 else { return }
            let xfer = Frame.readU32(body, 0)
            let total = Int(Frame.readU32(body, 4))
            let mtype = body[8]
            let mid = Frame.readU32(body, 9)
            let nm = String(bytes: body[13...], encoding: .utf8) ?? ""
            if !nm.isEmpty { upsertPeer(id: peerID, nick: nm, rssi: 0) }
            guard total > 0, total <= 3_000_000 else { return }   // sanity cap
            inbox[xfer] = Inbox(type: mtype, total: total,
                                buf: [UInt8](repeating: 0, count: total),
                                received: 0, peer: peerID, msgID: mid)
            setIncoming(peerID, 0)
        case Frame.CHUNK:
            guard body.count >= 8, var box = inbox[Frame.readU32(body, 0)] else { return }
            let xfer = Frame.readU32(body, 0)
            let off = Int(Frame.readU32(body, 4))
            let payload = body[8...]
            let n = payload.count
            guard n > 0, off >= 0, off + n <= box.total else { return }
            box.buf.replaceSubrange(off..<off+n, with: payload)
            box.received += n
            inbox[xfer] = box
            setIncoming(peerID, min(100, box.received * 100 / max(1, box.total)))
        case Frame.END:
            guard body.count >= 4 else { return }
            let xfer = Frame.readU32(body, 0)
            guard let box = inbox[xfer] else { return }
            inbox[xfer] = nil
            clearIncoming(peerID)
            append(ChatMessage(peerID: box.peer, mine: false, text: "",
                               date: Date(),
                               kind: box.type == Frame.typeImage ? .image : .audio,
                               data: Data(box.buf), wireID: box.msgID))
        case Frame.TYPING:
            DispatchQueue.main.async {
                self.typing[peerID] = Date()
                self.startTypingPrune()
            }
        case Frame.DEL:
            guard body.count >= 4 else { return }
            let mid = Frame.readU32(body, 0)
            DispatchQueue.main.async {
                self.messages.removeAll { $0.wireID == mid && $0.peerID == peerID }
            }
        case Frame.EDIT:
            guard body.count >= 4 else { return }
            let mid = Frame.readU32(body, 0)
            let nt = String(bytes: body[4...], encoding: .utf8) ?? ""
            guard !nt.isEmpty else { return }
            DispatchQueue.main.async {
                if let i = self.messages.firstIndex(where: {
                    $0.wireID == mid && $0.peerID == peerID
                }) { self.messages[i].text = nt }
            }
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
                // Exponential smoothing so the radar blip glides instead of
                // jumping on every noisy scan tick. rssi == 0 means "no new
                // signal reading" (came in on a text/media frame), so keep
                // the last smoothed distance.
                if rssi != 0 {
                    let old = self.peers[i].rssi
                    self.peers[i].rssi = old == 0
                        ? rssi
                        : Int(Double(old) * 0.78 + Double(rssi) * 0.22)
                }
                self.peers[i].lastSeen = Date()
                if !nick.isEmpty { self.peers[i].nick = nick }
            } else if !nick.isEmpty, nick != "Anon",
                      let j = self.peers.firstIndex(where: { $0.nick == nick }) {
                // Same person re-appeared under a new Bluetooth id (they
                // toggled BT / re-advertised). Keep ONE blip and track the
                // newest id so a tap still reaches them, instead of stacking
                // duplicate jittering dots.
                let keepRssi = rssi == 0 ? self.peers[j].rssi : rssi
                self.peers[j] = Peer(id: id, nick: nick,
                                     rssi: keepRssi, lastSeen: Date())
            } else {
                self.peers.append(Peer(id: id, nick: nick.isEmpty ? "Anon" : nick,
                                       rssi: rssi == 0 ? -65 : rssi, lastSeen: Date()))
            }
            // Drop peers not seen recently (also handled by the prune timer).
            let cutoff = Date().addingTimeInterval(-9)
            self.peers.removeAll { $0.lastSeen < cutoff }
        }
    }

    private func restartAdvertising() {
        guard visible, peripheral?.state == .poweredOn else { return }
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
        if m.state == .poweredOn, visible {
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
