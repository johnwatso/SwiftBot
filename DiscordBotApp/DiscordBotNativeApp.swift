import SwiftUI

@main
struct DiscordBotNativeApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .frame(minWidth: 1200, minHeight: 760)
        }
        .windowResizability(.contentSize)
    }
}
