import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = ArticleTTSViewModel()
    private var mainWindowController: NSWindowController?
    private var inboxCoordinator: InboxCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        inboxCoordinator = InboxCoordinator { [weak self] request in
            self?.showMainWindow()
            self?.viewModel.handleExternalInput(
                request.input,
                titleOverride: request.titleOverride,
                disableMetadataTitle: request.disableMetadataTitle,
                autoGenerate: request.autoGenerate
            )
        }
        inboxCoordinator?.start()
        AppLogger.info("Application launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        inboxCoordinator?.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func showMainWindow() {
        if mainWindowController == nil {
            let contentView = ContentView(viewModel: viewModel)
            let hostingController = NSHostingController(rootView: contentView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VoxBar"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("VoxBarMainWindow")
            mainWindowController = NSWindowController(window: window)
        }

        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleIncomingURL(_ url: URL) {
        guard let request = IncomingOpenRequest(url: url) else {
            AppLogger.error("Ignored unsupported incoming URL", metadata: ["url": url.absoluteString])
            return
        }

        showMainWindow()
        viewModel.handleExternalInput(
            request.input,
            titleOverride: request.titleOverride,
            disableMetadataTitle: request.disableMetadataTitle,
            autoGenerate: request.autoGenerate
        )
        AppLogger.info(
            "Handled incoming URL",
            metadata: [
                "action": request.autoGenerate ? "generate" : "open",
                "input_length": String(request.input.count),
                "has_title_override": request.titleOverride == nil ? "false" : "true",
            ]
        )
    }
}

private struct IncomingOpenRequest {
    let input: String
    let titleOverride: String?
    let disableMetadataTitle: Bool?
    let autoGenerate: Bool

    init?(url: URL) {
        guard url.scheme?.lowercased() == "voxbar" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })

        let action = IncomingOpenRequest.resolveAction(url: url)
        if let requestPath = queryMap["request"] ?? queryMap["file"],
           let payload = IncomingOpenRequest.loadPayload(from: requestPath) {
            let fallbackAutoGenerate = action == "generate"
                || IncomingOpenRequest.boolValue(queryMap["autoplay"])
                || IncomingOpenRequest.boolValue(queryMap["generate"])
            self.input = payload.input
            self.titleOverride = payload.titleOverride
            self.disableMetadataTitle = payload.disableMetadataTitle
            self.autoGenerate = payload.autoGenerate ?? fallbackAutoGenerate
            return
        }

        let input = queryMap["url"] ?? queryMap["text"] ?? queryMap["input"] ?? ""
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }

        self.input = trimmedInput
        self.titleOverride = queryMap["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.disableMetadataTitle = IncomingOpenRequest.optionalBoolValue(queryMap["no_metadata"])
            ?? IncomingOpenRequest.optionalBoolValue(queryMap["disable_metadata_title"])
        self.autoGenerate = action == "generate"
            || IncomingOpenRequest.boolValue(queryMap["autoplay"])
            || IncomingOpenRequest.boolValue(queryMap["generate"])
    }

    private static func resolveAction(url: URL) -> String {
        let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if let host, !host.isEmpty {
            return host
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return path
    }

    private static func boolValue(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func optionalBoolValue(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return boolValue(value)
    }

    private static func loadPayload(from rawPath: String) -> IncomingRequestPayload? {
        let fileURL: URL
        if let parsed = URL(string: rawPath), parsed.isFileURL {
            fileURL = parsed
        } else {
            fileURL = URL(fileURLWithPath: rawPath)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            let payload = try JSONDecoder().decode(IncomingRequestPayload.self, from: data)
            let trimmedInput = payload.input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInput.isEmpty else { return nil }
            return IncomingRequestPayload(
                input: trimmedInput,
                titleOverride: payload.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                disableMetadataTitle: payload.disableMetadataTitle,
                autoGenerate: payload.autoGenerate
            )
        } catch {
            AppLogger.error(
                "Failed to load incoming request payload",
                metadata: [
                    "path": fileURL.path,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }
}

private struct IncomingRequestPayload: Decodable {
    let input: String
    let titleOverride: String?
    let disableMetadataTitle: Bool?
    let autoGenerate: Bool?

    private enum CodingKeys: String, CodingKey {
        case input
        case titleOverride = "title"
        case disableMetadataTitle = "disable_metadata_title"
        case autoGenerate = "auto_generate"
    }
}
