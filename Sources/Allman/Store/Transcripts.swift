// On-device transcripts for voice notes (Speech framework, no network). Results
// are cached per media file under Application Support so each note is
// recognized once.

import Foundation
import Observation
import Speech

@MainActor
@Observable
final class TranscriptStore {
    static let enabledKey = "transcribeVoiceNotes"

    private(set) var transcripts: [String: String] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var failed: [String: String] = [:]
    private(set) var authorization: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
    private let fileURL: URL

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    init(fileURL: URL = StorePaths.appSupportURL.appendingPathComponent("transcripts.json")) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL), let d = try? JSONDecoder().decode([String: String].self, from: data) { transcripts = d }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(transcripts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func key(for url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    func transcript(for url: URL) -> String? { transcripts[Self.key(for: url)] }

    /// Recognize the file once; later calls return immediately.
    func transcribe(_ url: URL) {
        let key = Self.key(for: url)
        guard isEnabled, transcripts[key] == nil, !inFlight.contains(key), failed[key] == nil else { return }
        inFlight.insert(key)
        Task { @MainActor in
            defer { inFlight.remove(key) }
            if authorization == .notDetermined {
                authorization = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
            }
            guard authorization == .authorized else { failed[key] = "Speech recognition not allowed (System Settings → Privacy → Speech Recognition)"; return }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { failed[key] = "Speech recognition unavailable"; return }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            request.addsPunctuation = true
            do {
                let text: String = try await withCheckedThrowingContinuation { cont in
                    var done = false
                    recognizer.recognitionTask(with: request) { result, error in
                        guard !done else { return }
                        if let error { done = true; cont.resume(throwing: error); return }
                        if let result, result.isFinal { done = true; cont.resume(returning: result.bestTranscription.formattedString) }
                    }
                }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                transcripts[key] = clean.isEmpty ? "(no speech detected)" : clean
                save()
            } catch {
                failed[key] = error.localizedDescription
            }
        }
    }
}
