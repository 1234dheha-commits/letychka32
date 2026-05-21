import Foundation
import AVFoundation
import Combine

/// Records short voice notes to a temp .m4a using AAC at 32 kbps. Push-to-talk
/// style: caller calls `start()`, then `stop()` which returns `(data, ms)`.
/// On any failure returns nil so the chat just doesn't send.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    /// Live elapsed time while recording (updated by the meter timer).
    @Published var elapsedMs: Int = 0

    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var startedAt: Date?
    private var meterTimer: Timer?

    /// Asks for mic permission and starts recording into a temp file. Returns
    /// true if recording is actually in progress. If permission is denied or
    /// the session can't be configured, returns false.
    func start() async -> Bool {
        guard await Self.requestMicPermission() else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker,
                                              .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("VoiceRecorder: session setup failed: \(error)")
            return false
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey:           Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey:         22_050.0,
            AVNumberOfChannelsKey:   1,
            AVEncoderBitRateKey:     32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: file, settings: settings)
            r.isMeteringEnabled = false
            guard r.record() else { return false }
            recorder = r
            url = file
            startedAt = Date()
            isRecording = true
            elapsedMs = 0
            // 100ms timer just updates `elapsedMs` so the UI can show a
            // ticking duration without subscribing to AVAudioRecorder.
            meterTimer = Timer.scheduledTimer(
                withTimeInterval: 0.1, repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let s = self.startedAt else { return }
                    self.elapsedMs = Int(Date().timeIntervalSince(s) * 1000)
                }
            }
            return true
        } catch {
            print("VoiceRecorder: start failed: \(error)")
            return false
        }
    }

    /// Stops the active recording and returns the encoded `.m4a` bytes
    /// together with the duration in ms. Cleans up the temp file.
    /// Returns nil if there was no active recording, or the file is too
    /// short to be a real message (< 400 ms = accidental tap).
    func stop() -> (data: Data, ms: Int)? {
        guard let r = recorder, let f = url else { return nil }
        r.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        let ms = startedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            ?? elapsedMs
        recorder = nil
        startedAt = nil
        // Best-effort deactivate so other audio (music, calls) resumes.
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
        defer { try? FileManager.default.removeItem(at: f) }
        guard ms >= 400 else { return nil }
        guard let data = try? Data(contentsOf: f) else { return nil }
        return (data, ms)
    }

    /// Throw away the current recording without sending. Used when the user
    /// cancels a hold-to-record by dragging away from the button.
    func cancel() {
        recorder?.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        if let f = url { try? FileManager.default.removeItem(at: f) }
        recorder = nil
        url = nil
        startedAt = nil
        elapsedMs = 0
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false,
            options: .notifyOthersOnDeactivation)
    }

    private static func requestMicPermission() async -> Bool {
        if #available(iOS 17, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:    return true
            case .denied:     return false
            case .undetermined:
                return await AVAudioApplication.requestRecordPermission()
            @unknown default: return false
            }
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { ok in
                    cont.resume(returning: ok)
                }
            }
        }
    }
}

/// Single-instance audio playback used by all voice bubbles. Only one voice
/// can play at a time; tapping another voice bubble takes over. Publishes
/// `playingURL` so each bubble can highlight itself when it's the active one.
@MainActor
final class VoicePlayer: NSObject, ObservableObject {
    static let shared = VoicePlayer()

    @Published private(set) var playingURL: String?
    /// 0...1 progress for the active clip. Bubbles read this to draw the
    /// playback indicator. -1 = nothing playing.
    @Published private(set) var progress: Double = -1

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    /// Start playing `urlString`. If the same URL is already playing, pauses
    /// it (toggle behaviour, like Telegram). If a different one is playing
    /// the old one is stopped first.
    func toggle(_ urlString: String) {
        if playingURL == urlString {
            stop()
            return
        }
        stop()
        guard let u = URL(string: urlString) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("VoicePlayer: session setup failed: \(error)")
            return
        }
        let item = AVPlayerItem(url: u)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] t in
            guard let self else { return }
            let dur = item.duration.seconds
            if dur.isFinite && dur > 0 {
                self.progress = max(0, min(1, t.seconds / dur))
            }
        }
        player = p
        playingURL = urlString
        progress = 0
        p.play()
    }

    func stop() {
        if let o = timeObserver { player?.removeTimeObserver(o) }
        timeObserver = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        player = nil
        playingURL = nil
        progress = -1
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }
}
