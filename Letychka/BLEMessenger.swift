import Foundation
import CoreBluetooth
import Combine

/// Anonymous, server-less, internet-less messaging over Bluetooth LE.
/// Every device both advertises (peripheral) and scans (central). To chat,
/// the initiator (central) connects to the target (peripheral); text flows
/// via a single write+notify characteristic. Small text payloads only.
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

    // MARK: Sending

    func send(_ text: String, to peerID: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let data = Wire.encode(nick: nick, text: String(t.prefix(240)))

        if let p = connected[peerID], let c = outChar[peerID] {
            // We are the central on this link.
            p.writeValue(data, for: c, type: .withResponse)
        } else if let c = localChar, !subscribers.isEmpty {
            // We are the peripheral; notify subscribed centrals.
            peripheral.updateValue(data, for: c, onSubscribedCentrals: nil)
        } else if let p = discovered[peerID] {
            // Not connected yet: connect, then the write is retried on ready.
            pendingSend[peerID, default: []].append(data)
            central.connect(p, options: nil)
        }
        append(ChatMessage(peerID: peerID, mine: true, text: t, date: Date()))
    }

    private var pendingSend: [String: [Data]] = [:]

    func connect(_ peerID: String) {
        guard let p = discovered[peerID] else { return }
        central.connect(p, options: nil)
    }

    private func append(_ m: ChatMessage) {
        DispatchQueue.main.async { self.messages.append(m) }
    }

    private func upsertPeer(id: String, nick: String, rssi: Int) {
        DispatchQueue.main.async {
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
            for data in pendingSend[id] ?? [] {
                p.writeValue(data, for: c, type: .withResponse)
            }
            pendingSend[id] = nil
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic,
                    error: Error?) {
        guard let data = c.value, let msg = Wire.decode(data) else { return }
        let id = p.identifier.uuidString
        if !msg.nick.isEmpty { upsertPeer(id: id, nick: msg.nick, rssi: 0) }
        append(ChatMessage(peerID: id, mine: false, text: msg.text, date: Date()))
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
        pm.removeAllServices()
        pm.add(svc)
        localChar = c
        restartAdvertising()
    }

    func peripheralManager(_ pm: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if let data = r.value, let msg = Wire.decode(data) {
                let id = r.central.identifier.uuidString
                if !msg.nick.isEmpty { upsertPeer(id: id, nick: msg.nick, rssi: 0) }
                append(ChatMessage(peerID: id, mine: false, text: msg.text, date: Date()))
            }
            pm.respond(to: r, withResult: .success)
        }
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo c: CBCharacteristic) {
        if !subscribers.contains(where: { $0.identifier == central.identifier }) {
            subscribers.append(central)
        }
    }

    func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom c: CBCharacteristic) {
        subscribers.removeAll { $0.identifier == central.identifier }
    }
}
