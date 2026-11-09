import SwiftUI

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "dev.local.deezerlite.downloads" else {
            completionHandler()
            return
        }
        BackgroundDownloadManager.shared.handleBackgroundSession(completionHandler: completionHandler)
    }
}

@main
struct DeezerLiteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var player = Player.shared

    var body: some Scene {
        WindowGroup {
            RootView().environment(player)
        }
    }
}
