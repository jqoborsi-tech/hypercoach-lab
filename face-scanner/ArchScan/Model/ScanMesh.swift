import Foundation
import simd

/// A reconstructed surface.
///
/// Coordinate conventions used throughout ArchScan
/// -----------------------------------------------
/// * All internal geometry is in **metres**, in *face-anchor space*: the frame of
///   `ARFaceAnchor.transform`, whose origin sits just behind the nose with
///   +X to the patient's left, +Y superior and +Z anterior. Working in this frame
///   means head movement during the sweep is compensated for free — the operator
///   arcs the phone around the face and every depth frame lands in the same frame.
/// * Everything that leaves the app (OBJ / PLY / STL / landmark JSON) is written in
///   **millimetres**, because every dental CAD package (exocad, 3Shape, Blue Sky Plan,
///   Nemotec) assumes mm for an imported mesh.
struct ScanMesh {
    var positions: [SIMD3<Float>] = []   // metres, face-anchor space
    var normals: [SIMD3<Float>] = []
    var colors: [SIMD3<Float>] = []      // sRGB components, 0...1
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []           // triangle list

    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { positions.isEmpty || indices.isEmpty }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard let first = positions.first else { return (.zero, .zero) }
        var lo = first, hi = first
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    /// Surface area in m^2 — reported as a coverage sanity figure.
    var surfaceArea: Float {
        var total: Float = 0
        var i = 0
        while i + 2 < indices.count {
            let a = positions[Int(indices[i])]
            let b = positions[Int(indices[i + 1])]
            let c = positions[Int(indices[i + 2])]
            total += simd_length(simd_cross(b - a, c - a)) * 0.5
            i += 3
        }
        return total
    }

    /// Signed volume of the surface. Used only to detect inverted winding.
    var signedVolume: Float {
        var total: Float = 0
        var i = 0
        while i + 2 < indices.count {
            let a = positions[Int(indices[i])]
            let b = positions[Int(indices[i + 1])]
            let c = positions[Int(indices[i + 2])]
            total += simd_dot(a, simd_cross(b, c)) / 6.0
            i += 3
        }
        return total
    }

    mutating func flipWinding() {
        var i = 0
        while i + 2 < indices.count {
            indices.swapAt(i + 1, i + 2)
            i += 3
        }
        for k in normals.indices { normals[k] = -normals[k] }
    }

    /// Applies a rigid transform to positions and normals.
    func transformed(by m: simd_float4x4) -> ScanMesh {
        var out = self
        let rot = simd_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let normalMatrix = rot.inverse.transpose
        for i in out.positions.indices {
            let p = out.positions[i]
            let q = m * SIMD4<Float>(p.x, p.y, p.z, 1)
            out.positions[i] = SIMD3<Float>(q.x, q.y, q.z)
        }
        for i in out.normals.indices {
            let n = normalMatrix * out.normals[i]
            let len = simd_length(n)
            out.normals[i] = len > 1e-9 ? n / len : out.normals[i]
        }
        return out
    }

    /// Uniform scale about the origin (used by the calibration correction).
    func scaled(by s: Float) -> ScanMesh {
        guard s != 1 else { return self }
        var out = self
        for i in out.positions.indices { out.positions[i] *= s }
        return out
    }
}

// MARK: - Small math helpers shared across the app

enum MathKit {

    static func outer(_ r: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(r * r.x, r * r.y, r * r.z)
    }

    static func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !points.isEmpty else { return .zero }
        var c = SIMD3<Float>.zero
        for p in points { c += p }
        return c / Float(points.count)
    }

    /// Best-fit plane through a point set (total least squares).
    /// Returns the centroid and a unit normal.
    static func fitPlane(_ points: [SIMD3<Float>]) -> (point: SIMD3<Float>, normal: SIMD3<Float>)? {
        guard points.count >= 3 else { return nil }
        let c = centroid(points)
        var xx: Float = 0, xy: Float = 0, xz: Float = 0, yy: Float = 0, yz: Float = 0, zz: Float = 0
        for p in points {
            let r = p - c
            xx += r.x * r.x; xy += r.x * r.y; xz += r.x * r.z
            yy += r.y * r.y; yz += r.y * r.z; zz += r.z * r.z
        }
        let detX = yy * zz - yz * yz
        let detY = xx * zz - xz * xz
        let detZ = xx * yy - xy * xy
        let detMax = max(detX, max(detY, detZ))
        guard detMax > 1e-16 else { return nil }

        var normal: SIMD3<Float>
        if detMax == detX {
            normal = SIMD3<Float>(detX, xz * yz - xy * zz, xy * yz - xz * yy)
        } else if detMax == detY {
            normal = SIMD3<Float>(xz * yz - xy * zz, detY, xy * xz - yz * xx)
        } else {
            normal = SIMD3<Float>(xy * yz - xz * yy, xy * xz - yz * xx, detZ)
        }
        let len = simd_length(normal)
        guard len > 1e-9 else { return nil }
        return (c, normal / len)
    }

    /// Largest-variance axis of a point set, via power iteration on the covariance.
    static func principalAxis(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        guard points.count >= 2 else { return nil }
        let c = centroid(points)
        var cov = simd_float3x3(SIMD3<Float>.zero, SIMD3<Float>.zero, SIMD3<Float>.zero)
        for p in points { cov = cov + outer(p - c) }
        var v = SIMD3<Float>(0, 1, 0)
        for _ in 0..<48 {
            let nv = cov * v
            let len = simd_length(nv)
            if len < 1e-12 { return nil }
            v = nv / len
        }
        return v
    }

    /// Removes the component of `v` along `axis` and renormalises.
    static func orthogonalize(_ v: SIMD3<Float>, against axis: SIMD3<Float>) -> SIMD3<Float> {
        let r = v - axis * simd_dot(v, axis)
        let len = simd_length(r)
        return len > 1e-9 ? r / len : v
    }

    static func angleDegrees(between a: SIMD3<Float>, and b: SIMD3<Float>) -> Float {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 1e-9, lb > 1e-9 else { return 0 }
        let d = simd_dot(a / la, b / lb)
        return acos(max(-1, min(1, d))) * 180 / .pi
    }

    /// Angle between two planes, folded into 0...90 degrees.
    static func planeAngleDegrees(_ n1: SIMD3<Float>, _ n2: SIMD3<Float>) -> Float {
        let a = angleDegrees(between: n1, and: n2)
        return a > 90 ? 180 - a : a
    }

    /// World -> frame transform for an orthonormal basis: p' = R^T (p - origin).
    static func frameTransform(origin: SIMD3<Float>,
                               x: SIMD3<Float>,
                               y: SIMD3<Float>,
                               z: SIMD3<Float>) -> simd_float4x4 {
        let rt = simd_float3x3(x, y, z).transpose
        let t = -(rt * origin)
        let c0 = rt.columns.0, c1 = rt.columns.1, c2 = rt.columns.2
        return simd_float4x4(
            SIMD4<Float>(c0.x, c0.y, c0.z, 0),
            SIMD4<Float>(c1.x, c1.y, c1.z, 0),
            SIMD4<Float>(c2.x, c2.y, c2.z, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1))
    }
}
