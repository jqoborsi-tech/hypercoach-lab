import Foundation
import ImageIO
import UIKit

/// File handling for records. Everything lives under the case folder, with complete
/// file protection, exactly like the scans.
extension CaseStore {

    func recordsDirectory(caseID: UUID) -> URL {
        directory(for: caseID).appendingPathComponent("records", isDirectory: true)
    }

    func url(for entry: RecordEntry, caseID: UUID) -> URL? {
        guard !entry.fileName.isEmpty else { return nil }
        return recordsDirectory(caseID: caseID).appendingPathComponent(entry.fileName)
    }

    /// Files a record. `data` is written under a name derived from the kind, so the
    /// export folder is self-describing rather than a pile of UUIDs.
    @discardableResult
    func addRecord(_ kind: RecordKind,
                   data: Data,
                   fileExtension: String,
                   note: String = "",
                   metadata: [String: String] = [:],
                   to caseID: UUID) -> RecordEntry? {
        guard var value = caseByID(caseID) else { return nil }
        let directory = recordsDirectory(caseID: caseID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var entry = RecordEntry(kind: kind, note: note, metadata: metadata)
        let suffix = value.records(of: kind).count
        entry.fileName = suffix == 0
            ? "\(kind.rawValue).\(fileExtension)"
            : "\(kind.rawValue)-\(suffix + 1).\(fileExtension)"

        do {
            try data.write(to: directory.appendingPathComponent(entry.fileName),
                           options: [.atomic, .completeFileProtection])
        } catch {
            lastError = "Could not save the record: \(error.localizedDescription)"
            return nil
        }

        if !kind.allowsMultiple {
            // Replace rather than accumulate: there is one "upper occlusal", and a
            // second attempt means the first one was no good.
            for old in value.records(of: kind) {
                if let url = url(for: old, caseID: caseID) { try? FileManager.default.removeItem(at: url) }
            }
            value.records.removeAll { $0.kind == kind }
        }
        value.records.append(entry)
        update(value)
        return entry
    }

    /// Copies an imported file (mesh, DICOM folder) into the case.
    @discardableResult
    func importRecord(_ kind: RecordKind,
                      from source: URL,
                      note: String = "",
                      metadata: [String: String] = [:],
                      to caseID: UUID) -> RecordEntry? {
        guard var value = caseByID(caseID) else { return nil }
        let directory = recordsDirectory(caseID: caseID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var entry = RecordEntry(kind: kind, note: note, metadata: metadata)
        let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let ext = source.pathExtension.isEmpty ? "" : ".\(source.pathExtension.lowercased())"
        entry.fileName = isDirectory ? "\(kind.rawValue)" : "\(kind.rawValue)\(ext)"
        let destination = directory.appendingPathComponent(entry.fileName)

        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            lastError = "Could not import that file: \(error.localizedDescription)"
            return nil
        }

        for old in value.records(of: kind) where !kind.allowsMultiple {
            if let url = url(for: old, caseID: caseID), url != destination {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if !kind.allowsMultiple { value.records.removeAll { $0.kind == kind } }
        value.records.append(entry)
        update(value)
        return entry
    }

    @discardableResult
    func addNoteRecord(_ kind: RecordKind, note: String, to caseID: UUID) -> RecordEntry? {
        guard var value = caseByID(caseID) else { return nil }
        var entry = RecordEntry(kind: kind, note: note)
        entry.fileName = ""
        if !kind.allowsMultiple { value.records.removeAll { $0.kind == kind } }
        value.records.append(entry)
        update(value)
        return entry
    }

    func updateRecord(_ entry: RecordEntry, in caseID: UUID) {
        guard var value = caseByID(caseID),
              let index = value.records.firstIndex(where: { $0.id == entry.id }) else { return }
        value.records[index] = entry
        update(value)
    }

    func deleteRecord(_ entry: RecordEntry, from caseID: UUID) {
        guard var value = caseByID(caseID) else { return }
        if let url = url(for: entry, caseID: caseID) { try? FileManager.default.removeItem(at: url) }
        value.records.removeAll { $0.id == entry.id }
        update(value)
    }

    // MARK: - Smile designs

    func smileDesignDirectory(caseID: UUID) -> URL {
        directory(for: caseID).appendingPathComponent("smile-designs", isDirectory: true)
    }

    func smileDesignURL(caseID: UUID, fileName: String) -> URL? {
        fileName.isEmpty ? nil : smileDesignDirectory(caseID: caseID).appendingPathComponent(fileName)
    }

    @discardableResult
    func saveSmileDesign(_ design: SmileDesignRecord,
                         photo: Data?,
                         render: Data?,
                         to caseID: UUID) -> SmileDesignRecord? {
        guard var value = caseByID(caseID) else { return nil }
        var design = design
        let directory = smileDesignDirectory(caseID: caseID)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let photo {
            if design.photoFileName.isEmpty { design.photoFileName = "\(design.id.uuidString)-source.jpg" }
            try? photo.write(to: directory.appendingPathComponent(design.photoFileName),
                             options: [.atomic, .completeFileProtection])
        }
        if let render {
            if design.renderFileName.isEmpty { design.renderFileName = "\(design.id.uuidString)-design.jpg" }
            try? render.write(to: directory.appendingPathComponent(design.renderFileName),
                              options: [.atomic, .completeFileProtection])
        }
        if let index = value.smileDesigns.firstIndex(where: { $0.id == design.id }) {
            value.smileDesigns[index] = design
        } else {
            value.smileDesigns.insert(design, at: 0)
        }
        update(value)
        return design
    }

    func deleteSmileDesign(_ design: SmileDesignRecord, from caseID: UUID) {
        guard var value = caseByID(caseID) else { return }
        for name in [design.photoFileName, design.renderFileName] where !name.isEmpty {
            if let url = smileDesignURL(caseID: caseID, fileName: name) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        value.smileDesigns.removeAll { $0.id == design.id }
        update(value)
    }

    func loadSmileDesignImage(caseID: UUID, fileName: String) -> UIImage? {
        guard let url = smileDesignURL(caseID: caseID, fileName: fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Thumbnail via ImageIO, so a 48 MP photo is not fully decoded to draw a 64-point tile.
    func thumbnail(for entry: RecordEntry, caseID: UUID, maxPixel: Int = 256) -> UIImage? {
        guard let url = url(for: entry, caseID: caseID) else { return nil }
        switch entry.kind.medium {
        case .photo:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        default:
            return nil
        }
    }
}
