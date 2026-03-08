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

    private func applyWindowChromeIfAvailable() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.styleMask.insert(.fullSizeContentView)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true

            let cornerRadius: CGFloat = 24

            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.cornerRadius = 0
                contentView.layer?.masksToBounds = false
            }

            if let frameView = window.contentView?.superview {
                frameView.wantsLayer = true
                frameView.layer?.cornerRadius = cornerRadius
                frameView.layer?.cornerCurve = .continuous
                frameView.layer?.masksToBounds = true
            }

            window.invalidateShadow()
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
                    applyWindowChromeIfAvailable()
                    updater.checkForUpdatesInBackground()
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
        }
    }
}
