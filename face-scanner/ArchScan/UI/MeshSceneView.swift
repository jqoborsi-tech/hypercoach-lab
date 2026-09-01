import SwiftUI
import SceneKit
import UIKit
import simd

/// SceneKit preview of a reconstructed scan, with tap-to-place landmarks.
struct MeshSceneView: UIViewRepresentable {

    var mesh: ScanMesh
    var textureJPEG: Data?
    var landmarks: [Landmark]
    var registrationPoints: [RegistrationPoint] = []
    var activeLandmark: LandmarkID?
    var showTexture: Bool
    /// A second surface drawn over the first — used to show a CBCT surface sitting on
    /// the intraoral scan after registration.
    var overlayMesh: ScanMesh?
    var overlayTransform: simd_float4x4 = matrix_identity_float4x4
    var overlayOpacity: Double = 0.55
    var onPick: (SIMD3<Float>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(Palette.background)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.scene = SCNScene()
        view.pointOfView = context.coordinator.makeCamera(for: mesh)
        view.scene?.rootNode.addChildNode(view.pointOfView!)
        context.coordinator.addLighting(to: view.scene!)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.sceneView = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.updateMesh(mesh, textureJPEG: textureJPEG, showTexture: showTexture)
        context.coordinator.updateLandmarks(landmarks, registrationPoints: registrationPoints, active: activeLandmark)
        context.coordinator.updateOverlay(overlayMesh, transform: overlayTransform, opacity: overlayOpacity)
    }

    final class Coordinator: NSObject {
        var onPick: (SIMD3<Float>) -> Void
        weak var sceneView: SCNView?
        private var meshNode: SCNNode?
        private var landmarkRoot = SCNNode()
        private var overlayNode: SCNNode?
        private var lastOverlayCount = -1
        private var lastVertexCount = -1
        private var lastTextureCount = -1
        private var lastShowTexture: Bool?

        init(onPick: @escaping (SIMD3<Float>) -> Void) {
            self.onPick = onPick
        }

        func makeCamera(for mesh: ScanMesh) -> SCNNode {
            let camera = SCNCamera()
            camera.zNear = 0.01
            camera.zFar = 10
            camera.fieldOfView = 40
            let node = SCNNode()
            node.camera = camera
            node.position = SCNVector3(0, 0, 0.45)
            return node
        }

        func addLighting(to scene: SCNScene) {
            let key = SCNLight()
            key.type = .directional
            key.intensity = 700
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.eulerAngles = SCNVector3(-0.4, 0.5, 0)
            scene.rootNode.addChildNode(keyNode)

            let fill = SCNLight()
            fill.type = .ambient
            fill.intensity = 420
            let fillNode = SCNNode()
            fillNode.light = fill
            scene.rootNode.addChildNode(fillNode)

            scene.rootNode.addChildNode(landmarkRoot)
        }

        func updateMesh(_ mesh: ScanMesh, textureJPEG: Data?, showTexture: Bool) {
            guard let scene = sceneView?.scene, !mesh.isEmpty else { return }
            let textureCount = textureJPEG?.count ?? 0
            guard mesh.vertexCount != lastVertexCount
                    || textureCount != lastTextureCount
                    || showTexture != lastShowTexture else { return }
            lastVertexCount = mesh.vertexCount
            lastTextureCount = textureCount
            lastShowTexture = showTexture

            meshNode?.removeFromParentNode()
            let node = SCNNode(geometry: MeshSceneView.geometry(for: mesh,
                                                                textureJPEG: showTexture ? textureJPEG : nil))
            // Centre the scan in front of the camera without moving the data itself.
            let bounds = mesh.bounds
            let centre = (bounds.min + bounds.max) * 0.5
            node.pivot = SCNMatrix4MakeTranslation(centre.x, centre.y, centre.z)
            landmarkRoot.pivot = node.pivot
            meshNode = node
            scene.rootNode.addChildNode(node)
        }

        func updateLandmarks(_ landmarks: [Landmark],
                             registrationPoints: [RegistrationPoint],
                             active: LandmarkID?) {
            landmarkRoot.childNodes.forEach { $0.removeFromParentNode() }

            func marker(radius: CGFloat, color: UIColor, at position: SCNVector3) {
                let sphere = SCNSphere(radius: radius)
                sphere.segmentCount = 12
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = color
                sphere.materials = [material]
                let node = SCNNode(geometry: sphere)
                node.position = position
                landmarkRoot.addChildNode(node)
            }

            for landmark in landmarks {
                marker(radius: 0.0032,
                       color: landmark.id == active ? UIColor(Palette.accent) : UIColor(Palette.good),
                       at: SCNVector3(landmark.x, landmark.y, landmark.z))
            }
            // Registration markers are drawn larger and in a different colour, because
            // mistaking one for a landmark would send the lab's alignment off.
            for point in registrationPoints {
                marker(radius: 0.0042, color: UIColor(Palette.warn),
                       at: SCNVector3(point.x, point.y, point.z))
            }
        }

        func updateOverlay(_ mesh: ScanMesh?, transform: simd_float4x4, opacity: Double) {
            guard let scene = sceneView?.scene else { return }
            guard let mesh, !mesh.isEmpty else {
                overlayNode?.removeFromParentNode()
                overlayNode = nil
                lastOverlayCount = -1
                return
            }
            if mesh.vertexCount != lastOverlayCount {
                lastOverlayCount = mesh.vertexCount
                overlayNode?.removeFromParentNode()
                let geometry = MeshSceneView.geometry(for: mesh, textureJPEG: nil)
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                material.diffuse.contents = UIColor(Palette.accent)
                material.roughness.contents = 0.6
                material.isDoubleSided = true
                geometry.materials = [material]
                let node = SCNNode(geometry: geometry)
                overlayNode = node
                scene.rootNode.addChildNode(node)
            }
            overlayNode?.opacity = opacity
            overlayNode?.simdTransform = transform
            overlayNode?.pivot = meshNode?.pivot ?? SCNMatrix4Identity
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = sceneView, let meshNode else { return }
            let point = recognizer.location(in: view)
            let results = view.hitTest(point, options: [
                .rootNode: meshNode,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
                .ignoreHiddenNodes: true
            ])
            guard let hit = results.first else { return }
            let local = hit.localCoordinates
            onPick(SIMD3<Float>(Float(local.x), Float(local.y), Float(local.z)))
        }
    }

    // MARK: - Geometry

    static func geometry(for mesh: ScanMesh, textureJPEG: Data?) -> SCNGeometry {
        let vertices = mesh.positions.map { SCNVector3($0.x, $0.y, $0.z) }
        var sources: [SCNGeometrySource] = [SCNGeometrySource(vertices: vertices)]

        if mesh.normals.count == mesh.positions.count {
            sources.append(SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0.x, $0.y, $0.z) }))
        }
        if mesh.uvs.count == mesh.positions.count {
            sources.append(SCNGeometrySource(textureCoordinates: mesh.uvs.map { CGPoint(x: CGFloat($0.x), y: CGFloat(1 - $0.y)) }))
        }
        if mesh.colors.count == mesh.positions.count, textureJPEG == nil {
            var colorData = Data()
            colorData.reserveCapacity(mesh.colors.count * 12)
            for c in mesh.colors {
                for component in [c.x, c.y, c.z] {
                    var bits = component.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { colorData.append(contentsOf: $0) }
                }
            }
            sources.append(SCNGeometrySource(data: colorData,
                                             semantic: .color,
                                             vectorCount: mesh.colors.count,
                                             usesFloatComponents: true,
                                             componentsPerVector: 3,
                                             bytesPerComponent: MemoryLayout<Float>.size,
                                             dataOffset: 0,
                                             dataStride: MemoryLayout<Float>.size * 3))
        }

        let element = SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: sources, elements: [element])

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.85
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        if let textureJPEG, let image = UIImage(data: textureJPEG) {
            material.diffuse.contents = image
        } else {
            material.diffuse.contents = UIColor.white
        }
        geometry.materials = [material]
        return geometry
    }
}
