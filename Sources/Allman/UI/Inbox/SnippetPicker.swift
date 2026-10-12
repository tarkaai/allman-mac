import SwiftUI

/// Pick a saved reply for the open thread; placeholders are filled in the preview.
struct SnippetPicker: View {
    @Environment(AppModel.self) private var model
    let vars: [String: String]
    let onPick: (String) -> Void
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private var matching: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.snippets.snippets
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) || $0.body.lowercased().contains(q) }
    }

    var body: some View {
        let rows = matching
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote").foregroundStyle(.secondary)
                TextField("Search snippets…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if rows.indices.contains(cursor) { onPick(Snippet.render(rows[cursor].body, vars: vars)) } }
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(rows.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.snippets.snippets.isEmpty ? "No snippets yet." : "No snippet matches.").font(.callout).foregroundStyle(.secondary)
                    Text("Add saved replies in Settings → Snippets. Use {firstName}, {company}, {me}… and they fill in per thread.").font(.caption).foregroundStyle(.tertiary)
                    Button("Open Snippet Settings…") { model.openSettings() }.buttonStyle(.link).font(.caption)
                }
                .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, s in
                            Button { onPick(Snippet.render(s.body, vars: vars)) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.callout.weight(.medium))
                                    Text(Snippet.render(s.body, vars: vars).replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(i == cursor ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { if $0 { cursor = i } }
                        }
                    }
                }
                .frame(maxHeight: 260)
                Text("↑↓ choose · ⏎ insert").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in cursor = 0 }
    }
}

/// Settings → Snippets: add, edit, reorder, delete; import the TUI's templates.
struct SnippetSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Snippet?
    @State private var creating = false
    @State private var importResult: String?

    var body: some View {
        let store = model.snippets
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Available in the message field with ⇧⌘S, the quote button, or a lone / in an empty field.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            List {
                ForEach(store.snippets) { s in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name).font(.body.weight(.medium))
                            Text(s.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Button("Edit") { editing = s }.controlSize(.small)
                        Button { store.remove(s.id) } label: { Image(systemName: "trash") }.controlSize(.small).help("Delete")
                    }
                    .padding(.vertical, 3)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .frame(minHeight: 220)
            HStack {
                Button("New Snippet…") { creating = true }
                Button("Import from allman-tui…") {
                    let n = store.importFile(SnippetStore.tuiURL)
                    importResult = n == 0 ? "Nothing new in \(SnippetStore.tuiURL.path)" : "Imported \(n) snippet\(n == 1 ? "" : "s")"
                }
                Spacer()
                if let importResult { Text(importResult).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Variables: " + Snippet.variables.map { "{\($0.name)}" }.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $creating) { SnippetEditor(snippet: nil).environment(model) }
        .sheet(item: $editing) { SnippetEditor(snippet: $0).environment(model) }
    }
}

struct SnippetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet?
    @State private var name = ""
    @State private var body_ = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snippet == nil ? "New Snippet" : "Edit Snippet").font(.headline)
            TextField("Name (e.g. Follow up)", text: $name)
            TextEditor(text: $body_)
                .font(.body)
                .frame(minHeight: 140)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Snippet.variables, id: \.name) { v in
                    HStack(spacing: 6) {
                        Text("{\(v.name)}").font(.caption.monospaced())
                        Text(v.help).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let s = snippet { model.snippets.update(s.id, name: name, body: body_) } else { model.snippets.add(name: name, body: body_) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { name = snippet?.name ?? ""; body_ = snippet?.body ?? "" }
    }
}
