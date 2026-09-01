import Foundation

/// The record set a full-arch or full-mouth rehabilitation case needs before anyone
/// designs anything. The list is the point of the app: it is a checklist that knows
/// what is missing, not a folder.
enum RecordKind: String, Codable, CaseIterable, Identifiable {
    // Extraoral photographs
    case faceRest            = "face_rest"
    case faceSmile           = "face_smile"
    case faceRetractedFront  = "face_retracted_front"
    case profileRight        = "profile_right"
    case profileLeft         = "profile_left"
    case threeQuarterRight   = "three_quarter_right"
    case threeQuarterLeft    = "three_quarter_left"
    case twelveOClock        = "twelve_oclock"

    // Intraoral photographs
    case intraoralFrontal    = "intraoral_frontal"
    case intraoralBuccalRight = "intraoral_buccal_right"
    case intraoralBuccalLeft  = "intraoral_buccal_left"
    case occlusalUpper       = "occlusal_upper"
    case occlusalLower       = "occlusal_lower"
    case overjetOverbite     = "overjet_overbite"

    // Video
    case videoDynamicSmile   = "video_dynamic_smile"
    case videoPhonetics      = "video_phonetics"
    case videoProfile        = "video_profile"

    // Scans and imports
    case facialScan          = "facial_scan"
    case intraoralScanUpper  = "intraoral_scan_upper"
    case intraoralScanLower  = "intraoral_scan_lower"
    case intraoralScanBite   = "intraoral_scan_bite"
    case cbct

    // Notes
    case shade
    case jawRelation         = "jaw_relation"
    case existingProsthesis  = "existing_prosthesis"

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case extraoral, intraoral, video, digital, notes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .extraoral: return "Extraoral photos"
            case .intraoral: return "Intraoral photos"
            case .video:     return "Video"
            case .digital:   return "Scans and imports"
            case .notes:     return "Notes"
            }
        }
    }

    enum Medium {
        case photo, video, facialScan, mesh, dicom, note
    }

    var group: Group {
        switch self {
        case .faceRest, .faceSmile, .faceRetractedFront, .profileRight, .profileLeft,
             .threeQuarterRight, .threeQuarterLeft, .twelveOClock:
            return .extraoral
        case .intraoralFrontal, .intraoralBuccalRight, .intraoralBuccalLeft,
             .occlusalUpper, .occlusalLower, .overjetOverbite:
            return .intraoral
        case .videoDynamicSmile, .videoPhonetics, .videoProfile:
            return .video
        case .facialScan, .intraoralScanUpper, .intraoralScanLower, .intraoralScanBite, .cbct:
            return .digital
        case .shade, .jawRelation, .existingProsthesis:
            return .notes
        }
    }

    var medium: Medium {
        switch group {
        case .extraoral, .intraoral: return .photo
        case .video:                 return .video
        case .notes:                 return .note
        case .digital:
            switch self {
            case .facialScan: return .facialScan
            case .cbct:       return .dicom
            default:          return .mesh
            }
        }
    }

    var title: String {
        switch self {
        case .faceRest:            return "Full face, lips at rest"
        case .faceSmile:           return "Full face, full smile"
        case .faceRetractedFront:  return "Full face, retracted"
        case .profileRight:        return "Right profile"
        case .profileLeft:         return "Left profile"
        case .threeQuarterRight:   return "Right three-quarter"
        case .threeQuarterLeft:    return "Left three-quarter"
        case .twelveOClock:        return "12 o'clock"
        case .intraoralFrontal:    return "Retracted frontal"
        case .intraoralBuccalRight: return "Right buccal"
        case .intraoralBuccalLeft:  return "Left buccal"
        case .occlusalUpper:       return "Upper occlusal"
        case .occlusalLower:       return "Lower occlusal"
        case .overjetOverbite:     return "Overjet / overbite"
        case .videoDynamicSmile:   return "Dynamic smile"
        case .videoPhonetics:      return "Phonetics"
        case .videoProfile:        return "Profile in function"
        case .facialScan:          return "Facial scan"
        case .intraoralScanUpper:  return "Intraoral scan, upper"
        case .intraoralScanLower:  return "Intraoral scan, lower"
        case .intraoralScanBite:   return "Bite registration"
        case .cbct:                return "CBCT"
        case .shade:               return "Shade"
        case .jawRelation:         return "Jaw relation"
        case .existingProsthesis:  return "Existing prosthesis"
        }
    }

    /// What to actually do, phrased for whoever is holding the phone.
    var guidance: String {
        switch self {
        case .faceRest:
            return "Lips at rest, teeth apart, no expression, eyes on the lens. The vertical dimension and incisal-display reference."
        case .faceSmile:
            return "Full unstrained smile, held. Lip line, gingival display and the smile arc are read from this."
        case .faceRetractedFront:
            return "Retractors in, full face in frame. Ties the dentition to the face."
        case .profileRight, .profileLeft:
            return "True profile, Frankfort horizontal parallel to the floor, lips at rest. Gives the E-line and the soft-tissue profile."
        case .threeQuarterRight, .threeQuarterLeft:
            return "Forty-five degrees, smiling. Shows the buccal corridor and how the arch turns."
        case .twelveOClock:
            return "From above and behind, looking down the face. The best view of an incisal-plane cant."
        case .intraoralFrontal:
            return "Retractors, teeth in centric, occlusal plane level in frame, mirror-free."
        case .intraoralBuccalRight, .intraoralBuccalLeft:
            return "Buccal corridor mirror shot, canine to last molar, teeth together."
        case .occlusalUpper, .occlusalLower:
            return "Mirror shot of the whole arch, midline vertical in frame, no saliva pooling."
        case .overjetOverbite:
            return "Teeth in centric from the side with a probe or ruler in view if you are recording the numbers."
        case .videoDynamicSmile:
            return "Ten seconds: rest, then a social smile, then a full smile, then back to rest. This is what a still photograph cannot show."
        case .videoPhonetics:
            return "Have the patient say \\"Emma\\" (lips at rest), \\"fifty-five\\" (F and V position the incisal edge), and \\"Mississippi\\" (closest speaking space)."
        case .videoProfile:
            return "Profile view while speaking and smiling. Shows lip support and how the profile changes in function."
        case .facialScan:
            return "3D facial scan captured in this app. Rest and smile at minimum; retracted or with a scan flag if the lab is merging it."
        case .intraoralScanUpper, .intraoralScanLower:
            return "Export the arch from your intraoral scanner as STL, PLY or OBJ and import it here."
        case .intraoralScanBite:
            return "The bite registration or the scanned jaw relation, in the same coordinate system as the arches."
        case .cbct:
            return "Export the volume as uncompressed DICOM and import the folder. Large fields of view take a moment to load."
        case .shade:
            return "Shade tab beside the tooth, same lighting, unpolarised and polarised if you have it. Record the tab used."
        case .jawRelation:
            return "How the vertical dimension and centric relation were recorded, and any planned change to the VDO."
        case .existingProsthesis:
            return "What the patient wears now, what they like about it and what they do not. The single most useful note in the file."
        }
    }

    /// Records without which an All-on-X or full-mouth plan cannot responsibly start.
    var isEssential: Bool {
        switch self {
        case .faceRest, .faceSmile, .intraoralFrontal, .occlusalUpper, .occlusalLower,
             .videoDynamicSmile, .facialScan, .intraoralScanUpper, .intraoralScanLower, .cbct,
             .jawRelation:
            return true
        default:
            return false
        }
    }

    /// More than one file is normal for these.
    var allowsMultiple: Bool {
        switch self {
        case .facialScan, .shade, .jawRelation, .existingProsthesis: return true
        default: return false
        }
    }

    static func inGroup(_ group: Group) -> [RecordKind] {
        allCases.filter { $0.group == group }
    }
}
