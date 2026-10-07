import SwiftUI

struct ComposerView: View {
    @Environment(AppModel.self) private var model
    let convId: String
    let firstName: String

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let inbox = model.inbox
        VStack(alignment: .leading, spacing: 6) {
            if let err = inbox.composerError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(minHeight: 44, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($focused)
                        .onKeyPress(.return, phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            send()
                            return .handled
                        }
                    if text.isEmpty {
                        Text("Message \(firstName)…  ⌘↩ to send")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button(action: send) {
                    if inbox.isSending { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                    else { Image(systemName: "paperplane.fill") }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inbox.isSending)
                .help("Send (⌘↩)")
            }
            Text("Sends through the allman CLI — rate-limited, and it checks for new replies first.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
        .onAppear { focused = true }
    }

    private func send() {
        let body = text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.inbox.isSending else { return }
        text = ""
        Task {
            let ok = await model.inbox.send(body, to: convId)
            if !ok { text = body } // give the draft back on failure
        }
    }
}
