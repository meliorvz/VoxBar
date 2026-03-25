import Foundation

final class HistoryStore {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let fm = FileManager()

    init() {
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> [GenerationRecord] {
        guard fm.fileExists(atPath: AppPaths.historyFile.path),
              let data = try? Data(contentsOf: AppPaths.historyFile),
              let records = try? decoder.decode([GenerationRecord].self, from: data) else {
            return []
        }

        return records.sorted(by: { $0.createdAt > $1.createdAt })
    }

    func save(_ records: [GenerationRecord]) {
        do {
            try AppPaths.ensureDirectories()
            let data = try encoder.encode(records)
            try data.write(to: AppPaths.historyFile, options: .atomic)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    func delete(_ record: GenerationRecord) {
        try? fm.removeItem(at: record.runDirectoryURL)
    }
}
