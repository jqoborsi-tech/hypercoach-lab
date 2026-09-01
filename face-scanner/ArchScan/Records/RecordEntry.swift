import Foundation

/// One filed record: a photo, a video, an imported mesh, a CBCT series, or a note.
struct RecordEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: RecordKind
    /// Relative to the case's `records` folder. Empty for note-only entries, and for a
    /// CBCT it is the folder name rather than a file.
    var fileName: String = ""
    var addedAt: Date = Date()
    var note: String = ""
    /// Free-form facts worth keeping with the record — DICOM geometry, mesh triangle
    /// counts, the shade tab used.
    var metadata: [String: String] = [:]
    /// For a facial scan, the capture it points at.
    var captureID: UUID?

    var isNoteOnly: Bool { fileName.isEmpty && captureID == nil }

    enum CodingKeys: String, CodingKey {
        case id, kind, fileName, addedAt, note, metadata, captureID
    }

    init(kind: RecordKind, fileName: String = "", note: String = "",
         metadata: [String: String] = [:], captureID: UUID? = nil) {
        self.kind = kind
        self.fileName = fileName
        self.note = note
        self.metadata = metadata
        self.captureID = captureID
    }

    // Written by hand so a case saved by an older build still opens: every field
    // except the kind falls back to a default rather than throwing. Losing a
    // patient's records to a schema change is not an acceptable failure mode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(RecordKind.self, forKey: .kind)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        captureID = try container.decodeIfPresent(UUID.self, forKey: .captureID)
    }
}

/// Completion summary for a case, which is what the records screen is really for.
struct RecordsProgress {
    var essentialTotal = 0
    var essentialPresent = 0
    var total = 0
    var present = 0

    var essentialFraction: Double {
        essentialTotal > 0 ? Double(essentialPresent) / Double(essentialTotal) : 0
    }

    var isReadyToPlan: Bool { essentialPresent == essentialTotal && essentialTotal > 0 }

    var summary: String {
        isReadyToPlan
            ? "Every essential record is on file."
            : "\(essentialTotal - essentialPresent) essential record\(essentialTotal - essentialPresent == 1 ? "" : "s") still missing."
    }
}
