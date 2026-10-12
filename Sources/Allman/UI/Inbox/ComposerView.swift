import SwiftUI

/// iMessage-style field: a rounded capsule with the send button inside.
/// Return sends, Option-Return inserts a newline.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let convId: String
    let firstName: String
    /// Drafts open with the field focused; a thread keeps focus on the list (selection stays active).
    var autoFocus = false

    @State private var text = ""
    @State private var recorder = VoiceRecorder()
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let inbox = model.inbox
        VStack(alignment: .leading, spacing: 6) {
            if let reply = inbox.replyingTo[convId] {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color(nsColor: .systemBlue)).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(reply.isFromMe ? "yourself" : firstName)").font(.caption.weight(.semibold))
                        Text(reply.previewText.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { inbox.replyingTo[convId] = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help("Cancel reply")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onAppear { focused = true }
        .onChange(of: model.inbox.focusToken) { _, _ in
            if model.inbox.focusTarget == .composer { focused = true }
        }
            }
            if let err = inbox.composerError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if let err = recorder.error {
                Label(err, systemImage: "mic.slash").font(AFont.secondary).foregroundStyle(.orange)
            }
            if recorder.isRecording {
                recordingBar.onAppear { recorder.syncDebug() }
            } else if recorder.hasRecording {
                previewBar.onAppear { recorder.syncDebug() }
            } else {
            HStack(alignment: .bottom, spacing: 6) {
                @Bindable var inbox = inbox
                Button { inbox.showSnippetPicker.toggle() } label: {
                    Image(systemName: "text.quote")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 36)
                }
                .buttonStyle(.plain)
                .help("Insert a snippet (⇧⌘S, or type / in an empty field)")
                .padding(.leading, 4)
                .popover(isPresented: $inbox.showSnippetPicker, arrowEdge: .top) {
                    SnippetPicker(vars: snippetVars) { rendered in
                        inbox.showSnippetPicker = false
                        text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rendered : text + rendered
                        focused = true
                    }
                    .environment(model)
                }
                TextField("Message \(firstName)…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .onKeyPress(.escape) { model.inbox.requestFocus(.list); return .handled }
                    .onChange(of: text) { old, new in
                        // "/" alone in an empty field opens the snippet picker (Slack-style).
                        if old.isEmpty, new == "/" { text = ""; inbox.showSnippetPicker = true }
                    }
                    .padding(.leading, 2)
                    .padding(.vertical, 6)
                    .frame(minHeight: 36) // one line is exactly as tall as the send button
                if canSend {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Color(nsColor: .systemBlue))
                        // Same height as a one-line field, so the arrow is centered on the
                        // composing line and rides the last line as the field grows.
                        .frame(width: 30, height: 36)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Return)")
                    .padding(.trailing, 4)
                } else {
                    // Empty field: the mic takes the send button's spot, like Messages.
                    Button { Task { await recorder.start() } } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 36)
                    }
                    .buttonStyle(.plain)
                    .help("Record a voice note (sent with allman send --audio)")
                    .padding(.trailing, 4)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color(nsColor: .separatorColor)))
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .onAppear { if autoFocus { focused = true }; recorder.syncDebug() }
        .onChange(of: model.inbox.voiceDebugTick) { _, _ in recorder.syncDebug() }
        .onChange(of: model.inbox.focusToken) { _, _ in
            if model.inbox.focusTarget == .composer { focused = true }
        }
    }

    /// Red dot, elapsed time and a live level meter while the mic is open.
    private var recordingBar: some View {
        HStack(spacing: 10) {
            Button { recorder.discard() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Discard")
                .keyboardShortcut(.escape, modifiers: [])
            Circle().fill(.red).frame(width: 9, height: 9)
                .opacity(Int(recorder.duration * 2) % 2 == 0 ? 1 : 0.35)
            Text(VoiceRecorder.clock(recorder.duration)).font(AFont.body.monospacedDigit()).frame(width: 40, alignment: .leading)
            LevelMeter(level: recorder.level).frame(height: 18)
            Button { recorder.stop() } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 24)).foregroundStyle(.red)
            }
            .buttonStyle(.plain).help("Stop recording")
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10).frame(minHeight: 36)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.red.opacity(0.5)))
    }

    /// Listen back, discard, or send the recording.
    private var previewBar: some View {
        HStack(spacing: 10) {
            Button { recorder.discard() } label: { Image(systemName: "trash.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Discard")
                .keyboardShortcut(.escape, modifiers: [])
            Button { recorder.togglePreview() } label: {
                Image(systemName: recorder.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 22)).foregroundStyle(Color(nsColor: .systemBlue))
            }
            .buttonStyle(.plain).help(recorder.isPlaying ? "Pause" : "Listen")
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text("Voice note · \(VoiceRecorder.clock(recorder.duration))").font(AFont.body)
            Spacer()
            Button(action: sendRecording) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)).foregroundStyle(Color(nsColor: .systemBlue))
            }
            .buttonStyle(.plain).help("Send voice note (Return)")
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 10).frame(minHeight: 36)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color(nsColor: .separatorColor)))
    }

    private func sendRecording() {
        guard let (url, ms) = recorder.take() else { return }
        Task {
            let ok = await model.inbox.sendAudio(url, durationMs: ms, to: convId)
            if !ok, convId.hasPrefix("draft:") { model.inbox.toast = "Voice notes need an existing thread — send a text first." }
        }
    }

    /// Placeholder values for the thread (or draft recipient) this composer belongs to.
    private var snippetVars: [String: String] {
        let inbox = model.inbox
        let me = model.current?.displayName
        if let snap = inbox.byId[convId] {
            return snap.record.snippetVars(connection: inbox.connection(for: snap.record), me: me)
        }
        if let d = inbox.draft, d.convId == convId {
            let first = d.name.split(separator: " ").first.map(String.init) ?? d.name
            let last = d.name.split(separator: " ").dropFirst().joined(separator: " ")
            return ["firstName": first, "lastName": last, "name": d.name, "slug": d.slug, "company": inbox.connectionsBySlug[d.slug]?.company ?? "", "title": inbox.connectionsBySlug[d.slug]?.title ?? "", "me": me?.split(separator: " ").first.map(String.init) ?? ""]
        }
        return ["firstName": firstName, "name": firstName, "me": me?.split(separator: " ").first.map(String.init) ?? ""]
    }

    private func send() {
        let body = text
        guard canSend else { return }
        text = ""
        Task {
            let ok = await model.inbox.send(body, to: convId)
            // A thread send that fails stays in the stream as "Not Delivered"; a draft
            // (no thread yet) has nowhere to live, so hand the text back.
            if !ok, convId.hasPrefix("draft:") { text = body }
        }
    }
}


/// A row of bars that follow the mic level.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            let n = max(8, Int(geo.size.width / 5))
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<n, id: \.self) { i in
                    let phase = Float(i % 5) / 5
                    let h = CGFloat(max(0.15, min(1, level * (0.6 + phase * 0.8)))) * geo.size.height
                    Capsule().fill(Color.red.opacity(0.75)).frame(width: 3, height: h)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
