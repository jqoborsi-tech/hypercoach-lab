import Foundation
import SwiftUI

/// Everything lives in the app container under Documents/Cases/<case-uuid>/.
/// Files are written with complete file protection, so nothing is readable while
/// the device is locked.
@MainActor
final class CaseStore: ObservableObject {

    @Published private(set) var cases: [PatientCase] = []
    @Published var lastError: String?

    private let root: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = documents.appendingPathComponent("Cases", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Paths

    func directory(for caseID: UUID) -> URL {
        root.appendingPathComponent(caseID.uuidString, isDirectory: true)
    }

    func meshURL(caseID: UUID, capture: ScanCapture) -> URL {
        directory(for: caseID).appendingPathComponent(capture.meshFileName)
    }

    func textureURL(caseID: UUID, capture: ScanCapture) -> URL {
        directory(for: caseID).appendingPathComponent(capture.textureFileName)
    }

    func keyframeDirectory(caseID: UUID, captureID: UUID) -> URL {
        directory(for: caseID).appendingPathComponent("keyframes-\(captureID.uuidString)", isDirectory: true)
    }

    // MARK: - Loading and saving

    func reload() {
        var loaded: [PatientCase] = []
        let contents = (try? FileManager.default.contentsOfDirectory(at: root,
                                                                    includingPropertiesForKeys: nil)) ?? []
        for dir in contents {
            let metadata = dir.appendingPathComponent("case.json")
            guard let data = try? Data(contentsOf: metadata) else { continue }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let value = try? decoder.decode(PatientCase.self, from: data) {
                loaded.append(value)
            }
        }
        cases = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    private func persist(_ value: PatientCase) {
        do {
            let dir = directory(for: value.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(value)
            try data.write(to: dir.appendingPathComponent("case.json"),
                           options: [.atomic, .completeFileProtection])
        } catch {
            lastError = "Could not save the case: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    @discardableResult
    func createCase(code: String, note: String = "") -> PatientCase {
        var value = PatientCase()
        value.code = code
        value.note = note
        cases.insert(value, at: 0)
        persist(value)
        return value
    }

    func update(_ value: PatientCase) {
        if let idx = cases.firstIndex(where: { $0.id == value.id }) {
            cases[idx] = value
        } else {
            cases.insert(value, at: 0)
        }
        persist(value)
    }

    func delete(caseID: UUID) {
        cases.removeAll { $0.id == caseID }
        try? FileManager.default.removeItem(at: directory(for: caseID))
    }

    func caseByID(_ id: UUID) -> PatientCase? { cases.first { $0.id == id } }

    /// Stores a freshly reconstructed capture and its texture atlas.
    func addCapture(_ capture: ScanCapture,
                    mesh: ScanMesh,
                    textureJPEG: Data?,
                    to caseID: UUID) throws {
        guard var value = caseByID(caseID) else { return }
        let dir = directory(for: caseID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try MeshArchive.write(mesh, to: dir.appendingPathComponent(capture.meshFileName))
        if let textureJPEG {
            try textureJPEG.write(to: dir.appendingPathComponent(capture.textureFileName),
                                  options: [.atomic, .completeFileProtection])
        }
        value.captures.insert(capture, at: 0)
        update(value)
    }

    func updateCapture(_ capture: ScanCapture, in caseID: UUID) {
        guard var value = caseByID(caseID),
              let idx = value.captures.firstIndex(where: { $0.id == capture.id }) else { return }
        value.captures[idx] = capture
        update(value)
    }

    func deleteCapture(_ capture: ScanCapture, from caseID: UUID) {
        guard var value = caseByID(caseID) else { return }
        value.captures.removeAll { $0.id == capture.id }
        let dir = directory(for: caseID)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(capture.meshFileName))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(capture.textureFileName))
        try? FileManager.default.removeItem(at: keyframeDirectory(caseID: caseID, captureID: capture.id))
        update(value)
    }

    func loadMesh(caseID: UUID, capture: ScanCapture) -> ScanMesh? {
        try? MeshArchive.read(from: meshURL(caseID: caseID, capture: capture))
    }

    func loadTexture(caseID: UUID, capture: ScanCapture) -> Data? {
        try? Data(contentsOf: textureURL(caseID: caseID, capture: capture))
    }

    func keyframeURLs(caseID: UUID, captureID: UUID) -> [URL] {
        let dir = keyframeDirectory(caseID: caseID, captureID: captureID)
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
