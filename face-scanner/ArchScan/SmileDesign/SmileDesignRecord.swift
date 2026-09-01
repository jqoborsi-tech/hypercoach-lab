import Foundation
import CoreGraphics

/// A saved smile design: which photograph it was built on, the parameters, and when.
/// Stored with the case so a design can be reopened and adjusted rather than redone.
struct SmileDesignRecord: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = "Smile design"
    /// File name of the source photograph inside the case's `smile-designs` folder.
    var photoFileName: String = ""
    /// File name of the rendered result.
    var renderFileName: String = ""
    var parameters = SmileDesignParameters()
    var note: String = ""

    enum CodingKeys: String, CodingKey {
        case id, createdAt, title, photoFileName, renderFileName, parameters, note
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Smile design"
        photoFileName = try container.decodeIfPresent(String.self, forKey: .photoFileName) ?? ""
        renderFileName = try container.decodeIfPresent(String.self, forKey: .renderFileName) ?? ""
        parameters = try container.decodeIfPresent(SmileDesignParameters.self, forKey: .parameters) ?? SmileDesignParameters()
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}
