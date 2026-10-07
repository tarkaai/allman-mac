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
                    if inbox.isSending {
                        ProgressView().controlSize(.small).frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(canSend ? Color(nsColor: .systemBlue) : Color.secondary.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
                .padding(.trailing, 5).padding(.bottom, 4)
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
