// Records a voice note with AVAudioRecorder (AAC in an .m4a, mono) into a
// temp file the CLI then sends with `allman send --audio`. The app never
// talks to LinkedIn itself.

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceRecorder: NSObject, AVAudioRecorderDelegate {
    enum State: Equatable {
        case idle
        case recording
        case recorded(URL, Int)   // file, duration in ms
    }

    private(set) var state: State = .idle
    /// Dev snapshots only: every recorder mirrors this when set (no microphone involved).
    static var debugState: State?
    private(set) var duration: TimeInterval = 0
    /// 0…1, from the recorder's average power, smoothed for the meter.
    private(set) var level: Float = 0
    private(set) var error: String?

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private(set) var isPlaying = false

    var isRecording: Bool { effectiveState == .recording }
    var hasRecording: Bool { if case .recorded = effectiveState { return true } else { return false } }
    var effectiveState: State { Self.debugState ?? state }

    /// Called by the composer so the debug state is observed.
    func syncDebug() {
        guard let d = Self.debugState else {
            if case .recorded = state, recorder == nil, player == nil { state = .idle; duration = 0 } // snapshot cleanup
            return
        }
        state = d
        if case .recorded(_, let ms) = d { duration = Double(ms) / 1000 }
        if d == .recording { duration = 7; level = 0.6 }
    }

    func start() async {
        error = nil
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else {
            error = "Microphone access is off for Allman (System Settings → Privacy & Security → Microphone)."
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("allman-voice-\(Int(Date().timeIntervalSince1970)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.record() else { error = "Couldn't start recording."; return }
            recorder = r
            duration = 0
            level = 0
            state = .recording
            ticker = Task { @MainActor [weak self] in
                while let self, self.state == .recording, let r = self.recorder {
                    r.updateMeters()
                    // -160…0 dB → 0…1, biased so speech reads as a lively meter.
                    let db = max(-50, r.averagePower(forChannel: 0))
                    let target = Float((db + 50) / 50)
                    self.level = self.level * 0.6 + target * 0.4
                    self.duration = r.currentTime
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        } catch {
            self.error = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard let r = recorder, state == .recording else { return }
        ticker?.cancel(); ticker = nil
        let secs = r.currentTime
        r.stop()
        recorder = nil
        level = 0
        if secs < 0.5 {
            try? FileManager.default.removeItem(at: r.url)
            state = .idle
            error = "Too short — hold the mic a little longer."
            return
        }
        duration = secs
        state = .recorded(r.url, Int(secs * 1000))
    }

    func discard() {
        ticker?.cancel(); ticker = nil
        player?.stop(); player = nil; isPlaying = false
        if let r = recorder { r.stop(); try? FileManager.default.removeItem(at: r.url); recorder = nil }
        if case .recorded(let url, _) = state { try? FileManager.default.removeItem(at: url) }
        state = .idle
        duration = 0
        level = 0
    }

    /// Hand the file off (the sender owns deleting it afterwards) and reset.
    func take() -> (URL, Int)? {
        guard case .recorded(let url, let ms) = state else { return nil }
        player?.stop(); player = nil; isPlaying = false
        state = .idle
        duration = 0
        return (url, ms)
    }

    func togglePreview() {
        guard case .recorded(let url, _) = state else { return }
        if isPlaying { player?.stop(); isPlaying = false; return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.play()
        isPlaying = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(p.duration * 1000) + 100))
            if self?.player === p { self?.isPlaying = false }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.error = error?.localizedDescription ?? "Recording failed"; self.discard() }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
