import Foundation
import simd

/// Clean-up applied to the raw iso-surface before it is stored or exported.
enum MeshPostProcess {

    /// Full pipeline: drop stray components, Taubin-smooth, rebuild normals, lay out UVs.
    static func finish(_ mesh: ScanMesh, smoothingIterations: Int = 4) -> ScanMesh {
        guard !mesh.isEmpty else { return mesh }
        var out = keepLargestComponent(mesh)
        if smoothingIterations > 0 {
            out = taubinSmooth(out, iterations: smoothingIterations)
        }
        recomputeNormals(&out)
        assignCylindricalUVs(&out)
        // The extractor orients triangles locally; this is a cheap global sanity check.
        if out.signedVolume < 0 { out.flipWinding() }
        return out
    }

    // MARK: - Adjacency

    /// Compressed neighbour lists (CSR), deduplicated.
    struct Adjacency {
        var offsets: [Int]
        var neighbours: [UInt32]

        func range(_ v: Int) -> Range<Int> { offsets[v]..<offsets[v + 1] }
    }

    static func buildAdjacency(_ mesh: ScanMesh) -> Adjacency {
        let n = mesh.positions.count
        var degree = [Int](repeating: 0, count: n)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = Int(mesh.indices[i]), b = Int(mesh.indices[i + 1]), c = Int(mesh.indices[i + 2])
            degree[a] += 2; degree[b] += 2; degree[c] += 2
            i += 3
        }
        var offsets = [Int](repeating: 0, count: n + 1)
        for v in 0..<n { offsets[v + 1] = offsets[v] + degree[v] }
        var cursor = offsets
        var neighbours = [UInt32](repeating: 0, count: offsets[n])
        i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i], b = mesh.indices[i + 1], c = mesh.indices[i + 2]
            func push(_ v: UInt32, _ x: UInt32, _ y: UInt32) {
                neighbours[cursor[Int(v)]] = x; cursor[Int(v)] += 1
                neighbours[cursor[Int(v)]] = y; cursor[Int(v)] += 1
            }
            push(a, b, c); push(b, a, c); push(c, a, b)
            i += 3
        }
        // Deduplicate each row in place and compact.
        var compactOffsets = [Int](repeating: 0, count: n + 1)
        var compact: [UInt32] = []
        compact.reserveCapacity(neighbours.count / 2)
        for v in 0..<n {
            var row = Array(neighbours[offsets[v]..<offsets[v + 1]])
            row.sort()
            var last: UInt32 = .max
            for value in row where value != last {
                compact.append(value)
                last = value
            }
            compactOffsets[v + 1] = compact.count
        }
        return Adjacency(offsets: compactOffsets, neighbours: compact)
    }

    // MARK: - Components

    static func keepLargestComponent(_ mesh: ScanMesh) -> ScanMesh {
        let n = mesh.positions.count
        guard n > 0 else { return mesh }
        let adjacency = buildAdjacency(mesh)

        var component = [Int32](repeating: -1, count: n)
        var sizes: [Int] = []
        var stack: [Int] = []
        for seed in 0..<n where component[seed] < 0 {
            let id = Int32(sizes.count)
            var count = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            component[seed] = id
            while let v = stack.popLast() {
                count += 1
                for slot in adjacency.range(v) {
                    let w = Int(adjacency.neighbours[slot])
                    if component[w] < 0 {
                        component[w] = id
                        stack.append(w)
                    }
                }
            }
            sizes.append(count)
        }
        guard let best = sizes.indices.max(by: { sizes[$0] < sizes[$1] }) else { return mesh }
        let keep = Int32(best)

        var remap = [Int32](repeating: -1, count: n)
        var out = ScanMesh()
        for v in 0..<n where component[v] == keep {
            remap[v] = Int32(out.positions.count)
            out.positions.append(mesh.positions[v])
            if v < mesh.colors.count { out.colors.append(mesh.colors[v]) }
        }
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = remap[Int(mesh.indices[i])]
            let b = remap[Int(mesh.indices[i + 1])]
            let c = remap[Int(mesh.indices[i + 2])]
            if a >= 0, b >= 0, c >= 0 {
                out.indices.append(contentsOf: [UInt32(a), UInt32(b), UInt32(c)])
            }
            i += 3
        }
        return out
    }

    // MARK: - Smoothing

    /// Taubin's λ/μ filter: a smoothing pass followed by an inflating pass, which
    /// suppresses depth noise without the shrinkage plain Laplacian smoothing causes.
    /// Shrinkage matters here — the scan is a measurement, not a picture.
    static func taubinSmooth(_ mesh: ScanMesh, iterations: Int, lambda: Float = 0.53, mu: Float = -0.55) -> ScanMesh {
        var out = mesh
        let adjacency = buildAdjacency(mesh)
        let n = out.positions.count
        var scratch = out.positions

        func pass(_ factor: Float) {
            for v in 0..<n {
                let row = adjacency.range(v)
                if row.isEmpty { scratch[v] = out.positions[v]; continue }
                var mean = SIMD3<Float>.zero
                for slot in row { mean += out.positions[Int(adjacency.neighbours[slot])] }
                mean /= Float(row.count)
                scratch[v] = out.positions[v] + (mean - out.positions[v]) * factor
            }
            swap(&out.positions, &scratch)
        }

        for _ in 0..<iterations {
            pass(lambda)
            pass(mu)
        }
        return out
    }

    // MARK: - Normals

    static func recomputeNormals(_ mesh: inout ScanMesh) {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        var i = 0
        while i + 2 < mesh.indices.count {
            let ia = Int(mesh.indices[i]), ib = Int(mesh.indices[i + 1]), ic = Int(mesh.indices[i + 2])
            let a = mesh.positions[ia], b = mesh.positions[ib], c = mesh.positions[ic]
            let faceNormal = simd_cross(b - a, c - a)      // area weighted by construction
            normals[ia] += faceNormal
            normals[ib] += faceNormal
            normals[ic] += faceNormal
            i += 3
        }
        for k in normals.indices {
            let length = simd_length(normals[k])
            normals[k] = length > 1e-12 ? normals[k] / length : SIMD3<Float>(0, 0, 1)
        }
        mesh.normals = normals
    }

    // MARK: - Texture coordinates

    /// Cylindrical unwrap about the head's vertical axis. A face is star-shaped about
    /// that axis, so the parameterisation is well behaved everywhere the scan actually
    /// covers, and the seam falls at the back of the head where there is no data.
    static func assignCylindricalUVs(_ mesh: inout ScanMesh) {
        guard !mesh.positions.isEmpty else { return }
        let bounds = mesh.bounds
        let height = max(bounds.max.y - bounds.min.y, 1e-4)
        var uvs = [SIMD2<Float>](repeating: .zero, count: mesh.positions.count)
        for k in mesh.positions.indices {
            let p = mesh.positions[k]
            let angle = atan2(p.x, p.z)                    // 0 at the tip of the nose
            let u = 0.5 + angle / (2 * .pi)
            let v = (p.y - bounds.min.y) / height
            uvs[k] = SIMD2<Float>(min(max(u, 0), 1), min(max(v, 0), 1))
        }
        mesh.uvs = uvs
    }
}
