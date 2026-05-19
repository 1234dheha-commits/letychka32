import SwiftUI
import PhotosUI
import AVFoundation
import Speech
import UIKit

struct ChatView: View {
    @ObservedObject var ble: BLEMessenger
    let peer: Peer
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var player = AudioPlayer()
    @StateObject private var stt = SpeechTranscriber()
    @State private var notice: String?
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var lastTyped = Date.distantPast
    @State private var willCancel = false
    @State private var wave: [CGFloat] = Array(repeating: 0.06, count: 26)
    private let emojis = ["👍", "❤️", "😂", "🔥", "😮", "😢"]

    private var msgs: [ChatMessage] { ble.messages(with: peer.id) }
    private var receiving: Int? { ble.incoming[peer.id] }

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

            if let pct = receiving {
                Text(L("Receiving media %d%%", pct))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 6)
            }
            if let notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 6)
            }

            if ble.isTyping(peer.id) {
                Text(L("%@ is typing...", peer.nick))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.top, 6)
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
        .navigationTitle(peer.nick)
        .navigationBarTitleDisplayMode(.inline)
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
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                let blob = data.flatMap { Self.compressImage($0) }
                await MainActor.run {
                    if let blob { ble.sendMedia(blob, image: true, to: peer.id) }
                    else { notice = L("Could not attach that photo") }
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
            if !on { wave = Array(repeating: 0.06, count: wave.count) }
        }
        .onChange(of: recorder.denied) { _, d in
            if d { notice = L("Microphone access is needed for voice messages") }
        }
    }

    // MARK: Row (reply preview + bubble + reaction + seen)

    private func snippet(_ m: ChatMessage) -> String {
        switch m.kind {
        case .text:  return String(m.text.prefix(50))
        case .image: return L("Photo")
        case .audio: return L("Voice message")
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
            if m.kind == .audio { transcriptView(m) }
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
        if m.kind == .audio, ble.transcripts[m.id] == nil,
           !stt.busy.contains(m.id) {
            Button {
                stt.transcribe(m, langCode: Lang.code, into: ble)
            } label: {
                Label(L("Transcribe to text"), systemImage: "text.quote")
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
        return (0..<22).map { _ in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            return 6 + CGFloat((h >> 33) % 18)
        }
    }

    private func audioBubble(_ m: ChatMessage) -> some View {
        let isPlaying = player.playingID == m.id
        let fg: Color = m.mine ? .white : Theme.accent
        return Button {
            if let d = m.data { player.toggle(m.id, d) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(fg)
                HStack(spacing: 2.5) {
                    ForEach(Array(bars(for: m.id).enumerated()), id: \.offset) { _, h in
                        Capsule().fill(fg.opacity(0.85))
                            .frame(width: 2.5, height: h)
                    }
                }
                .frame(height: 24)
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(m.mine ? Theme.accent : Theme.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// On-device speech-to-text shown under a voice bubble.
    @ViewBuilder
    private func transcriptView(_ m: ChatMessage) -> some View {
        if stt.busy.contains(m.id) {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text(L("Transcribing...")).font(.system(size: 12))
                    .foregroundStyle(Theme.muted(scheme))
            }
            .padding(.horizontal, 4).padding(.top, 2)
        } else if let t = ble.transcripts[m.id] {
            Text(t)
                .font(.system(size: 14))
                .foregroundStyle(Theme.text(scheme))
                .padding(.vertical, 7).padding(.horizontal, 11)
                .background(Theme.surface(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.line(scheme), lineWidth: 0.5))
                .frame(maxWidth: 240,
                       alignment: m.mine ? .trailing : .leading)
                .padding(m.mine ? .trailing : .leading, 2)
                .textSelection(.enabled)
        } else if let e = stt.failed[m.id] {
            Text(e)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted(scheme))
                .frame(maxWidth: 240,
                       alignment: m.mine ? .trailing : .leading)
                .padding(.horizontal, 4).padding(.top, 2)
        }
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
    private var player: AVAudioPlayer?

    func toggle(_ id: UUID, _ data: Data) {
        if playingID == id { stop(); return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback)
            try s.setActive(true)
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            p.play()
            player = p
            playingID = id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully f: Bool) {
        DispatchQueue.main.async { self.playingID = nil }
    }
}

/// Voice-to-text that stays true to the app's promise: recognition is forced
/// ON-DEVICE (`requiresOnDeviceRecognition`), so the audio never leaves the
/// phone and no server/internet is used. If a language has no offline model
/// we say so honestly instead of falling back to Apple's servers.
final class SpeechTranscriber: ObservableObject {
    @Published var busy: Set<UUID> = []
    @Published var failed: [UUID: String] = [:]

    func transcribe(_ m: ChatMessage, langCode: String, into ble: BLEMessenger) {
        guard m.kind == .audio, let data = m.data else { return }
        guard !busy.contains(m.id), ble.transcripts[m.id] == nil else { return }
        busy.insert(m.id)
        failed[m.id] = nil
        let locales = Self.candidateLocales(langCode)

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.fail(m.id, L("Allow speech recognition in Settings to transcribe"))
                    return
                }
                guard let rec = Self.onDeviceRecognizer(locales) else {
                    self.fail(m.id, L("Offline transcription is not available for this language"))
                    return
                }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tr_\(m.id.uuidString).m4a")
                do { try data.write(to: url) }
                catch {
                    self.fail(m.id, L("Could not transcribe this voice message"))
                    return
                }
                let req = SFSpeechURLRecognitionRequest(url: url)
                req.requiresOnDeviceRecognition = true
                req.shouldReportPartialResults = false
                if #available(iOS 16.0, *) { req.addsPunctuation = true }
                rec.recognitionTask(with: req) { result, error in
                    if let result, result.isFinal {
                        let text = result.bestTranscription.formattedString
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        DispatchQueue.main.async {
                            ble.transcripts[m.id] = text.isEmpty
                                ? L("No speech recognized") : text
                            self.busy.remove(m.id)
                            try? FileManager.default.removeItem(at: url)
                        }
                    } else if error != nil {
                        DispatchQueue.main.async {
                            self.fail(m.id, L("Could not transcribe this voice message"))
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
        }
    }

    private func fail(_ id: UUID, _ msg: String) {
        busy.remove(id)
        failed[id] = msg
    }

    /// Best-guess spoken language: the chosen app language, else the phone's.
    private static func candidateLocales(_ code: String) -> [Locale] {
        switch code {
        case "en": return [Locale(identifier: "en-US")]
        case "ru": return [Locale(identifier: "ru-RU")]
        case "uk": return [Locale(identifier: "uk-UA")]
        default:
            let pref = Locale.preferredLanguages.first ?? "en-US"
            return [Locale(identifier: pref), Locale(identifier: "en-US")]
        }
    }

    /// Only return a recognizer that can run fully offline.
    private static func onDeviceRecognizer(_ locales: [Locale]) -> SFSpeechRecognizer? {
        for l in locales {
            if let r = SFSpeechRecognizer(locale: l),
               r.isAvailable, r.supportsOnDeviceRecognition {
                return r
            }
        }
        return nil
    }
}
