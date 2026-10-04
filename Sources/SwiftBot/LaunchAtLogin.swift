import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// Launch-at-login state as `SMAppService` reports it, collapsed to what the UI needs.
enum LaunchAtLoginState: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the person has to allow it in System Settings › Login Items.
    case requiresApproval
    case unavailable
}

/// Registers SwiftBot to open at login. A protocol so the settings UI can be
/// previewed and tested without touching the real login items.
@MainActor
protocol LaunchAtLoginControlling {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp`: the app itself as a login item.
@MainActor
struct SystemLaunchAtLogin: LaunchAtLoginControlling {
    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// The login item's state for the settings UI. The system owns the truth (the
/// person can change it in System Settings at any time), so this re-reads it
/// rather than persisting a copy.
@MainActor
@Observable
final class LaunchAtLoginModel {
    private(set) var state: LaunchAtLoginState
    private(set) var errorMessage: String?

    private let controller: any LaunchAtLoginControlling

    init(controller: any LaunchAtLoginControlling = SystemLaunchAtLogin()) {
        self.controller = controller
        self.state = controller.state
    }

    /// On when registered, including while it waits for approval, so the
    /// switch matches what the person asked for.
    var isOn: Bool {
        state == .enabled || state == .requiresApproval
    }

    func refresh() {
        state = controller.state
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try controller.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        state = controller.state
    }
}

/// "Launch SwiftBot at Login" for Settings › General, with the approval
/// hand-off to System Settings when macOS asks for it.
struct LaunchAtLoginToggle: View {
    @State private var model = LaunchAtLoginModel()

    var body: some View {
        Toggle(isOn: Binding(get: { model.isOn }, set: { model.setEnabled($0) })) {
            Text("Launch SwiftBot at login")
            if let detail {
                Text(detail)
            }
        }
        .disabled(model.state == .unavailable)
        .onAppear { model.refresh() }
        // The person may have approved or removed the item in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }

        if model.state == .requiresApproval {
            LabeledContent("Allow SwiftBot in Login Items to finish turning this on.") {
                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            .font(.callout)
        }
    }

    private var detail: String? {
        if let message = model.errorMessage { return message }
        switch model.state {
        case .unavailable: return "Unavailable for this copy of SwiftBot. Move it to the Applications folder."
        case .enabled, .disabled, .requiresApproval: return "Keeps SwiftBot running after you restart this Mac."
        }
    }
}
