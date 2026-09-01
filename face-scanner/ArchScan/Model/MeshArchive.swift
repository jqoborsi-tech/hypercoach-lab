import Foundation
import simd

/// On-device storage format for a reconstructed mesh. Flat, versioned and
/// mmap-friendly; nothing clever, it just has to survive an app relaunch.
enum MeshArchive {

    private static let magic: UInt32 = 0x4D534831   // "MSH1"

    static func write(_ mesh: ScanMesh, to url: URL) throws {
        var data = Data()
        func appendU32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func appendFloats(_ values: [Float]) {
            values.withUnsafeBufferPointer { buf in
                data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
            }
        }

        appendU32(magic)
        appendU32(UInt32(mesh.positions.count))
        appendU32(UInt32(mesh.indices.count))

        var flat: [Float] = []
        flat.reserveCapacity(mesh.positions.count * 11)
        for i in 0..<mesh.positions.count {
            let p = mesh.positions[i]
            let n = i < mesh.normals.count ? mesh.normals[i] : SIMD3<Float>(0, 0, 1)
            let c = i < mesh.colors.count ? mesh.colors[i] : SIMD3<Float>(0.75, 0.7, 0.68)
            let t = i < mesh.uvs.count ? mesh.uvs[i] : SIMD2<Float>(0.5, 0.5)
            flat.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, c.x, c.y, c.z, t.x, t.y])
        }
        appendFloats(flat)
        mesh.indices.withUnsafeBufferPointer { buf in
            data.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count))
        }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func read(from url: URL) throws -> ScanMesh {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 12 else { throw ArchiveError.truncated }

        let header: (UInt32, UInt32, UInt32) = data.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        }
        guard header.0 == magic else { throw ArchiveError.badMagic }
        let vertexCount = Int(header.1)
        let indexCount = Int(header.2)

        let floatBytes = vertexCount * 11 * MemoryLayout<Float>.size
        let indexBytes = indexCount * MemoryLayout<UInt32>.size
        guard data.count >= 12 + floatBytes + indexBytes else { throw ArchiveError.truncated }

        var mesh = ScanMesh()
        mesh.positions.reserveCapacity(vertexCount)
        mesh.normals.reserveCapacity(vertexCount)
        mesh.colors.reserveCapacity(vertexCount)
        mesh.uvs.reserveCapacity(vertexCount)

        data.withUnsafeBytes { raw in
            var offset = 12
            for _ in 0..<vertexCount {
                var v = [Float](repeating: 0, count: 11)
                for k in 0..<11 {
                    v[k] = raw.loadUnaligned(fromByteOffset: offset + k * 4, as: Float.self)
                }
                offset += 44
                mesh.positions.append(SIMD3<Float>(v[0], v[1], v[2]))
                mesh.normals.append(SIMD3<Float>(v[3], v[4], v[5]))
                mesh.colors.append(SIMD3<Float>(v[6], v[7], v[8]))
                mesh.uvs.append(SIMD2<Float>(v[9], v[10]))
            }
            mesh.indices.reserveCapacity(indexCount)
            for k in 0..<indexCount {
                mesh.indices.append(raw.loadUnaligned(fromByteOffset: offset + k * 4, as: UInt32.self))
            }
        }
        return mesh
    }

    enum ArchiveError: Error, LocalizedError {
        case badMagic, truncated
        var errorDescription: String? {
            switch self {
            case .badMagic:  return "This scan file was not written by ArchScan."
            case .truncated: return "The scan file is incomplete."
            }
        }
    }
}
