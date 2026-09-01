import Foundation
import ARKit
import CoreVideo
import simd

/// A quarter-resolution RGB copy of the captured frame, kept so colour can be
/// sampled off the ARKit queue without holding on to pixel buffers from the pool.
struct RGBImage {
    var width: Int
    var height: Int
    var pixels: [UInt8]          // 3 bytes per pixel, sRGB
    var fx: Float, fy: Float, cx: Float, cy: Float

    @inline(__always)
    func sample(u: Float, v: Float) -> SIMD3<Float>? {
        let x = Int(u), y = Int(v)
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 3
        return SIMD3<Float>(Float(pixels[i]) / 255, Float(pixels[i + 1]) / 255, Float(pixels[i + 2]) / 255)
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
    var rgb: RGBImage?
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

    static func make(from frame: ARFrame, faceAnchor: ARFaceAnchor, wantsColor: Bool) -> DepthFrame? {
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

        let rgb = wantsColor ? makeRGB(from: frame) : nil

        return DepthFrame(width: width, height: height, depth: depth,
                          fx: fx, fy: fy, cx: cx, cy: cy,
                          cameraToFace: cameraToFace, rgb: rgb,
                          timestamp: frame.capturedDepthDataTimestamp,
                          faceYawDegrees: yaw, facePitchDegrees: pitch, faceDistance: distance)
    }

    /// Quarter-resolution YCbCr -> RGB conversion of the captured image.
    private static func makeRGB(from frame: ARFrame) -> RGBImage? {
        let buffer = frame.capturedImage
        guard CVPixelBufferGetPlaneCount(buffer) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let fullWidth = CVPixelBufferGetWidth(buffer)
        let fullHeight = CVPixelBufferGetHeight(buffer)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        let step = 4
        let width = fullWidth / step
        let height = fullHeight / step
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        pixels.withUnsafeMutableBufferPointer { dst in
            for j in 0..<height {
                let sy = j * step
                let cy = sy / 2
                for i in 0..<width {
                    let sx = i * step
                    let luma = Float(yPtr[sy * yStride + sx])
                    let cIndex = cy * cStride + (sx / 2) * 2
                    let cb = Float(cPtr[cIndex]) - 128
                    let cr = Float(cPtr[cIndex + 1]) - 128
                    let r = luma + 1.402 * cr
                    let g = luma - 0.344136 * cb - 0.714136 * cr
                    let b = luma + 1.772 * cb
                    let o = (j * width + i) * 3
                    dst[o]     = UInt8(max(0, min(255, r)))
                    dst[o + 1] = UInt8(max(0, min(255, g)))
                    dst[o + 2] = UInt8(max(0, min(255, b)))
                }
            }
        }

        let m = frame.camera.intrinsics
        let reference = frame.camera.imageResolution
        let sx = Float(width) / Float(reference.width)
        let sy = Float(height) / Float(reference.height)
        return RGBImage(width: width, height: height, pixels: pixels,
                        fx: m.columns.0.x * sx, fy: m.columns.1.y * sy,
                        cx: m.columns.2.x * sx, cy: m.columns.2.y * sy)
    }
}
