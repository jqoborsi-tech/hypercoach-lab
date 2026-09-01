import Foundation
import simd

/// A named anatomical plane, in metres, face-anchor space.
struct ReferencePlaneSpec {
    let key: String
    let label: String
    let point: SIMD3<Float>
    let normal: SIMD3<Float>
    let note: String
    /// Half-extent of the quad written into `reference-planes.stl`, in metres.
    let halfSize: Float
}

struct Measurement {
    let key: String
    let label: String
    let value: Double
    let unit: String
    let note: String?
}

/// Rigid transform from face-anchor space into the clinical reference frame
/// (+X patient's left, +Y superior, +Z anterior; right-handed, no mirroring).
struct ClinicalFrame {
    let transform: simd_float4x4
    let originDescription: String
    let axesDescription: String
}

struct CalibrationReference: Codable, Equatable {
    /// True distance between the two calibration landmarks, in millimetres.
    var expectedMillimetres: Double
    /// When true the export applies the derived uniform scale correction.
    var applyScaleToExports: Bool

    static let none = CalibrationReference(expectedMillimetres: 0, applyScaleToExports: false)
}

struct ClinicalAnalysis {
    var planes: [ReferencePlaneSpec] = []
    var measurements: [Measurement] = []
    var frame: ClinicalFrame?
    var warnings: [String] = []
    /// Uniform scale factor derived from the calibration reference (1.0 when unused).
    var scaleCorrection: Float = 1.0

    func measurement(_ key: String) -> Measurement? { measurements.first { $0.key == key } }

    // MARK: - Computation

    static func compute(landmarks: [LandmarkID: SIMD3<Float>],
                        calibration: CalibrationReference = .none) -> ClinicalAnalysis {
        var out = ClinicalAnalysis()
        func L(_ id: LandmarkID) -> SIMD3<Float>? { landmarks[id] }
        func mm(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double { Double(simd_distance(a, b)) * 1000 }

        // ---- Superior direction ------------------------------------------------
        // Prefer glabella -> gnathion, which survives partial landmark sets.
        var superior = SIMD3<Float>(0, 1, 0)
        if let g = L(.glabella), let gn = L(.gnathion) {
            superior = simd_normalize(g - gn)
        } else if let n = L(.nasion), let s = L(.subnasale) {
            superior = simd_normalize(n - s)
        } else {
            out.warnings.append("No midline vertical reference (glabella + gnathion) — using the face-anchor Y axis as superior.")
        }

        // ---- Frankfort horizontal ---------------------------------------------
        var frankfortNormal: SIMD3<Float>?
        var frankfortPoint = SIMD3<Float>.zero
        let frankfortPoints = [L(.tragusRight), L(.tragusLeft), L(.orbitaleRight), L(.orbitaleLeft)].compactMap { $0 }
        if frankfortPoints.count >= 3, var fit = MathKit.fitPlane(frankfortPoints).map({ ($0.point, $0.normal) }) {
            if simd_dot(fit.1, superior) < 0 { fit.1 = -fit.1 }
            frankfortNormal = fit.1
            frankfortPoint = fit.0
            out.planes.append(ReferencePlaneSpec(
                key: "frankfort_horizontal",
                label: "Frankfort horizontal",
                point: fit.0,
                normal: fit.1,
                note: "Fitted through both tragi (porion surrogate) and both orbitale points.",
                halfSize: 0.11))
        } else {
            out.warnings.append("Frankfort horizontal needs both tragi and at least one orbitale point.")
        }

        // A cant is read against the true horizontal, and Frankfort is what defines
        // that. Glabella–gnathion is only the fallback: it leans with the profile, so a
        // purely vertical difference measured against it picks up part of any
        // anterior-posterior offset as well.
        let vertical = frankfortNormal ?? superior

        // ---- Mid-sagittal plane ------------------------------------------------
        let midlinePoints = LandmarkID.allCases
            .filter { $0.isMidline }
            .compactMap { landmarks[$0] }

        var sagittalNormal: SIMD3<Float>?
        var sagittalPoint = SIMD3<Float>.zero

        if midlinePoints.count >= 3, let fit = MathKit.fitPlane(midlinePoints) {
            sagittalNormal = fit.normal
            sagittalPoint = fit.point
        } else if let pr = L(.pupilRight), let pl = L(.pupilLeft) {
            sagittalNormal = simd_normalize(pl - pr)
            sagittalPoint = (pl + pr) * 0.5
            out.warnings.append("Fewer than three midline landmarks — mid-sagittal plane derived from the pupils only.")
        }

        // Orient the sagittal normal toward the patient's left.
        if var n = sagittalNormal {
            if let pr = L(.pupilRight), let pl = L(.pupilLeft), simd_dot(n, pl - pr) < 0 { n = -n }
            n = MathKit.orthogonalize(n, against: vertical)   // keep it truly vertical
            sagittalNormal = n
            out.planes.append(ReferencePlaneSpec(
                key: "mid_sagittal",
                label: "Mid-sagittal plane",
                point: sagittalPoint,
                normal: n,
                note: "Least-squares fit through the midline landmarks, held perpendicular to the vertical reference.",
                halfSize: 0.10))
        }

        // ---- Camper's plane ----------------------------------------------------
        let camperPoints = [L(.alareRight), L(.alareLeft), L(.tragusRight), L(.tragusLeft)].compactMap { $0 }
        var camperNormal: SIMD3<Float>?
        if camperPoints.count >= 3, var fit = MathKit.fitPlane(camperPoints).map({ ($0.point, $0.normal) }) {
            if simd_dot(fit.1, vertical) < 0 { fit.1 = -fit.1 }
            camperNormal = fit.1
            out.planes.append(ReferencePlaneSpec(
                key: "campers_plane",
                label: "Camper's plane (ala–tragus)",
                point: fit.0,
                normal: fit.1,
                note: "Fitted through both alae and both tragi. Conventional guide for the occlusal plane in a full-arch set-up.",
                halfSize: 0.11))
        } else {
            out.warnings.append("Camper's plane needs both alae and both tragi.")
        }

        // ---- Anterior occlusal (incisal) plane --------------------------------
        let incisalPoints = [L(.incisalEdgeRight), L(.incisalEdgeLeft),
                             L(.canineTipRight), L(.canineTipLeft), L(.incisalMidpoint)].compactMap { $0 }
        var incisalNormal: SIMD3<Float>?
        if incisalPoints.count >= 3, var fit = MathKit.fitPlane(incisalPoints).map({ ($0.point, $0.normal) }) {
            if simd_dot(fit.1, vertical) < 0 { fit.1 = -fit.1 }
            incisalNormal = fit.1
            out.planes.append(ReferencePlaneSpec(
                key: "incisal_plane",
                label: "Anterior occlusal (incisal) plane",
                point: fit.0,
                normal: fit.1,
                note: "Fitted through the incisal edges and canine tips. This is the plane the set-up is judged against; compare it with the interpupillary plane, not with Camper's.",
                halfSize: 0.045))
        }

        // ---- Interpupillary plane ---------------------------------------------
        if let pr = L(.pupilRight), let pl = L(.pupilLeft), let sag = sagittalNormal {
            let dir = simd_normalize(pl - pr)
            let n = simd_normalize(simd_cross(dir, simd_cross(sag, dir)))  // in-plane vertical
            out.planes.append(ReferencePlaneSpec(
                key: "interpupillary_plane",
                label: "Interpupillary plane",
                point: (pl + pr) * 0.5,
                normal: simd_dot(n, vertical) < 0 ? -n : n,
                note: "Contains the interpupillary line and is perpendicular to the mid-sagittal plane. The usual horizontal aesthetic reference for the incisal plane.",
                halfSize: 0.10))
        }

        // ---- Clinical reference frame -----------------------------------------
        if let pr = L(.pupilRight), let pl = L(.pupilLeft) {
            let up = vertical
            let left = MathKit.orthogonalize(pl - pr, against: up)
            let anterior = simd_normalize(simd_cross(left, up))   // right-handed: L x S = A
            var origin = (pl + pr) * 0.5
            if let sag = sagittalNormal {
                // Project the origin onto the mid-sagittal plane so X = 0 is the facial midline.
                let d = simd_dot(origin - sagittalPoint, sag)
                origin -= sag * d
            }
            // Sanity check that +Z really points out of the face.
            if let pn = L(.pronasale) ?? L(.subnasale), let tr = L(.tragusRight), let tl = L(.tragusLeft) {
                let forward = pn - (tr + tl) * 0.5
                if simd_dot(anterior, forward) < 0 {
                    out.warnings.append("Anterior axis check failed — verify the pupil and tragus landmarks before trusting the aligned export.")
                }
            }
            out.frame = ClinicalFrame(
                transform: MathKit.frameTransform(origin: origin, x: left, y: up, z: anterior),
                originDescription: "Midpoint of the interpupillary line, projected onto the mid-sagittal plane.",
                axesDescription: "+X patient's left, +Y superior (normal of \(frankfortNormal != nil ? "Frankfort horizontal" : "the midline vertical")), +Z anterior. Right-handed, unmirrored, millimetres.")
        } else {
            out.warnings.append("Both pupils are required to build the clinical reference frame — the export will stay in raw scanner coordinates.")
        }

        // ---- Measurements ------------------------------------------------------
        var ms: [Measurement] = []

        if let pr = L(.pupilRight), let pl = L(.pupilLeft) {
            ms.append(Measurement(key: "interpupillary_distance", label: "Interpupillary distance",
                                  value: mm(pr, pl), unit: "mm",
                                  note: "Adult range is roughly 58–68 mm; a value far outside it points to a scale or landmark problem."))
            let cant = Double(asin(max(-1, min(1, simd_dot(simd_normalize(pl - pr), vertical)))) * 180 / .pi)
            ms.append(Measurement(key: "interpupillary_cant", label: "Interpupillary cant",
                                  value: cant, unit: "°",
                                  note: "Positive = patient's left pupil higher, measured against the Frankfort horizontal."))
        }
        if let cr = L(.cheilionRight), let cl = L(.cheilionLeft) {
            ms.append(Measurement(key: "intercommissural_width", label: "Intercommissural width",
                                  value: mm(cr, cl), unit: "mm",
                                  note: "Common starting width for the six anterior teeth in a full-arch set-up."))
            let cant = Double(asin(max(-1, min(1, simd_dot(simd_normalize(cl - cr), vertical)))) * 180 / .pi)
            ms.append(Measurement(key: "commissural_cant", label: "Commissural cant",
                                  value: cant, unit: "°", note: "Positive = patient's left commissure higher."))
            if let pr = L(.pupilRight), let pl = L(.pupilLeft) {
                let a = Double(MathKit.angleDegrees(between: pl - pr, and: cl - cr))
                ms.append(Measurement(key: "lip_to_pupil_divergence", label: "Lip line vs interpupillary line",
                                      value: a > 90 ? 180 - a : a, unit: "°",
                                      note: "Divergence between the smile line and the interpupillary line."))
            }
        }
        if let zr = L(.zygionRight), let zl = L(.zygionLeft) {
            ms.append(Measurement(key: "bizygomatic_width", label: "Bizygomatic width",
                                  value: mm(zr, zl), unit: "mm",
                                  note: "House / Berry proportion: central incisor width ≈ bizygomatic width ÷ 16."))
            ms.append(Measurement(key: "berry_central_incisor_width", label: "Berry index central incisor width",
                                  value: mm(zr, zl) / 16.0, unit: "mm", note: "Derived from bizygomatic width."))
        }
        if let ar = L(.alareRight), let al = L(.alareLeft) {
            ms.append(Measurement(key: "alar_width", label: "Alar width", value: mm(ar, al), unit: "mm",
                                  note: "Classic guide to intercanine distance."))
        }
        if let sn = L(.subnasale), let gn = L(.gnathion) {
            ms.append(Measurement(key: "lower_facial_height", label: "Lower facial height (subnasale–gnathion)",
                                  value: mm(sn, gn), unit: "mm",
                                  note: "Vertical dimension reference. Compare rest and prosthesis-in scans for the freeway space."))
        }
        if let g = L(.glabella), let sn = L(.subnasale) {
            ms.append(Measurement(key: "middle_facial_height", label: "Middle facial height (glabella–subnasale)",
                                  value: mm(g, sn), unit: "mm", note: nil))
            if let gn = L(.gnathion) {
                let ratio = mm(sn, gn) / max(mm(g, sn), 0.0001)
                ms.append(Measurement(key: "lower_to_middle_third_ratio", label: "Lower : middle third ratio",
                                      value: ratio, unit: "", note: "≈ 1.00 in a balanced face; below 0.95 suggests a collapsed vertical dimension."))
            }
        }
        if let camper = camperNormal, let frank = frankfortNormal {
            ms.append(Measurement(key: "camper_frankfort_angle", label: "Camper's plane vs Frankfort horizontal",
                                  value: Double(MathKit.planeAngleDegrees(camper, frank)), unit: "°",
                                  note: "Typically 10–15°. Use it to orient the occlusal plane when Frankfort is the mounting reference."))
        }
        if let sag = sagittalNormal {
            func deviation(_ id: LandmarkID, _ label: String) {
                guard let p = landmarks[id] else { return }
                let d = Double(simd_dot(p - sagittalPoint, sag)) * 1000
                ms.append(Measurement(key: "midline_deviation_\(id.rawValue)", label: label,
                                      value: d, unit: "mm", note: "Positive = displaced toward the patient's left."))
            }
            deviation(.stomion, "Stomion off the facial midline")
            deviation(.gnathion, "Gnathion off the facial midline")
            deviation(.incisalMidpoint, "Dental midline off the facial midline")
        }

        // ---- Smile design ------------------------------------------------------
        // Everything here is measured in the frontal projection where that is how the
        // eye judges it, and signed so that positive always means "toward the patient's
        // left" or "superior", never "toward the operator".
        let leftAxis = sagittalNormal ?? SIMD3<Float>(1, 0, 0)
        func cant(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> Double {
            let direction = simd_normalize(to - from)
            return Double(asin(max(-1, min(1, simd_dot(direction, vertical)))) * 180 / .pi)
        }

        if let ir = L(.incisalEdgeRight), let il = L(.incisalEdgeLeft) {
            let incisalCant = cant(ir, il)
            ms.append(Measurement(key: "incisal_plane_cant", label: "Incisal plane cant",
                                  value: incisalCant, unit: "°",
                                  note: "Positive = the patient's left central sits higher, measured against the Frankfort horizontal."))
            if let pr = L(.pupilRight), let pl = L(.pupilLeft) {
                ms.append(Measurement(key: "incisal_vs_interpupillary_cant",
                                      label: "Incisal plane vs interpupillary line",
                                      value: incisalCant - cant(pr, pl), unit: "°",
                                      note: "The number the eye actually reads. Under about 1° is imperceptible; past 2–3° the set-up looks tipped even when every tooth is correct."))
            }
            if let camper = camperNormal, let incisal = incisalNormal {
                ms.append(Measurement(key: "incisal_vs_camper", label: "Incisal plane vs Camper's plane",
                                      value: Double(MathKit.planeAngleDegrees(incisal, camper)), unit: "°",
                                      note: "Camper's plane is the posterior guide; a large divergence here means the anterior set-up and the posterior scheme disagree."))
            }
            if let midpoint = L(.incisalMidpoint) {
                let halfWidth = Double(simd_distance(midpoint, ir)) * 1000
                let estimated = halfWidth * 2
                ms.append(Measurement(key: "central_incisor_width_estimated",
                                      label: "Central incisor width (estimated)",
                                      value: estimated, unit: "mm",
                                      note: "Twice the midline-to-edge-centre distance. An estimate from the face scan — take the definitive width from the intraoral scan."))
                ms.append(Measurement(key: "golden_proportion_lateral",
                                      label: "Golden-proportion apparent lateral width",
                                      value: estimated * 0.618, unit: "mm",
                                      note: "Design target for the apparent width seen from the front, not the true mesio-distal width."))
                ms.append(Measurement(key: "golden_proportion_canine",
                                      label: "Golden-proportion apparent canine width",
                                      value: estimated * 0.618 * 0.618, unit: "mm", note: nil))
            }
        }

        if let gr = L(.gingivalZenithRight), let gl = L(.gingivalZenithLeft) {
            ms.append(Measurement(key: "gingival_zenith_cant", label: "Gingival zenith cant",
                                  value: cant(gr, gl), unit: "°",
                                  note: "Positive = the patient's left zenith is higher. A cant here with a level incisal plane means unequal crown lengths."))
            if let ir = L(.incisalEdgeRight) {
                ms.append(Measurement(key: "crown_length_right", label: "Clinical crown length, right central",
                                      value: mm(gr, ir), unit: "mm",
                                      note: "Zenith to incisal edge. Typical central is 10–11 mm."))
            }
            if let il = L(.incisalEdgeLeft) {
                ms.append(Measurement(key: "crown_length_left", label: "Clinical crown length, left central",
                                      value: mm(gl, il), unit: "mm", note: nil))
            }
            if let lip = L(.upperLipLowPoint) {
                let zenith = (gr + gl) * 0.5
                let display = Double(simd_dot(lip - zenith, vertical)) * 1000
                ms.append(Measurement(key: "gingival_display", label: "Gingival display at full smile",
                                      value: display, unit: "mm",
                                      note: "Positive = gingiva visible above the zeniths. Above about 3 mm reads as a gummy smile; negative means the lip covers the zenith."))
            }
        }

        if let stomion = L(.stomion), let incisal = L(.incisalMidpoint) {
            ms.append(Measurement(key: "incisal_display_at_rest", label: "Incisal display",
                                  value: Double(simd_dot(stomion - incisal, vertical)) * 1000, unit: "mm",
                                  note: "Positive = incisal edge below the lip line. Measure this on the REST capture: it is the starting point for incisal-edge position."))
        }

        if let cr = L(.canineTipRight), let cl = L(.canineTipLeft) {
            ms.append(Measurement(key: "intercanine_width", label: "Intercanine width (cusp tip)",
                                  value: mm(cr, cl), unit: "mm", note: nil))
            if let incisal = L(.incisalMidpoint) {
                let canineMid = (cr + cl) * 0.5
                let incisalDepth = Double(simd_dot(canineMid - incisal, vertical)) * 1000
                ms.append(Measurement(key: "incisal_curve_depth", label: "Incisal curve depth",
                                      value: incisalDepth, unit: "mm",
                                      note: "How far the central edges hang below the canine tips. Positive is the normal, consonant direction."))
                if let lipMid = L(.lowerLipMidpoint), let chR = L(.cheilionRight), let chL = L(.cheilionLeft) {
                    let commissureMid = (chR + chL) * 0.5
                    let lipDepth = Double(simd_dot(commissureMid - lipMid, vertical)) * 1000
                    ms.append(Measurement(key: "lower_lip_curve_depth", label: "Lower lip curve depth",
                                          value: lipDepth, unit: "mm", note: nil))
                    ms.append(Measurement(key: "smile_arc_harmony", label: "Smile arc vs lower lip",
                                          value: incisalDepth - lipDepth, unit: "mm",
                                          note: "Near zero is a consonant smile arc. Negative means the incisal curve is flatter than the lip — the usual ageing pattern, and the usual thing a design corrects."))
                }
            }
        }

        if let chR = L(.cheilionRight), let chL = L(.cheilionLeft),
           let bcR = L(.buccalCorridorRight), let bcL = L(.buccalCorridorLeft) {
            let smileWidth = Double(simd_distance(chR, chL)) * 1000
            let visibleWidth = Double(simd_distance(bcR, bcL)) * 1000
            let corridor = smileWidth - visibleWidth
            ms.append(Measurement(key: "buccal_corridor_total", label: "Buccal corridor, both sides",
                                  value: corridor, unit: "mm", note: nil))
            ms.append(Measurement(key: "buccal_corridor_ratio", label: "Buccal corridor as a share of smile width",
                                  value: smileWidth > 0 ? corridor / smileWidth * 100 : 0, unit: "%",
                                  note: "Around 10–15% reads as natural. Much more looks narrow-arched; much less looks denture-like."))
            ms.append(Measurement(key: "buccal_corridor_asymmetry", label: "Buccal corridor asymmetry",
                                  value: (Double(simd_distance(chL, bcL)) - Double(simd_distance(chR, bcR))) * 1000,
                                  unit: "mm", note: "Positive = wider corridor on the patient's left."))
        }

        if let incisal = L(.incisalMidpoint), let gr = L(.gingivalZenithRight), let gl = L(.gingivalZenithLeft) {
            // Long axis of the central incisors at the midline, read in the frontal plane.
            let axis = (gr + gl) * 0.5 - incisal
            let alongVertical = Double(simd_dot(axis, vertical))
            let alongLeft = Double(simd_dot(axis, leftAxis))
            ms.append(Measurement(key: "dental_midline_angulation", label: "Dental midline angulation",
                                  value: atan2(alongLeft, alongVertical) * 180 / .pi, unit: "°",
                                  note: "Tip of the midline away from vertical. Positive = the crowns lean toward the patient's left. A canted midline is more noticeable than a displaced one."))
        }

        // ---- Soft-tissue profile ------------------------------------------------
        if let pn = L(.pronasale), let pg = L(.pogonion) {
            let eLine = simd_normalize(pg - pn)
            func toELine(_ p: SIMD3<Float>) -> Double {
                let v = p - pn
                let along = simd_dot(v, eLine)
                let perpendicular = v - eLine * along
                // Signed by the anterior direction: positive = in front of the E-line.
                let anterior = simd_normalize(simd_cross(leftAxis, vertical))
                return Double(simd_dot(perpendicular, anterior)) * 1000
            }
            if let ls = L(.labialeSuperius) {
                ms.append(Measurement(key: "e_line_upper_lip", label: "Upper lip to E-line",
                                      value: toELine(ls), unit: "mm",
                                      note: "Ricketts: the upper lip normally sits about 4 mm behind the line, so around -4 mm here."))
            }
            if let li = L(.labialeInferius) {
                ms.append(Measurement(key: "e_line_lower_lip", label: "Lower lip to E-line",
                                      value: toELine(li), unit: "mm",
                                      note: "Normally about 2 mm behind the line."))
            }
        }

        // ---- Calibration -------------------------------------------------------
        if let a = L(.calibrationA), let b = L(.calibrationB), calibration.expectedMillimetres > 0 {
            let measured = mm(a, b)
            let expected = calibration.expectedMillimetres
            let error = measured - expected
            ms.append(Measurement(key: "calibration_measured", label: "Calibration reference, measured",
                                  value: measured, unit: "mm", note: "Expected \(String(format: "%.2f", expected)) mm."))
            ms.append(Measurement(key: "calibration_error", label: "Calibration error",
                                  value: error, unit: "mm", note: "Positive = the scan reads larger than the physical reference."))
            ms.append(Measurement(key: "calibration_error_percent", label: "Calibration error",
                                  value: error / expected * 100, unit: "%", note: nil))
            if calibration.applyScaleToExports, measured > 0 {
                out.scaleCorrection = Float(expected / measured)
            }
            if abs(error / expected) > 0.02 {
                out.warnings.append(String(format: "Calibration is off by %.1f%% — re-scan before using this file for anything load-bearing.", error / expected * 100))
            }
        } else if landmarks[.calibrationA] != nil || landmarks[.calibrationB] != nil {
            out.warnings.append("Calibration landmarks are incomplete — set both points and enter the true distance.")
        }

        out.measurements = ms
        return out
    }
}
