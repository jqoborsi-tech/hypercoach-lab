import Foundation
import simd

/// Reads the mesh formats an intraoral scanner or a lab exports: STL (binary and
/// ASCII), PLY (binary little/big endian and ASCII) and OBJ.
///
/// Intraoral scans are written in millimetres; everything inside ArchScan is metres,
/// so imports are converted on the way in and the assumed unit is reported back so a
/// mis-scaled file is visible rather than silent.
enum MeshImporter {

    struct Result {
        var mesh: ScanMesh
        var detectedFormat: String
        var assumedUnit: String
        var warnings: [String]
    }

    enum ImportError: Error, LocalizedError {
        case unsupported(String)
        case malformed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let ext): return "\(ext.uppercased()) files are not supported. Export the scan as STL, PLY or OBJ."
            case .malformed(let detail): return "The file could not be read: \(detail)"
            case .empty: return "That file contains no geometry."
            }
        }
    }

    static func load(from url: URL) throws -> Result {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let ext = url.pathExtension.lowercased()
        var mesh: ScanMesh
        var format: String

        switch ext {
        case "stl":       mesh = try readSTL(data); format = "STL"
        case "ply":       mesh = try readPLY(data); format = "PLY"
        case "obj":       mesh = try readOBJ(data); format = "OBJ"
        default:          throw ImportError.unsupported(ext)
        }
        guard !mesh.isEmpty else { throw ImportError.empty }

        var warnings: [String] = []
        // Decide the unit from the size of the thing. An arch is 40–90 mm across; the
        // same numbers read as metres would be a 50-metre object.
        let bounds = mesh.bounds
        let extent = simd_length(bounds.max - bounds.min)
        var assumedUnit = "millimetres"
        if extent > 20 {
            mesh = mesh.scaled(by: 0.001)          // the file was in millimetres
        } else if extent > 0.02 {
            assumedUnit = "metres"
            warnings.append("This file appears to already be in metres, which is unusual for an intraoral scan. Check the scale before registering it.")
        } else {
            warnings.append("The imported geometry spans only \(String(format: "%.1f", extent * 1000)) mm, which is smaller than any dental scan. Check the export settings.")
            mesh = mesh.scaled(by: 0.001)
        }

        MeshPostProcess.recomputeNormals(&mesh)
        if mesh.colors.count != mesh.positions.count {
            mesh.colors = [SIMD3<Float>](repeating: SIMD3<Float>(0.86, 0.84, 0.80), count: mesh.positions.count)
        }
        return Result(mesh: mesh, detectedFormat: format, assumedUnit: assumedUnit, warnings: warnings)
    }

    // MARK: - STL

    private static func readSTL(_ data: Data) throws -> ScanMesh {
        guard data.count >= 84 else { throw ImportError.malformed("the STL is too short.") }
        let triangleCount = Int(data.readUInt32(at: 80))
        let looksBinary = data.count == 84 + triangleCount * 50

        if !looksBinary {
            return try readASCIISTL(data)
        }

        var mesh = ScanMesh()
        mesh.positions.reserveCapacity(triangleCount * 3)
        mesh.indices.reserveCapacity(triangleCount * 3)
        var offset = 84
        for _ in 0..<triangleCount {
            offset += 12                                   // the face normal, recomputed later
            let start = UInt32(mesh.positions.count)
            for _ in 0..<3 {
                mesh.positions.append(SIMD3<Float>(data.readFloat(at: offset),
                                                   data.readFloat(at: offset + 4),
                                                   data.readFloat(at: offset + 8)))
                offset += 12
            }
            offset += 2
            mesh.indices.append(contentsOf: [start, start + 1, start + 2])
        }
        return weld(mesh)
    }

    private static func readASCIISTL(_ data: Data) throws -> ScanMesh {
        let text = String(decoding: data, as: UTF8.self)
        var mesh = ScanMesh()
        var pending: [SIMD3<Float>] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, parts[0] == "vertex" else { continue }
            pending.append(SIMD3<Float>(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0))
            if pending.count == 3 {
                let start = UInt32(mesh.positions.count)
                mesh.positions.append(contentsOf: pending)
                mesh.indices.append(contentsOf: [start, start + 1, start + 2])
                pending.removeAll(keepingCapacity: true)
            }
        }
        return weld(mesh)
    }

    /// STL has no vertex sharing at all, so an imported arch arrives as loose
    /// triangles. Welding is what makes smoothing, components and ICP behave.
    private static func weld(_ mesh: ScanMesh, tolerance: Float = 1e-6) -> ScanMesh {
        guard !mesh.positions.isEmpty else { return mesh }
        var lookup: [SIMD3<Int32>: UInt32] = [:]
        lookup.reserveCapacity(mesh.positions.count / 2)
        var out = ScanMesh()
        var remap = [UInt32](repeating: 0, count: mesh.positions.count)
        let inverseTolerance = 1 / tolerance

        for (index, p) in mesh.positions.enumerated() {
            let key = SIMD3<Int32>(Int32((p.x * inverseTolerance).rounded()),
                                   Int32((p.y * inverseTolerance).rounded()),
                                   Int32((p.z * inverseTolerance).rounded()))
            if let existing = lookup[key] {
                remap[index] = existing
            } else {
                let newIndex = UInt32(out.positions.count)
                out.positions.append(p)
                lookup[key] = newIndex
                remap[index] = newIndex
            }
        }
        out.indices = mesh.indices.map { remap[Int($0)] }
        return out
    }

    // MARK: - PLY

    private static func readPLY(_ data: Data) throws -> ScanMesh {
        let headerLimit = min(data.count, 16384)
        let headerText = String(decoding: data.prefix(headerLimit), as: UTF8.self)
        guard let endRange = headerText.range(of: "end_header") else {
            throw ImportError.malformed("no PLY header was found.")
        }
        var headerEnd = headerText.distance(from: headerText.startIndex, to: endRange.upperBound)
        while headerEnd < data.count, data[data.startIndex + headerEnd] != 0x0A { headerEnd += 1 }
        headerEnd += 1

        struct Property { var type: String; var name: String }
        var format = "ascii"
        var vertexCount = 0, faceCount = 0
        var properties: [Property] = []
        var listCountType = "uchar", listIndexType = "int"
        var currentElement = ""

        for rawLine in headerText[..<endRange.lowerBound].split(separator: "\n") {
            let parts = rawLine.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let keyword = parts.first else { continue }
            switch keyword {
            case "format": if parts.count > 1 { format = parts[1] }
            case "element":
                if parts.count > 2 {
                    currentElement = parts[1]
                    if currentElement == "vertex" { vertexCount = Int(parts[2]) ?? 0 }
                    if currentElement == "face" { faceCount = Int(parts[2]) ?? 0 }
                }
            case "property":
                if parts.count > 3, parts[1] == "list" {
                    listCountType = parts[2]; listIndexType = parts[3]
                } else if parts.count > 2, currentElement == "vertex" {
                    properties.append(Property(type: parts[1], name: parts[2]))
                }
            default: break
            }
        }
        guard vertexCount > 0 else { throw ImportError.empty }

        var mesh = ScanMesh()
        mesh.positions = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var colors = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var hasColor = false

        func store(_ index: Int, _ name: String, _ value: Double) {
            switch name {
            case "x": mesh.positions[index].x = Float(value)
            case "y": mesh.positions[index].y = Float(value)
            case "z": mesh.positions[index].z = Float(value)
            case "red":   colors[index].x = Float(value) / 255; hasColor = true
            case "green": colors[index].y = Float(value) / 255
            case "blue":  colors[index].z = Float(value) / 255
            default: break
            }
        }

        if format == "ascii" {
            let body = String(decoding: data.dropFirst(headerEnd), as: UTF8.self).split(separator: "\n")
            var cursor = 0
            for index in 0..<vertexCount {
                guard cursor < body.count else { break }
                let parts = body[cursor].split(separator: " ").compactMap { Double($0) }
                cursor += 1
                for (position, property) in properties.enumerated() where position < parts.count {
                    store(index, property.name, parts[position])
                }
            }
            for _ in 0..<faceCount {
                guard cursor < body.count else { break }
                let parts = body[cursor].split(separator: " ").compactMap { Int($0) }
                cursor += 1
                guard let n = parts.first, n >= 3, parts.count > n else { continue }
                for k in 1...(n - 2) {
                    mesh.indices.append(contentsOf: [UInt32(parts[1]), UInt32(parts[k + 1]), UInt32(parts[k + 2])])
                }
            }
        } else {
            let little = format.contains("little")
            var offset = headerEnd
            for index in 0..<vertexCount {
                for property in properties {
                    let size = byteWidth(property.type)
                    guard offset + size <= data.count else { break }
                    store(index, property.name, data.readNumber(at: offset, type: property.type, littleEndian: little))
                    offset += size
                }
            }
            for _ in 0..<faceCount {
                let countWidth = byteWidth(listCountType)
                guard offset + countWidth <= data.count else { break }
                let n = Int(data.readNumber(at: offset, type: listCountType, littleEndian: little))
                offset += countWidth
                let indexWidth = byteWidth(listIndexType)
                var face: [UInt32] = []
                face.reserveCapacity(n)
                for _ in 0..<n {
                    guard offset + indexWidth <= data.count else { break }
                    face.append(UInt32(max(0, data.readNumber(at: offset, type: listIndexType, littleEndian: little))))
                    offset += indexWidth
                }
                guard face.count >= 3 else { continue }
                for k in 1..<(face.count - 1) {
                    mesh.indices.append(contentsOf: [face[0], face[k], face[k + 1]])
                }
            }
        }

        if hasColor { mesh.colors = colors }
        return mesh
    }

    // MARK: - OBJ

    private static func readOBJ(_ data: Data) throws -> ScanMesh {
        let text = String(decoding: data, as: UTF8.self)
        var mesh = ScanMesh()
        var vertices: [SIMD3<Float>] = []

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let keyword = parts.first else { continue }
            if keyword == "v", parts.count >= 4 {
                vertices.append(SIMD3<Float>(Float(parts[1]) ?? 0, Float(parts[2]) ?? 0, Float(parts[3]) ?? 0))
            } else if keyword == "f", parts.count >= 4 {
                var face: [UInt32] = []
                for token in parts.dropFirst() {
                    let first = token.split(separator: "/", omittingEmptySubsequences: false).first ?? ""
                    guard let raw = Int(first) else { continue }
                    let index = raw < 0 ? vertices.count + raw : raw - 1
                    guard index >= 0, index < vertices.count else { continue }
                    face.append(UInt32(index))
                }
                guard face.count >= 3 else { continue }
                for k in 1..<(face.count - 1) {
                    mesh.indices.append(contentsOf: [face[0], face[k], face[k + 1]])
                }
            }
        }
        mesh.positions = vertices
        return mesh
    }

    private static func byteWidth(_ type: String) -> Int {
        switch type {
        case "char", "uchar", "int8", "uint8":   return 1
        case "short", "ushort", "int16", "uint16": return 2
        case "double", "float64":                return 8
        default:                                 return 4
        }
    }
}

private extension Data {
    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    func readFloat(at offset: Int) -> Float {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { Float(bitPattern: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) }
    }

    func readNumber(at offset: Int, type: String, littleEndian: Bool) -> Double {
        withUnsafeBytes { raw -> Double in
            switch type {
            case "char", "int8":     return Double(raw.loadUnaligned(fromByteOffset: offset, as: Int8.self))
            case "uchar", "uint8":   return Double(raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
            case "short", "int16":
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                return Double(Int16(bitPattern: littleEndian ? v.littleEndian : v.bigEndian))
            case "ushort", "uint16":
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                return Double(littleEndian ? v.littleEndian : v.bigEndian)
            case "int", "int32":
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Double(Int32(bitPattern: littleEndian ? v.littleEndian : v.bigEndian))
            case "uint", "uint32":
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Double(littleEndian ? v.littleEndian : v.bigEndian)
            case "double", "float64":
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                return Double(bitPattern: littleEndian ? v.littleEndian : v.bigEndian)
            default:
                let v = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                return Double(Float(bitPattern: littleEndian ? v.littleEndian : v.bigEndian))
            }
        }
    }
}
