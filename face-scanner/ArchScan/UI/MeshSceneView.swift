import SwiftUI
import SceneKit
import UIKit
import simd

/// SceneKit preview of a reconstructed scan, with tap-to-place landmarks.
struct MeshSceneView: UIViewRepresentable {

    var mesh: ScanMesh
    var textureJPEG: Data?
    var landmarks: [Landmark]
    var activeLandmark: LandmarkID?
    var showTexture: Bool
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
        context.coordinator.updateLandmarks(landmarks, active: activeLandmark)
    }

    final class Coordinator: NSObject {
        var onPick: (SIMD3<Float>) -> Void
        weak var sceneView: SCNView?
        private var meshNode: SCNNode?
        private var landmarkRoot = SCNNode()
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

        func updateLandmarks(_ landmarks: [Landmark], active: LandmarkID?) {
            landmarkRoot.childNodes.forEach { $0.removeFromParentNode() }
            for landmark in landmarks {
                let sphere = SCNSphere(radius: 0.0035)
                sphere.segmentCount = 12
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = landmark.id == active
                    ? UIColor(Palette.accent) : UIColor(Palette.good)
                sphere.materials = [material]
                let node = SCNNode(geometry: sphere)
                node.position = SCNVector3(landmark.x, landmark.y, landmark.z)
                landmarkRoot.addChildNode(node)
            }
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
