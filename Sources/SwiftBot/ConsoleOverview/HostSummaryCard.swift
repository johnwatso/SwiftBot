import AppKit
import SwiftUI

/// The SwiftBot summary: icon with a live status dot, name and environment,
/// overall state, and version / node / uptime. When something needs
/// attention, one quiet line per issue says what and offers to show it.
struct HostSummaryCard: View {
    let botName: String
    let status: HostStatus
    let details: HostDetails
    let meshRole: String
    var onReviewIssue: (ConsoleServiceKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 26) {
                appIcon

                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 12) {
                            Text(botName)
                                .font(.title.weight(.semibold))
                                .lineLimit(1)
                            StatusBadge(health: status.health, text: status.badge)
                        }
                        Text("\(details.buildChannel) · \(meshRole)")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    factsRow
                }

                Spacer(minLength: 0)
            }
            .padding(28)

            if !status.issues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(status.issues) { issue in
                        ConsoleIssueRow(issue: issue) { onReviewIssue(issue.kind) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, -8)
            }
        }
        .consoleSurface(cornerRadius: 22)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 108, height: 108)
            .overlay(alignment: .bottomTrailing) {
                StatusDot(health: status.health, size: 22)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 3.5))
                    .offset(x: -8, y: -8)
            }
            .accessibilityLabel("\(botName), \(status.badge)")
    }

    private var factsRow: some View {
        HStack(alignment: .top, spacing: 28) {
            HostFact(title: "Version") { Text(details.appVersion) }
            Divider()
            HostFact(title: "Node") { Text(details.computerName) }
            Divider()
            HostFact(title: "Uptime") { UptimeText(startedAt: status.startedAt) }
        }
        .fixedSize()
    }
}

/// A caption over a value.
private struct HostFact<Value: View>: View {
    let title: String
    @ViewBuilder var value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            value
                .font(.title3.weight(.medium))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Uptime that keeps counting without the rest of the Overview re-rendering.
struct UptimeText: View {
    let startedAt: Date?

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Duration.seconds(max(0, context.date.timeIntervalSince(startedAt))).uptimeText)
                    .monospacedDigit()
            }
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}
