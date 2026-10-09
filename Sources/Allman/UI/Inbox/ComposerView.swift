import SwiftUI

/// iMessage-style field: a rounded capsule with the send button inside.
/// Return sends, Option-Return inserts a newline.
struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let convId: String
    let firstName: String

    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.inbox.isSending
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
            }
            if let err = inbox.composerError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message \(firstName)…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.leading, 12).padding(.vertical, 7)
                Button(action: send) {
                    Group {
                        if inbox.isSending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(canSend ? Color(nsColor: .systemBlue) : Color.secondary.opacity(0.5))
                        }
                    }
                    // Same height as a one-line field, so the arrow is centered on the
                    // composing line and rides the last line as the field grows.
                    .frame(width: 30, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
                .padding(.trailing, 4)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color(nsColor: .separatorColor)))
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .onAppear { focused = true }
    }

    private func send() {
        let body = text
        guard canSend else { return }
        text = ""
        Task {
            let ok = await model.inbox.send(body, to: convId)
            if !ok { text = body } // give the draft back on failure
        }
    }
}
