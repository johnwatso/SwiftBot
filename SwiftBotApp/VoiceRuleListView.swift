import SwiftUI

struct RuleListView: View {
    @Binding var rules: [Rule]
    @Binding var selectedRuleID: UUID?
    let onAddNew: () -> Void
    let onDeleteRuleID: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            RulePaneHeader(
                title: "Actions",
                subtitle: "Build reusable flows from triggers, filters, and outputs.",
                systemImage: "point.3.filled.connected.trianglepath.dotted"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button(action: onAddNew) {
                        Label("New Rule", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassActionButtonStyle())

                    LazyVStack(spacing: 10) {
                        ForEach($rules) { $rule in
                            RuleRowView(
                                rule: $rule,
                                isSelected: selectedRuleID == rule.id,
                                onSelect: {
                                    withAnimation(.snappy(duration: 0.12)) {
                                        selectedRuleID = rule.id
                                    }
                                },
                                onDelete: { onDeleteRuleID(rule.id) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .background(rulePaneBackground)
    }

    private var rulePaneBackground: some View {
        Rectangle()
            .fill(.white.opacity(0.04))
    }
}

struct RuleRowView: View {
    @Binding var rule: Rule
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.headline)
                Text(rule.triggerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderless)
            .alert("Delete Rule?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(rule.name)\" will be permanently deleted.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(selectionBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? .white.opacity(0.28) : .white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var selectionBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(.thinMaterial)
        }
        return AnyShapeStyle(Color.white.opacity(0.05))
    }
}
