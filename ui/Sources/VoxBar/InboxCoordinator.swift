import Foundation

final class InboxCoordinator: @unchecked Sendable {
    typealias RequestHandler = @MainActor (InboxRequest) -> Void

    private let fm = FileManager()
    private let queue = DispatchQueue(label: "voxbar.inbox", qos: .utility)
    private let handler: RequestHandler
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var isProcessing = false

    init(handler: @escaping RequestHandler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        do {
            try AppPaths.ensureDirectories()
            processPendingRequests()
            startWatchingInbox()
            AppLogger.info("Inbox coordinator started", metadata: ["path": AppPaths.inboxRoot.path])
        } catch {
            AppLogger.error(
                "Inbox coordinator failed to start",
                metadata: [
                    "path": AppPaths.inboxRoot.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    private func startWatchingInbox() {
        guard source == nil else { return }

        fileDescriptor = open(AppPaths.inboxRoot.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            AppLogger.error("Failed to watch inbox", metadata: ["path": AppPaths.inboxRoot.path])
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.processPendingRequests()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        self.source = source
        source.resume()
    }

    private func processPendingRequests() {
        guard !isProcessing else { return }
        isProcessing = true

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }

            let urls = self.pendingRequestURLs()
            for url in urls {
                self.consumeRequest(at: url)
            }
        }
    }

    private func pendingRequestURLs() -> [URL] {
        guard let contents = try? fm.contentsOfDirectory(
            at: AppPaths.inboxRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
                return lhsDate < rhsDate
            }
    }

    private func consumeRequest(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let request = try JSONDecoder().decode(InboxRequest.self, from: data)
            let trimmedInput = request.input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedInput.isEmpty else {
                try? fm.removeItem(at: url)
                return
            }

            try? fm.removeItem(at: url)
            let normalizedRequest = InboxRequest(
                input: trimmedInput,
                titleOverride: request.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
                disableMetadataTitle: request.disableMetadataTitle,
                autoGenerate: request.autoGenerate,
                origin: request.origin,
                sourceKind: request.sourceKind,
                createdAt: request.createdAt
            )
            let handler = self.handler
            Task { @MainActor in
                handler(normalizedRequest)
            }
            AppLogger.info(
                "Consumed inbox request",
                metadata: [
                    "path": url.path,
                    "origin": request.origin ?? "unknown",
                    "auto_generate": request.autoGenerate ? "true" : "false",
                ]
            )
        } catch {
            AppLogger.error(
                "Failed to consume inbox request",
                metadata: [
                    "path": url.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }
}
