import Foundation
import CoreGraphics
import simd

/// A smile design laid out over a photograph.
///
/// This is a *parametric* design, not a generative one. Every tooth position comes
/// from a measurable rule — the interpupillary line, the facial midline, the golden
/// proportion series, a smile arc fitted to the lower lip — so the result is
/// reproducible, adjustable, and can be handed to the lab as numbers rather than as a
/// picture. It is a proposal to discuss and to build from, and it is watermarked as a
/// simulation because a patient shown a rendered smile will remember it as a promise.
struct SmileDesignParameters: Codable, Equatable {

    // MARK: - Points marked on the photograph, in normalised image coordinates (0...1)

    var pupilRight = CGPoint(x: 0.40, y: 0.42)
    var pupilLeft = CGPoint(x: 0.60, y: 0.42)
    /// A point on the facial midline — the philtrum is the usual choice.
    var midline = CGPoint(x: 0.50, y: 0.60)
    /// Where the incisal edge of the centrals should sit. The single most consequential
    /// decision in the design.
    var incisalEdge = CGPoint(x: 0.50, y: 0.68)
    var commissureRight = CGPoint(x: 0.42, y: 0.68)
    var commissureLeft = CGPoint(x: 0.58, y: 0.68)
    /// Closed contour of the lip aperture; the design is clipped to it.
    var lipContour: [CGPoint] = []

    // MARK: - Design controls

    /// True interpupillary distance in millimetres. Taken from the case's facial scan
    /// when there is one — which is what makes a photograph measurable.
    var interpupillaryMillimetres: Double = 63
    var interpupillaryIsMeasured = false

    /// Apparent width of the central incisor, seen from the front.
    var centralWidthMillimetres: Double = 8.6
    /// Width to length ratio of the central. 0.75–0.85 is the usual range; 0.80 reads
    /// as neither stubby nor horsey.
    var widthToLengthRatio: Double = 0.80
    /// How far the central edges hang below the canine tips.
    var smileArcDepthMillimetres: Double = 1.2
    /// Rotate the design so the incisal plane is level with the interpupillary line.
    var levelToInterpupillary = true
    /// Interproximal separation as a fraction of the central's width.
    var embrasureFraction: Double = 0.018
    var shade: ToothShade = .naturalLight
    var includeCanines = true
    var includePremolars = true

    enum ToothShade: String, Codable, CaseIterable, Identifiable {
        case bleach, naturalLight, natural, warm
        var id: String { rawValue }
        var title: String {
            switch self {
            case .bleach:       return "Bleach"
            case .naturalLight: return "Light natural"
            case .natural:      return "Natural"
            case .warm:         return "Warm"
            }
        }
        /// Body, cervical and incisal colours. Cervical is warmer and more saturated,
        /// the incisal third cooler and more translucent — that gradient is most of
        /// what makes a rendered tooth stop looking like a tile.
        var body: SIMD3<Double> {
            switch self {
            case .bleach:       return [0.976, 0.973, 0.957]
            case .naturalLight: return [0.949, 0.933, 0.890]
            case .natural:      return [0.918, 0.890, 0.827]
            case .warm:         return [0.890, 0.847, 0.760]
            }
        }
        var cervical: SIMD3<Double> {
            switch self {
            case .bleach:       return [0.945, 0.929, 0.890]
            case .naturalLight: return [0.906, 0.867, 0.788]
            case .natural:      return [0.867, 0.812, 0.706]
            case .warm:         return [0.831, 0.757, 0.624]
            }
        }
        var incisal: SIMD3<Double> {
            switch self {
            case .bleach:       return [0.965, 0.976, 0.984]
            case .naturalLight: return [0.925, 0.945, 0.957]
            case .natural:      return [0.882, 0.906, 0.925]
            case .warm:         return [0.855, 0.867, 0.878]
            }
        }
    }

    // MARK: - Derived geometry, in image pixels

    struct Frame {
        /// Unit vector along the design's horizontal, in image pixels.
        var horizontal: CGVector
        /// Unit vector pointing down the face, perpendicular to `horizontal`.
        var vertical: CGVector
        /// Image-pixel position of the dental midline at the incisal level.
        var origin: CGPoint
        /// Pixels per millimetre.
        var scale: Double
    }

    /// Builds the design frame for an image of the given pixel size.
    func frame(in size: CGSize) -> Frame {
        func pixel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * size.width, y: p.y * size.height)
        }
        let right = pixel(pupilRight)
        let left = pixel(pupilLeft)
        let pupilVector = CGVector(dx: left.x - right.x, dy: left.y - right.y)
        let pupilLength = max(hypot(pupilVector.dx, pupilVector.dy), 1)
        let scale = pupilLength / interpupillaryMillimetres

        var horizontal = CGVector(dx: pupilVector.dx / pupilLength, dy: pupilVector.dy / pupilLength)
        if !levelToInterpupillary {
            // Follow the commissures instead, which keeps an existing cant.
            let commissureVector = CGVector(dx: pixel(commissureLeft).x - pixel(commissureRight).x,
                                            dy: pixel(commissureLeft).y - pixel(commissureRight).y)
            let length = max(hypot(commissureVector.dx, commissureVector.dy), 1)
            horizontal = CGVector(dx: commissureVector.dx / length, dy: commissureVector.dy / length)
        }
        let vertical = CGVector(dx: -horizontal.dy, dy: horizontal.dx)

        // The dental midline runs down the face through the marked midline point; the
        // incisal edge sets how far down the design starts.
        let midlinePoint = pixel(midline)
        let edgePoint = pixel(incisalEdge)
        let alongVertical = (edgePoint.x - midlinePoint.x) * vertical.dx + (edgePoint.y - midlinePoint.y) * vertical.dy
        let origin = CGPoint(x: midlinePoint.x + vertical.dx * alongVertical,
                             y: midlinePoint.y + vertical.dy * alongVertical)

        return Frame(horizontal: horizontal, vertical: vertical, origin: origin, scale: scale)
    }

    /// Millimetre position (x across, y down) to image pixels.
    static func project(_ x: Double, _ y: Double, in frame: Frame) -> CGPoint {
        CGPoint(x: frame.origin.x + frame.horizontal.dx * x * frame.scale + frame.vertical.dx * y * frame.scale,
                y: frame.origin.y + frame.horizontal.dy * x * frame.scale + frame.vertical.dy * y * frame.scale)
    }

    /// Intercommissural width in millimetres, using the photo's own scale.
    func intercommissuralMillimetres(in size: CGSize) -> Double {
        let frame = frame(in: size)
        let right = CGPoint(x: commissureRight.x * size.width, y: commissureRight.y * size.height)
        let left = CGPoint(x: commissureLeft.x * size.width, y: commissureLeft.y * size.height)
        return hypot(left.x - right.x, left.y - right.y) / frame.scale
    }

    /// A starting central width from the smile width, when there is no bizygomatic
    /// measurement to use the Berry index on.
    static func suggestedCentralWidth(intercommissuralMillimetres: Double) -> Double {
        min(10.5, max(7.5, intercommissuralMillimetres * 0.165))
    }

    // MARK: - The tooth series

    struct ToothSpec {
        var name: String
        /// Apparent width seen from the front, in millimetres.
        var width: Double
        var length: Double
        /// Centre of the tooth along the arch, in millimetres from the midline.
        /// Negative is the patient's right.
        var centreX: Double
        /// Incisal edge position, in millimetres below the design origin.
        var edgeY: Double
        var isCanine: Bool
        var isPosterior: Bool
    }

    /// The golden-proportion series: each tooth's apparent width is 0.618 of the one
    /// before it as the arch turns away from the viewer. It is a starting point that
    /// looks right far more often than it looks wrong, and every value stays editable.
    func teeth() -> [ToothSpec] {
        let central = centralWidthMillimetres
        let lateral = central * 0.618
        let canine = lateral * 0.618
        // The golden ratio describes central : lateral : canine. Continuing it past the
        // canine produces 1.2 mm premolars, which no mouth has; posteriors foreshorten
        // more gently than that.
        let firstPremolar = canine * 0.75
        let secondPremolar = firstPremolar * 0.72

        var widths: [(String, Double, Bool, Bool)] = [
            ("central", central, false, false),
            ("lateral", lateral, false, false)
        ]
        if includeCanines { widths.append(("canine", canine, true, false)) }
        if includePremolars {
            widths.append(("first premolar", firstPremolar, false, true))
            widths.append(("second premolar", secondPremolar, false, true))
        }

        let lengths: [String: Double] = [
            "central": central / widthToLengthRatio,
            "lateral": central / widthToLengthRatio * 0.86,
            "canine": central / widthToLengthRatio * 0.96,
            "first premolar": central / widthToLengthRatio * 0.72,
            "second premolar": central / widthToLengthRatio * 0.64
        ]

        let gap = central * embrasureFraction
        // Half the span, used to normalise the smile arc.
        var cumulative = 0.0
        var offsets: [Double] = []
        for (_, width, _, _) in widths {
            offsets.append(cumulative + width / 2)
            cumulative += width + gap
        }
        let halfSpan = max(cumulative, 1)

        var out: [ToothSpec] = []
        for side in [-1.0, 1.0] {
            for (index, entry) in widths.enumerated() {
                let centreX = side * offsets[index]
                // The smile arc: edges rise toward the corners of the mouth, following
                // the lower lip. Quadratic is the shape a consonant arc actually takes.
                let normalised = abs(centreX) / halfSpan
                let edgeY = -smileArcDepthMillimetres * normalised * normalised
                out.append(ToothSpec(name: entry.0,
                                     width: entry.1,
                                     length: lengths[entry.0] ?? central,
                                     centreX: centreX,
                                     edgeY: edgeY,
                                     isCanine: entry.2,
                                     isPosterior: entry.3))
            }
        }
        return out.sorted { $0.centreX < $1.centreX }
    }

    /// The numbers the design implies, for the report and for the lab.
    func designMeasurements(in size: CGSize) -> [(String, String)] {
        let central = centralWidthMillimetres
        let smileWidth = intercommissuralMillimetres(in: size)
        return [
            ("Central incisor width", String(format: "%.2f mm", central)),
            ("Central incisor length", String(format: "%.2f mm", central / widthToLengthRatio)),
            ("Width : length", String(format: "%.2f", widthToLengthRatio)),
            ("Lateral apparent width", String(format: "%.2f mm", central * 0.618)),
            ("Canine apparent width", String(format: "%.2f mm", central * 0.618 * 0.618)),
            ("Smile arc depth", String(format: "%.2f mm", smileArcDepthMillimetres)),
            ("Intercommissural width", String(format: "%.1f mm", smileWidth)),
            ("Scale reference", interpupillaryIsMeasured
                ? String(format: "%.1f mm IPD, measured from the facial scan", interpupillaryMillimetres)
                : String(format: "%.1f mm IPD, assumed — no facial scan linked", interpupillaryMillimetres))
        ]
    }
}
