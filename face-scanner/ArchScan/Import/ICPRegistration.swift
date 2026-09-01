import Foundation
import simd

/// Uniform-grid nearest-neighbour lookup over a mesh's vertices.
/// A KD-tree would be tidier; a hash grid is faster to build and dental surfaces are
/// close to uniformly sampled, which is the case a grid handles best.
final class PointGrid {
    private let cellSize: Float
    private let points: [SIMD3<Float>]
    private let normals: [SIMD3<Float>]
    private var cells: [Int64: [Int32]] = [:]

    init(points: [SIMD3<Float>], normals: [SIMD3<Float>], cellSize: Float) {
        self.cellSize = max(cellSize, 1e-5)
        self.points = points
        self.normals = normals
        cells.reserveCapacity(points.count / 4 + 16)
        for (index, p) in points.enumerated() {
            cells[key(for: p), default: []].append(Int32(index))
        }
    }

    @inline(__always)
    private func key(for p: SIMD3<Float>) -> Int64 {
        key(Int32(floor(p.x / cellSize)), Int32(floor(p.y / cellSize)), Int32(floor(p.z / cellSize)))
    }

    @inline(__always)
    private func key(_ x: Int32, _ y: Int32, _ z: Int32) -> Int64 {
        (Int64(x) &* 73_856_093) ^ (Int64(y) &* 19_349_663) ^ (Int64(z) &* 83_492_791)
    }

    /// Nearest vertex within `radius`, with its normal.
    func nearest(to p: SIMD3<Float>, radius: Float) -> (index: Int, distance: Float, normal: SIMD3<Float>)? {
        let cx = Int32(floor(p.x / cellSize)), cy = Int32(floor(p.y / cellSize)), cz = Int32(floor(p.z / cellSize))
        let span = Int32(max(1, Int((radius / cellSize).rounded(.up))))
        var best = -1
        var bestDistance = radius

        var dz = -span
        while dz <= span {
            var dy = -span
            while dy <= span {
                var dx = -span
                while dx <= span {
                    if let bucket = cells[key(cx + dx, cy + dy, cz + dz)] {
                        for candidate in bucket {
                            let distance = simd_distance(points[Int(candidate)], p)
                            if distance < bestDistance {
                                bestDistance = distance
                                best = Int(candidate)
                            }
                        }
                    }
                    dx += 1
                }
                dy += 1
            }
            dz += 1
        }
        guard best >= 0 else { return nil }
        return (best, bestDistance, normals[best])
    }
}

/// Point-to-plane ICP, used to settle a CBCT surface onto an intraoral scan after a
/// coarse three-point alignment.
///
/// Point-to-plane rather than point-to-point because dental surfaces slide against
/// each other: a plain point-to-point fit locks onto whatever sampling pattern the two
/// scanners happened to produce, while the plane formulation lets the points glide
/// along the surface and settle on the shape.
enum ICPRegistration {

    struct Result {
        /// Maps the source into the target's coordinate system.
        var transform: simd_float4x4
        var rmsMillimetres: Float
        var medianMillimetres: Float
        var inlierFraction: Float
        var iterations: Int
        var converged: Bool
        /// How far ICP moved the surface away from the coarse alignment the operator
        /// gave it. Refinement should be small; a large value means ICP slid the arch
        /// somewhere else, which a low RMS will happily conceal.
        var driftMillimetres: Float
        var driftDegrees: Float

        /// A registration is only usable if it fits closely, sees enough of the
        /// surface, AND stayed near where it was put. A low RMS on 12 % of the points
        /// is not a good registration — it is a small patch that found somewhere
        /// comfortable to sit. That failure mode is why the other two terms are here.
        var isTrustworthy: Bool {
            rmsMillimetres < 0.6 && inlierFraction >= 0.40 && driftMillimetres < 4.0 && driftDegrees < 6.0
        }

        var quality: String {
            guard inlierFraction >= 0.40 else {
                return "Rejected — only \(Int(inlierFraction * 100))% of the surface found a match"
            }
            guard driftMillimetres < 4.0, driftDegrees < 6.0 else {
                return "Rejected — the fit slid \(String(format: "%.1f", driftMillimetres)) mm off the points you picked"
            }
            switch rmsMillimetres {
            case ..<0.15: return "Excellent"
            case ..<0.30: return "Good"
            case ..<0.60: return "Acceptable"
            default:      return "Poor — do not use"
            }
        }
    }

    /// - Parameters:
    ///   - source: the mesh being moved (the CBCT surface).
    ///   - target: the mesh being matched (the intraoral scan, the more accurate one).
    ///   - initial: coarse alignment, normally from three picked point pairs.
    static func align(source: ScanMesh,
                      target: ScanMesh,
                      initial: simd_float4x4,
                      maximumIterations: Int = 40,
                      progress: ((Double) -> Void)? = nil) -> Result? {
        guard !source.isEmpty, !target.isEmpty,
              target.normals.count == target.positions.count else { return nil }

        // Subsample the source: ICP converges on a few thousand well-spread points just
        // as well as on half a million, and far faster.
        let sampleTarget = 6000
        let stride = max(1, source.positions.count / sampleTarget)
        var samples: [SIMD3<Float>] = []
        samples.reserveCapacity(sampleTarget + 1)
        var index = 0
        while index < source.positions.count {
            samples.append(source.positions[index])
            index += stride
        }

        let grid = PointGrid(points: target.positions, normals: target.normals, cellSize: 0.0015)
        var transform = initial
        var lastRMS = Float.greatestFiniteMagnitude
        var converged = false
        var iterationsRun = 0

        // Coarse to fine: start tolerant of a rough initial alignment, then tighten so
        // the final iterations only see genuine correspondences. Shrinking too fast
        // starves the fit of correspondences and lets it wander.
        var rejection: Float = 0.008

        // Keep the best iterate rather than the last. ICP on a smooth arch can slide
        // downhill into a worse pose while its residuals keep shrinking, so "the one it
        // stopped on" is not necessarily the one to return.
        var bestTransform = initial
        var bestScore = Float.greatestFiniteMagnitude
        var bestRMS = Float.greatestFiniteMagnitude
        var bestMedian = Float.greatestFiniteMagnitude
        var bestInliers: Float = 0
        let minimumInlierFraction: Float = 0.40

        for iteration in 0..<maximumIterations {
            iterationsRun = iteration + 1
            progress?(Double(iteration) / Double(maximumIterations))

            var ata = [Double](repeating: 0, count: 36)
            var atb = [Double](repeating: 0, count: 6)
            var pairs: [(position: SIMD3<Float>, normal: SIMD3<Float>, residual: Float)] = []
            pairs.reserveCapacity(samples.count)

            for p in samples {
                let h = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                let moved = SIMD3<Float>(h.x, h.y, h.z)
                guard let hit = grid.nearest(to: moved, radius: rejection) else { continue }
                let residual = simd_dot(moved - target.positions[hit.index], hit.normal)
                pairs.append((moved, hit.normal, residual))
            }
            guard pairs.count >= 100 else { break }

            // Trimmed ICP: keep the best 80 % by point-to-plane deviation, so a region
            // present in one scan and not the other cannot drag the fit. On a CBCT this
            // is what stops scatter around a restoration from pulling the arch over.
            let magnitudes = pairs.map { abs($0.residual) }.sorted()
            let cutoff = magnitudes[Int(Float(magnitudes.count) * 0.8)]
            var used = 0
            var inlierSquares: Float = 0

            for pair in pairs where abs(pair.residual) <= cutoff {
                let rotationPart = simd_cross(pair.position, pair.normal)
                let j: [Double] = [Double(rotationPart.x), Double(rotationPart.y), Double(rotationPart.z),
                                   Double(pair.normal.x), Double(pair.normal.y), Double(pair.normal.z)]
                let r = Double(pair.residual)
                for a in 0..<6 {
                    atb[a] -= j[a] * r
                    for b in 0..<6 { ata[a * 6 + b] += j[a] * j[b] }
                }
                inlierSquares += pair.residual * pair.residual
                used += 1
            }
            guard used >= 50 else { break }
            for a in 0..<6 { ata[a * 6 + a] *= 1.0 + 1e-6 }
            guard let xi = LinearSolver.solve6(ata, atb) else { break }

            let omega = SIMD3<Float>(Float(xi[0]), Float(xi[1]), Float(xi[2]))
            let translation = SIMD3<Float>(Float(xi[3]), Float(xi[4]), Float(xi[5]))
            guard omega.x.isFinite, translation.x.isFinite,
                  simd_length(translation) < 0.05, simd_length(omega) < 0.5 else { break }

            transform = TSDFVolume.exponentialMap(omega: omega, translation: translation) * transform

            let rms = sqrt(inlierSquares / Float(max(used, 1)))
            let fraction = Float(used) / Float(samples.count)

            // Score prefers a close fit, but only among iterates that actually see the
            // surface: an iterate matching 15 % of the points is not in the running
            // however small its residuals are.
            if fraction >= minimumInlierFraction, rms < bestScore {
                bestScore = rms
                bestRMS = rms
                bestMedian = magnitudes[magnitudes.count / 2]
                bestInliers = fraction
                bestTransform = transform
            }

            if abs(lastRMS - rms) < 1e-6 {
                converged = true
                lastRMS = rms
                break
            }
            lastRMS = rms
            rejection = max(0.0012, rejection * 0.92)
        }
        progress?(1)

        guard bestScore < .greatestFiniteMagnitude else { return nil }

        // How far the refinement moved things away from the operator's own alignment.
        let drift = ICPRegistration.difference(from: initial, to: bestTransform)
        return Result(transform: bestTransform,
                      rmsMillimetres: bestRMS * 1000,
                      medianMillimetres: bestMedian * 1000,
                      inlierFraction: bestInliers,
                      iterations: iterationsRun,
                      converged: converged,
                      driftMillimetres: drift.millimetres,
                      driftDegrees: drift.degrees)
    }

    /// Translation and rotation between two rigid transforms.
    static func difference(from a: simd_float4x4, to b: simd_float4x4) -> (millimetres: Float, degrees: Float) {
        let delta = b * simd_inverse(a)
        let translation = SIMD3<Float>(delta.columns.3.x, delta.columns.3.y, delta.columns.3.z)
        let rotation = simd_float3x3(SIMD3<Float>(delta.columns.0.x, delta.columns.0.y, delta.columns.0.z),
                                     SIMD3<Float>(delta.columns.1.x, delta.columns.1.y, delta.columns.1.z),
                                     SIMD3<Float>(delta.columns.2.x, delta.columns.2.y, delta.columns.2.z))
        let trace = rotation.columns.0.x + rotation.columns.1.y + rotation.columns.2.z
        let angle = acos(max(-1, min(1, (trace - 1) / 2))) * 180 / .pi
        return (simd_length(translation) * 1000, angle.isFinite ? angle : 0)
    }

    /// Coarse alignment from picked point pairs, then ICP refinement — the sequence
    /// that actually works. Fully automatic registration without any correspondence is
    /// not attempted: on a CBCT with restorations, scatter makes it fail silently, and
    /// a silently wrong merge is the worst possible output.
    static func alignWithCorrespondences(source: ScanMesh,
                                         sourcePoints: [SIMD3<Float>],
                                         target: ScanMesh,
                                         targetPoints: [SIMD3<Float>],
                                         progress: ((Double) -> Void)? = nil) -> Result? {
        guard sourcePoints.count == targetPoints.count, sourcePoints.count >= 3 else { return nil }
        guard let coarse = Superimposition.rigidTransform(from: sourcePoints, to: targetPoints) else { return nil }
        return align(source: source, target: target, initial: coarse, progress: progress)
    }
}
