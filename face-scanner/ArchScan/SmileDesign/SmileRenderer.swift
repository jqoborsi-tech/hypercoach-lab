import Foundation
import UIKit
import CoreGraphics

/// Draws the parametric design over the photograph.
///
/// Nothing here is generated or invented: every edge comes from the tooth series in
/// `SmileDesignParameters`, so the picture and the numbers handed to the lab are the
/// same object. The watermark is not optional — a patient shown a rendered smile
/// remembers it as a promise, and this is a proposal.
enum SmileRenderer {

    static let simulationLabel = "SIMULATION — NOT A CLINICAL OUTCOME"

    /// Longest edge of the rendered image. Enough for a chairside screen and a printed
    /// consultation sheet, without decoding a 48 MP photo into a full-size context.
    static let maximumDimension: CGFloat = 2400

    static func render(photo: UIImage,
                       parameters: SmileDesignParameters,
                       practiceName: String?,
                       maxDimension: CGFloat = maximumDimension) -> UIImage? {
        let source = downscaled(photo, to: maxDimension)
        let size = source.size
        guard size.width > 1, size.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { rendererContext in
            let context = rendererContext.cgContext
            source.draw(in: CGRect(origin: .zero, size: size))

            let frame = parameters.frame(in: size)
            let aperture = aperturePath(parameters: parameters, size: size)

            context.saveGState()
            context.addPath(aperture.cgPath)
            context.clip()
            drawMouth(context: context,
                      parameters: parameters,
                      frame: frame,
                      apertureBounds: aperture.bounds)
            context.restoreGState()

            // A soft dark line just inside the lips, so the teeth read as sitting in
            // the mouth rather than pasted over it.
            context.saveGState()
            context.addPath(aperture.cgPath)
            context.clip()
            context.setShadow(offset: .zero, blur: size.width * 0.006,
                              color: UIColor(white: 0, alpha: 0.55).cgColor)
            context.setStrokeColor(UIColor(white: 0, alpha: 0.30).cgColor)
            context.setLineWidth(max(1, size.width * 0.004))
            context.addPath(aperture.cgPath)
            context.strokePath()
            context.restoreGState()

            drawWatermark(context: context, size: size, practiceName: practiceName)
        }
    }

    // MARK: - The mouth

    private static func drawMouth(context: CGContext,
                                  parameters: SmileDesignParameters,
                                  frame: SmileDesignParameters.Frame,
                                  apertureBounds: CGRect) {
        // 1. The dark interior, so anything not covered by a tooth reads as oral cavity.
        context.setFillColor(UIColor(red: 0.11, green: 0.05, blue: 0.05, alpha: 1).cgColor)
        context.fill(apertureBounds.insetBy(dx: -apertureBounds.width, dy: -apertureBounds.height))

        let teeth = parameters.teeth()
        guard !teeth.isEmpty else { return }

        // 2. Gingiva above the necks. Without this the space between lip and tooth
        // reads as a black gap, which is the giveaway in most mock-ups.
        let gingivalLine = teeth.flatMap { tooth -> [CGPoint] in
            let gingival = tooth.edgeY - tooth.length
            return stride(from: -0.5, through: 0.5, by: 0.25).map { fraction in
                SmileDesignParameters.project(tooth.centreX + tooth.width * fraction,
                                              gingival - gingivalScallop(tooth, fraction),
                                              in: frame)
            }
        }
        if gingivalLine.count > 2 {
            let gingiva = UIBezierPath()
            gingiva.move(to: CGPoint(x: apertureBounds.minX - 10, y: apertureBounds.minY - 10))
            gingiva.addLine(to: CGPoint(x: apertureBounds.maxX + 10, y: apertureBounds.minY - 10))
            let ordered = gingivalLine.sorted { $0.x > $1.x }
            for point in ordered { gingiva.addLine(to: point) }
            gingiva.close()
            context.saveGState()
            context.addPath(gingiva.cgPath)
            context.clip()
            drawVerticalGradient(context: context,
                                 rect: apertureBounds.insetBy(dx: -20, dy: -20),
                                 colors: [UIColor(red: 0.56, green: 0.28, blue: 0.28, alpha: 1),
                                          UIColor(red: 0.78, green: 0.45, blue: 0.44, alpha: 1)],
                                 locations: [0, 1])
            context.restoreGState()
        }

        // 3. Teeth, posteriors first so the anteriors overlap them at the corridor.
        for tooth in teeth.sorted(by: { abs($0.centreX) > abs($1.centreX) }) {
            drawTooth(tooth, context: context, parameters: parameters, frame: frame)
        }

        // 4. Shadow under the upper lip, falling onto the teeth.
        context.saveGState()
        let shadowHeight = apertureBounds.height * 0.42
        drawVerticalGradient(context: context,
                             rect: CGRect(x: apertureBounds.minX - 10, y: apertureBounds.minY - 10,
                                          width: apertureBounds.width + 20, height: shadowHeight),
                             colors: [UIColor(white: 0, alpha: 0.42), UIColor(white: 0, alpha: 0)],
                             locations: [0, 1])
        context.restoreGState()
    }

    /// The gingival margin is scalloped, highest over the middle of the tooth and
    /// dropping to the contact points.
    private static func gingivalScallop(_ tooth: SmileDesignParameters.ToothSpec, _ fraction: Double) -> Double {
        let depth = tooth.isPosterior ? 0.25 : 0.55
        return depth * (1 - 4 * fraction * fraction)     // zero at the contacts, peak at the centre
    }

    // MARK: - One tooth

    private static func drawTooth(_ tooth: SmileDesignParameters.ToothSpec,
                                  context: CGContext,
                                  parameters: SmileDesignParameters,
                                  frame: SmileDesignParameters.Frame) {
        let outline = toothOutline(tooth)
        guard outline.count > 3 else { return }
        let path = UIBezierPath()
        path.move(to: SmileDesignParameters.project(outline[0].x, outline[0].y, in: frame))
        for point in outline.dropFirst() {
            path.addLine(to: SmileDesignParameters.project(point.x, point.y, in: frame))
        }
        path.close()

        // Depth cue: the further round the arch, the less light reaches it.
        let depth = tooth.isPosterior ? 0.74 : (tooth.isCanine ? 0.93 : 1.0)
        let shade = parameters.shade
        func colour(_ value: SIMD3<Double>, _ factor: Double) -> UIColor {
            UIColor(red: value.x * factor, green: value.y * factor, blue: value.z * factor, alpha: 1)
        }

        context.saveGState()
        context.addPath(path.cgPath)
        context.clip()

        let gingivalPoint = SmileDesignParameters.project(tooth.centreX, tooth.edgeY - tooth.length, in: frame)
        let incisalPoint = SmileDesignParameters.project(tooth.centreX, tooth.edgeY, in: frame)
        drawGradient(context: context,
                     from: gingivalPoint, to: incisalPoint,
                     colors: [colour(shade.cervical, depth * 0.94),
                              colour(shade.cervical, depth),
                              colour(shade.body, depth),
                              colour(shade.body, depth * 1.02),
                              colour(shade.incisal, depth)],
                     locations: [0, 0.10, 0.42, 0.72, 1.0])

        // Incisal translucency: the enamel thins toward the edge and picks up the dark
        // of the mouth behind it.
        if !tooth.isPosterior {
            let translucencyStart = SmileDesignParameters.project(tooth.centreX, tooth.edgeY - tooth.length * 0.30, in: frame)
            drawGradient(context: context,
                         from: translucencyStart, to: incisalPoint,
                         colors: [UIColor(red: 0.44, green: 0.50, blue: 0.56, alpha: 0),
                                  UIColor(red: 0.40, green: 0.47, blue: 0.54, alpha: 0.30)],
                         locations: [0, 1])
        }
        context.restoreGState()

        // Proximal separation. A single hairline does more for realism than any amount
        // of surface texture.
        context.saveGState()
        context.addPath(path.cgPath)
        context.setStrokeColor(UIColor(red: 0.30, green: 0.24, blue: 0.20, alpha: 0.30).cgColor)
        context.setLineWidth(max(0.6, frame.scale * 0.09))
        context.strokePath()
        context.restoreGState()
    }

    /// Half width at a height up the tooth: `u` is 0 at the incisal edge and 1 at the
    /// gingival margin. A tooth is widest at the contact point, roughly a third of the
    /// way up — not at its middle, which is what leaves gaping interproximal wedges.
    private static func halfWidth(_ full: Double, at u: Double) -> Double {
        u <= 0.30
            ? full * (0.94 + (1.00 - 0.94) * (u / 0.30))
            : full * (1.00 + (0.87 - 1.00) * ((u - 0.30) / 0.70))
    }

    /// Tooth outline as a polyline in millimetres. Built as points rather than béziers
    /// so it can be projected through the design frame without transforming controls.
    ///
    /// The loop is strictly geometric — incisal edge left to right, up the right side,
    /// gingival right to left, down the left side. Mesial and distal decide only which
    /// corner is rounder and where the zenith sits; letting them drive the traversal
    /// order makes the outline cross itself on one side of the mouth.
    private static func toothOutline(_ tooth: SmileDesignParameters.ToothSpec) -> [(x: Double, y: Double)] {
        let half = tooth.width / 2
        let gingivalY = tooth.edgeY - tooth.length
        let mesialSign: Double = tooth.centreX < 0 ? 1 : -1     // +1 when mesial is toward +x
        let zenithX = tooth.centreX - mesialSign * tooth.width * 0.10
        let scallop = tooth.isPosterior ? 0.25 : 0.55
        let incisalHalf = halfWidth(half, at: 0)

        func edgeY(at x: Double) -> Double {
            if tooth.isCanine {
                // A canine cusp is a low point, not a fang: about half a millimetre,
                // with a shorter mesial slope than distal.
                let cusp = tooth.centreX + mesialSign * tooth.width * 0.10
                let offset = (x - cusp) / max(incisalHalf, 0.001)
                let slope = offset * mesialSign > 0 ? 0.62 : 1.0
                return tooth.edgeY - abs(offset) * slope * 0.75
            }
            if tooth.isPosterior {
                let normalised = (x - tooth.centreX) / tooth.width
                return tooth.edgeY - tooth.length * 0.10 * (1 - 4 * normalised * normalised)
            }
            let edge = (x - tooth.centreX) / half
            let corner = edge * mesialSign > 0 ? 0.42 : 0.72     // the distal corner is rounder
            return tooth.edgeY - pow(abs(edge), 4) * corner
        }

        var points: [(x: Double, y: Double)] = []
        points.reserveCapacity(56)

        for step in 0...16 {                                    // incisal edge, left to right
            let x = tooth.centreX - incisalHalf + 2 * incisalHalf * (Double(step) / 16)
            points.append((x, edgeY(at: x)))
        }
        for step in 1...12 {                                    // right proximal, incisal to gingival
            let u = Double(step) / 12
            points.append((tooth.centreX + halfWidth(half, at: u),
                           tooth.edgeY + (gingivalY - tooth.edgeY) * u))
        }
        let cervicalHalf = halfWidth(half, at: 1)
        for step in 0...12 {                                    // gingival margin, right to left
            let u = Double(step) / 12
            let x = tooth.centreX + cervicalHalf - 2 * cervicalHalf * u
            let fraction = (x - zenithX) / max(tooth.width, 0.001)
            points.append((x, gingivalY - max(0, scallop * (1 - 4 * fraction * fraction))))
        }
        for step in 1...11 {                                    // left proximal, gingival to incisal
            let u = 1.0 - Double(step) / 12
            points.append((tooth.centreX - halfWidth(half, at: u),
                           tooth.edgeY + (gingivalY - tooth.edgeY) * u))
        }
        return points
    }

    // MARK: - Lip aperture

    /// The design is clipped to the lip opening. When the clinician has not traced it,
    /// a lens shape through the commissures and the marked incisal level is a
    /// reasonable start that they can then drag into place.
    static func defaultLipContour(parameters: SmileDesignParameters) -> [CGPoint] {
        let right = parameters.commissureRight
        let left = parameters.commissureLeft
        let width = left.x - right.x
        let centreX = (right.x + left.x) / 2
        let centreY = (right.y + left.y) / 2
        let upper = min(parameters.incisalEdge.y, centreY) - abs(width) * 0.16
        let lower = centreY + abs(width) * 0.20

        return [
            right,
            CGPoint(x: centreX - width * 0.25, y: upper + abs(width) * 0.03),
            CGPoint(x: centreX, y: upper),
            CGPoint(x: centreX + width * 0.25, y: upper + abs(width) * 0.03),
            left,
            CGPoint(x: centreX + width * 0.22, y: lower),
            CGPoint(x: centreX, y: lower + abs(width) * 0.02),
            CGPoint(x: centreX - width * 0.22, y: lower)
        ]
    }

    static func aperturePath(parameters: SmileDesignParameters, size: CGSize) -> UIBezierPath {
        var contour = parameters.lipContour
        if contour.count < 4 { contour = defaultLipContour(parameters: parameters) }
        let points = contour.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        return smoothClosedPath(points)
    }

    /// Catmull-Rom through the control points, converted to cubic béziers, so dragging
    /// eight points gives a lip line rather than an octagon.
    static func smoothClosedPath(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard points.count >= 3 else { return path }
        let count = points.count
        path.move(to: points[0])
        for index in 0..<count {
            let p0 = points[(index - 1 + count) % count]
            let p1 = points[index]
            let p2 = points[(index + 1) % count]
            let p3 = points[(index + 2) % count]
            let control1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let control2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, controlPoint1: control1, controlPoint2: control2)
        }
        path.close()
        return path
    }

    // MARK: - Helpers

    private static func drawGradient(context: CGContext,
                                     from start: CGPoint, to end: CGPoint,
                                     colors: [UIColor], locations: [CGFloat]) {
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors.map { $0.cgColor } as CFArray,
                                        locations: locations) else { return }
        context.drawLinearGradient(gradient, start: start, end: end,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawVerticalGradient(context: CGContext, rect: CGRect,
                                             colors: [UIColor], locations: [CGFloat]) {
        context.saveGState()
        context.clip(to: rect)
        drawGradient(context: context,
                     from: CGPoint(x: rect.midX, y: rect.minY),
                     to: CGPoint(x: rect.midX, y: rect.maxY),
                     colors: colors, locations: locations)
        context.restoreGState()
    }

    private static func drawWatermark(context: CGContext, size: CGSize, practiceName: String?) {
        let barHeight = max(28, size.height * 0.042)
        let rect = CGRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
        context.setFillColor(UIColor(white: 0.08, alpha: 0.82).cgColor)
        context.fill(rect)

        let fontSize = barHeight * 0.42
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: UIColor.white,
            .kern: fontSize * 0.06
        ]
        let text = simulationLabel as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                              y: rect.midY - textSize.height / 2),
                  withAttributes: attributes)

        if let practiceName, !practiceName.isEmpty {
            let smallAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize * 0.8, weight: .semibold),
                .foregroundColor: UIColor(white: 1, alpha: 0.75)
            ]
            let name = practiceName as NSString
            let nameSize = name.size(withAttributes: smallAttributes)
            name.draw(at: CGPoint(x: size.width - nameSize.width - barHeight * 0.4,
                                  y: rect.minY - nameSize.height - barHeight * 0.25),
                      withAttributes: smallAttributes)
        }
    }

    private static func downscaled(_ image: UIImage, to limit: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > limit else {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: pixelSize))
            }
        }
        let factor = limit / longest
        let target = CGSize(width: (pixelSize.width * factor).rounded(),
                            height: (pixelSize.height * factor).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
