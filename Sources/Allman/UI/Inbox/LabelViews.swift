import SwiftUI

extension InboxLabel {
    var swiftUIColor: Color { InboxLabel.color(named: color) }

    static func color(named name: String) -> Color {
        switch name {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "blue": return .blue
        case "indigo": return .indigo
        case "purple": return .purple
        case "pink": return .pink
        default: return .gray
        }
    }
}

/// A small colored capsule naming a label (rows, inspector, strip).
struct LabelChip: View {
    let label: InboxLabel
    var selected = false
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(label.swiftUIColor).frame(width: 7, height: 7)
            Text(label.name).lineLimit(1)
            if let count, count > 0 { Text("\(count)").foregroundStyle(selected ? .primary : .secondary).monospacedDigit() }
        }
        .font(.caption.weight(selected ? .semibold : .regular))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(selected ? label.swiftUIColor.opacity(0.22) : Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(selected ? label.swiftUIColor.opacity(0.6) : .clear, lineWidth: 1))
    }
}

/// Split inboxes: one chip per label above the list, plus All. Scrolls when there are many.
struct LabelStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let inbox = model.inbox
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { inbox.filter = .all } label: {
                    Text("All").font(.caption.weight(inbox.filter == .all ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(inbox.filter == .all ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                ForEach(inbox.organizer.labels) { label in
                    Button { inbox.filter = inbox.filter == .label(label.id) ? .all : .label(label.id) } label: {
                        LabelChip(label: label, selected: inbox.filter == .label(label.id), count: inbox.unreadCount(label: label.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu { LabelMenu(label: label) }
                }
                let due = inbox.dueCount
                if !inbox.organizer.snoozes.isEmpty {
                    Button { inbox.filter = inbox.filter == .reminders ? .all : .reminders } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            if due > 0 { Text("\(due)").monospacedDigit() }
                        }
                        .font(.caption.weight(inbox.filter == .reminders ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(inbox.filter == .reminders ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Snoozed & reminders")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }
}

/// Rename / recolor / delete, from a chip's or the picker's context menu.
struct LabelMenu: View {
    @Environment(AppModel.self) private var model
    let label: InboxLabel

    var body: some View {
        let inbox = model.inbox
        Menu("Color") {
            ForEach(InboxLabel.colors, id: \.self) { c in
                Button { inbox.rename(label: label.id, to: label.name, color: c) } label: {
                    Label(c.capitalized, systemImage: label.color == c ? "checkmark.circle.fill" : "circle.fill")
                }
            }
        }
        Button("Rename…") { inbox.renamingLabel = label }
        Divider()
        Button("Delete Label", role: .destructive) { inbox.deleteLabel(label.id) }
    }
}

/// Toggle labels on one conversation; type to filter or create a new one.
struct LabelPicker: View {
    @Environment(AppModel.self) private var model
    let convId: String
    @State private var query = ""
    @State private var newColor = InboxLabel.colors[0]
    @FocusState private var focused: Bool

    private var matching: [InboxLabel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.inbox.organizer.labels
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    private var canCreate: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return !q.isEmpty && !model.inbox.organizer.labels.contains { $0.name.caseInsensitiveCompare(q) == .orderedSame }
    }

    var body: some View {
        let inbox = model.inbox
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tag").foregroundStyle(.secondary)
                TextField("Label name…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { submit() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            if matching.isEmpty && !canCreate {
                Text("No labels yet. Type a name and press Return.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(matching) { label in
                    let on = inbox.organizer.has(label: label.id, convId)
                    Button { inbox.toggle(label: label.id, convId) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                            Circle().fill(label.swiftUIColor).frame(width: 9, height: 9)
                            Text(label.name)
                            Spacer()
                            Text("\(inbox.organizer.count(label: label.id))").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { LabelMenu(label: label) }
                }
            }
            if canCreate {
                Divider()
                HStack(spacing: 8) {
                    Button { submit() } label: {
                        Label("Create “\(query.trimmingCharacters(in: .whitespaces))”", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(InboxLabel.colors, id: \.self) { c in
                            Button { newColor = c } label: {
                                Circle().fill(InboxLabel.color(named: c)).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Color.primary.opacity(newColor == c ? 0.7 : 0), lineWidth: 1.5).padding(-2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { focused = true; newColor = InboxLabel.colors[inbox.organizer.labels.count % InboxLabel.colors.count] }
    }

    private func submit() {
        let inbox = model.inbox
        if canCreate {
            inbox.addLabel(query, color: newColor, to: convId)
            query = ""
        } else if let first = matching.first {
            inbox.toggle(label: first.id, convId)
        }
    }
}

/// Rename sheet (from a label's context menu).
struct RenameLabelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let label: InboxLabel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Label").font(.headline)
            TextField("Name", text: $name).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { name = label.name }
    }

    private func save() {
        model.inbox.rename(label: label.id, to: name)
        dismiss()
    }
}
