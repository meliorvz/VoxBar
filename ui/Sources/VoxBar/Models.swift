import Foundation

enum InputSourceKind: String, Codable, CaseIterable {
    case url
    case text
}

enum GenerationPhase: String, Codable {
    case idle
    case fetching
    case rendering
    case saving
    case ready
    case failed
}

struct GenerationRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let title: String
    let metadataSummary: String?
    let tags: [String]?
    let metadataModel: String?
    let sourceKind: InputSourceKind
    let sourcePreview: String
    let voice: String
    let inputValue: String
    let runDirectory: String
    let textFile: String
    let audioFile: String
    let summary: String

    var audioURL: URL { URL(fileURLWithPath: audioFile) }
    var textURL: URL { URL(fileURLWithPath: textFile) }
    var runDirectoryURL: URL { URL(fileURLWithPath: runDirectory) }
    var tagList: [String] { tags ?? [] }
}

struct GenerationProgress: Equatable {
    var phase: GenerationPhase = .idle
    var message: String = "Ready"
    var detail: String = "Paste a URL or text, pick a voice, and generate."
    var chunkIndex: Int?
    var chunkTotal: Int?
    var logLines: [String] = []
    var lastError: String?

    var fraction: Double? {
        guard let chunkIndex, let chunkTotal, chunkTotal > 0 else { return nil }
        return min(max(Double(chunkIndex) / Double(chunkTotal), 0), 1)
    }
}

struct CLIResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct FavoriteVoiceSetting: Codable, Hashable, Identifiable {
    let voice: String
    let speed: Double

    var id: String {
        "\(voice)|\(String(format: "%.2f", speed))"
    }
}

enum VoiceGender: String {
    case female
    case male
    case unknown

    var shortLabel: String {
        switch self {
        case .female:
            return "F"
        case .male:
            return "M"
        case .unknown:
            return "?"
        }
    }

    var symbolName: String {
        switch self {
        case .female:
            return "person.crop.circle.badge.plus"
        case .male:
            return "person.crop.circle"
        case .unknown:
            return "person.crop.circle.dashed"
        }
    }
}

struct VoiceProfile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let gender: VoiceGender
    let regionCode: String
    let languageLabel: String

    init(id: String) {
        self.id = id

        let parts = id.split(separator: "_", maxSplits: 1).map(String.init)
        let family = parts.first ?? id
        let rawName = parts.count > 1 ? parts[1] : id

        displayName = rawName
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { fragment in
                let value = String(fragment)
                guard let first = value.first else { return value }
                return first.uppercased() + value.dropFirst()
            }
            .joined(separator: " ")

        if family.hasSuffix("f") {
            gender = .female
        } else if family.hasSuffix("m") {
            gender = .male
        } else {
            gender = .unknown
        }

        let localeKey = String(family.prefix(1))
        switch localeKey {
        case "a":
            regionCode = "US"
            languageLabel = "American English"
        case "b":
            regionCode = "UK"
            languageLabel = "British English"
        case "e":
            regionCode = "ES"
            languageLabel = "Spanish"
        case "f":
            regionCode = "FR"
            languageLabel = "French"
        case "h":
            regionCode = "IN"
            languageLabel = "Hindi"
        case "i":
            regionCode = "IT"
            languageLabel = "Italian"
        case "j":
            regionCode = "JP"
            languageLabel = "Japanese"
        case "p":
            regionCode = "BR"
            languageLabel = "Portuguese"
        case "z":
            regionCode = "CN"
            languageLabel = "Mandarin"
        default:
            regionCode = "--"
            languageLabel = "Unknown"
        }
    }
}
