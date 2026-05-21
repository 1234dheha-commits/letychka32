import SwiftUI
import PhotosUI
import UIKit

/// Chat surface for the Global mode. Supports text, photo and voice messages.
/// Subscribes to a light 2s polling loop in `Global.openChat` for incoming
/// updates; reads its own messages back through the server too so all clients
/// see the same canonical row.
struct GlobalChatView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var g = Global.shared
    @StateObject private var rec = VoiceRecorder()
    @ObservedObject private var player = VoicePlayer.shared
    /// The row at the time we navigated in. Used as a fallback when the
    /// live row is briefly missing (e.g. while a just-created group is
    /// still propagating into `g.chats`).
    let initialRow: Global.ChatRow

    @State private var input: String = ""
    @State private var showInfo = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var fullscreenURL: String?
    /// "Recording…" overlay drag offset to cancel; negative = sliding left.
    @State private var recDragX: CGFloat = 0
    @State private var sendingMedia = false

    init(row: Global.ChatRow) { self.initialRow = row }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var row: Global.ChatRow {
        g.chats.first(where: { $0.chat.id == initialRow.chat.id })
            ?? initialRow
    }

    private var msgs: [Global.Message] { g.messages[row.chat.id] ?? [] }

    private var title: String {
        let myID = g.me?.id ?? UUID()
        if let other = row.otherParty(me: myID) {
            return other.display_name?.isEmpty == false
                ? (other.display_name ?? "")
                : other.username
        }
        return row.chat.name ?? L("Group chat")
    }

    /// "online" / "last seen X ago" text for the principal toolbar. Returns
    /// nil for group chats and for direct chats where the other party has
    /// hidden their online status.
    private var subtitle: String? {
        let myID = g.me?.id ?? UUID()
        guard let other = row.otherParty(me: myID) else { return nil }
        // Other side hides presence -> no subtitle (Telegram-like).
        if other.online_visible == false { return nil }
        guard let seen = other.last_seen_at else { return nil }
        let delta = Date().timeIntervalSince(seen)
        if delta < 90 { return L("online") }
        return L("last seen %@", Self.lastSeenRel(delta))
    }

    var body: some View {
        ZStack {
            Theme.bg(scheme).ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(msgs) { m in
                                bubble(m).id(m.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: msgs.count) { _, _ in
                        if let last = msgs.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                composer
            }
            if rec.isRecording { recordingOverlay }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text(scheme))
                    if let s = subtitle {
                        Text(s)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted(scheme))
                    }
                }
            }
            if row.chat.kind == .group {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showInfo = true } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
        }
        .navigationDestination(isPresented: $showInfo) {
            GroupSettingsView(row: row)
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { ui in
                showCamera = false
                if let ui { Task { await sendImage(ui) } }
            }
        }
        .fullScreenCover(item: Binding(
            get: { fullscreenURL.map { Identified(value: $0) } },
            set: { fullscreenURL = $0?.value }
        )) { ident in
            ImageViewer(urlString: ident.value) { fullscreenURL = nil }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    await sendImage(ui)
                }
                photoItem = nil
            }
        }
        .task {
            await g.openChat(row.chat.id)
            await g.markChatRead(row.chat.id)
        }
        .onChange(of: msgs.count) { _, _ in
            Task { await g.markChatRead(row.chat.id) }
        }
        .onDisappear { Task { await g.closeChat() } }
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubble(_ m: Global.Message) -> some View {
        let mine = m.sender_id == g.me?.id
        HStack {
            if mine { Spacer(minLength: 50) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                switch m.effectiveKind {
                case .text:  textBubble(m, mine: mine)
                case .image: imageBubble(m, mine: mine)
                case .audio: audioBubble(m, mine: mine)
                }
                HStack(spacing: 4) {
                    Text(Self.timeFmt.string(from: m.created_at))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted(scheme))
                    if mine { readIcon(for: m) }
                }
                .padding(.horizontal, 4)
            }
            if !mine { Spacer(minLength: 50) }
        }
    }

    @ViewBuilder
    private func textBubble(_ m: Global.Message, mine: Bool) -> some View {
        Text(m.body ?? "")
            .font(.system(size: 15))
            .foregroundStyle(mine ? .white : Theme.text(scheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                mine ? Theme.accent : Theme.surface(scheme),
                in: RoundedRectangle(cornerRadius: 16)
            )
    }

    @ViewBuilder
    private func imageBubble(_ m: Global.Message, mine: Bool) -> some View {
        let aspect: CGFloat = {
            let w = CGFloat(m.width ?? 4)
            let h = CGFloat(m.height ?? 3)
            return max(0.5, min(2.0, w / max(1, h)))
        }()
        let url = m.media_url.flatMap(URL.init(string:))
        Button { fullscreenURL = m.media_url } label: {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    Image(systemName: "photo")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.muted(scheme))
                default:
                    ProgressView()
                }
            }
            .frame(width: 220, height: 220 / aspect)
            .background(Theme.surface(scheme))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func audioBubble(_ m: Global.Message, mine: Bool) -> some View {
        let urlStr = m.media_url ?? ""
        let isPlaying = player.playingURL == urlStr
        let progress: Double = isPlaying ? max(0, player.progress) : 0
        let durSec = Double(m.duration_ms ?? 0) / 1000.0
        HStack(spacing: 10) {
            Button { player.toggle(urlStr) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(mine ? Theme.accent : .white)
                    .frame(width: 32, height: 32)
                    .background(mine ? .white : Theme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            // 24 little bars; the leading ones fill as playback progresses.
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { i in
                    let filled = Double(i) / 24.0 <= progress
                    Capsule()
                        .fill(filled
                              ? (mine ? Color.white : Theme.accent)
                              : (mine ? Color.white.opacity(0.5)
                                      : Theme.muted(scheme).opacity(0.4)))
                        .frame(width: 2,
                               height: CGFloat([6, 10, 14, 18, 14, 10, 8,
                                                12, 16, 12, 8, 14, 18, 14,
                                                10, 6, 8, 12, 16, 14, 10,
                                                8, 6, 4][i]))
                }
            }
            Text(Self.formatDuration(durSec))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mine ? .white : Theme.muted(scheme))
                .frame(minWidth: 34, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            mine ? Theme.accent : Theme.surface(scheme),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    /// One check = on the server (delivered). Two checks = at least one
    /// other member has opened the chat after this message arrived.
    @ViewBuilder
    private func readIcon(for m: Global.Message) -> some View {
        let cutoff = row.othersReadCutoff(me: g.me?.id ?? UUID())
        let read = (cutoff ?? .distantPast) >= m.created_at
        Image(systemName: read ? "checkmark.circle.fill" : "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(read ? Theme.accent : Theme.muted(scheme))
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Plus menu: gallery / camera.
            Menu {
                PhotosPicker(selection: $photoItem,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Label(L("Photo from library"),
                          systemImage: "photo.on.rectangle")
                }
                Button {
                    showCamera = true
                } label: {
                    Label(L("Take photo"), systemImage: "camera")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 36, height: 36)
            }
            .disabled(sendingMedia || rec.isRecording)

            TextField(L("Message"), text: $input, axis: .vertical)
                .lineLimit(1...4)
                .padding(10)
                .background(Theme.surface(scheme),
                            in: RoundedRectangle(cornerRadius: 18))
                .disabled(rec.isRecording)

            // Send when text exists, otherwise hold-to-record mic.
            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    let t = input
                    input = ""
                    Task { await g.sendText(t, to: row.chat.id) }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: Circle())
                }
            } else {
                micButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.bg(scheme))
    }

    /// Push-and-hold mic. Releases sends; sliding left far enough cancels.
    private var micButton: some View {
        Image(systemName: rec.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(rec.isRecording ? Color.red : Theme.accent, in: Circle())
            .scaleEffect(rec.isRecording ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: rec.isRecording)
            .gesture(
                LongPressGesture(minimumDuration: 0.15)
                    .onEnded { _ in
                        Task {
                            let ok = await rec.start()
                            if !ok { rec.cancel() }
                        }
                    }
                    .simultaneously(with:
                        DragGesture(minimumDistance: 0,
                                    coordinateSpace: .local)
                            .onChanged { v in
                                if rec.isRecording { recDragX = v.translation.width }
                            }
                            .onEnded { v in
                                if rec.isRecording {
                                    if v.translation.width < -80 {
                                        rec.cancel()
                                    } else {
                                        finishRecording()
                                    }
                                }
                                recDragX = 0
                            }
                    )
            )
    }

    /// Big red "Recording 0:03   ← slide to cancel" strip drawn on top of
    /// the chat while the mic button is held.
    private var recordingOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                    .opacity(rec.elapsedMs / 500 % 2 == 0 ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.4)
                        .repeatForever(autoreverses: true), value: rec.elapsedMs)
                Text(Self.formatDuration(Double(rec.elapsedMs) / 1000))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text(scheme))
                    .monospacedDigit()
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text(L("Slide to cancel"))
                        .font(.system(size: 13))
                }
                .foregroundStyle(Theme.muted(scheme))
                .offset(x: max(-40, min(0, recDragX / 3)))
                .opacity(recDragX < -40 ? 0.3 : 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Theme.surface(scheme),
                        in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 14)
            .padding(.bottom, 64)
        }
        .allowsHitTesting(false)
    }

    private func finishRecording() {
        guard let r = rec.stop() else { return }
        sendingMedia = true
        Task {
            await g.sendAudio(r.data, durationMs: r.ms, to: row.chat.id)
            sendingMedia = false
        }
    }

    /// Resize the picked image to <= 1600 px on the long side, JPEG q 0.78.
    /// Keeps uploads small while staying sharp enough on any modern phone.
    private func sendImage(_ image: UIImage) async {
        let maxDim: CGFloat = 1600
        let s = min(1, maxDim / max(image.size.width, image.size.height))
        let sz = CGSize(width: image.size.width * s,
                        height: image.size.height * s)
        let renderer = UIGraphicsImageRenderer(size: sz)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: sz))
        }
        guard let data = resized.jpegData(compressionQuality: 0.78) else { return }
        sendingMedia = true
        await g.sendImage(data,
                          width: Int(sz.width), height: Int(sz.height),
                          to: row.chat.id)
        sendingMedia = false
    }

    // MARK: Helpers

    static func formatDuration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Coarse "5m / 2h / yesterday / 21 May" relative format for last_seen.
    private static func lastSeenRel(_ delta: TimeInterval) -> String {
        let m = Int(delta / 60)
        if m < 60 { return L("%d min ago", max(1, m)) }
        let h = m / 60
        if h < 24 { return L("%d h ago", h) }
        let d = h / 24
        if d == 1 { return L("yesterday") }
        if d < 7 { return L("%d d ago", d) }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: Date().addingTimeInterval(-delta))
    }
}

/// Tiny wrapper so we can use `fullScreenCover(item:)` with a plain String.
private struct Identified: Identifiable, Hashable {
    let value: String
    var id: String { value }
}

/// UIKit camera bridge. PhotosPicker handles the library; for the camera we
/// still need UIImagePickerController because iOS has no SwiftUI-native camera
/// type that ships in the SDK.
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        p.allowsEditing = false
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController,
                                context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onPick: (UIImage?) -> Void
        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]
        ) {
            let img = info[.originalImage] as? UIImage
            onPick(img)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPick(nil)
        }
    }
}

/// Pinch-to-zoom, tap-to-dismiss fullscreen image viewer.
struct ImageViewer: View {
    let urlString: String
    var onDone: () -> Void
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { v in
                                        scale = max(1, min(5, lastScale * v))
                                    }
                                    .onEnded { _ in lastScale = scale }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation { scale = scale > 1 ? 1 : 2 }
                                lastScale = scale
                            }
                    default:
                        ProgressView().tint(.white)
                    }
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button { onDone() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.black.opacity(0.6), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(16)
        }
        .onTapGesture { if scale == 1 { onDone() } }
    }
}
