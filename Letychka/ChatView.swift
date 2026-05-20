import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct ChatView: View {
    @ObservedObject var ble: BLEMessenger
    let peer: Peer
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var player = AudioPlayer()
    @State private var durations: [UUID: Double] = [:]
    @State private var notice: String?
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var lastTyped = Date.distantPast
    @State private var lastActivity = Date.distantPast
    @State private var photoView: PhotoItem?
    @State private var willCancel = false
    @State private var wave: [CGFloat] = Array(repeating: 0.06, count: 26)
    private let emojis = ["👍", "❤️", "😂", "🔥", "😮", "😢"]

    private var msgs: [ChatMessage] { ble.messages(with: peer.id) }
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(msgs) { m in
                            HStack {
                                if m.mine { Spacer(minLength: 40) }
                                row(m)
                                    .contextMenu { menu(m) }
                                if !m.mine { Spacer(minLength: 40) }
                            }
                            .id(m.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: msgs.count) { _, _ in
                    if let last = msgs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 6)
            }

            if let act = ble.peerActivity(peer.id) {
                HStack(spacing: 7) {
                    TypingDots()
                    Text(activityText(act))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18).padding(.top, 6)
                .transition(.opacity)
            }

            if editing != nil {
                HStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text(L("Editing message"))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                    Spacer()
                    Button(L("Cancel")) { editing = nil; draft = "" }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 18).padding(.top, 6)
            }

            if let r = replyingTo {
                HStack(spacing: 8) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                    Text(L("Reply: %@", snippet(r)))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                        .lineLimit(1)
                    Spacer()
                    Button(L("Cancel")) { replyingTo = nil }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 18).padding(.top, 6)
            }

            inputBar
        }
        .background(Theme.bg(scheme).ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $photoView) { it in
            PhotoViewer(image: it.image) { photoView = nil }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(peer.nick)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text(scheme))
                    if let pct = ble.outgoing[peer.id] {
                        progressLine(L("Sending media %d%%", pct),
                                     pct: pct)
                    } else if let pct = ble.incoming[peer.id] {
                        progressLine(L("Receiving media %d%%", pct),
                                     pct: pct)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        ble.toggleMute(peer.id)
                    } label: {
                        Label(ble.isMuted(peer.id) ? L("Unmute") : L("Mute"),
                              systemImage: ble.isMuted(peer.id)
                                  ? "bell" : "bell.slash")
                    }
                    Button(role: .destructive) {
                        ble.deleteConversation(peer.id)
                        dismiss()
                    } label: {
                        Label(L("Delete chat"), systemImage: "trash")
                    }
                    if ble.isBlocked(peer.id) {
                        Button { ble.unblock(peer.id) } label: {
                            Label(L("Unblock"), systemImage: "hand.raised.slash")
                        }
                    } else {
                        Button(role: .destructive) {
                            ble.block(peer.id)
                            dismiss()
                        } label: {
                            Label(L("Block"), systemImage: "hand.raised")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .onAppear { ble.connect(peer.id); ble.openChat(peer.id) }
        .onDisappear { ble.closeChat() }
        .onChange(of: draft) { _, v in
            guard !v.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            if Date().timeIntervalSince(lastTyped) > 2 {
                lastTyped = Date()
                ble.sendTyping(to: peer.id)
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            ble.sendTyping(to: peer.id, kind: .photo)
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let blob = data.flatMap { Self.compressImage($0) }
                await MainActor.run {
                    if let blob {
                        ble.sendTyping(to: peer.id, kind: .photo)
                        ble.sendMedia(blob, image: true, to: peer.id)
                    } else { notice = L("Could not attach that photo") }
                    photoItem = nil
                }
            }
        }
        .onChange(of: recorder.level) { _, lv in
            guard recorder.isRecording else { return }
            wave.removeFirst()
            wave.append(max(0.06, min(1, lv)))
        }
        .onChange(of: recorder.isRecording) { _, on in
            if on {
                lastActivity = Date()
                ble.sendTyping(to: peer.id, kind: .voice)
            } else {
                wave = Array(repeating: 0.06, count: wave.count)
            }
        }
        .onChange(of: recorder.elapsed) { _, _ in
            guard recorder.isRecording,
                  Date().timeIntervalSince(lastActivity) > 2.5 else { return }
            lastActivity = Date()
            ble.sendTyping(to: peer.id, kind: .voice)
        }
        .onChange(of: recorder.denied) { _, d in
            if d { notice = L("Microphone access is needed for voice messages") }
        }
    }

    // MARK: Row (reply preview + bubble + reaction + seen)

    /// Telegram-style small text + thin progress bar under the nick.
    @ViewBuilder
    private func progressLine(_ label: String, pct: Int) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted(scheme))
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line(scheme)).frame(height: 2)
                    Capsule().fill(Theme.accent)
                        .frame(width: w * CGFloat(min(max(pct, 0), 100)) / 100,
                               height: 2)
                }
            }
            .frame(width: 140, height: 2)
        }
    }

    private func snippet(_ m: ChatMessage) -> String {
        switch m.kind {
        case .text:  return String(m.text.prefix(50))
        case .image: return L("Photo")
        case .audio: return L("Voice message")
        }
    }

    private func activityText(_ a: Activity) -> String {
        switch a {
        case .typing: return L("%@ is typing...", peer.nick)
        case .photo:  return L("%@ is sending a photo...", peer.nick)
        case .voice:  return L("%@ is recording a voice message...", peer.nick)
        }
    }

    private var lastMineID: UUID? {
        msgs.last(where: { $0.mine })?.id
    }

    @ViewBuilder
    private func row(_ m: ChatMessage) -> some View {
        VStack(alignment: m.mine ? .trailing : .leading, spacing: 2) {
            if let rid = m.replyTo,
               let orig = msgs.first(where: { $0.wireID == rid }) {
                HStack(spacing: 5) {
                    Rectangle().fill(Theme.accent).frame(width: 2, height: 14)
                    Text(snippet(orig))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
            }
            bubble(m)
            if let r = m.reaction {
                Text(r)
                    .font(.system(size: 13))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.surface(scheme), in: Capsule())
                    .overlay(Capsule().stroke(Theme.line(scheme), lineWidth: 0.5))
                    .padding(m.mine ? .trailing : .leading, 6)
            }
            if m.mine {
                if m.id == lastMineID {
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        tick(m, timed: true)
                    }
                } else {
                    tick(m, timed: false)
                }
            }
        }
    }

    private enum Tick { case sending, delivered, seen, failed }

    private func tickKind(_ m: ChatMessage, timed: Bool) -> Tick {
        if m.wireID != 0, (ble.seenUpTo[peer.id] ?? 0) >= m.wireID { return .seen }
        if m.delivered == true { return .delivered }
        if timed, Date().timeIntervalSince(m.date) > 25 { return .failed }
        return .sending
    }

    /// Small status tick under our message: clock (sending), one check
    /// (delivered), double accent check (seen), red ! (not delivered yet).
    @ViewBuilder
    private func tick(_ m: ChatMessage, timed: Bool) -> some View {
        let k = tickKind(m, timed: timed)
        HStack(spacing: 3) {
            switch k {
            case .sending:
                Image(systemName: "clock")
                    .foregroundStyle(Theme.muted(scheme))
            case .delivered:
                Image(systemName: "checkmark")
                    .foregroundStyle(Theme.muted(scheme))
            case .seen:
                HStack(spacing: -4) {
                    Image(systemName: "checkmark")
                    Image(systemName: "checkmark")
                }
                .foregroundStyle(Theme.accent)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.trailing, 4)
    }

    // MARK: Bubbles

    /// Turn plain text into an AttributedString with tappable links.
    static func linkified(_ s: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: s)
        let full = NSRange(location: 0, length: (s as NSString).length)
        if let det = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) {
            det.enumerateMatches(in: s, range: full) { m, _, _ in
                if let m, let url = m.url {
                    ns.addAttribute(.link, value: url, range: m.range)
                }
            }
        }
        return (try? AttributedString(
            ns, including: AttributeScopes.FoundationAttributes.self))
            ?? AttributedString(s)
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .text:
            Text(Self.linkified(m.text))
                .font(.system(size: 15))
                .foregroundStyle(m.mine ? .white : Theme.text(scheme))
                .tint(m.mine ? .white : Theme.accent)
                .padding(.vertical, 9).padding(.horizontal, 13)
                .background(m.mine ? Theme.accent : Theme.surface(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        case .image:
            if let d = m.data, let ui = UIImage(data: d) {
                Image(uiImage: ui)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 15)
                        .stroke(Theme.line(scheme), lineWidth: 0.5))
                    .onTapGesture { photoView = PhotoItem(image: ui) }
            } else {
                brokenBubble(L("Photo"))
            }
        case .audio:
            audioBubble(m)
        }
    }

    @ViewBuilder
    private func menu(_ m: ChatMessage) -> some View {
        Menu {
            ForEach(emojis, id: \.self) { e in
                Button(e) { ble.sendReaction(m, m.reaction == e ? "" : e) }
            }
            if m.reaction != nil {
                Button(role: .destructive) { ble.sendReaction(m, "") } label: {
                    Label(L("Remove reaction"), systemImage: "xmark")
                }
            }
        } label: { Label(L("React"), systemImage: "face.smiling") }
        Button { replyingTo = m; editing = nil } label: {
            Label(L("Reply"), systemImage: "arrowshape.turn.up.left")
        }
        if m.mine, m.wireID != 0, m.delivered != true,
           (ble.seenUpTo[peer.id] ?? 0) < m.wireID {
            Button { ble.resend(m) } label: {
                Label(L("Send again"),
                      systemImage: "arrow.clockwise")
            }
        }
        if m.mine && m.kind == .text {
            Button {
                editing = m
                replyingTo = nil
                draft = m.text
            } label: { Label(L("Edit"), systemImage: "pencil") }
        }
        Button(role: .destructive) {
            if editing?.id == m.id { editing = nil; draft = "" }
            ble.deleteMessage(m)
        } label: {
            Label(m.mine ? L("Delete for everyone") : L("Delete for me"),
                  systemImage: "trash")
        }
    }

    private func brokenBubble(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 14))
            .foregroundStyle(Theme.muted(scheme))
            .padding(.vertical, 9).padding(.horizontal, 13)
            .background(Theme.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    // Stable pseudo-random bar heights per message id (a little "waveform"
    // look without decoding the audio).
    private func bars(for id: UUID) -> [CGFloat] {
        var h = UInt64(truncatingIfNeeded: id.hashValue)
        return (0..<26).map { _ in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return 5 + CGFloat((h >> 33) % 19)
        }
    }

    private func timeStr(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func loadDuration(_ m: ChatMessage) {
        guard durations[m.id] == nil, let d = m.data else { return }
        durations[m.id] = (try? AVAudioPlayer(data: d))?.duration ?? 0
    }

    private func audioBubble(_ m: ChatMessage) -> some View {
        let isPlaying = player.playingID == m.id
        let fg: Color = m.mine ? .white : Theme.accent
        let dim = fg.opacity(0.3)
        let list = bars(for: m.id)
        let prog = isPlaying ? player.progress : 0
        let dur = durations[m.id] ?? 0
        let shown = (isPlaying && dur > 0) ? prog * dur : dur
        return Button {
            if let d = m.data {
                loadDuration(m)
                player.toggle(m.id, d)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(fg)
                HStack(spacing: 2.5) {
                    ForEach(Array(list.enumerated()), id: \.offset) { i, h in
                        Capsule()
                            .fill(!isPlaying
                                  ? fg
                                  : (Double(i) / Double(list.count) <= prog
                                     ? fg : dim))
                            .frame(width: 2.5, height: h)
                    }
                }
                .frame(height: 24)
                .animation(.linear(duration: 0.08), value: prog)
                Text(timeStr(shown))
                    .font(.system(size: 11, weight: .semibold)
                        .monospacedDigit())
                    .foregroundStyle(fg.opacity(0.9))
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(m.mine ? Theme.accent : Theme.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .onAppear { loadDuration(m) }
    }

    // MARK: Input

    private var hasText: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func timeString(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private func sendText() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let e = editing {
            ble.editMessage(e, newText: draft)
            editing = nil
        } else {
            ble.send(draft, to: peer.id, replyTo: replyingTo?.wireID ?? 0)
            replyingTo = nil
        }
        draft = ""
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            if recorder.isRecording {
                recordingLeft
            } else {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 34, height: 42)
                }
                TextField(L("Message"), text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 11).padding(.horizontal, 14)
                    .background(Theme.surface(scheme))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            rightControl
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.15), value: recorder.isRecording)
        .animation(.easeInOut(duration: 0.15), value: recorder.locked)
    }

    @ViewBuilder
    private var recordingLeft: some View {
        HStack(spacing: 10) {
            if recorder.locked {
                Button { recorder.stop(send: false) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17))
                        .foregroundStyle(.red)
                        .frame(width: 34, height: 42)
                }
            } else {
                Circle().fill(.red).frame(width: 9, height: 9)
            }
            Text(timeString(recorder.elapsed))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.text(scheme))
            liveWave
            Spacer(minLength: 0)
            if !recorder.locked {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text(willCancel ? L("Release to cancel")
                                     : L("Slide up to lock, left to cancel"))
                }
                .font(.system(size: 11, weight: willCancel ? .semibold : .regular))
                .foregroundStyle(willCancel ? .red : Theme.muted(scheme))
                .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
    }

    private var liveWave: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(wave.enumerated()), id: \.offset) { _, v in
                Capsule().fill(Theme.accent)
                    .frame(width: 2.5, height: 5 + v * 24)
            }
        }
        .frame(height: 30)
        .animation(.linear(duration: 0.05), value: wave)
    }

    @ViewBuilder
    private var rightControl: some View {
        if recorder.locked {
            Button { recorder.stop(send: true) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
        } else if hasText && !recorder.isRecording {
            Button { sendText() } label: {
                Image(systemName: editing == nil ? "arrow.up" : "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
        } else {
            micView
        }
    }

    private var micView: some View {
        ZStack {
            Circle()
                .fill(recorder.isRecording ? Color.red : Theme.accent)
                .frame(width: recorder.isRecording ? 54 : 42,
                       height: recorder.isRecording ? 54 : 42)
            Image(systemName: "mic.fill")
                .font(.system(size: recorder.isRecording ? 21 : 17,
                              weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 58, height: 58)
        .contentShape(Rectangle())
        .scaleEffect(1 + (recorder.isRecording ? min(recorder.level, 1) * 0.22 : 0))
        .overlay(alignment: .top) {
            if recorder.isRecording && !recorder.locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.accent, in: Circle())
                    .offset(y: -42)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !recorder.isRecording && !recorder.locked {
                        notice = nil
                        willCancel = false
                        recorder.start { blob in
                            if let blob {
                                ble.sendMedia(blob, image: false, to: peer.id)
                            }
                        }
                    }
                    guard recorder.isRecording && !recorder.locked else { return }
                    if v.translation.height < -70 {
                        recorder.lock()
                    } else if v.translation.width < -90 {
                        willCancel = false
                        recorder.stop(send: false)
                    } else {
                        willCancel = v.translation.width < -45
                    }
                }
                .onEnded { _ in
                    if recorder.locked { return }
                    if recorder.isRecording { recorder.stop(send: true) }
                    willCancel = false
                }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.7),
                   value: recorder.isRecording)
    }

    // MARK: Image compression (BLE is slow, keep it tiny)

    static func compressImage(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        func scaled(_ maxDim: CGFloat) -> UIImage {
            let s = min(1, maxDim / max(img.size.width, img.size.height))
            let sz = CGSize(width: img.size.width * s, height: img.size.height * s)
            let r = UIGraphicsImageRenderer(size: sz)
            return r.image { _ in img.draw(in: CGRect(origin: .zero, size: sz)) }
        }
        var out = scaled(384).jpegData(compressionQuality: 0.4)
        if let d = out, d.count > 60_000 {
            out = scaled(384).jpegData(compressionQuality: 0.3)
        }
        if let d = out, d.count > 90_000 {
            out = scaled(256).jpegData(compressionQuality: 0.35)
        }
        return out
    }
}

// MARK: - Audio helpers

final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var locked = false
    @Published var denied = false
    @Published var elapsed = 0
    @Published var level: CGFloat = 0          // 0...1 smoothed mic level
    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?
    private var onFinish: ((Data?) -> Void)?
    private var startAt = Date()
    private let maxSeconds = 30

    /// Begin recording (hold-to-talk). Asks for mic permission the first time.
    func start(_ onFinish: @escaping (Data?) -> Void) {
        guard !isRecording else { return }
        self.onFinish = onFinish
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    self.denied = true
                    self.onFinish = nil
                    return
                }
                self.denied = false
                do {
                    let s = AVAudioSession.sharedInstance()
                    try s.setCategory(.playAndRecord, options: [.defaultToSpeaker])
                    try s.setActive(true)
                    let u = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ly_\(UUID().uuidString).m4a")
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 24000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 32000,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                    ]
                    let r = try AVAudioRecorder(url: u, settings: settings)
                    r.isMeteringEnabled = true
                    r.record()
                    self.rec = r
                    self.url = u
                    self.isRecording = true
                    self.locked = false
                    self.elapsed = 0
                    self.level = 0
                    self.startAt = Date()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 0.05,
                                                      repeats: true) { _ in
                        self.poll()
                    }
                } catch {
                    self.finish(send: false)
                }
            }
        }
    }

    private func poll() {
        guard let r = rec else { return }
        r.updateMeters()
        let db = CGFloat(r.averagePower(forChannel: 0))     // ~ -160...0
        let norm = max(0, min(1, (db + 50) / 50))           // -50dB..0dB -> 0..1
        level = level * 0.6 + norm * 0.4                    // smooth
        let e = Int(Date().timeIntervalSince(startAt))
        if e != elapsed { elapsed = e }
        if e >= maxSeconds { finish(send: true) }
    }

    func lock() {
        guard isRecording else { return }
        locked = true
    }

    /// Stop recording. send=true delivers the clip, send=false discards it.
    func stop(send: Bool) {
        guard isRecording else { return }
        finish(send: send)
    }

    private func finish(send: Bool) {
        timer?.invalidate(); timer = nil
        rec?.stop(); rec = nil
        isRecording = false
        locked = false
        level = 0
        let cb = onFinish
        onFinish = nil
        guard send else {
            url.flatMap { try? FileManager.default.removeItem(at: $0) }
            return
        }
        let d = url.flatMap { try? Data(contentsOf: $0) }
        // Drop accidental taps and oversized clips BLE cannot move sensibly.
        if let d, d.count > 1200, d.count <= 200_000 { cb?(d) }
        else { cb?(nil) }
    }
}

final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingID: UUID?
    @Published var progress: Double = 0      // 0...1 of the playing clip
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ id: UUID, _ data: Data) {
        if playingID == id { stop(); return }
        stop()
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback)
            try s.setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.play()
            player = p
            playingID = id
            progress = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05,
                                         repeats: true) { [weak self] _ in
                guard let self, let pl = self.player, pl.duration > 0 else { return }
                self.progress = min(1, pl.currentTime / pl.duration)
            }
        } catch {
            playingID = nil
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully f: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}

/// Wrapper so a UIImage can be presented in `.fullScreenCover(item:)`.
struct PhotoItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Fullscreen photo viewer with pinch zoom, drag-to-pan and a share
/// sheet (which includes Save Image).
struct PhotoViewer: View {
    let image: UIImage
    var onClose: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable().scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in
                            scale = max(1, min(4, lastScale * v))
                        }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1 {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    offset = .zero; lastOffset = .zero
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(
                                width: lastOffset.width + v.translation.width,
                                height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if scale > 1 {
                            scale = 1; lastScale = 1
                            offset = .zero; lastOffset = .zero
                        } else {
                            scale = 2; lastScale = 2
                        }
                    }
                }
            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    ShareLink(
                        item: Image(uiImage: image),
                        preview: SharePreview("Photo",
                                              image: Image(uiImage: image))
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 6)
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Three little bouncing dots, like a real messenger's "typing" bubble.
struct TypingDots: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .opacity(on ? 1 : 0.25)
                    .scaleEffect(on ? 1 : 0.6)
                    .animation(.easeInOut(duration: 0.5).repeatForever()
                        .delay(Double(i) * 0.15), value: on)
            }
        }
        .onAppear { on = true }
    }
}
