import Foundation

enum AppLogger {
    private static let queue = DispatchQueue(label: "voxbar.logger", qos: .utility)

    static func info(_ message: String, metadata: [String: String] = [:]) {
        write(level: "INFO", message: message, metadata: metadata)
    }

    static func error(_ message: String, metadata: [String: String] = [:]) {
        write(level: "ERROR", message: message, metadata: metadata)
    }

    private static func write(level: String, message: String, metadata: [String: String]) {
        queue.async {
            do {
                try AppPaths.ensureDirectories()
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let metadataText = metadata
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                let line = metadataText.isEmpty
                    ? "\(timestamp) [\(level)] \(message)\n"
                    : "\(timestamp) [\(level)] \(message) \(metadataText)\n"
                if let data = line.data(using: .utf8) {
                    if FileManager().fileExists(atPath: AppPaths.appLogFile.path) {
                        let handle = try FileHandle(forWritingTo: AppPaths.appLogFile)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: data)
                    } else {
                        try data.write(to: AppPaths.appLogFile, options: .atomic)
                    }
                }
            } catch {
                fputs("VoxBar logging failed: \(error)\n", stderr)
            }
        }
    }
}
