import Foundation

enum AppPaths {
    static var bridgeScript: URL {
        if let override = ProcessInfo.processInfo.environment["VOXBAR_BACKEND_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent("speak-article")
        }

        let bundleRoot = Bundle.main.bundleURL
        let repoRoot = bundleRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("backend/speak-article")
    }
    static let legacySupportRoot = FileManager().urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("ArticleTTSBar", isDirectory: true)

    static var supportRoot: URL {
        let fm = FileManager()
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = base.appendingPathComponent("VoxBar", isDirectory: true)
        migrateLegacySupportRootIfNeeded(from: legacySupportRoot, to: current)
        return current
    }

    static var historyFile: URL { supportRoot.appendingPathComponent("history.json") }
    static var runsRoot: URL { supportRoot.appendingPathComponent("Runs", isDirectory: true) }
    static var previewsRoot: URL { supportRoot.appendingPathComponent("Previews", isDirectory: true) }

    static func ensureDirectories() throws {
        let root = supportRoot
        let fm = FileManager()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: previewsRoot, withIntermediateDirectories: true)
    }

    private static func migrateLegacySupportRootIfNeeded(from legacyRoot: URL, to currentRoot: URL) {
        let fm = FileManager()
        guard fm.fileExists(atPath: legacyRoot.path), !fm.fileExists(atPath: currentRoot.path) else {
            return
        }

        do {
            try fm.moveItem(at: legacyRoot, to: currentRoot)
        } catch {
            print("Failed to migrate legacy support directory: \(error)")
        }
    }
}
