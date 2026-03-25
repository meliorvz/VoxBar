import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = ArticleTTSViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLogger.info("Application launched")
    }
}
