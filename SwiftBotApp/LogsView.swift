import SwiftUI

struct LogsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showClearLogsConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ViewSectionHeader(title: "Logs", symbol: "list.bullet.clipboard.fill")
                Spacer()
                Button("Clear") { showClearLogsConfirm = true }
                    .alert("Clear All Logs?", isPresented: $showClearLogsConfirm) {
                        Button("Clear", role: .destructive) { app.logs.clear() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("All log entries will be permanently removed.")
                    }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.logs.fullLog(), forType: .string)
                }
                Toggle("Auto-scroll", isOn: $app.logs.autoScroll)
                    .toggleStyle(.switch)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(app.logs.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("❌") ? .red : (line.contains("⚠️") ? .yellow : .green))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .glassCard(cornerRadius: 20, tint: .black.opacity(0.04), stroke: .white.opacity(0.16))
                .onChange(of: app.logs.lines.count) {
                    if app.logs.autoScroll, let last = app.logs.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}
