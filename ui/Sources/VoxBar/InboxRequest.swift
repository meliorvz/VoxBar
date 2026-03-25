import Foundation

struct InboxRequest: Decodable {
    let input: String
    let titleOverride: String?
    let disableMetadataTitle: Bool?
    let autoGenerate: Bool
    let origin: String?
    let sourceKind: String?
    let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case input
        case titleOverride = "title"
        case disableMetadataTitle = "disable_metadata_title"
        case autoGenerate = "auto_generate"
        case origin
        case sourceKind = "source_kind"
        case createdAt = "created_at"
    }
}

