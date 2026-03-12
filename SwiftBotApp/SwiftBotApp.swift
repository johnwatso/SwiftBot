import AppKit
import SwiftUI

@main
struct SwiftBotApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var updater = AppUpdater()

    private func applyAppIconIfAvailable() {
        if let image = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = image
            return
        }

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: iconURL)
        else { return }
        NSApp.applicationIconImage = image
    }

    private func applyMainWindowChrome(to window: NSWindow) {
        guard window.identifier != .settingsWindow else { return }
        guard !(window.titleVisibility == .hidden && window.backgroundColor == .clear && window.isOpaque == false) else { return }

        window.identifier = .mainWindow
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarSeparatorStyle = .none
        window.setContentBorderThickness(0, for: .minY)
        window.setContentBorderThickness(0, for: .maxY)
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])

        let cornerRadius: CGFloat = 12

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 0
            contentView.layer?.masksToBounds = false
            contentView.layer?.borderWidth = 0
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.cornerRadius = cornerRadius
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
            frameView.layer?.borderWidth = 0
            frameView.layer?.borderColor = NSColor.clear.cgColor
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if let chromeView = window.contentView?.superview?.superview {
            chromeView.wantsLayer = true
            chromeView.layer?.cornerRadius = cornerRadius
            chromeView.layer?.cornerCurve = .continuous
            chromeView.layer?.borderWidth = 0
            chromeView.layer?.borderColor = NSColor.clear.cgColor
            chromeView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        let trafficLightButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in trafficLightButtons {
            guard let button = window.standardWindowButton(type) else { continue }
            var origin = button.frame.origin
            origin.x += 14
            origin.y -= 10
            button.setFrameOrigin(origin)
        }

        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.action = #selector(NSWindow.performZoom(_:))
            zoomButton.target = window
        }

        window.invalidateShadow()
    }

    private func restoreSettingsWindowChrome(_ window: NSWindow) {
        window.identifier = .settingsWindow
        window.ignoresMouseEvents = false
        window.level = .normal
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarSeparatorStyle = .automatic
        window.setContentBorderThickness(0, for: .minY)
        window.setContentBorderThickness(0, for: .maxY)

        if let contentView = window.contentView {
            contentView.wantsLayer = false
            contentView.layer?.backgroundColor = nil
        }

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = false
            frameView.layer?.cornerRadius = 0
            frameView.layer?.borderWidth = 0
            frameView.layer?.backgroundColor = nil
        }

        if let chromeView = window.contentView?.superview?.superview {
            chromeView.wantsLayer = false
            chromeView.layer?.cornerRadius = 0
            chromeView.layer?.borderWidth = 0
            chromeView.layer?.backgroundColor = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .environmentObject(updater)
                .frame(minWidth: 1200, minHeight: 760)
                .onAppear {
                    applyAppIconIfAvailable()
                    updater.checkForUpdatesInBackground()
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .background(WindowAccessor { window in
                    applyMainWindowChrome(to: window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .sidebar) { }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }
            if appModel.canOpenRemoteDashboardFromLocalApp {
                CommandMenu("View") {
                    Button("Local Dashboard") {
                        appModel.viewMode = .local
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                    .disabled(appModel.viewMode == .local)

                    Button("Remote Dashboard") {
                        appModel.viewMode = .remote
                    }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                    .disabled(appModel.viewMode == .remote)
                }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(appModel)
                .environmentObject(updater)
                .background(WindowAccessor { window in
                    restoreSettingsWindowChrome(window)
                })
        }
        .windowResizability(.contentSize)
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "swiftbot" else { return }
        
        switch url.host {
        case "auth":
            handleAuthDeepLink(url)
        default:
            break
        }
    }

    private func handleAuthDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return }
        
        // Extract session token from deep link: swiftbot://auth?session=<token>
        if let sessionToken = queryItems.first(where: { $0.name == "session" })?.value,
           !sessionToken.isEmpty {
            // Store session token for remote authentication
            appModel.handleRemoteAuthSession(sessionToken)
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let mainWindow = NSUserInterfaceItemIdentifier("SwiftBotMainWindow")
    static let settingsWindow = NSUserInterfaceItemIdentifier("SwiftBotSettingsWindow")
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}
