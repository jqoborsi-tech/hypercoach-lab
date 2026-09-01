import Foundation
import simd

/// Puts several captures of the same patient into one coordinate system.
///
/// A smile design is a comparison: rest against full smile, existing against
/// proposed, pre-op against delivered. That only works if the scans are superimposed,
/// and superimposed on parts of the face that did not move between them — the upper
/// face. Lips, chin and teeth all move with expression, so they are excluded from the
/// fit and are exactly what you want to *see* moving afterwards.
enum Superimposition {

    struct Result {
        /// Rigid transform mapping the source capture's scanner frame onto the reference's.
        var transform: simd_float4x4
        var rmsMillimetres: Float
        var maximumErrorMillimetres: Float
        var landmarksUsed: [LandmarkID]
    }

    /// Landmarks that stay put between a rest scan and a smile scan.
    static let stableLandmarks: [LandmarkID] = [
        .pupilRight, .pupilLeft, .orbitaleRight, .orbitaleLeft,
        .tragusRight, .tragusLeft, .glabella, .nasion, .pronasale,
        .alareRight, .alareLeft, .subnasale, .zygionRight, .zygionLeft
    ]

    static func align(source: ScanCapture, onto reference: ScanCapture) -> Result? {
        align(sourceLandmarks: source.landmarkMap, referenceLandmarks: reference.landmarkMap)
    }

    /// Overload taking raw maps, so the caller can align landmarks that have already had
    /// a calibration scale applied.
    static func align(sourceLandmarks sourceMap: [LandmarkID: SIMD3<Float>],
                      referenceLandmarks referenceMap: [LandmarkID: SIMD3<Float>]) -> Result? {
        let shared = stableLandmarks.filter { sourceMap[$0] != nil && referenceMap[$0] != nil }
        guard shared.count >= 3 else { return nil }

        let from = shared.map { sourceMap[$0]! }
        let to = shared.map { referenceMap[$0]! }
        guard let transform = rigidTransform(from: from, to: to) else { return nil }

        var sumSquares: Float = 0
        var worst: Float = 0
        for (index, point) in from.enumerated() {
            let h = transform * SIMD4<Float>(point.x, point.y, point.z, 1)
            let error = simd_distance(SIMD3<Float>(h.x, h.y, h.z), to[index])
            sumSquares += error * error
            worst = max(worst, error)
        }
        return Result(transform: transform,
                      rmsMillimetres: sqrt(sumSquares / Float(from.count)) * 1000,
                      maximumErrorMillimetres: worst * 1000,
                      landmarksUsed: shared)
    }

    /// Least-squares rigid transform between corresponding point sets — Horn's
    /// quaternion method. Rotation and translation only: no scaling, because the scan
    /// is a measurement and letting the fit rescale it would hide an error rather than
    /// reveal one.
    static func rigidTransform(from source: [SIMD3<Float>], to target: [SIMD3<Float>]) -> simd_float4x4? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let n = Float(source.count)
        var sourceCentroid = SIMD3<Float>.zero, targetCentroid = SIMD3<Float>.zero
        for i in source.indices { sourceCentroid += source[i]; targetCentroid += target[i] }
        sourceCentroid /= n
        targetCentroid /= n

        var sxx: Double = 0, sxy: Double = 0, sxz: Double = 0
        var syx: Double = 0, syy: Double = 0, syz: Double = 0
        var szx: Double = 0, szy: Double = 0, szz: Double = 0
        for i in source.indices {
            let s = source[i] - sourceCentroid
            let t = target[i] - targetCentroid
            sxx += Double(s.x * t.x); sxy += Double(s.x * t.y); sxz += Double(s.x * t.z)
            syx += Double(s.y * t.x); syy += Double(s.y * t.y); syz += Double(s.y * t.z)
            szx += Double(s.z * t.x); szy += Double(s.z * t.y); szz += Double(s.z * t.z)
        }

        // Horn's symmetric 4x4; its dominant eigenvector is the rotation quaternion.
        let n00 = sxx + syy + szz
        let matrix: [Double] = [
            n00,         syz - szy,      szx - sxz,      sxy - syx,
            syz - szy,   sxx - syy - szz, sxy + syx,     szx + sxz,
            szx - sxz,   sxy + syx,      -sxx + syy - szz, syz + szy,
            sxy - syx,   szx + sxz,      syz + szy,      -sxx - syy + szz
        ]
        guard let q = dominantEigenvector4(matrix) else { return nil }

        let quaternion = simd_quatf(ix: Float(q[1]), iy: Float(q[2]), iz: Float(q[3]), r: Float(q[0]))
        let rotation = simd_float3x3(simd_normalize(quaternion))
        let translation = targetCentroid - rotation * sourceCentroid
        let c0 = rotation.columns.0, c1 = rotation.columns.1, c2 = rotation.columns.2
        return simd_float4x4(
            SIMD4<Float>(c0.x, c0.y, c0.z, 0),
            SIMD4<Float>(c1.x, c1.y, c1.z, 0),
            SIMD4<Float>(c2.x, c2.y, c2.z, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1))
    }

    /// Cyclic Jacobi eigen-decomposition of a symmetric 4x4, returning the eigenvector
    /// belonging to the largest eigenvalue.
    private static func dominantEigenvector4(_ input: [Double]) -> [Double]? {
        guard input.count == 16 else { return nil }
        var a = input
        var v = [Double](repeating: 0, count: 16)
        for i in 0..<4 { v[i * 4 + i] = 1 }

        for _ in 0..<64 {
            var offDiagonal: Double = 0
            for p in 0..<4 { for q in (p + 1)..<4 { offDiagonal += a[p * 4 + q] * a[p * 4 + q] } }
            if offDiagonal < 1e-18 { break }

            for p in 0..<4 {
                for q in (p + 1)..<4 {
                    let apq = a[p * 4 + q]
                    if abs(apq) < 1e-20 { continue }
                    let theta = (a[q * 4 + q] - a[p * 4 + p]) / (2 * apq)
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot()
                    let s = t * c

                    for k in 0..<4 {
                        let akp = a[k * 4 + p], akq = a[k * 4 + q]
                        a[k * 4 + p] = c * akp - s * akq
                        a[k * 4 + q] = s * akp + c * akq
                    }
                    for k in 0..<4 {
                        let apk = a[p * 4 + k], aqk = a[q * 4 + k]
                        a[p * 4 + k] = c * apk - s * aqk
                        a[q * 4 + k] = s * apk + c * aqk
                    }
                    for k in 0..<4 {
                        let vkp = v[k * 4 + p], vkq = v[k * 4 + q]
                        v[k * 4 + p] = c * vkp - s * vkq
                        v[k * 4 + q] = s * vkp + c * vkq
                    }
                }
            }
        }

        var best = 0
        for i in 1..<4 where a[i * 4 + i] > a[best * 4 + best] { best = i }
        let vector = [v[best], v[4 + best], v[8 + best], v[12 + best]]
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 1e-12, vector.allSatisfy({ $0.isFinite }) else { return nil }
        return vector.map { $0 / length }
    }
}
