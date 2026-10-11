import SwiftUI

/// A label as an icon + name chip (inbox bar, rows, inspector).
struct LabelChip: View {
    let label: InboxLabel
    var selected = false
    var count: Int? = nil
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: label.icon).font(.caption2.weight(.medium))
            if !compact { Text(label.name).lineLimit(1) }
            if let count, count > 0 { Text("\(count)").foregroundStyle(selected ? .primary : .secondary).monospacedDigit() }
        }
        .font(.caption.weight(selected ? .semibold : .regular))
        .padding(.horizontal, compact ? 5 : 8).padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
        .foregroundStyle(selected ? Color.accentColor : .primary)
    }
}

/// Rename / change icon / delete, from a chip's or the picker's context menu.
struct LabelMenu: View {
    @Environment(AppModel.self) private var model
    let label: InboxLabel

    var body: some View {
        let inbox = model.inbox
        Menu("Icon") {
            ForEach(InboxLabel.icons, id: \.self) { icon in
                Button { inbox.rename(label: label.id, to: label.name, icon: icon) } label: {
                    Label(icon.replacingOccurrences(of: ".", with: " "), systemImage: icon)
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
    @State private var newIcon = InboxLabel.icons[0]
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
                            Image(systemName: label.icon).frame(width: 16)
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
                VStack(alignment: .leading, spacing: 6) {
                    Button { submit() } label: {
                        Label("Create “\(query.trimmingCharacters(in: .whitespaces))”", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    IconGrid(selected: $newIcon)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            focused = true
            let used = Set(inbox.organizer.labels.map(\.icon))
            newIcon = InboxLabel.icons.first { !used.contains($0) } ?? InboxLabel.icons[0]
        }
    }

    private func submit() {
        let inbox = model.inbox
        if canCreate {
            inbox.addLabel(query, icon: newIcon, to: convId)
            query = ""
        } else if let first = matching.first {
            inbox.toggle(label: first.id, convId)
        }
    }
}

/// Pick an SF Symbol for a label.
struct IconGrid: View {
    @Binding var selected: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 8), spacing: 4) {
            ForEach(InboxLabel.icons, id: \.self) { icon in
                Button { selected = icon } label: {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .frame(width: 26, height: 24)
                        .background(selected == icon ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(selected == icon ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(icon)
            }
        }
    }
}

/// Rename / re-icon sheet (from a label's context menu).
struct RenameLabelSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let label: InboxLabel
    @State private var name = ""
    @State private var icon = "tag"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Label").font(.headline)
            TextField("Name", text: $name).onSubmit(save)
            IconGrid(selected: $icon)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { name = label.name; icon = label.icon }
    }

    private func save() {
        model.inbox.rename(label: label.id, to: name, icon: icon)
        dismiss()
    }
}

/// The messenger this thread lives on. Allman is built for several; today it's LinkedIn.
struct MessengerBadge: View {
    var size: CGFloat = 14

    var body: some View {
        Text("in")
            .font(.system(size: size * 0.64, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(red: 0.04, green: 0.4, blue: 0.76), in: RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
            .help("LinkedIn")
            .accessibilityLabel("LinkedIn")
    }
}
