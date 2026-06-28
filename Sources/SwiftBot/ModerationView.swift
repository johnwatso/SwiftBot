import SwiftUI

/// Sidebar tab for moderation rules. Shares the AutomationsView layout
/// (metrics, NL drafter, templates, list, editor sheet) but is filtered
/// to rules tagged with `.moderation` and ships its own template catalog.
struct ModerationView: View {
    var body: some View {
        AutomationsView(category: .moderation)
    }
}
