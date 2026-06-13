import AppKit
import SwiftUI

@main
struct SwiftBotApp: App {
    @NSApplicationDelegateAdaptor(SwiftBotAppDelegate.self) private var appDelegate
    @Environment(\.openSettings) private var openSettings
    @StateObject private var appModel = AppModel()
    @StateObject private var updater = AppUpdater()
    @StateObject private var statusItemController = SwiftBotStatusItemController()

    private func applyAppIconIfAvailable() {
        // Only apply once, cache the result (prevents icon flash on settings save)
        if NSApp.applicationIconImage != nil {
            return
        }
        
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

        positionTrafficLightButtons(in: window)

        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.action = #selector(NSWindow.performZoom(_:))
            zoomButton.target = window
        }

        window.invalidateShadow()
    }

    private func positionTrafficLightButtons(in window: NSWindow) {
        let trafficLightButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let leadingInset: CGFloat = 22
        let topInset: CGFloat = 22
        let spacing: CGFloat = 28

        for (index, type) in trafficLightButtons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            let titlebarHeight = button.superview?.bounds.height ?? 0
            let y = titlebarHeight > 0 ? titlebarHeight - topInset - button.frame.height : button.frame.origin.y
            button.setFrameOrigin(CGPoint(
                x: leadingInset + (CGFloat(index) * spacing),
                y: y
            ))
        }
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
            if AppModel.isRunningUnderXCTest {
                Color.clear.frame(width: 1, height: 1)
            } else {
                RootView()
                    .environmentObject(appModel)
                    .environmentObject(updater)
                    .frame(minWidth: 1200, minHeight: 760)
                    .onAppear {
                        applyAppIconIfAvailable()
                        applyPresenceMode(appModel.settings.presenceMode)
                        statusItemController.update(appModel: appModel, mode: appModel.settings.presenceMode) {
                            openSettings()
                        }
                        updater.checkForUpdatesInBackground()
                    }
                    .onOpenURL { url in
                        handleDeepLink(url)
                    }
                    .background(WindowAccessor { window in
                        applyMainWindowChrome(to: window)
                    })
            }
        }
        .onChange(of: appModel.settings.presenceMode) { _, newValue in
            applyPresenceMode(newValue)
            statusItemController.update(appModel: appModel, mode: newValue) {
                openSettings()
            }
        }
        .onChange(of: appModel.status) { _, _ in
            statusItemController.update(appModel: appModel, mode: appModel.settings.presenceMode) {
                openSettings()
            }
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
            // Mirrors SwiftMiner's Help menu: a single entry to save a fully
            // redacted diagnostic report for issue reports / debugging.
            CommandGroup(after: .help) {
                Button("Export Diagnostic Logs…") {
                    LogExporter.presentSavePanel(app: appModel)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
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
        switch url.scheme {
        case "swiftbot":
            switch url.host {
            case "auth":
                handleAuthDeepLink(url)
            case "swiftminer-pair":
                handleSwiftMinerPairingDeepLink(url)
            default:
                break
            }
        case "swiftmesh":
            // Stash the request; RootView shows a confirmation sheet. Never
            // auto-apply — a malicious link could otherwise repoint the node.
            Task { @MainActor in
                _ = appModel.handleSwiftMeshDeepLink(url)
            }
        default:
            break
        }
    }

    private func applyPresenceMode(_ mode: AppPresenceMode) {
        NSApp.setActivationPolicy(mode.showsDockIcon ? .regular : .accessory)
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

    private func handleSwiftMinerPairingDeepLink(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payload = components.queryItems?.first(where: { $0.name == "b" })?.value,
              !payload.isEmpty else { return }

        let result = appModel.applySwiftMinerPairingToken(payload)
        appModel.swiftMinerPairingStatusSucceeded = result.ok
        appModel.swiftMinerPairingStatusMessage = result.ok
            ? "SwiftMiner paired successfully. Discord DMs are ready."
            : result.message

        UserDefaults.standard.set(3, forKey: "swiftbot.preferences.selectedTab")
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

@MainActor
private final class SwiftBotStatusItemController: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private weak var appModel: AppModel?
    private var openSettings: (() -> Void)?

    func update(appModel: AppModel, mode: AppPresenceMode, openSettings: @escaping () -> Void) {
        self.appModel = appModel
        self.openSettings = openSettings

        guard mode.showsMenuBarIcon else {
            removeStatusItem()
            return
        }

        if statusItem == nil {
            createStatusItem()
        }

        rebuildMenu()
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.toolTip = "SwiftBot"

        let image = NSImage(named: "SwiftBirdMenuBar") ?? NSImage(named: "SwiftBird3")
        image?.isTemplate = true
        image?.size = NSSize(width: 22, height: 17)
        item.button?.image = image

        statusItem = item
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "Show SwiftBot",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        ))
        menu.items.last?.target = self

        menu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(showSettingsWindow),
            keyEquivalent: ","
        ))
        menu.items.last?.target = self

        menu.addItem(.separator())

        let statusText = appModel?.primaryServiceStatusText ?? "Status unavailable"
        let status = NSMenuItem()
        status.view = statusMenuRow(title: statusText)
        menu.addItem(status)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit SwiftBot",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        menu.items.last?.target = self

        statusItem?.menu = menu
    }

    private func statusMenuRow(title: String) -> NSView {
        let imageView = NSImageView()
        imageView.image = NSImage(
            systemSymbolName: statusSymbolName,
            accessibilityDescription: title
        )
        imageView.contentTintColor = statusSymbolColor
        imageView.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 210, height: 26))
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        return view
    }

    private var statusSymbolName: String {
        guard let appModel else { return "questionmark.circle.fill" }

        if appModel.primaryServiceIsOnline {
            return "checkmark.circle.fill"
        }

        switch appModel.status {
        case .connecting:
            return "bolt.horizontal.circle.fill"
        case .reconnecting:
            return "arrow.clockwise.circle.fill"
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "xmark.circle.fill"
        }
    }

    private var statusSymbolColor: NSColor {
        guard let appModel else { return .secondaryLabelColor }

        if appModel.primaryServiceIsOnline {
            return .systemGreen
        }

        switch appModel.status {
        case .connecting, .reconnecting:
            return .systemOrange
        case .running:
            return .systemGreen
        case .stopped:
            return .systemRed
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.identifier == .mainWindow }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            showSettingsWindow()
        }
    }

    @objc private func showSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private final class SwiftBotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await TunnelManager.shared.stopForAppTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let mainWindow = NSUserInterfaceItemIdentifier("SwiftBotMainWindow")
    static let settingsWindow = NSUserInterfaceItemIdentifier("SwiftBotSettingsWindow")
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResolve: onResolve)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.attach(to: window)
                onResolve(window)
            }
        }
    }

    final class Coordinator: @unchecked Sendable {
        private let onResolve: (NSWindow) -> Void
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?

        init(onResolve: @escaping (NSWindow) -> Void) {
            self.onResolve = onResolve
        }

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }

            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }

            self.window = window
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let resizedWindow = notification.object as? NSWindow else { return }
                self?.onResolve(resizedWindow)
            }
        }
    }
}
