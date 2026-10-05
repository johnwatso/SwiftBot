import AppKit
import SwiftUI

// Sidebar building blocks shared with SwiftMiner: a sidebar-material column
// with a hairline edge, rows drawn by hand rather than by `List`, and one
// rounded highlight that slides between rows instead of each row painting
// its own.

/// The sidebar column's background: the system sidebar material with a
/// hairline on its trailing edge.
struct SidebarMaterialBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .underPageBackgroundColor)
            } else {
                SidebarMaterialView()
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .clipShape(Rectangle())
        .ignoresSafeArea()
    }
}

private struct SidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = .sidebar
        view.blendingMode = .withinWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// One navigation row: glyph, title, and an optional count.
struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    var badgeCount = 0
    var brandAsset: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let brandAsset {
                    Image(brandAsset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: systemImage)
                        .symbolVariant(isSelected ? .fill : .none)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
                // The selected row's glyph takes the accent, so the row stays
                // the anchor even when the window is inactive.
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: Capsule())
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if isSelected {
                SidebarSelectionHighlight()
                    .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionNamespace)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// The rounded glass lozenge behind the selected row. Thinner material while
/// the window is key, the duller bar material when it isn't.
private struct SidebarSelectionHighlight: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .controlBackgroundColor))
            } else {
                shape.fill(controlActiveState == .active ? Material.ultraThinMaterial : Material.bar)
            }
        }
        .overlay {
            shape
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

/// Each row's frame in the sidebar's coordinate space, so a drag can select
/// whichever row it's over.
struct SidebarRowFramesKey: PreferenceKey {
    static var defaultValue: [SidebarItem: CGRect] { [:] }

    static func reduce(value: inout [SidebarItem: CGRect], nextValue: () -> [SidebarItem: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
