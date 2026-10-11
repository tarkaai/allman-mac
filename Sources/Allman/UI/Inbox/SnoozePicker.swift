import SwiftUI

/// Snooze (hide until) or remind (ping, keep in place) for one conversation.
struct SnoozePicker: View {
    @Environment(AppModel.self) private var model
    let convId: String
    var onDone: () -> Void = {}
    @State private var keepVisible = false
    @State private var note = ""
    @State private var custom = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)!
    @State private var showCustom = false

    var body: some View {
        let inbox = model.inbox
        let existing = inbox.organizer.snooze(convId)
        VStack(alignment: .leading, spacing: 10) {
            if let existing {
                HStack(spacing: 6) {
                    Image(systemName: existing.hidden ? "moon.zzz.fill" : "bell.fill").foregroundStyle(.orange)
                    Text("\(existing.hidden ? "Snoozed until" : "Reminder") \(Fmt.reminderTime(existing.until))").font(.callout)
                    Spacer()
                    Button("Clear") { inbox.clearSnooze(convId); onDone() }.controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Picker("", selection: $keepVisible) {
                Text("Snooze").tag(false)
                Text("Remind").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(keepVisible ? "Stays in the inbox; you get a notification at the time." : "Leaves the inbox and comes back at the time — or sooner if they write.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(Snooze.presets().enumerated()), id: \.offset) { _, p in
                    Button { apply(p.date) } label: {
                        HStack {
                            Text(p.title)
                            Spacer()
                            Text(Fmt.reminderTime(p.date)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { withAnimation { showCustom.toggle() } } label: {
                    HStack { Text("Pick a date & time…"); Spacer(); Image(systemName: showCustom ? "chevron.up" : "chevron.down").font(.caption) }
                        .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showCustom {
                    HStack {
                        DatePicker("", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                        Spacer()
                        Button("Set") { apply(custom) }.controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                }
            }
            TextField("Note to self (optional)", text: $note).textFieldStyle(.roundedBorder).controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            if let existing { keepVisible = !existing.hidden; note = existing.note ?? "" }
        }
    }

    private func apply(_ date: Date) {
        model.inbox.snooze(convId, until: date, hidden: !keepVisible, note: note)
        onDone()
    }
}

/// Banner at the top of a thread that has a snooze or reminder.
struct ReminderBanner: View {
    @Environment(AppModel.self) private var model
    let convId: String

    var body: some View {
        let inbox = model.inbox
        if let s = inbox.organizer.snooze(convId) {
            let due = s.until <= Date()
            let woken = inbox.byId[convId].map { inbox.organizer.isWoken($0) } ?? false
            HStack(spacing: 8) {
                Image(systemName: due ? "bell.badge.fill" : (s.hidden ? "moon.zzz.fill" : "bell.fill")).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(due ? "Reminder due \(Fmt.reminderTime(s.until))" : woken ? "They wrote back — \(s.hidden ? "snooze" : "reminder") for \(Fmt.reminderTime(s.until)) still set" : "\(s.hidden ? "Snoozed until" : "Reminder") \(Fmt.reminderTime(s.until))")
                        .font(.callout.weight(.medium))
                    if let n = s.note, !n.isEmpty { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Button("Done") { inbox.clearSnooze(convId) }.controlSize(.small)
                Button("Change…") { inbox.showSnoozePicker = true }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

/// Free-form note about a contact, autosaved.
struct NoteEditor: View {
    @Environment(AppModel.self) private var model
    let convId: String
    var compact = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: compact ? 120 : 90, maxHeight: compact ? 220 : 240)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty { Text("Notes only you can see — context, next steps, how you met…").font(.callout).foregroundStyle(.tertiary).padding(11).allowsHitTesting(false) }
                }
                .focused($focused)
            if compact { Text("Saved automatically").font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(width: compact ? 320 : nil)
        .padding(compact ? 12 : 0)
        .onAppear { text = model.inbox.organizer.note(convId); if compact { focused = true } }
        .onChange(of: text) { _, t in model.inbox.setNote(t, convId) }
        // Follow the stored note (another editor, undo, or a thread switch) unless this one is mid-edit.
        .onChange(of: model.inbox.organizer.note(convId)) { _, stored in if stored != text, !focused { text = stored } }
        .onChange(of: convId) { _, id in text = model.inbox.organizer.note(id) }
    }
}
