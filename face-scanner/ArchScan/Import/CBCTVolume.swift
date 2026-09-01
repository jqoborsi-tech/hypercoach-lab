import Foundation
import simd

/// A CBCT series loaded into one scalar volume, in Hounsfield-like units.
///
/// Positions are reported in **metres**, matching `ScanMesh`, so a surface extracted
/// from the CBCT lands in the same units as the facial and intraoral meshes and needs
/// no conversion before registration.
final class CBCTVolume: ScalarField {

    let nx: Int, ny: Int, nz: Int
    /// Patient-space step for one increment of each index axis, in metres.
    let stepI: SIMD3<Float>
    let stepJ: SIMD3<Float>
    let stepK: SIMD3<Float>
    /// Patient-space position of voxel (0,0,0), in metres.
    let origin: SIMD3<Float>
    let voxelSizeMillimetres: SIMD3<Float>
    let info: DICOMReader.StudyInfo
    let sourceSliceCount: Int
    let downsampleFactor: Int

    /// Surface threshold, in the volume's stored units. Iso-surface extraction treats
    /// anything denser than this as inside.
    var threshold: Float = 1500

    private let values: UnsafeMutablePointer<Int16>

    /// Common CBCT thresholds. CBCT grey values are not true Hounsfield units — they
    /// drift with field of view and exposure — so these are starting points to be
    /// adjusted against the preview, not constants.
    enum Preset: String, CaseIterable, Identifiable {
        case enamel, bone, softTissue, airway
        var id: String { rawValue }
        var title: String {
            switch self {
            case .enamel:     return "Enamel / restorations"
            case .bone:       return "Bone"
            case .softTissue: return "Soft tissue"
            case .airway:     return "Airway"
            }
        }
        var value: Float {
            switch self {
            case .enamel:     return 1800
            case .bone:       return 500
            case .softTissue: return -300
            case .airway:     return -800
            }
        }
        var note: String {
            switch self {
            case .enamel:     return "Teeth and any metal. This is the surface to register the intraoral scan against."
            case .bone:       return "Cortical and dense trabecular bone, for the implant plan."
            case .softTissue: return "The facial soft-tissue envelope. Lips are often distorted during a CBCT — do not register the face scan to this."
            case .airway:     return "Air column."
            }
        }
    }

    deinit { values.deallocate() }

    private init(nx: Int, ny: Int, nz: Int,
                 origin: SIMD3<Float>, stepI: SIMD3<Float>, stepJ: SIMD3<Float>, stepK: SIMD3<Float>,
                 voxelSizeMillimetres: SIMD3<Float>,
                 info: DICOMReader.StudyInfo,
                 sourceSliceCount: Int,
                 downsampleFactor: Int,
                 values: UnsafeMutablePointer<Int16>) {
        self.nx = nx; self.ny = ny; self.nz = nz
        self.origin = origin; self.stepI = stepI; self.stepJ = stepJ; self.stepK = stepK
        self.voxelSizeMillimetres = voxelSizeMillimetres
        self.info = info
        self.sourceSliceCount = sourceSliceCount
        self.downsampleFactor = downsampleFactor
        self.values = values
    }

    // MARK: - Loading

    /// Voxel budget. A full CBCT is commonly 600–800 cubed at 16 bits, which is more
    /// than an iPhone should hold; the series is subsampled to fit. Registration and
    /// surface extraction do not need the native grid, and the original files stay on
    /// disk untouched for anything that does.
    private static let maximumVoxels = 40_000_000

    static func load(slices: [DICOMReader.Slice],
                     info: DICOMReader.StudyInfo,
                     progress: ((Double) -> Void)? = nil) throws -> CBCTVolume {
        guard let first = slices.first, slices.count > 1 else { throw DICOMReader.ReaderError.noSlices }

        // Slice spacing from the positions themselves, which is more trustworthy than
        // SliceThickness when the export has overlapping or padded slices.
        let normal = first.normal
        let spanStart = simd_dot(slices[0].position, normal)
        let spanEnd = simd_dot(slices[slices.count - 1].position, normal)
        var sliceSpacing = abs(spanEnd - spanStart) / Double(slices.count - 1)
        if sliceSpacing < 1e-6 { sliceSpacing = first.sliceThickness }
        guard sliceSpacing > 1e-6 else {
            throw DICOMReader.ReaderError.inconsistentSeries("slice spacing could not be determined.")
        }

        // Pick a subsample that fits the budget, keeping the grid roughly isotropic.
        var stride = 1
        while (first.columns / stride) * (first.rows / stride) * (slices.count / stride) > maximumVoxels {
            stride += 1
        }

        let nx = first.columns / stride
        let ny = first.rows / stride
        let nz = slices.count / stride
        guard nx > 4, ny > 4, nz > 4 else {
            throw DICOMReader.ReaderError.inconsistentSeries("the series is too small to reconstruct.")
        }

        let toMetres: Float = 0.001
        let rowDirection = SIMD3<Float>(first.orientationRow)
        let columnDirection = SIMD3<Float>(first.orientationColumn)
        let sliceDirection = SIMD3<Float>(normal) * Float(spanEnd >= spanStart ? 1 : -1)

        let stepI = rowDirection * Float(first.columnSpacing * Double(stride)) * toMetres
        let stepJ = columnDirection * Float(first.rowSpacing * Double(stride)) * toMetres
        let stepK = sliceDirection * Float(sliceSpacing * Double(stride)) * toMetres
        let origin = SIMD3<Float>(first.position) * toMetres

        let count = nx * ny * nz
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: count)
        buffer.initialize(repeating: -1024, count: count)

        for k in 0..<nz {
            progress?(0.5 + Double(k) / Double(nz) * 0.5)
            let slice = slices[k * stride]
            guard let data = try? Data(contentsOf: slice.url, options: [.mappedIfSafe]) else { continue }
            let bytesPerSample = slice.bitsAllocated / 8
            let expected = slice.rows * slice.columns * bytesPerSample
            guard slice.pixelDataOffset + expected <= data.count else { continue }

            let slope = Float(slice.rescaleSlope == 0 ? 1 : slice.rescaleSlope)
            let intercept = Float(slice.rescaleIntercept)
            let signed = slice.signed
            let columns = slice.columns
            let base = slice.pixelDataOffset

            data.withUnsafeBytes { raw in
                for j in 0..<ny {
                    let sourceRow = j * stride
                    for i in 0..<nx {
                        let sourceColumn = i * stride
                        let byteOffset = base + (sourceRow * columns + sourceColumn) * bytesPerSample
                        var stored: Float
                        if bytesPerSample == 2 {
                            let bits = raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt16.self).littleEndian
                            stored = signed ? Float(Int16(bitPattern: bits)) : Float(bits)
                        } else {
                            stored = Float(raw.loadUnaligned(fromByteOffset: byteOffset, as: UInt8.self))
                        }
                        let hu = stored * slope + intercept
                        buffer[(k * ny + j) * nx + i] = Int16(max(-32000, min(32000, hu)))
                    }
                }
            }
        }
        progress?(1)

        let voxelMillimetres = SIMD3<Float>(Float(first.columnSpacing * Double(stride)),
                                            Float(first.rowSpacing * Double(stride)),
                                            Float(sliceSpacing * Double(stride)))
        return CBCTVolume(nx: nx, ny: ny, nz: nz,
                          origin: origin, stepI: stepI, stepJ: stepJ, stepK: stepK,
                          voxelSizeMillimetres: voxelMillimetres,
                          info: info,
                          sourceSliceCount: slices.count,
                          downsampleFactor: stride,
                          values: buffer)
    }

    // MARK: - Description

    var fieldOfViewMillimetres: SIMD3<Float> {
        SIMD3<Float>(Float(nx) * voxelSizeMillimetres.x,
                     Float(ny) * voxelSizeMillimetres.y,
                     Float(nz) * voxelSizeMillimetres.z)
    }

    @inline(__always)
    func storedValue(_ i: Int, _ j: Int, _ k: Int) -> Float {
        Float(values[(k * ny + j) * nx + i])
    }

    /// Fraction of voxels above the current threshold — the quick sanity check that a
    /// threshold is picking out teeth rather than the whole head or nothing at all.
    func fractionAboveThreshold() -> Double {
        var above = 0
        var total = 0
        var k = 0
        while k < nz {
            var j = 0
            while j < ny {
                var i = 0
                while i < nx {
                    if storedValue(i, j, k) > threshold { above += 1 }
                    total += 1
                    i += 3
                }
                j += 3
            }
            k += 3
        }
        return total > 0 ? Double(above) / Double(total) : 0
    }

    /// Restricts extraction to a box, in index space. Used to cut a full head volume
    /// down to the dentition before meshing.
    var regionOfInterest: (lower: SIMD3<Int>, upper: SIMD3<Int>)?

    // MARK: - ScalarField

    func fieldValue(_ i: Int, _ j: Int, _ k: Int) -> Float {
        threshold - storedValue(i, j, k)
    }

    func fieldIsObserved(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        guard let roi = regionOfInterest else { return true }
        return i >= roi.lower.x && i <= roi.upper.x
            && j >= roi.lower.y && j <= roi.upper.y
            && k >= roi.lower.z && k <= roi.upper.z
    }

    func fieldColor(_ i: Int, _ j: Int, _ k: Int) -> (SIMD3<Float>, Bool) {
        (SIMD3<Float>(0.90, 0.88, 0.84), false)
    }

    func fieldPosition(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        origin + stepI * Float(i) + stepJ * Float(j) + stepK * Float(k)
    }
}
