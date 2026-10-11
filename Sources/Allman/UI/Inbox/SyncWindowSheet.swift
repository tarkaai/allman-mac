import SwiftUI

/// "Sync older history…": pick how far back `allman sync --from` should walk.
struct SyncWindowSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choice = "30d"
    @State private var customDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @State private var resync = false

    private let presets: [(String, String)] = [("7d", "Last week"), ("30d", "Last month"), ("90d", "Last 3 months"), ("180d", "Last 6 months"), ("1y", "Last year"), ("custom", "Since a date…")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync older history").font(.headline)
            Text("Pulls every conversation that had activity in the window, oldest message first. Longer windows take a while; the inbox keeps working meanwhile.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Window", selection: $choice) {
                ForEach(presets, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.radioGroup)
            if choice == "custom" {
                DatePicker("Since", selection: $customDate, in: ...Date(), displayedComponents: .date)
            }
            Toggle("Re-fetch messages already stored (slower; repairs gaps)", isOn: $resync).font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sync") {
                    let from: String
                    if choice == "custom" {
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; from = f.string(from: customDate)
                    } else { from = choice }
                    model.engine.syncNow(from: from, resync: resync)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.engine.isSyncing)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
