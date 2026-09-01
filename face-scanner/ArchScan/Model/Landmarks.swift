import Foundation
import simd

/// Which part of the analysis a landmark serves. The picker groups by this, and a
/// clinician doing a smile design only has to work through `facial` + `dental`.
enum LandmarkGroup: String, Codable, CaseIterable, Identifiable {
    case facial
    case dental
    case profile
    case calibration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .facial:      return "Facial reference"
        case .dental:      return "Smile design"
        case .profile:     return "Profile"
        case .calibration: return "Scale check"
        }
    }

    var note: String {
        switch self {
        case .facial:
            return "Pupils, tragi and orbitale points build the horizontal references; the midline points build the mid-sagittal plane."
        case .dental:
            return "Place these on the retracted or full-smile capture. They drive the incisal plane, the dental midline and the smile-line analysis."
        case .profile:
            return "Optional. Adds the Ricketts E-line and soft-tissue profile figures."
        case .calibration:
            return "Two ends of a physical reference of known length, for the scale check."
        }
    }
}

/// The landmark set ArchScan asks for, in the order it prompts for them.
/// Everything downstream (reference planes, measurements, the clinical alignment
/// frame) is derived from these points, so the identifiers are stable and are
/// written verbatim into `landmarks.json`.
enum LandmarkID: String, CaseIterable, Codable {
    // Facial reference
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

    // Smile design
    case incisalMidpoint      = "incisal_midpoint"
    case incisalEdgeRight     = "incisal_edge_right"
    case incisalEdgeLeft      = "incisal_edge_left"
    case canineTipRight       = "canine_tip_right"
    case canineTipLeft        = "canine_tip_left"
    case gingivalZenithRight  = "gingival_zenith_right"
    case gingivalZenithLeft   = "gingival_zenith_left"
    case upperLipLowPoint     = "upper_lip_low_point"
    case lowerLipMidpoint     = "lower_lip_midpoint"
    case buccalCorridorRight  = "buccal_corridor_right"
    case buccalCorridorLeft   = "buccal_corridor_left"

    // Profile
    case labialeSuperius   = "labiale_superius"
    case labialeInferius   = "labiale_inferius"
    case pogonion

    // Scale check
    case calibrationA      = "calibration_a"
    case calibrationB      = "calibration_b"

    var group: LandmarkGroup {
        switch self {
        case .incisalMidpoint, .incisalEdgeRight, .incisalEdgeLeft,
             .canineTipRight, .canineTipLeft,
             .gingivalZenithRight, .gingivalZenithLeft,
             .upperLipLowPoint, .lowerLipMidpoint,
             .buccalCorridorRight, .buccalCorridorLeft:
            return .dental
        case .labialeSuperius, .labialeInferius, .pogonion:
            return .profile
        case .calibrationA, .calibrationB:
            return .calibration
        default:
            return .facial
        }
    }

    var displayName: String {
        switch self {
        case .pupilRight:          return "Right pupil"
        case .pupilLeft:           return "Left pupil"
        case .glabella:            return "Glabella"
        case .nasion:              return "Nasion"
        case .pronasale:           return "Pronasale"
        case .subnasale:           return "Subnasale"
        case .alareRight:          return "Right alare"
        case .alareLeft:           return "Left alare"
        case .tragusRight:         return "Right tragus"
        case .tragusLeft:          return "Left tragus"
        case .orbitaleRight:       return "Right orbitale"
        case .orbitaleLeft:        return "Left orbitale"
        case .zygionRight:         return "Right zygion"
        case .zygionLeft:          return "Left zygion"
        case .cheilionRight:       return "Right cheilion"
        case .cheilionLeft:        return "Left cheilion"
        case .stomion:             return "Stomion"
        case .gnathion:            return "Gnathion"
        case .incisalMidpoint:     return "Dental midline"
        case .incisalEdgeRight:    return "Incisal edge, right central"
        case .incisalEdgeLeft:     return "Incisal edge, left central"
        case .canineTipRight:      return "Right canine tip"
        case .canineTipLeft:       return "Left canine tip"
        case .gingivalZenithRight: return "Gingival zenith, right central"
        case .gingivalZenithLeft:  return "Gingival zenith, left central"
        case .upperLipLowPoint:    return "Upper lip, low point"
        case .lowerLipMidpoint:    return "Lower lip, midline"
        case .buccalCorridorRight: return "Right buccal corridor"
        case .buccalCorridorLeft:  return "Left buccal corridor"
        case .labialeSuperius:     return "Labiale superius"
        case .labialeInferius:     return "Labiale inferius"
        case .pogonion:            return "Pogonion"
        case .calibrationA:        return "Calibration A"
        case .calibrationB:        return "Calibration B"
        }
    }

    /// What the clinician should tap, phrased the way it is taught.
    var guidance: String {
        switch self {
        case .pupilRight, .pupilLeft:
            return "Centre of the pupil, patient looking straight ahead. Defines the interpupillary line — the horizontal reference the incisal plane is judged against."
        case .glabella:
            return "Most prominent midline point between the brows."
        case .nasion:
            return "Deepest midline point of the nasal bridge, level with the inner canthi."
        case .pronasale:
            return "Most anterior point of the nasal tip. Anterior end of the Ricketts E-line."
        case .subnasale:
            return "Midline point where the columella meets the upper lip. Upper limit of the lower facial third."
        case .alareRight, .alareLeft:
            return "Most lateral point of the nasal ala. Anterior reference for Camper's plane, and a classic guide to intercanine width."
        case .tragusRight, .tragusLeft:
            return "Superior border of the tragus. Posterior reference for Camper's plane and Frankfort horizontal."
        case .orbitaleRight, .orbitaleLeft:
            return "Lowest point of the infraorbital rim. Anterior reference for Frankfort horizontal."
        case .zygionRight, .zygionLeft:
            return "Most lateral point of the zygomatic arch. Gives bizygomatic width for tooth-size selection."
        case .cheilionRight, .cheilionLeft:
            return "Labial commissure. Intercommissural width, lip cant, and the outer limit of the smile."
        case .stomion:
            return "Midline point of the lip contact line. On the rest capture this is what incisal display is measured from."
        case .gnathion:
            return "Lowest midline point of the chin. With subnasale this gives the lower facial height / VDO reference."
        case .incisalMidpoint:
            return "Midpoint of the contact between the two central incisors, at the incisal edge. This is the dental midline."
        case .incisalEdgeRight:
            return "Middle of the incisal edge of the RIGHT central incisor. With the left one this gives the incisal plane and its cant."
        case .incisalEdgeLeft:
            return "Middle of the incisal edge of the LEFT central incisor."
        case .canineTipRight, .canineTipLeft:
            return "Cusp tip of the canine. Intercanine width, and the corner of the smile arc."
        case .gingivalZenithRight, .gingivalZenithLeft:
            return "Most apical point of the gingival margin on the central incisor. With the incisal edge this gives clinical crown length."
        case .upperLipLowPoint:
            return "Lowest point of the upper lip border at the midline. Place on the FULL SMILE capture — this is the lip line for gingival display."
        case .lowerLipMidpoint:
            return "Highest point of the lower lip border at the midline, on the smile capture. The smile arc is judged against this curve."
        case .buccalCorridorRight, .buccalCorridorLeft:
            return "Most distal tooth surface visible in the smile, on that side. With the commissure this gives the buccal corridor."
        case .labialeSuperius:
            return "Most anterior point of the upper lip vermilion, in profile."
        case .labialeInferius:
            return "Most anterior point of the lower lip vermilion, in profile."
        case .pogonion:
            return "Most anterior soft-tissue point of the chin. Posterior end of the Ricketts E-line."
        case .calibrationA, .calibrationB:
            return "The two ends of your calibration reference of known length (sticker, ruler, or a marked bite fork)."
        }
    }

    /// Midline landmarks are used to fit the mid-sagittal plane.
    var isMidline: Bool {
        switch self {
        case .glabella, .nasion, .pronasale, .subnasale, .stomion, .gnathion:
            return true
        default:
            return false
        }
    }

    /// Needed before the clinical reference frame and the core measurements exist.
    static var coreSet: [LandmarkID] {
        [.pupilRight, .pupilLeft, .glabella, .nasion, .subnasale,
         .alareRight, .alareLeft, .tragusRight, .tragusLeft,
         .orbitaleRight, .orbitaleLeft, .cheilionRight, .cheilionLeft,
         .stomion, .gnathion]
    }

    /// The set that drives the smile-design figures.
    static var smileSet: [LandmarkID] {
        [.incisalMidpoint, .incisalEdgeRight, .incisalEdgeLeft,
         .canineTipRight, .canineTipLeft,
         .gingivalZenithRight, .gingivalZenithLeft,
         .upperLipLowPoint, .lowerLipMidpoint,
         .buccalCorridorRight, .buccalCorridorLeft]
    }

    /// Prompt order used by the guided picker.
    static var pickingOrder: [LandmarkID] {
        [.pupilRight, .pupilLeft, .orbitaleRight, .orbitaleLeft,
         .tragusRight, .tragusLeft, .glabella, .nasion, .pronasale,
         .alareRight, .alareLeft, .subnasale, .cheilionRight, .cheilionLeft,
         .stomion, .gnathion, .zygionRight, .zygionLeft,
         .incisalMidpoint, .incisalEdgeRight, .incisalEdgeLeft,
         .canineTipRight, .canineTipLeft,
         .gingivalZenithRight, .gingivalZenithLeft,
         .upperLipLowPoint, .lowerLipMidpoint,
         .buccalCorridorRight, .buccalCorridorLeft,
         .labialeSuperius, .labialeInferius, .pogonion,
         .calibrationA, .calibrationB]
    }

    static func inGroup(_ group: LandmarkGroup) -> [LandmarkID] {
        pickingOrder.filter { $0.group == group }
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

/// What the lab will align the face scan to.
enum RegistrationTarget: String, Codable, CaseIterable, Identifiable {
    case teeth
    case scanFlag = "scan_flag"
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teeth:    return "Visible teeth"
        case .scanFlag: return "Scan flag / bite fork"
        case .custom:   return "Custom markers"
        }
    }

    var guidance: String {
        switch self {
        case .teeth:
            return "Pick three or more widely separated points on tooth surfaces that are sharp in this scan — incisal edges and canine cusp tips. Wet enamel scatters the infrared pattern, so check the teeth actually reconstructed before relying on this route."
        case .scanFlag:
            return "The reliable route. Pick the flag's corners or its printed markers. The flag is a rigid object of known geometry, so the lab aligns flag-to-flag instead of trusting the tooth surfaces in a face scan."
        case .custom:
            return "Any features present in both this scan and the model — stickers, a jig, an appliance. Three minimum, more is better, spread out rather than collinear."
        }
    }
}

/// A point the lab uses to superimpose this scan onto the intraoral scan.
/// Exported as named markers so the same point can be identified in CAD.
struct RegistrationPoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var index: Int
    var label: String
    var x: Float
    var y: Float
    var z: Float

    init(index: Int, label: String, position: SIMD3<Float>) {
        self.index = index
        self.label = label
        self.x = position.x
        self.y = position.y
        self.z = position.z
    }

    var position: SIMD3<Float> {
        get { SIMD3<Float>(x, y, z) }
        set { x = newValue.x; y = newValue.y; z = newValue.z }
    }

    var markerName: String { "P\(index)" }
}
