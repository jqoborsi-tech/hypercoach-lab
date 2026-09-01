import Foundation
import simd

/// Minimal DICOM reader, scoped to what a CBCT export actually contains.
///
/// It reads Part 10 files (and bare datasets, which some CBCT exports produce),
/// explicit and implicit VR little endian, uncompressed pixel data. Anything else —
/// a JPEG-compressed transfer syntax in particular — is reported as unsupported
/// rather than decoded into plausible-looking nonsense, because a silently wrong
/// CBCT is far worse than one that refuses to load.
enum DICOMReader {

    // MARK: - Tags

    struct Tag: Hashable {
        let group: UInt16
        let element: UInt16
        init(_ group: UInt16, _ element: UInt16) { self.group = group; self.element = element }

        static let transferSyntaxUID  = Tag(0x0002, 0x0010)
        static let sopClassUID        = Tag(0x0008, 0x0016)
        static let modality           = Tag(0x0008, 0x0060)
        static let manufacturer       = Tag(0x0008, 0x0070)
        static let studyDate          = Tag(0x0008, 0x0020)
        static let patientName        = Tag(0x0010, 0x0010)
        static let patientID          = Tag(0x0010, 0x0020)
        static let patientBirthDate   = Tag(0x0010, 0x0030)
        static let sliceThickness     = Tag(0x0018, 0x0050)
        static let kvp                = Tag(0x0018, 0x0060)
        static let spacingBetweenSlices = Tag(0x0018, 0x0088)
        static let seriesInstanceUID  = Tag(0x0020, 0x000E)
        static let instanceNumber     = Tag(0x0020, 0x0013)
        static let imagePosition      = Tag(0x0020, 0x0032)
        static let imageOrientation   = Tag(0x0020, 0x0037)
        static let rows               = Tag(0x0028, 0x0010)
        static let columns            = Tag(0x0028, 0x0011)
        static let pixelSpacing       = Tag(0x0028, 0x0030)
        static let bitsAllocated      = Tag(0x0028, 0x0100)
        static let bitsStored         = Tag(0x0028, 0x0101)
        static let pixelRepresentation = Tag(0x0028, 0x0103)
        static let rescaleIntercept   = Tag(0x0028, 0x1052)
        static let rescaleSlope       = Tag(0x0028, 0x1053)
        static let pixelData          = Tag(0x7FE0, 0x0010)
    }

    /// One parsed slice: the header values the volume needs, plus where its pixels start.
    struct Slice {
        var url: URL
        var rows = 0
        var columns = 0
        var rowSpacing: Double = 0
        var columnSpacing: Double = 0
        var sliceThickness: Double = 0
        var position = SIMD3<Double>.zero
        var orientationRow = SIMD3<Double>(1, 0, 0)
        var orientationColumn = SIMD3<Double>(0, 1, 0)
        var instanceNumber = 0
        var bitsAllocated = 16
        var signed = false
        var rescaleSlope: Double = 1
        var rescaleIntercept: Double = 0
        var seriesUID = ""
        var pixelDataOffset = 0
        var pixelDataLength = 0

        var normal: SIMD3<Double> { simd_cross(orientationRow, orientationColumn) }
    }

    struct StudyInfo {
        var modality = ""
        var manufacturer = ""
        var studyDate = ""
        var kvp = ""
        /// Present so the clinician knows what identifiers the files carry.
        var patientName = ""
        var patientID = ""
        var patientBirthDate = ""

        var carriesPatientIdentifiers: Bool {
            !patientName.isEmpty || !patientID.isEmpty || !patientBirthDate.isEmpty
        }
    }

    enum ReaderError: Error, LocalizedError {
        case notDICOM(String)
        case compressed(String)
        case inconsistentSeries(String)
        case noSlices
        case unsupportedBitDepth(Int)

        var errorDescription: String? {
            switch self {
            case .notDICOM(let name):
                return "\(name) is not a DICOM file."
            case .compressed(let syntax):
                return "This CBCT uses a compressed transfer syntax (\(syntax)). Re-export it from your CBCT software as uncompressed DICOM — most scanners offer that directly."
            case .inconsistentSeries(let detail):
                return "The slices do not form one consistent series: \(detail)"
            case .noSlices:
                return "No readable DICOM slices were found in that folder."
            case .unsupportedBitDepth(let bits):
                return "\(bits)-bit pixel data is not supported; CBCT is normally 16-bit."
            }
        }
    }

    private static let uncompressedSyntaxes: Set<String> = [
        "1.2.840.10008.1.2",        // implicit VR little endian
        "1.2.840.10008.1.2.1",      // explicit VR little endian
        "1.2.840.10008.1.2.1.99"    // deflated — header only, still uncompressed pixels
    ]

    // MARK: - Header parsing

    /// Parses one file's header. Pixel data is left on disk and read later.
    static func readSlice(at url: URL) throws -> (slice: Slice, info: StudyInfo) {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count > 132 else { throw ReaderError.notDICOM(url.lastPathComponent) }

        // Part 10 files carry a 128-byte preamble then "DICM"; bare datasets do not.
        let hasPreamble = data[128] == 0x44 && data[129] == 0x49 && data[130] == 0x43 && data[131] == 0x4D
        var offset = hasPreamble ? 132 : 0
        if !hasPreamble {
            let firstGroup = data.readUInt16(at: 0)
            guard firstGroup == 0x0008 || firstGroup == 0x0002 else {
                throw ReaderError.notDICOM(url.lastPathComponent)
            }
        }

        var slice = Slice(url: url)
        var info = StudyInfo()
        var transferSyntax = "1.2.840.10008.1.2.1"

        // The file-meta group is explicit VR little endian by definition. The dataset
        // after it uses whatever that group's transfer syntax declares. A bare dataset
        // has no meta group, so sniff it: two uppercase letters where the VR would sit.
        var inMetaGroup = hasPreamble
        var explicitVR = true
        if !hasPreamble {
            let a = data[4], b = data[5]
            explicitVR = (a >= 65 && a <= 90 && b >= 65 && b <= 90)
        }

        while offset + 8 <= data.count {
            let group = data.readUInt16(at: offset)
            let element = data.readUInt16(at: offset + 2)
            let tag = Tag(group, element)

            if inMetaGroup, group != 0x0002 {
                inMetaGroup = false
                explicitVR = transferSyntax != "1.2.840.10008.1.2"
            }

            var valueOffset = offset + 4
            var length = 0
            var vr = ""

            if explicitVR {
                guard valueOffset + 4 <= data.count else { break }
                vr = String(bytes: [data[valueOffset], data[valueOffset + 1]], encoding: .ascii) ?? ""
                if ["OB", "OW", "OF", "SQ", "UT", "UN"].contains(vr) {
                    valueOffset += 4
                    guard valueOffset + 4 <= data.count else { break }
                    length = Int(data.readUInt32(at: valueOffset))
                    valueOffset += 4
                } else {
                    length = Int(data.readUInt16(at: valueOffset + 2))
                    valueOffset += 4
                }
            } else {
                guard valueOffset + 4 <= data.count else { break }
                length = Int(data.readUInt32(at: valueOffset))
                valueOffset += 4
            }

            // Sequences and encapsulated pixel data use an undefined length.
            if length == Int(UInt32.max) {
                if tag == Tag.pixelData {
                    throw ReaderError.compressed(transferSyntax)
                }
                // Skip the sequence by scanning to its delimiter (FFFE,E0DD).
                var scan = valueOffset
                while scan + 8 <= data.count {
                    if data.readUInt16(at: scan) == 0xFFFE && data.readUInt16(at: scan + 2) == 0xE0DD {
                        scan += 8
                        break
                    }
                    scan += 2
                }
                offset = scan
                continue
            }

            if tag == Tag.pixelData {
                slice.pixelDataOffset = valueOffset
                slice.pixelDataLength = length
                break
            }

            let valueEnd = min(valueOffset + length, data.count)
            guard valueOffset <= valueEnd else { break }
            let value = data.subdata(in: valueOffset..<valueEnd)

            switch tag {
            case Tag.transferSyntaxUID: transferSyntax = value.trimmedString
            case Tag.modality:          info.modality = value.trimmedString
            case Tag.manufacturer:      info.manufacturer = value.trimmedString
            case Tag.studyDate:         info.studyDate = value.trimmedString
            case Tag.kvp:               info.kvp = value.trimmedString
            case Tag.patientName:       info.patientName = value.trimmedString
            case Tag.patientID:         info.patientID = value.trimmedString
            case Tag.patientBirthDate:  info.patientBirthDate = value.trimmedString
            case Tag.rows:              slice.rows = Int(value.readUInt16(at: 0))
            case Tag.columns:           slice.columns = Int(value.readUInt16(at: 0))
            case Tag.bitsAllocated:     slice.bitsAllocated = Int(value.readUInt16(at: 0))
            case Tag.pixelRepresentation: slice.signed = value.readUInt16(at: 0) == 1
            case Tag.instanceNumber:    slice.instanceNumber = Int(value.trimmedString) ?? 0
            case Tag.seriesInstanceUID: slice.seriesUID = value.trimmedString
            case Tag.sliceThickness:    slice.sliceThickness = Double(value.trimmedString) ?? 0
            case Tag.rescaleSlope:      slice.rescaleSlope = Double(value.trimmedString) ?? 1
            case Tag.rescaleIntercept:  slice.rescaleIntercept = Double(value.trimmedString) ?? 0
            case Tag.pixelSpacing:
                let parts = value.decimalValues
                if parts.count >= 2 { slice.rowSpacing = parts[0]; slice.columnSpacing = parts[1] }
            case Tag.imagePosition:
                let parts = value.decimalValues
                if parts.count >= 3 { slice.position = SIMD3<Double>(parts[0], parts[1], parts[2]) }
            case Tag.imageOrientation:
                let parts = value.decimalValues
                if parts.count >= 6 {
                    slice.orientationRow = SIMD3<Double>(parts[0], parts[1], parts[2])
                    slice.orientationColumn = SIMD3<Double>(parts[3], parts[4], parts[5])
                }
            default:
                break
            }

            offset = valueOffset + length
            if length % 2 == 1 { offset += 1 }     // DICOM values are even-length padded
        }

        guard uncompressedSyntaxes.contains(transferSyntax) else {
            throw ReaderError.compressed(transferSyntax)
        }
        guard slice.rows > 0, slice.columns > 0, slice.pixelDataLength > 0 else {
            throw ReaderError.notDICOM(url.lastPathComponent)
        }
        guard slice.bitsAllocated == 16 || slice.bitsAllocated == 8 else {
            throw ReaderError.unsupportedBitDepth(slice.bitsAllocated)
        }
        return (slice, info)
    }

    /// Finds every DICOM in a folder, keeps the largest consistent series, and sorts it.
    static func readSeries(in folder: URL,
                           progress: ((Double) -> Void)? = nil) throws -> (slices: [Slice], info: StudyInfo) {
        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: folder,
                                                           includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if ext == "dcm" || ext == "" || ext == "ima" || ext == "dicom" { candidates.append(url) }
            }
        }
        guard !candidates.isEmpty else { throw ReaderError.noSlices }

        var bySeries: [String: [Slice]] = [:]
        var info = StudyInfo()
        var compressionError: Error?

        for (index, url) in candidates.enumerated() {
            progress?(Double(index) / Double(candidates.count) * 0.5)
            do {
                let (slice, sliceInfo) = try readSlice(at: url)
                bySeries[slice.seriesUID, default: []].append(slice)
                if info.modality.isEmpty { info = sliceInfo }
            } catch let error as ReaderError {
                if case .compressed = error { compressionError = error }
            } catch {
                continue
            }
        }

        guard var slices = bySeries.values.max(by: { $0.count < $1.count }), slices.count > 1 else {
            throw compressionError ?? ReaderError.noSlices
        }

        // Sort along the slice normal; instance number is the fallback when the
        // position tag is missing or constant.
        let normal = slices[0].normal
        let spread = slices.map { simd_dot($0.position, normal) }
        if let low = spread.min(), let high = spread.max(), high - low > 1e-6 {
            slices.sort { simd_dot($0.position, normal) < simd_dot($1.position, normal) }
        } else {
            slices.sort { $0.instanceNumber < $1.instanceNumber }
        }

        let first = slices[0]
        guard slices.allSatisfy({ $0.rows == first.rows && $0.columns == first.columns }) else {
            throw ReaderError.inconsistentSeries("the slices are not all the same size.")
        }
        progress?(0.5)
        return (slices, info)
    }
}

// MARK: - Little-endian reads

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    var trimmedString: String {
        String(decoding: self, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
    }

    var decimalValues: [Double] {
        trimmedString.split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}
