import AppKit
import SwiftUI

@main
struct SwiftBotApp: App {
    @StateObject private var appModel = AppModel()

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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .frame(minWidth: 1200, minHeight: 760)
                .onAppear {
                    applyAppIconIfAvailable()
                }
        }
        .windowResizability(.contentSize)
    }
}
