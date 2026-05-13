import SwiftUI

struct RuleListView: View {
    @Binding var rules: [Rule]
    @Binding var selectedRuleID: UUID?
    let onAddNew: () -> Void
    let onDeleteRuleID: (UUID) -> Void
    var isLoading: Bool = false
    @State private var searchText: String = ""
    @State private var scope: RuleNavigatorScope = .all

    var body: some View {
        VStack(spacing: 0) {
            RuleNavigatorHeader(
                totalRuleCount: rules.count,
                visibleRuleCount: filteredRuleIndices.count,
                searchText: $searchText,
                scope: $scope,
                onAddNew: onAddNew
            )

            if isLoading {
                Spacer()
                ProgressView()
                    .padding()
                Spacer()
            } else if rules.isEmpty {
                RuleListEmptyStateView(onCreateRule: onAddNew)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        LazyVStack(spacing: 1) {
                            ForEach(filteredRuleIndices, id: \.self) { index in
                                RuleRowView(
                                    rule: $rules[index],
                                    isSelected: selectedRuleID == rules[index].id,
                                    onSelect: {
                                        withAnimation(.snappy(duration: 0.12)) {
                                            selectedRuleID = rules[index].id
                                        }
                                    },
                                    onDelete: { onDeleteRuleID(rules[index].id) }
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(rulePaneBackground)
    }

    private var rulePaneBackground: some View {
        Color.primary.opacity(0.012)
    }

    private var filteredRuleIndices: [Int] {
        rules.indices.filter { index in
            let rule = rules[index]
            let matchesScope: Bool = {
                switch scope {
                case .all:
                    return true
                case .enabled:
                    return rule.isEnabled
                case .disabled:
                    return !rule.isEnabled
                }
            }()

            guard matchesScope else { return false }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return true }

            return rule.name.localizedCaseInsensitiveContains(query)
                || rule.triggerSummary.localizedCaseInsensitiveContains(query)
        }
    }
}

// MARK: - Empty State

private enum RuleNavigatorScope: String, CaseIterable {
    case all
    case enabled
    case disabled

    var label: String {
        switch self {
        case .all: return "All Rules"
        case .enabled: return "Enabled"
        case .disabled: return "Disabled"
        }
    }
}

private struct RuleNavigatorHeader: View {
    let totalRuleCount: Int
    let visibleRuleCount: Int
    @Binding var searchText: String
    @Binding var scope: RuleNavigatorScope
    let onAddNew: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rules")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .tracking(0.35)
                    Text("\(visibleRuleCount) of \(totalRuleCount) workflow\(totalRuleCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onAddNew) {
                    Label("New Rule", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Search rules", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.026), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Picker("Scope", selection: $scope) {
                    ForEach(RuleNavigatorScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.primary.opacity(0.05))
                .frame(height: 1)
        }
    }
}

private struct RuleListEmptyStateView: View {
    let onCreateRule: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text("No Rules Yet")
                        .font(.headline)
                    Text("SwiftBot automations let you respond to\nevents in your Discord server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: onCreateRule) {
                    Label("Create First Rule", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassActionButtonStyle())
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}

struct RuleRowView: View {
    @Binding var rule: Rule
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: rule.trigger?.symbol ?? "bolt.badge.automatic.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(rule.triggerSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Circle()
                        .fill(rule.isEnabled ? Color.green : Color.secondary.opacity(0.6))
                        .frame(width: 4, height: 4)
                }
            }

            Spacer()

            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .scaleEffect(0.72)

            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Image(systemName: "trash")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .alert("Delete Rule?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(rule.name)\" will be permanently deleted.")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selectionBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.08) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var selectionBackground: some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(0.075))
        }
        return AnyShapeStyle(Color.clear)
    }
}
