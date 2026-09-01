import Foundation
import simd

/// The landmark set ArchScan asks for, in the order it prompts for them.
/// Everything downstream (reference planes, measurements, the clinical alignment
/// frame) is derived from these points, so the identifiers are stable and are
/// written verbatim into `landmarks.json`.
enum LandmarkID: String, CaseIterable, Codable {
    case pupilRight        = "pupil_right"
    case pupilLeft         = "pupil_left"
    case glabella
    case nasion
    case pronasale
    case subnasale
    case alareRight        = "alare_right"
    case alareLeft         = "alare_left"
    case tragusRight       = "tragus_right"
    case tragusLeft        = "tragus_left"
    case orbitaleRight     = "orbitale_right"
    case orbitaleLeft      = "orbitale_left"
    case zygionRight       = "zygion_right"
    case zygionLeft        = "zygion_left"
    case cheilionRight     = "cheilion_right"
    case cheilionLeft      = "cheilion_left"
    case stomion
    case gnathion
    case incisalMidpoint   = "incisal_midpoint"
    case calibrationA      = "calibration_a"
    case calibrationB      = "calibration_b"

    var displayName: String {
        switch self {
        case .pupilRight:      return "Right pupil"
        case .pupilLeft:       return "Left pupil"
        case .glabella:        return "Glabella"
        case .nasion:          return "Nasion"
        case .pronasale:       return "Pronasale"
        case .subnasale:       return "Subnasale"
        case .alareRight:      return "Right alare"
        case .alareLeft:       return "Left alare"
        case .tragusRight:     return "Right tragus"
        case .tragusLeft:      return "Left tragus"
        case .orbitaleRight:   return "Right orbitale"
        case .orbitaleLeft:    return "Left orbitale"
        case .zygionRight:     return "Right zygion"
        case .zygionLeft:      return "Left zygion"
        case .cheilionRight:   return "Right cheilion"
        case .cheilionLeft:    return "Left cheilion"
        case .stomion:         return "Stomion"
        case .gnathion:        return "Gnathion"
        case .incisalMidpoint: return "Incisal midpoint"
        case .calibrationA:    return "Calibration A"
        case .calibrationB:    return "Calibration B"
        }
    }

    /// What the clinician should tap, phrased the way it is taught.
    var guidance: String {
        switch self {
        case .pupilRight, .pupilLeft:
            return "Centre of the pupil, patient looking straight ahead. Defines the interpupillary line."
        case .glabella:
            return "Most prominent midline point between the brows."
        case .nasion:
            return "Deepest midline point of the nasal bridge, level with the inner canthi."
        case .pronasale:
            return "Most anterior point of the nasal tip."
        case .subnasale:
            return "Midline point where the columella meets the upper lip. Upper limit of the lower facial third."
        case .alareRight, .alareLeft:
            return "Most lateral point of the nasal ala. Anterior reference for Camper's plane."
        case .tragusRight, .tragusLeft:
            return "Superior border of the tragus. Posterior reference for Camper's plane and Frankfort horizontal."
        case .orbitaleRight, .orbitaleLeft:
            return "Lowest point of the infraorbital rim. Anterior reference for Frankfort horizontal."
        case .zygionRight, .zygionLeft:
            return "Most lateral point of the zygomatic arch. Gives bizygomatic width for tooth-size selection."
        case .cheilionRight, .cheilionLeft:
            return "Labial commissure. Intercommissural width and lip cant."
        case .stomion:
            return "Midline point of the lip contact line at rest."
        case .gnathion:
            return "Lowest midline point of the chin. With subnasale this gives the lower facial height / VDO reference."
        case .incisalMidpoint:
            return "Midpoint of the incisal edges of the central incisors — capture this on the retracted or prosthesis-in scan."
        case .calibrationA, .calibrationB:
            return "The two ends of your calibration reference of known length (sticker, ruler, or bite-fork marker)."
        }
    }

    /// Midline landmarks are used to fit the mid-sagittal plane.
    var isMidline: Bool {
        switch self {
        case .glabella, .nasion, .pronasale, .subnasale, .stomion, .gnathion, .incisalMidpoint:
            return true
        default:
            return false
        }
    }

    /// Landmarks needed before the clinical reference frame and the core
    /// measurements can be computed.
    static var coreSet: [LandmarkID] {
        [.pupilRight, .pupilLeft, .glabella, .nasion, .subnasale,
         .alareRight, .alareLeft, .tragusRight, .tragusLeft,
         .orbitaleRight, .orbitaleLeft, .cheilionRight, .cheilionLeft,
         .stomion, .gnathion]
    }

    static var optionalSet: [LandmarkID] {
        [.pronasale, .zygionRight, .zygionLeft, .incisalMidpoint, .calibrationA, .calibrationB]
    }

    /// Prompt order used by the guided picker.
    static var pickingOrder: [LandmarkID] {
        [.pupilRight, .pupilLeft, .orbitaleRight, .orbitaleLeft,
         .tragusRight, .tragusLeft, .glabella, .nasion, .pronasale,
         .alareRight, .alareLeft, .subnasale, .cheilionRight, .cheilionLeft,
         .stomion, .gnathion, .zygionRight, .zygionLeft, .incisalMidpoint,
         .calibrationA, .calibrationB]
    }
}

/// A landmark placed on the reconstructed surface, stored in metres in
/// face-anchor space (the same frame as `ScanMesh.positions`).
struct Landmark: Codable, Identifiable, Equatable {
    var id: LandmarkID
    var x: Float
    var y: Float
    var z: Float

    init(id: LandmarkID, position: SIMD3<Float>) {
        self.id = id
        self.x = position.x
        self.y = position.y
        self.z = position.z
    }

    var position: SIMD3<Float> {
        get { SIMD3<Float>(x, y, z) }
        set { x = newValue.x; y = newValue.y; z = newValue.z }
    }
}
