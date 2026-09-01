import Foundation
import simd

/// Truncated signed distance volume in face-anchor space.
///
/// Each depth frame is fused by walking a short band along every viewing ray, so the
/// per-frame cost is proportional to the number of depth samples rather than to the
/// size of the volume. Because every frame is expressed in the head's own frame, the
/// operator can arc the phone around the patient and the samples pile up in register;
/// `refinePose` then removes the residual jitter in ARKit's face pose by minimising
/// the accumulated SDF directly (KinectFusion-style direct tracking).
final class TSDFVolume {

    let voxelSize: Float
    let truncation: Float
    let origin: SIMD3<Float>
    let nx: Int, ny: Int, nz: Int

    private let sdf: UnsafeMutablePointer<Float>
    private let weight: UnsafeMutablePointer<UInt16>      // fixed point, `weightScale` units per observation
    private let rgb: UnsafeMutablePointer<UInt8>          // 3 bytes per voxel
    private let rgbWeight: UnsafeMutablePointer<UInt8>

    private let weightScale: Float = 64
    private let maxWeightRaw: Float = 32000

    /// Minimum accumulated weight for a voxel to be considered observed when meshing.
    let meshingMinimumWeight: UInt16 = 40

    struct IntegrationResult {
        var accepted: Bool
        var samples: Int
        var poseCorrectionMillimetres: Float
    }

    /// Default extent: 250 x 290 x 220 mm around the face anchor, which reaches past
    /// both tragi, above the brow and below the chin.
    init(voxelSize: Float,
         lower: SIMD3<Float> = SIMD3<Float>(-0.125, -0.155, -0.105),
         upper: SIMD3<Float> = SIMD3<Float>(0.125, 0.135, 0.115)) {
        self.voxelSize = voxelSize
        self.truncation = voxelSize * 3.5
        self.origin = lower
        let extent = upper - lower
        nx = max(8, Int((extent.x / voxelSize).rounded(.up)))
        ny = max(8, Int((extent.y / voxelSize).rounded(.up)))
        nz = max(8, Int((extent.z / voxelSize).rounded(.up)))
        let count = nx * ny * nz
        sdf = .allocate(capacity: count)
        weight = .allocate(capacity: count)
        rgb = .allocate(capacity: count * 3)
        rgbWeight = .allocate(capacity: count)
        sdf.initialize(repeating: 0, count: count)
        weight.initialize(repeating: 0, count: count)
        rgb.initialize(repeating: 0, count: count * 3)
        rgbWeight.initialize(repeating: 0, count: count)
    }

    deinit {
        sdf.deallocate()
        weight.deallocate()
        rgb.deallocate()
        rgbWeight.deallocate()
    }

    var voxelCount: Int { nx * ny * nz }
    var approximateBytes: Int { voxelCount * 10 }

    @inline(__always)
    private func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * ny + j) * nx + i }

    // MARK: - Sampling

    /// Trilinear sample of the truncated distance, in metres. Nil where unobserved.
    @inline(__always)
    func sample(_ p: SIMD3<Float>) -> Float? {
        let gx = (p.x - origin.x) / voxelSize - 0.5
        let gy = (p.y - origin.y) / voxelSize - 0.5
        let gz = (p.z - origin.z) / voxelSize - 0.5
        let i0 = Int(floor(gx)), j0 = Int(floor(gy)), k0 = Int(floor(gz))
        guard i0 >= 0, j0 >= 0, k0 >= 0, i0 + 1 < nx, j0 + 1 < ny, k0 + 1 < nz else { return nil }
        let fx = gx - Float(i0), fy = gy - Float(j0), fz = gz - Float(k0)

        let base = index(i0, j0, k0)
        let strideY = nx
        let strideZ = nx * ny
        let i000 = base,               i100 = base + 1
        let i010 = base + strideY,     i110 = base + strideY + 1
        let i001 = base + strideZ,     i101 = base + strideZ + 1
        let i011 = base + strideZ + strideY, i111 = base + strideZ + strideY + 1

        if weight[i000] == 0 || weight[i100] == 0 || weight[i010] == 0 || weight[i110] == 0 ||
           weight[i001] == 0 || weight[i101] == 0 || weight[i011] == 0 || weight[i111] == 0 {
            return nil
        }

        let x00 = sdf[i000] + (sdf[i100] - sdf[i000]) * fx
        let x10 = sdf[i010] + (sdf[i110] - sdf[i010]) * fx
        let x01 = sdf[i001] + (sdf[i101] - sdf[i001]) * fx
        let x11 = sdf[i011] + (sdf[i111] - sdf[i011]) * fx
        let y0 = x00 + (x10 - x00) * fy
        let y1 = x01 + (x11 - x01) * fy
        return (y0 + (y1 - y0) * fz) * truncation
    }

    @inline(__always)
    func gradient(_ p: SIMD3<Float>) -> SIMD3<Float>? {
        let h = voxelSize
        guard let xp = sample(SIMD3<Float>(p.x + h, p.y, p.z)), let xm = sample(SIMD3<Float>(p.x - h, p.y, p.z)),
              let yp = sample(SIMD3<Float>(p.x, p.y + h, p.z)), let ym = sample(SIMD3<Float>(p.x, p.y - h, p.z)),
              let zp = sample(SIMD3<Float>(p.x, p.y, p.z + h)), let zm = sample(SIMD3<Float>(p.x, p.y, p.z - h))
        else { return nil }
        return SIMD3<Float>(xp - xm, yp - ym, zp - zm) / (2 * h)
    }

    // MARK: - Raw access for meshing

    @inline(__always) func rawSDF(_ i: Int, _ j: Int, _ k: Int) -> Float { sdf[index(i, j, k)] * truncation }
    @inline(__always) func rawWeight(_ i: Int, _ j: Int, _ k: Int) -> UInt16 { weight[index(i, j, k)] }
    @inline(__always) func rawColor(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        let o = index(i, j, k) * 3
        return SIMD3<Float>(Float(rgb[o]) / 255, Float(rgb[o + 1]) / 255, Float(rgb[o + 2]) / 255)
    }
    @inline(__always) func rawHasColor(_ i: Int, _ j: Int, _ k: Int) -> Bool { rgbWeight[index(i, j, k)] > 0 }
    @inline(__always) func voxelCenter(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        SIMD3<Float>(origin.x + (Float(i) + 0.5) * voxelSize,
                     origin.y + (Float(j) + 0.5) * voxelSize,
                     origin.z + (Float(k) + 0.5) * voxelSize)
    }

    // MARK: - Integration

    private let minDepth: Float = 0.15
    private let maxDepth: Float = 0.60

    @discardableResult
    func integrate(_ frame: DepthFrame,
                   color: ColorSampler?,
                   refinePose: Bool,
                   hasData: Bool) -> IntegrationResult {
        var cameraToFace = frame.cameraToFace
        var correction: Float = 0

        if refinePose, hasData, let refined = refinedPose(frame) {
            let a = cameraToFace.columns.3, b = refined.columns.3
            correction = simd_length(SIMD3<Float>(b.x - a.x, b.y - a.y, b.z - a.z)) * 1000
            cameraToFace = refined
        }

        let camOriginH = cameraToFace.columns.3
        let camOrigin = SIMD3<Float>(camOriginH.x, camOriginH.y, camOriginH.z)
        let step = voxelSize * 0.7
        let steps = Int((truncation / step).rounded(.up))
        var samples = 0

        let width = frame.width, height = frame.height

        frame.depth.withUnsafeBufferPointer { depthBuf in
            guard let depth = depthBuf.baseAddress else { return }
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let d = depth[y * width + x]
                    guard d > minDepth, d < maxDepth else { continue }

                    let dr = depth[y * width + x + 1]
                    let dd = depth[(y + 1) * width + x]
                    guard dr > minDepth, dr < maxDepth, dd > minDepth, dd < maxDepth else { continue }
                    guard abs(dr - d) < 0.02, abs(dd - d) < 0.02 else { continue }   // step over depth edges

                    let p0 = frame.deproject(x: x, y: y, depthValue: d)
                    let p1 = frame.deproject(x: x + 1, y: y, depthValue: dr)
                    let p2 = frame.deproject(x: x, y: y + 1, depthValue: dd)
                    var surfaceNormal = simd_cross(p1 - p0, p2 - p0)
                    let normalLength = simd_length(surfaceNormal)
                    guard normalLength > 1e-9 else { continue }
                    surfaceNormal /= normalLength

                    let viewDir = simd_normalize(p0)        // the camera is at the origin of this space
                    let facing = abs(simd_dot(surfaceNormal, viewDir))
                    guard facing > 0.2 else { continue }    // drop grazing hits, they are the noisy ones

                    let h = cameraToFace * SIMD4<Float>(p0.x, p0.y, p0.z, 1)
                    let surface = SIMD3<Float>(h.x, h.y, h.z)
                    let ray = simd_normalize(surface - camOrigin)

                    // TrueDepth noise grows roughly with the square of range.
                    let rangeWeight = min(1, (0.35 * 0.35) / (d * d))
                    let w = max(0.05, facing * rangeWeight)
                    let wRaw = w * weightScale

                    // Colour is weighted far more sharply than geometry. A texel seen
                    // face-on is in focus and correctly lit; the same texel at 60 degrees
                    // is smeared across more skin and often in shadow. Cubing the
                    // incidence term keeps the frontal views dominant, which is what
                    // stops the incisal edges and the gingival margin going soft.
                    var sampledColor: SIMD3<Float>?
                    var colorWeight: Float = 0
                    if let color {
                        let u = color.fx * (p0.x / -p0.z) + color.cx
                        let v = color.fy * (-p0.y / -p0.z) + color.cy
                        sampledColor = color.sample(u: u, v: v)
                        colorWeight = facing * facing * facing * rangeWeight
                    }

                    var lastIndex = -1
                    for s in -steps...steps {
                        let along = Float(s) * step
                        let q = surface + ray * along
                        let gx = (q.x - origin.x) / voxelSize
                        let gy = (q.y - origin.y) / voxelSize
                        let gz = (q.z - origin.z) / voxelSize
                        guard gx >= 0, gy >= 0, gz >= 0 else { continue }
                        let i = Int(gx), j = Int(gy), k = Int(gz)
                        guard i < nx, j < ny, k < nz else { continue }
                        let idx = index(i, j, k)
                        if idx == lastIndex { continue }
                        lastIndex = idx

                        let value = max(-1, min(1, -along / truncation))
                        let oldRaw = Float(weight[idx])
                        let newRaw = min(maxWeightRaw, oldRaw + wRaw)
                        sdf[idx] = (sdf[idx] * oldRaw + value * wRaw) / max(newRaw, 1e-6)
                        weight[idx] = UInt16(newRaw)

                        if let sampledColor, colorWeight > 0.001, abs(along) < voxelSize {
                            let o = idx * 3
                            let cw = Float(rgbWeight[idx])
                            let denominator = cw + colorWeight
                            let r = (Float(rgb[o]) * cw + sampledColor.x * 255 * colorWeight) / denominator
                            let g = (Float(rgb[o + 1]) * cw + sampledColor.y * 255 * colorWeight) / denominator
                            let b = (Float(rgb[o + 2]) * cw + sampledColor.z * 255 * colorWeight) / denominator
                            rgb[o]     = UInt8(max(0, min(255, r)))
                            rgb[o + 1] = UInt8(max(0, min(255, g)))
                            rgb[o + 2] = UInt8(max(0, min(255, b)))
                            rgbWeight[idx] = UInt8(min(200, denominator))
                        }
                        samples += 1
                    }
                }
            }
        }

        return IntegrationResult(accepted: samples > 2000, samples: samples,
                                 poseCorrectionMillimetres: correction)
    }

    // MARK: - Direct SDF pose refinement

    /// Gauss-Newton refinement of the camera pose against the accumulated volume.
    /// Returns nil when the correction is implausibly large, in which case the caller
    /// keeps ARKit's own face pose.
    private func refinedPose(_ frame: DepthFrame) -> simd_float4x4? {
        var transform = frame.cameraToFace
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(4200)

        outer: for y in Swift.stride(from: 2, to: frame.height - 2, by: 6) {
            for x in Swift.stride(from: 2, to: frame.width - 2, by: 6) {
                let d = frame.depth[y * frame.width + x]
                guard d > minDepth, d < maxDepth else { continue }
                points.append(frame.deproject(x: x, y: y, depthValue: d))
                if points.count >= 4000 { break outer }
            }
        }
        guard points.count >= 400 else { return nil }

        for _ in 0..<4 {
            var ata = [Double](repeating: 0, count: 36)
            var atb = [Double](repeating: 0, count: 6)
            var used = 0

            for p in points {
                let h = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                let q = SIMD3<Float>(h.x, h.y, h.z)
                guard let residual = sample(q), let grad = gradient(q) else { continue }
                guard abs(residual) < truncation * 0.9, simd_length(grad) > 0.1 else { continue }

                let rotationPart = simd_cross(q, grad)
                let j: [Double] = [Double(rotationPart.x), Double(rotationPart.y), Double(rotationPart.z),
                                   Double(grad.x), Double(grad.y), Double(grad.z)]
                let r = Double(residual)
                for a in 0..<6 {
                    atb[a] -= j[a] * r
                    for b in 0..<6 { ata[a * 6 + b] += j[a] * j[b] }
                }
                used += 1
            }
            guard used >= 300 else { return nil }

            for a in 0..<6 { ata[a * 6 + a] *= 1.0 + 1e-3 }
            guard let xi = LinearSolver.solve6(ata, atb) else { return nil }

            let omega = SIMD3<Float>(Float(xi[0]), Float(xi[1]), Float(xi[2]))
            let translation = SIMD3<Float>(Float(xi[3]), Float(xi[4]), Float(xi[5]))
            guard omega.x.isFinite, translation.x.isFinite else { return nil }
            guard simd_length(translation) < 0.01, simd_length(omega) < 0.09 else { return nil }

            transform = TSDFVolume.exponentialMap(omega: omega, translation: translation) * transform
        }

        let before = frame.cameraToFace.columns.3
        let after = transform.columns.3
        let shift = simd_length(SIMD3<Float>(after.x - before.x, after.y - before.y, after.z - before.z))
        guard shift < 0.012 else { return nil }
        return transform
    }

    /// Exponential map for a rigid twist.
    static func exponentialMap(omega: SIMD3<Float>, translation: SIMD3<Float>) -> simd_float4x4 {
        let theta = simd_length(omega)
        var rotation = matrix_identity_float3x3
        if theta > 1e-8 {
            rotation = simd_float3x3(simd_quatf(angle: theta, axis: omega / theta))
        }
        let c0 = rotation.columns.0, c1 = rotation.columns.1, c2 = rotation.columns.2
        return simd_float4x4(
            SIMD4<Float>(c0.x, c0.y, c0.z, 0),
            SIMD4<Float>(c1.x, c1.y, c1.z, 0),
            SIMD4<Float>(c2.x, c2.y, c2.z, 0),
            SIMD4<Float>(translation.x, translation.y, translation.z, 1))
    }
}

extension TSDFVolume: ScalarField {
    func fieldValue(_ i: Int, _ j: Int, _ k: Int) -> Float { rawSDF(i, j, k) }
    func fieldIsObserved(_ i: Int, _ j: Int, _ k: Int) -> Bool { rawWeight(i, j, k) >= meshingMinimumWeight }
    func fieldColor(_ i: Int, _ j: Int, _ k: Int) -> (SIMD3<Float>, Bool) {
        (rawColor(i, j, k), rawHasColor(i, j, k))
    }
    func fieldPosition(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { voxelCenter(i, j, k) }
}

/// Dense 6x6 solve (Gaussian elimination with partial pivoting).
enum LinearSolver {
    static func solve6(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = a
        var v = b
        let n = 6
        for col in 0..<n {
            var pivot = col
            var best = abs(m[col * n + col])
            for row in (col + 1)..<n where abs(m[row * n + col]) > best {
                best = abs(m[row * n + col]); pivot = row
            }
            guard best > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<n { m.swapAt(col * n + k, pivot * n + k) }
                v.swapAt(col, pivot)
            }
            let diagonal = m[col * n + col]
            for row in (col + 1)..<n {
                let factor = m[row * n + col] / diagonal
                if factor == 0 { continue }
                for k in col..<n { m[row * n + k] -= factor * m[col * n + k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row * n + k] * x[k] }
            x[row] = sum / m[row * n + row]
        }
        return x.allSatisfy { $0.isFinite } ? x : nil
    }
}
