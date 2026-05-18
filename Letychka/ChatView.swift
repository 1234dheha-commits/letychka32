import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct ChatView: View {
    @ObservedObject var ble: BLEMessenger
    let peer: Peer
    @Environment(\.colorScheme) private var scheme
    @State private var draft = ""
    @State private var photoItem: PhotosPickerItem?
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var player = AudioPlayer()
    @State private var notice: String?
    @State private var editing: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var lastTyped = Date.distantPast
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
                Text("Receiving media \(pct)%")
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
                Text("\(peer.nick) is typing...")
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
                    Text("Editing message")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                    Spacer()
                    Button("Cancel") { editing = nil; draft = "" }
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
                    Text("Reply: \(snippet(r))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted(scheme))
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") { replyingTo = nil }
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
                    else { notice = "Could not attach that photo" }
                    photoItem = nil
                }
            }
        }
    }

    // MARK: Row (reply preview + bubble + reaction + seen)

    private func snippet(_ m: ChatMessage) -> String {
        switch m.kind {
        case .text:  return String(m.text.prefix(50))
        case .image: return "Photo"
        case .audio: return "Voice message"
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
                .overlay(alignment: m.mine ? .bottomLeading : .bottomTrailing) {
                    if let r = m.reaction {
                        Text(r)
                            .font(.system(size: 14))
                            .padding(3)
                            .background(Theme.bg(scheme), in: Circle())
                            .overlay(Circle().stroke(Theme.line(scheme),
                                                     lineWidth: 0.5))
                            .offset(x: m.mine ? -8 : 8, y: 9)
                    }
                }
            if m.mine, m.id == lastMineID, m.wireID != 0,
               let up = ble.seenUpTo[peer.id], m.wireID <= up {
                Text("Seen")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted(scheme))
                    .padding(.trailing, 4)
            }
        }
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubble(_ m: ChatMessage) -> some View {
        switch m.kind {
        case .text:
            Text(m.text)
                .font(.system(size: 15))
                .foregroundStyle(m.mine ? .white : Theme.text(scheme))
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
                brokenBubble("Photo")
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
                    Label("Remove reaction", systemImage: "xmark")
                }
            }
        } label: { Label("React", systemImage: "face.smiling") }
        Button { replyingTo = m; editing = nil } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        if m.mine && m.kind == .text {
            Button {
                editing = m
                replyingTo = nil
                draft = m.text
            } label: { Label("Edit", systemImage: "pencil") }
        }
        Button(role: .destructive) {
            if editing?.id == m.id { editing = nil; draft = "" }
            ble.deleteMessage(m)
        } label: {
            Label(m.mine ? "Delete for everyone" : "Delete for me",
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

    private func audioBubble(_ m: ChatMessage) -> some View {
        let isPlaying = player.playingID == m.id
        return Button {
            if let d = m.data { player.toggle(m.id, d) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(m.mine ? .white : Theme.accent)
                Image(systemName: "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(m.mine ? .white : Theme.text(scheme))
                Text("Voice message")
                    .font(.system(size: 14))
                    .foregroundStyle(m.mine ? .white : Theme.text(scheme))
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(m.mine ? Theme.accent : Theme.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 42)
            }
            Button {
                notice = nil
                recorder.toggle { blob in
                    if let blob { ble.sendMedia(blob, image: false, to: peer.id) }
                    else { notice = "Microphone access is needed for voice messages" }
                }
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                    .font(.system(size: 19))
                    .foregroundStyle(recorder.isRecording ? .red : Theme.accent)
                    .frame(width: 34, height: 42)
            }
            if recorder.isRecording {
                Text("\(recorder.elapsed)s")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 26)
            }
            TextField("Message", text: $draft)
                .textFieldStyle(.plain)
                .padding(.vertical, 11).padding(.horizontal, 14)
                .background(Theme.surface(scheme))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Button {
                let t = draft.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                if let e = editing {
                    ble.editMessage(e, newText: draft)
                    editing = nil
                } else {
                    ble.send(draft, to: peer.id,
                             replyTo: replyingTo?.wireID ?? 0)
                    replyingTo = nil
                }
                draft = ""
            } label: {
                Image(systemName: editing == nil ? "arrow.up" : "checkmark")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Theme.accent)
                    .clipShape(Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
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
    @Published var elapsed = 0
    private var rec: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL?

    func toggle(_ onFinish: @escaping (Data?) -> Void) {
        if isRecording { finish(onFinish) } else { begin(onFinish) }
    }

    private func begin(_ onFinish: @escaping (Data?) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else { onFinish(nil); return }
                do {
                    let s = AVAudioSession.sharedInstance()
                    try s.setCategory(.playAndRecord, options: [.defaultToSpeaker])
                    try s.setActive(true)
                    let u = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ly_\(UUID().uuidString).m4a")
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 12000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 16000,
                        AVEncoderAudioQualityKey: AVAudioQuality.low.rawValue
                    ]
                    let r = try AVAudioRecorder(url: u, settings: settings)
                    r.record()
                    self.rec = r
                    self.url = u
                    self.isRecording = true
                    self.elapsed = 0
                    self.timer = Timer.scheduledTimer(withTimeInterval: 1,
                                                      repeats: true) { _ in
                        self.elapsed += 1
                        if self.elapsed >= 8 { self.finish(onFinish) }
                    }
                } catch {
                    onFinish(nil)
                }
            }
        }
    }

    private func finish(_ onFinish: @escaping (Data?) -> Void) {
        timer?.invalidate(); timer = nil
        rec?.stop(); rec = nil
        isRecording = false
        let d = url.flatMap { try? Data(contentsOf: $0) }
        // Cap: ignore empty/oversized clips that BLE cannot move sensibly.
        if let d, d.count > 0, d.count <= 200_000 { onFinish(d) }
        else { onFinish(nil) }
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
