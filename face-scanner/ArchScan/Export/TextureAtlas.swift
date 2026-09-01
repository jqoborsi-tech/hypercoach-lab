import Foundation
import UIKit
import simd

/// Bakes the per-vertex colour accumulated during fusion into a texture atlas laid
/// out with the mesh's cylindrical UVs, so the exported OBJ carries a real texture
/// map. Vertex colours alone are not portable — exocad and 3Shape both want an
/// OBJ + MTL + image triple, and shade matters for smile design.
enum TextureAtlas {

    struct Result {
        var jpeg: Data
        var size: Int
    }

    static func bake(_ mesh: ScanMesh, size: Int = 4096, quality: CGFloat = 0.95) -> Result? {
        guard !mesh.isEmpty, mesh.uvs.count == mesh.positions.count,
              mesh.colors.count == mesh.positions.count else { return nil }

        let width = size, height = size
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        var covered = [Bool](repeating: false, count: width * height)

        // Background: the mean skin colour of the scan, so any un-rasterised gap in
        // the atlas blends instead of showing up as a black patch in CAD.
        var mean = SIMD3<Float>.zero
        for c in mesh.colors { mean += c }
        mean /= Float(max(mesh.colors.count, 1))
        let background = SIMD3<UInt8>(UInt8(max(0, min(255, mean.x * 255))),
                                      UInt8(max(0, min(255, mean.y * 255))),
                                      UInt8(max(0, min(255, mean.z * 255))))
        for i in 0..<(width * height) {
            pixels[i * 3] = background.x
            pixels[i * 3 + 1] = background.y
            pixels[i * 3 + 2] = background.z
        }

        func pixelCoordinate(_ uv: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(uv.x * Float(width - 1), (1 - uv.y) * Float(height - 1))
        }

        var t = 0
        while t + 2 < mesh.indices.count {
            let ia = Int(mesh.indices[t]), ib = Int(mesh.indices[t + 1]), ic = Int(mesh.indices[t + 2])
            let a = pixelCoordinate(mesh.uvs[ia])
            let b = pixelCoordinate(mesh.uvs[ib])
            let c = pixelCoordinate(mesh.uvs[ic])
            t += 3

            // Triangles that straddle the seam wrap the whole way round; skip them.
            let span = max(max(abs(a.x - b.x), abs(b.x - c.x)), abs(a.x - c.x))
            if span > Float(width) * 0.5 { continue }

            let minX = max(0, Int(floor(min(a.x, min(b.x, c.x)))))
            let maxX = min(width - 1, Int(ceil(max(a.x, max(b.x, c.x)))))
            let minY = max(0, Int(floor(min(a.y, min(b.y, c.y)))))
            let maxY = min(height - 1, Int(ceil(max(a.y, max(b.y, c.y)))))
            guard minX <= maxX, minY <= maxY else { continue }

            let area = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
            if abs(area) < 1e-6 { continue }

            let ca = mesh.colors[ia], cb = mesh.colors[ib], cc = mesh.colors[ic]

            for y in minY...maxY {
                for x in minX...maxX {
                    let px = Float(x) + 0.5, py = Float(y) + 0.5
                    let w0 = ((b.x - a.x) * (py - a.y) - (px - a.x) * (b.y - a.y)) / area
                    let w1 = ((px - a.x) * (c.y - a.y) - (c.x - a.x) * (py - a.y)) / area
                    let w2 = 1 - w0 - w1
                    // w1 -> b, w0 -> c, w2 -> a (standard edge-function barycentrics)
                    guard w0 >= -0.0005, w1 >= -0.0005, w2 >= -0.0005 else { continue }
                    let colour = ca * w2 + cb * w1 + cc * w0
                    let o = (y * width + x) * 3
                    pixels[o]     = UInt8(max(0, min(255, colour.x * 255)))
                    pixels[o + 1] = UInt8(max(0, min(255, colour.y * 255)))
                    pixels[o + 2] = UInt8(max(0, min(255, colour.z * 255)))
                    covered[y * width + x] = true
                }
            }
        }

        bleed(&pixels, covered: &covered, width: width, height: height, passes: 6)

        guard let image = makeImage(pixels: pixels, width: width, height: height),
              let jpeg = image.jpegData(compressionQuality: quality) else { return nil }
        return Result(jpeg: jpeg, size: size)
    }

    /// Bleeds covered pixels outwards so bilinear filtering in the CAD viewer does not
    /// pull background colour across a triangle edge. Works on the coverage frontier
    /// rather than rescanning the whole atlas each pass, which matters at 4096².
    private static func bleed(_ pixels: inout [UInt8], covered: inout [Bool],
                              width: Int, height: Int, passes: Int) {
        var frontier: [Int] = []
        frontier.reserveCapacity(1 << 16)
        for y in 0..<height {
            for x in 0..<width where covered[y * width + x] {
                let index = y * width + x
                if x == 0 || y == 0 || x == width - 1 || y == height - 1
                    || !covered[index - 1] || !covered[index + 1]
                    || !covered[index - width] || !covered[index + width] {
                    frontier.append(index)
                }
            }
        }

        for _ in 0..<passes {
            var next: [Int] = []
            next.reserveCapacity(frontier.count)
            for index in frontier {
                let x = index % width, y = index / width
                let source = index * 3
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let neighbour = ny * width + nx
                        if covered[neighbour] { continue }
                        let destination = neighbour * 3
                        pixels[destination] = pixels[source]
                        pixels[destination + 1] = pixels[source + 1]
                        pixels[destination + 2] = pixels[source + 2]
                        covered[neighbour] = true
                        next.append(neighbour)
                    }
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
    }

    private static func makeImage(pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 24,
                                    bytesPerRow: width * 3,
                                    space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
