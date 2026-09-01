import Foundation
import ARKit
import CoreVideo
import simd

/// Reads colour straight out of ARKit's captured image at **full sensor resolution**
/// (1920x1440 on the iPhone 15 Pro Max front camera), without copying or downsampling.
///
/// For smile design the texture is the deliverable as much as the geometry is — shade,
/// incisal translucency, the gingival margin — so colour is sampled at native
/// resolution rather than from a reduced copy. The pointers are only valid for the
/// duration of `ColorSampler.with(frame:)`, which is why fusion runs inside that scope.
struct ColorSampler {
    let luma: UnsafePointer<UInt8>
    let chroma: UnsafePointer<UInt8>
    let lumaStride: Int
    let chromaStride: Int
    let width: Int
    let height: Int
    let fx: Float, fy: Float, cx: Float, cy: Float
    /// Video-range buffers need the 16–235 expansion; full-range ones do not.
    let videoRange: Bool

    @inline(__always)
    func sample(u: Float, v: Float) -> SIMD3<Float>? {
        let x = Int(u), y = Int(v)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        var yy = Float(luma[y * lumaStride + x])
        let chromaIndex = (y >> 1) * chromaStride + (x >> 1) * 2
        var cb = Float(chroma[chromaIndex]) - 128
        var cr = Float(chroma[chromaIndex + 1]) - 128
        if videoRange {
            yy = (yy - 16) * (255.0 / 219.0)
            cb *= 255.0 / 224.0
            cr *= 255.0 / 224.0
        }
        let r = yy + 1.402 * cr
        let g = yy - 0.344136 * cb - 0.714136 * cr
        let b = yy + 1.772 * cb
        return SIMD3<Float>(min(max(r, 0), 255) / 255,
                            min(max(g, 0), 255) / 255,
                            min(max(b, 0), 255) / 255)
    }

    /// Locks the frame's pixel buffer, builds a sampler over it, and unlocks on exit.
    static func with<T>(frame: ARFrame, _ body: (ColorSampler?) -> T) -> T {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return body(nil) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return body(nil) }

        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let m = frame.camera.intrinsics
        let reference = frame.camera.imageResolution
        let sx = Float(width) / Float(reference.width)
        let sy = Float(height) / Float(reference.height)

        let sampler = ColorSampler(
            luma: lumaBase.assumingMemoryBound(to: UInt8.self),
            chroma: chromaBase.assumingMemoryBound(to: UInt8.self),
            lumaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
            chromaStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
            width: width, height: height,
            fx: m.columns.0.x * sx, fy: m.columns.1.y * sy,
            cx: m.columns.2.x * sx, cy: m.columns.2.y * sy,
            videoRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        return body(sampler)
    }
}

/// One TrueDepth measurement, already detached from ARKit's buffer pool.
struct DepthFrame {
    var width: Int
    var height: Int
    var depth: [Float]            // metres along the optical axis; 0 where invalid
    var fx: Float, fy: Float, cx: Float, cy: Float
    /// ARKit camera space -> face-anchor space.
    var cameraToFace: simd_float4x4
    var timestamp: TimeInterval
    /// Head pose relative to the camera, used for coverage bookkeeping.
    var faceYawDegrees: Float
    var facePitchDegrees: Float
    var faceDistance: Float

    @inline(__always)
    func deproject(x: Int, y: Int, depthValue d: Float) -> SIMD3<Float> {
        // Computer-vision convention (x right, y down, z forward) ...
        let xc = (Float(x) + 0.5 - cx) * d / fx
        let yc = (Float(y) + 0.5 - cy) * d / fy
        // ... converted to ARKit camera space (x right, y up, z toward the viewer).
        return SIMD3<Float>(xc, -yc, -d)
    }

    static func make(from frame: ARFrame, faceAnchor: ARFaceAnchor) -> DepthFrame? {
        guard let raw = frame.capturedDepthData else { return nil }
        let converted = raw.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)

        var depth = [Float](repeating: 0, count: width * height)
        depth.withUnsafeMutableBufferPointer { dst in
            for row in 0..<height {
                let src = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float.self)
                for col in 0..<width {
                    let value = src[col]
                    dst[row * width + col] = value.isFinite ? value : 0
                }
            }
        }

        // Intrinsics, scaled to the depth map's own resolution.
        var fx: Float, fy: Float, cx: Float, cy: Float
        if let calibration = converted.cameraCalibration {
            let m = calibration.intrinsicMatrix
            let reference = calibration.intrinsicMatrixReferenceDimensions
            let sx = Float(width) / Float(reference.width)
            let sy = Float(height) / Float(reference.height)
            fx = m.columns.0.x * sx
            fy = m.columns.1.y * sy
            cx = m.columns.2.x * sx
            cy = m.columns.2.y * sy
        } else {
            let m = frame.camera.intrinsics
            let reference = frame.camera.imageResolution
            let sx = Float(width) / Float(reference.width)
            let sy = Float(height) / Float(reference.height)
            fx = m.columns.0.x * sx
            fy = m.columns.1.y * sy
            cx = m.columns.2.x * sx
            cy = m.columns.2.y * sy
        }

        let cameraToFace = simd_inverse(faceAnchor.transform) * frame.camera.transform

        // Head orientation relative to the camera, for the coverage gauge.
        let faceToCamera = simd_inverse(frame.camera.transform) * faceAnchor.transform
        let forward = SIMD3<Float>(faceToCamera.columns.2.x, faceToCamera.columns.2.y, faceToCamera.columns.2.z)
        let yaw = atan2(forward.x, -forward.z) * 180 / .pi
        let pitch = asin(max(-1, min(1, forward.y))) * 180 / .pi
        let t = faceToCamera.columns.3
        let distance = simd_length(SIMD3<Float>(t.x, t.y, t.z))

        return DepthFrame(width: width, height: height, depth: depth,
                          fx: fx, fy: fy, cx: cx, cy: cy,
                          cameraToFace: cameraToFace,
                          timestamp: frame.capturedDepthDataTimestamp,
                          faceYawDegrees: yaw, facePitchDegrees: pitch, faceDistance: distance)
    }

}
