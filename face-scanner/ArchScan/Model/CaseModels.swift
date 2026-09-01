import Foundation
import simd

/// What the scan is of. Full-arch work normally needs at least a rest scan and a
/// retracted (or prosthesis-in) scan; the retracted one is what gets registered
/// against the intraoral scan.
enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case rest
    case smile
    case retracted
    case biteFork      = "bite_fork"
    case prosthesisIn  = "prosthesis_in"
    case postOp        = "post_op"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rest:         return "Rest / natural"
        case .smile:        return "Full smile"
        case .retracted:    return "Retracted"
        case .biteFork:     return "Bite fork / scan flag"
        case .prosthesisIn: return "Prosthesis in"
        case .postOp:       return "Post-op"
        }
    }

    var protocolNote: String {
        switch self {
        case .rest:
            return "Lips at rest, teeth apart, neutral expression, eyes open and looking at the lens. This is the reference for vertical dimension."
        case .smile:
            return "Full unstrained smile held steady. Used for the incisal display and smile line."
        case .retracted:
            return "Cheek retractors in, teeth in centric. This is the scan that registers to the intraoral scan."
        case .biteFork:
            return "Bite fork or scan flag seated and stable. Keep the whole marker inside the sweep so it can be matched in CAD."
        case .prosthesisIn:
            return "Trial prosthesis or provisional seated. Compare lower facial height against the rest scan."
        case .postOp:
            return "Definitive prosthesis delivered. Same protocol as the rest scan so the two can be superimposed."
        }
    }
}

/// Quality figures kept with each capture so a scan can be judged later.
struct CaptureQuality: Codable, Equatable {
    init() {}

    var integratedFrames: Int = 0
    var rejectedFrames: Int = 0
    var yawCoverageDegrees: Float = 0
    var pitchCoverageDegrees: Float = 0
    var voxelSizeMillimetres: Float = 1.2
    var vertexCount: Int = 0
    var triangleCount: Int = 0
    var surfaceAreaSquareCentimetres: Float = 0
    var medianPoseCorrectionMillimetres: Float = 0
    var meanDistanceCentimetres: Float = 0

    var coverageScore: Float {
        let yaw = min(yawCoverageDegrees / 110, 1)
        let pitch = min(pitchCoverageDegrees / 45, 1)
        let frames = min(Float(integratedFrames) / 120, 1)
        return (yaw * 0.5 + pitch * 0.25 + frames * 0.25)
    }
}

struct ScanCapture: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: CaptureKind = .rest
    var createdAt: Date = Date()
    var note: String = ""
    var landmarks: [Landmark] = []
    /// Points the lab superimposes onto the intraoral scan.
    var registrationPoints: [RegistrationPoint] = []
    var registrationTarget: RegistrationTarget = .scanFlag
    /// When set, this capture is exported in the reference capture's coordinate frame,
    /// so a rest scan and a smile scan of the same patient land superimposed.
    var superimposeOntoCaptureID: UUID?
    var calibration: CalibrationReference = .none
    var quality: CaptureQuality = CaptureQuality()
    /// Export in the landmark-derived clinical frame rather than raw scanner coordinates.
    var alignToClinicalFrame: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, note, landmarks, registrationPoints, registrationTarget
        case superimposeOntoCaptureID, calibration, quality, alignToClinicalFrame
    }

    init() {}

    // Hand-written so a case written by an older build still opens after the schema
    // grows. Every field but the identity falls back to a default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(CaptureKind.self, forKey: .kind) ?? .rest
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        landmarks = try container.decodeIfPresent([Landmark].self, forKey: .landmarks) ?? []
        registrationPoints = try container.decodeIfPresent([RegistrationPoint].self, forKey: .registrationPoints) ?? []
        registrationTarget = try container.decodeIfPresent(RegistrationTarget.self, forKey: .registrationTarget) ?? .scanFlag
        superimposeOntoCaptureID = try container.decodeIfPresent(UUID.self, forKey: .superimposeOntoCaptureID)
        calibration = try container.decodeIfPresent(CalibrationReference.self, forKey: .calibration) ?? .none
        quality = try container.decodeIfPresent(CaptureQuality.self, forKey: .quality) ?? CaptureQuality()
        alignToClinicalFrame = try container.decodeIfPresent(Bool.self, forKey: .alignToClinicalFrame) ?? true
    }

    var meshFileName: String { "\(id.uuidString).mesh" }
    var textureFileName: String { "\(id.uuidString).jpg" }

    var landmarkMap: [LandmarkID: SIMD3<Float>] {
        var out: [LandmarkID: SIMD3<Float>] = [:]
        for l in landmarks { out[l.id] = l.position }
        return out
    }

    var placedCoreCount: Int {
        let placed = Set(landmarks.map { $0.id })
        return LandmarkID.coreSet.filter { placed.contains($0) }.count
    }

    mutating func setLandmark(_ id: LandmarkID, position: SIMD3<Float>) {
        if let idx = landmarks.firstIndex(where: { $0.id == id }) {
            landmarks[idx].position = position
        } else {
            landmarks.append(Landmark(id: id, position: position))
        }
    }

    mutating func removeLandmark(_ id: LandmarkID) {
        landmarks.removeAll { $0.id == id }
    }

    var placedSmileCount: Int {
        let placed = Set(landmarks.map { $0.id })
        return LandmarkID.smileSet.filter { placed.contains($0) }.count
    }

    mutating func addRegistrationPoint(at position: SIMD3<Float>, label: String? = nil) {
        let index = (registrationPoints.map { $0.index }.max() ?? 0) + 1
        registrationPoints.append(RegistrationPoint(index: index,
                                                    label: label ?? "Point \(index)",
                                                    position: position))
    }

    mutating func removeRegistrationPoint(id: UUID) {
        registrationPoints.removeAll { $0.id == id }
        for (offset, _) in registrationPoints.enumerated() { registrationPoints[offset].index = offset + 1 }
    }

    func analysis() -> ClinicalAnalysis {
        ClinicalAnalysis.compute(landmarks: landmarkMap, calibration: calibration)
    }
}

struct PatientCase: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// Deliberately a code, not a name — see the privacy note in the README.
    var code: String = ""
    var note: String = ""
    var createdAt: Date = Date()
    var captures: [ScanCapture] = []
    /// Photographs, video, imported scans, the CBCT, and the written notes.
    var records: [RecordEntry] = []
    /// Smile designs built over a photograph.
    var smileDesigns: [SmileDesignRecord] = []

    var displayCode: String { code.isEmpty ? "Untitled case" : code }

    enum CodingKeys: String, CodingKey {
        case id, code, note, createdAt, captures, records, smileDesigns
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        code = try container.decodeIfPresent(String.self, forKey: .code) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        captures = try container.decodeIfPresent([ScanCapture].self, forKey: .captures) ?? []
        records = try container.decodeIfPresent([RecordEntry].self, forKey: .records) ?? []
        smileDesigns = try container.decodeIfPresent([SmileDesignRecord].self, forKey: .smileDesigns) ?? []
    }

    // MARK: - Records

    func records(of kind: RecordKind) -> [RecordEntry] {
        records.filter { $0.kind == kind }
    }

    func hasRecord(_ kind: RecordKind) -> Bool {
        if kind == .facialScan { return !captures.isEmpty }
        return records.contains { $0.kind == kind }
    }

    var recordsProgress: RecordsProgress {
        var progress = RecordsProgress()
        for kind in RecordKind.allCases {
            let present = hasRecord(kind)
            progress.total += 1
            if present { progress.present += 1 }
            if kind.isEssential {
                progress.essentialTotal += 1
                if present { progress.essentialPresent += 1 }
            }
        }
        return progress
    }

    var missingEssentials: [RecordKind] {
        RecordKind.allCases.filter { $0.isEssential && !hasRecord($0) }
    }
}
