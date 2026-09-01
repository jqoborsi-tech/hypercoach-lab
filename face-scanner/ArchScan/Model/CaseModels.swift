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
    var calibration: CalibrationReference = .none
    var quality: CaptureQuality = CaptureQuality()
    /// Export in the landmark-derived clinical frame rather than raw scanner coordinates.
    var alignToClinicalFrame: Bool = true

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

    var displayCode: String { code.isEmpty ? "Untitled case" : code }
}
