import Foundation
import simd

/// Writers for the mesh formats dental CAD actually ingests.
/// Every file is written in **millimetres**; the caller passes a mesh in metres.
enum MeshIO {

    static let metresToMillimetres: Float = 1000

    // MARK: - Buffered writing

    /// Appends to a file in chunks so a half-million-vertex OBJ never materialises
    /// as one giant String in memory.
    final class ChunkWriter {
        private let handle: FileHandle
        private var buffer = Data()
        private let flushThreshold = 1 << 20

        init(url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.protectionKey: FileProtectionType.complete])
            handle = try FileHandle(forWritingTo: url)
            buffer.reserveCapacity(flushThreshold + 4096)
        }

        func write(_ string: String) {
            buffer.append(contentsOf: Array(string.utf8))
            if buffer.count >= flushThreshold { flush() }
        }

        func write(_ data: Data) {
            buffer.append(data)
            if buffer.count >= flushThreshold { flush() }
        }

        private func flush() {
            if !buffer.isEmpty {
                handle.write(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        func close() {
            flush()
            try? handle.close()
        }
    }

    // MARK: - OBJ + MTL

    /// Writes `name.obj`, `name.mtl` and (when a texture is supplied) `name.jpg`.
    static func writeOBJ(_ mesh: ScanMesh,
                         to directory: URL,
                         name: String,
                         textureJPEG: Data?,
                         header: [String]) throws {
        let objURL = directory.appendingPathComponent("\(name).obj")
        let writer = try ChunkWriter(url: objURL)
        defer { writer.close() }

        for line in header { writer.write("# \(line)\n") }
        writer.write("# Units: millimetres\n")
        if textureJPEG != nil {
            writer.write("mtllib \(name).mtl\n")
        }
        writer.write("o \(name)\n")

        let scale = metresToMillimetres
        for p in mesh.positions {
            writer.write("v \(fmt(p.x * scale)) \(fmt(p.y * scale)) \(fmt(p.z * scale))\n")
        }
        let hasUVs = mesh.uvs.count == mesh.positions.count && textureJPEG != nil
        if hasUVs {
            for uv in mesh.uvs { writer.write("vt \(fmt(uv.x)) \(fmt(uv.y))\n") }
        }
        let hasNormals = mesh.normals.count == mesh.positions.count
        if hasNormals {
            for n in mesh.normals { writer.write("vn \(fmt(n.x)) \(fmt(n.y)) \(fmt(n.z))\n") }
        }
        if textureJPEG != nil {
            writer.write("usemtl \(name)_material\n")
        }
        writer.write("s 1\n")

        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.indices[i] + 1, b = mesh.indices[i + 1] + 1, c = mesh.indices[i + 2] + 1
            if hasUVs && hasNormals {
                writer.write("f \(a)/\(a)/\(a) \(b)/\(b)/\(b) \(c)/\(c)/\(c)\n")
            } else if hasNormals {
                writer.write("f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n")
            } else {
                writer.write("f \(a) \(b) \(c)\n")
            }
            i += 3
        }

        if let textureJPEG {
            let textureName = "\(name).jpg"
            try textureJPEG.write(to: directory.appendingPathComponent(textureName), options: .atomic)
            let mtl = """
            # ArchScan material
            newmtl \(name)_material
            Ka 1.000 1.000 1.000
            Kd 1.000 1.000 1.000
            Ks 0.000 0.000 0.000
            d 1.0
            illum 1
            map_Kd \(textureName)

            """
            try mtl.data(using: .utf8)?.write(to: directory.appendingPathComponent("\(name).mtl"), options: .atomic)
        }
    }

    // MARK: - PLY (binary little endian, with vertex colours)

    static func writePLY(_ mesh: ScanMesh, to url: URL, comments: [String]) throws {
        var header = "ply\nformat binary_little_endian 1.0\n"
        for comment in comments { header += "comment \(comment)\n" }
        header += "comment units millimetres\n"
        header += "element vertex \(mesh.positions.count)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        header += "property float nx\nproperty float ny\nproperty float nz\n"
        header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        header += "element face \(mesh.triangleCount)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"

        let writer = try ChunkWriter(url: url)
        defer { writer.close() }
        writer.write(header)

        let scale = metresToMillimetres
        var vertexData = Data()
        vertexData.reserveCapacity(mesh.positions.count * 27)
        for i in mesh.positions.indices {
            let p = mesh.positions[i] * scale
            let n = i < mesh.normals.count ? mesh.normals[i] : SIMD3<Float>(0, 0, 1)
            let c = i < mesh.colors.count ? mesh.colors[i] : SIMD3<Float>(0.8, 0.7, 0.65)
            appendFloat(&vertexData, p.x); appendFloat(&vertexData, p.y); appendFloat(&vertexData, p.z)
            appendFloat(&vertexData, n.x); appendFloat(&vertexData, n.y); appendFloat(&vertexData, n.z)
            vertexData.append(UInt8(max(0, min(255, c.x * 255))))
            vertexData.append(UInt8(max(0, min(255, c.y * 255))))
            vertexData.append(UInt8(max(0, min(255, c.z * 255))))
            if vertexData.count > (1 << 20) { writer.write(vertexData); vertexData.removeAll(keepingCapacity: true) }
        }
        writer.write(vertexData)

        var faceData = Data()
        faceData.reserveCapacity(mesh.triangleCount * 13)
        var i = 0
        while i + 2 < mesh.indices.count {
            faceData.append(UInt8(3))
            appendInt32(&faceData, Int32(mesh.indices[i]))
            appendInt32(&faceData, Int32(mesh.indices[i + 1]))
            appendInt32(&faceData, Int32(mesh.indices[i + 2]))
            i += 3
            if faceData.count > (1 << 20) { writer.write(faceData); faceData.removeAll(keepingCapacity: true) }
        }
        writer.write(faceData)
    }

    // MARK: - STL (binary)

    static func writeSTL(_ mesh: ScanMesh, to url: URL, title: String) throws {
        let writer = try ChunkWriter(url: url)
        defer { writer.close() }

        var header = Data(count: 80)
        let titleBytes = Array(title.prefix(78).utf8)
        for (i, byte) in titleBytes.enumerated() { header[i] = byte }
        writer.write(header)

        var countData = Data()
        appendUInt32(&countData, UInt32(mesh.triangleCount))
        writer.write(countData)

        let scale = metresToMillimetres
        var body = Data()
        body.reserveCapacity(1 << 20)
        var i = 0
        while i + 2 < mesh.indices.count {
            let a = mesh.positions[Int(mesh.indices[i])] * scale
            let b = mesh.positions[Int(mesh.indices[i + 1])] * scale
            let c = mesh.positions[Int(mesh.indices[i + 2])] * scale
            var normal = simd_cross(b - a, c - a)
            let length = simd_length(normal)
            normal = length > 1e-12 ? normal / length : SIMD3<Float>(0, 0, 1)
            appendFloat(&body, normal.x); appendFloat(&body, normal.y); appendFloat(&body, normal.z)
            appendFloat(&body, a.x); appendFloat(&body, a.y); appendFloat(&body, a.z)
            appendFloat(&body, b.x); appendFloat(&body, b.y); appendFloat(&body, b.z)
            appendFloat(&body, c.x); appendFloat(&body, c.y); appendFloat(&body, c.z)
            body.append(contentsOf: [0, 0])
            i += 3
            if body.count > (1 << 20) { writer.write(body); body.removeAll(keepingCapacity: true) }
        }
        writer.write(body)
    }

    /// Reference planes as a single STL of thin quads, so they can be dropped into the
    /// planning software alongside the face and used to orient the occlusal plane.
    static func writePlanesSTL(_ planes: [ReferencePlaneSpec], to url: URL) throws {
        var mesh = ScanMesh()
        for plane in planes {
            let n = simd_normalize(plane.normal)
            var helper = SIMD3<Float>(0, 1, 0)
            if abs(simd_dot(helper, n)) > 0.9 { helper = SIMD3<Float>(1, 0, 0) }
            let u = simd_normalize(simd_cross(helper, n)) * plane.halfSize
            let v = simd_normalize(simd_cross(n, u)) * plane.halfSize
            let base = UInt32(mesh.positions.count)
            mesh.positions.append(plane.point - u - v)
            mesh.positions.append(plane.point + u - v)
            mesh.positions.append(plane.point + u + v)
            mesh.positions.append(plane.point - u + v)
            mesh.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
        try writeSTL(mesh, to: url, title: "ArchScan reference planes (mm)")
    }

    // MARK: - Helpers

    @inline(__always)
    private static func appendFloat(_ data: inout Data, _ value: Float) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    private static func appendInt32(_ data: inout Data, _ value: Int32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    private static func fmt(_ value: Float) -> String {
        String(format: "%.4f", value)
    }
}
