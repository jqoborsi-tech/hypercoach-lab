import Foundation
import simd

/// Iso-surface extraction from the TSDF.
///
/// This uses marching *tetrahedra* rather than marching cubes: each cell is split
/// into six tetrahedra around the main diagonal, which has only four cases per
/// tetrahedron instead of the 256-entry cube table. It produces more triangles for
/// the same surface, but it cannot produce the ambiguous-face holes the cube table
/// is famous for — and for a clinical scan a watertight surface matters more than a
/// tidy triangle budget.
enum SurfaceExtractor {

    /// Six tetrahedra sharing the cube's 0–7 diagonal.
    private static let tetrahedra: [[Int]] = [
        [0, 7, 1, 3], [0, 7, 3, 2], [0, 7, 2, 6],
        [0, 7, 6, 4], [0, 7, 4, 5], [0, 7, 5, 1]
    ]

    /// Corner offsets, indexed so that bit 0 is x, bit 1 is y, bit 2 is z.
    private static let cornerOffsets: [(Int, Int, Int)] = [
        (0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0),
        (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)
    ]

    static func extract(from volume: TSDFVolume,
                        progress: ((Double) -> Void)? = nil) -> ScanMesh {
        var mesh = ScanMesh()
        var vertexForEdge: [UInt64: UInt32] = [:]
        vertexForEdge.reserveCapacity(400_000)

        let minWeight = volume.meshingMinimumWeight
        let nx = volume.nx, ny = volume.ny, nz = volume.nz

        var values = [Float](repeating: 0, count: 8)
        var positions = [SIMD3<Float>](repeating: .zero, count: 8)
        var colors = [SIMD3<Float>](repeating: .zero, count: 8)
        var colorValid = [Bool](repeating: false, count: 8)
        var cellIndices = [UInt32](repeating: 0, count: 8)

        for k in 0..<(nz - 1) {
            if k % 8 == 0 { progress?(Double(k) / Double(max(nz - 1, 1))) }
            for j in 0..<(ny - 1) {
                for i in 0..<(nx - 1) {
                    // Cheap rejection: most of the volume is never observed.
                    if volume.rawWeight(i, j, k) < minWeight { continue }

                    var usable = true
                    var negative = 0
                    for c in 0..<8 {
                        let o = cornerOffsets[c]
                        let ci = i + o.0, cj = j + o.1, ck = k + o.2
                        if volume.rawWeight(ci, cj, ck) < minWeight { usable = false; break }
                        let v = volume.rawSDF(ci, cj, ck)
                        values[c] = v
                        if v < 0 { negative += 1 }
                        positions[c] = volume.voxelCenter(ci, cj, ck)
                        colors[c] = volume.rawColor(ci, cj, ck)
                        colorValid[c] = volume.rawHasColor(ci, cj, ck)
                        cellIndices[c] = UInt32((ck * ny + cj) * nx + ci)
                    }
                    guard usable, negative > 0, negative < 8 else { continue }

                    for tet in tetrahedra {
                        emit(tet: tet, values: values, positions: positions, colors: colors,
                             colorValid: colorValid, cellIndices: cellIndices,
                             mesh: &mesh, vertexForEdge: &vertexForEdge)
                    }
                }
            }
        }
        progress?(1)
        return mesh
    }

    private static func emit(tet: [Int],
                             values: [Float],
                             positions: [SIMD3<Float>],
                             colors: [SIMD3<Float>],
                             colorValid: [Bool],
                             cellIndices: [UInt32],
                             mesh: inout ScanMesh,
                             vertexForEdge: inout [UInt64: UInt32]) {

        var inside: [Int] = []
        var outside: [Int] = []
        for c in tet {
            if values[c] < 0 { inside.append(c) } else { outside.append(c) }
        }
        guard !inside.isEmpty, !outside.isEmpty else { return }

        var insideCentroid = SIMD3<Float>.zero
        for c in inside { insideCentroid += positions[c] }
        insideCentroid /= Float(inside.count)

        func vertex(_ a: Int, _ b: Int) -> UInt32 {
            let ia = cellIndices[a], ib = cellIndices[b]
            let key = ia < ib ? (UInt64(ia) << 32 | UInt64(ib)) : (UInt64(ib) << 32 | UInt64(ia))
            if let existing = vertexForEdge[key] { return existing }
            let fa = values[a], fb = values[b]
            var t = fa / (fa - fb)
            if !t.isFinite { t = 0.5 }
            t = max(0, min(1, t))
            let index = UInt32(mesh.positions.count)
            mesh.positions.append(positions[a] + (positions[b] - positions[a]) * t)
            switch (colorValid[a], colorValid[b]) {
            case (true, true):   mesh.colors.append(colors[a] + (colors[b] - colors[a]) * t)
            case (true, false):  mesh.colors.append(colors[a])
            case (false, true):  mesh.colors.append(colors[b])
            case (false, false): mesh.colors.append(SIMD3<Float>(0.78, 0.66, 0.60))
            }
            vertexForEdge[key] = index
            return index
        }

        func addTriangle(_ i0: UInt32, _ i1: UInt32, _ i2: UInt32) {
            let a = mesh.positions[Int(i0)], b = mesh.positions[Int(i1)], c = mesh.positions[Int(i2)]
            let normal = simd_cross(b - a, c - a)
            // Orient every triangle away from the material side of the tetrahedron, so
            // the whole surface comes out consistently wound without a global repair pass.
            if simd_dot(normal, (a + b + c) / 3 - insideCentroid) >= 0 {
                mesh.indices.append(contentsOf: [i0, i1, i2])
            } else {
                mesh.indices.append(contentsOf: [i0, i2, i1])
            }
        }

        switch (inside.count, outside.count) {
        case (1, 3):
            let a = inside[0]
            addTriangle(vertex(a, outside[0]), vertex(a, outside[1]), vertex(a, outside[2]))
        case (3, 1):
            let a = outside[0]
            addTriangle(vertex(a, inside[0]), vertex(a, inside[1]), vertex(a, inside[2]))
        case (2, 2):
            let v0 = vertex(inside[0], outside[0])
            let v1 = vertex(inside[0], outside[1])
            let v2 = vertex(inside[1], outside[1])
            let v3 = vertex(inside[1], outside[0])
            addTriangle(v0, v1, v2)
            addTriangle(v0, v2, v3)
        default:
            break
        }
    }
}
