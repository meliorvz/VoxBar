import AppKit
import SwiftUI

@main
struct VoxBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView(viewModel: appDelegate.viewModel)
        } label: {
            Label("VoxBar", systemImage: "waveform.circle.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
