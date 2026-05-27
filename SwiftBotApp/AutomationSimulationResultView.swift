import SwiftUI

/// A premium macOS sheet that displays the diagnostic results of a rule dry-run simulation.
struct AutomationSimulationResultView: View {
    @Environment(\.dismiss) private var dismiss
    
    let ruleName: String
    let result: Automations.SimulationResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroStatusCard
                    
                    triggerSection
                    
                    filtersSection
                    
                    stepsTimelineSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            
            footerBar
        }
        .frame(minWidth: 540, maxWidth: 600, minHeight: 480, maxHeight: 650)
        .background(VisualEffectView().ignoresSafeArea())
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rule Simulation Trace")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(ruleName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(Color.primary.opacity(0.02))
        .overlay(
            VStack {
                Spacer()
                Divider().opacity(0.4)
            }
        )
    }
    
    // MARK: - Footer Bar
    
    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(.thinMaterial)
    }
    
    // MARK: - Hero Status Card
    
    private var heroStatusCard: some View {
        let isPassed = result.triggerMatched && result.filtersMatched
        let isTriggerFailed = !result.triggerMatched
        
        let icon: String
        let title: String
        let description: String
        let color: Color
        
        if isPassed {
            icon = "checkmark.seal.fill"
            title = "Simulation Passed"
            description = "The triggering event occurred, all conditions matched, and the automation steps successfully fired."
            color = .green
        } else if isTriggerFailed {
            icon = "exclamationmark.triangle.fill"
            title = "Rule Bypassed (Trigger Mismatch)"
            description = "The mock event did not match the required trigger pattern (e.g. channel ID or duration did not align)."
            color = .orange
        } else {
            icon = "exclamationmark.shield.fill"
            title = "Rule Bypassed (Conditions Not Met)"
            description = "The event successfully triggered the rule, but one or more of your custom filter conditions failed."
            color = .orange
        }
        
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.2), lineWidth: 1))
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
    
    // MARK: - Trigger Section
    
    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Trigger Match Details", systemImage: "bolt.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            
            HStack {
                Image(systemName: result.triggerMatched ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.triggerMatched ? .green : .red)
                Text(result.triggerMatched ? "Trigger criteria matched successfully" : "Event did not match trigger criteria")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)
        }
    }
    
    // MARK: - Filters Section
    
    private var filtersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Condition Filters Trace", systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)
            
            if result.filterTraces.isEmpty {
                Text("No custom conditions configured — this rule fires on any trigger match.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    ForEach(result.filterTraces) { trace in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: trace.matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(trace.matched ? .green : .red)
                                .font(.system(size: 14, weight: .bold))
                                .padding(.top, 2)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(filterLabel(trace.kind))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(trace.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(trace.matched ? Color.green.opacity(0.03) : Color.red.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(trace.matched ? Color.green.opacity(0.1) : Color.red.opacity(0.1), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Steps Timeline Section
    
    private var stepsTimelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Steps Dry-Run Timeline", systemImage: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(.primary)
            
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(result.stepTraces.enumerated()), id: \.element.id) { idx, trace in
                    HStack(alignment: .top, spacing: 12) {
                        // Connector timeline graphics
                        VStack(spacing: 0) {
                            Circle()
                                .fill(trace.executed ? Color.green : Color.secondary.opacity(0.3))
                                .frame(width: 10, height: 10)
                            
                            if idx < result.stepTraces.count - 1 {
                                Rectangle()
                                    .fill(trace.executed ? Color.green : Color.secondary.opacity(0.2))
                                    .frame(width: 2, height: 32)
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Step \(idx + 1): \(stepLabel(trace.kind))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(trace.executed ? .primary : .secondary)
                            
                            Text(trace.detail)
                                .font(.caption)
                                .foregroundStyle(trace.executed ? Color.secondary : Color.secondary.opacity(0.7))
                        }
                        .padding(.bottom, idx < result.stepTraces.count - 1 ? 16 : 0)
                        
                        Spacer()
                    }
                }
            }
            .padding(.leading, 6)
        }
    }
    
    // MARK: - Labels Mapping
    
    private func filterLabel(_ kind: Automations.FilterKind) -> String {
        switch kind {
        case .inChannel: return "In channel"
        case .directMessage: return "DM check"
        case .userIsOneOf: return "User ID check"
        case .userHasAnyRole: return "Has any role"
        case .userHasAllRoles: return "Has all roles"
        case .userHasNoneOfRoles: return "Has none of roles"
        case .messageContains: return "Message contains substring"
        case .messageContainsAny: return "Message contains any of"
        case .messageEquals: return "Message matches exactly"
        case .messageDoesNotContain: return "Message does not contain"
        case .messageMatchesRegex: return "Message matches regular expression"
        case .messageIsReply: return "Message reply check"
        case .fromBot: return "Author is bot check"
        case .minVoiceDurationSeconds: return "Voice connection duration minimum"
        case .reactionEmoji: return "Reaction emoji check"
        case .mediaSource: return "Media source check"
        case .messageContainsSpamLink: return "Contains spam link patterns"
        case .messageCapsPercentage: return "Caps percentage limit"
        case .messageMentionsCount: return "Mentions count threshold"
        }
    }
    
    private func stepLabel(_ kind: Automations.StepKind) -> String {
        switch kind {
        case .sendMessage: return "Send Message"
        case .modifyMember: return "Modify Member (Role/Timeout/Kick)"
        case .modifyMessage: return "Modify Message (Delete/React)"
        case .log: return "Write to System Log"
        case .webhook: return "Call Webhook"
        case .delay: return "Wait"
        }
    }
}

// MARK: - VisualEffectView for Tahoe Background

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
