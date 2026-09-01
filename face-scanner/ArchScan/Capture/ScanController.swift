import Foundation
import ARKit
import CoreImage
import SwiftUI
import UIKit
import simd

/// Sweep coverage is bucketed into 10-degree bins: yaw -70...+70, pitch -30...+30.
enum CoverageBins {
    static let yawCount = 14
    static let pitchCount = 6
    static let binSize: Float = 10
}

/// Everything that touches the TSDF lives here, and every method runs on the
/// session's delegate queue (a single serial queue), so the mutable state needs no
/// further locking. The controller above it owns the published, main-actor copy.
final class FusionEngine: @unchecked Sendable {

    struct Snapshot {
        var trackingFace = false
        var guidance = ""
        var distanceCentimetres: Float = 0
        var yawDegrees: Float = 0
        var pitchDegrees: Float = 0
        var lightIsLow = false
        var integratedFrames = 0
        var rejectedFrames = 0
        var yawBins: Set<Int> = []
        var pitchBins: Set<Int> = []
        var keyframeURLs: [URL] = []
    }

    private(set) var volume: TSDFVolume?
    private(set) var isRunning = false
    private(set) var poseCorrections: [Float] = []
    private(set) var distanceSamples: [Float] = []

    private var lastDepthTimestamp: TimeInterval = -1
    private var keyframeDirectory: URL?
    private var capturedKeyframeBins: Set<Int> = []
    private var state = Snapshot()

    /// Called on the delegate queue after every processed frame.
    var onUpdate: ((Snapshot) -> Void)?

    private let minimumWorkingDistance: Float = 0.22
    private let maximumWorkingDistance: Float = 0.48

    func begin(voxelSizeMillimetres: Float, keyframeDirectory: URL?) {
        volume = TSDFVolume(voxelSize: voxelSizeMillimetres / 1000)
        self.keyframeDirectory = keyframeDirectory
        lastDepthTimestamp = -1
        capturedKeyframeBins.removeAll()
        poseCorrections.removeAll()
        distanceSamples.removeAll()
        state = Snapshot()
        isRunning = true
    }

    func stop() { isRunning = false }

    func takeVolume() -> TSDFVolume? {
        isRunning = false
        let value = volume
        volume = nil
        return value
    }

    var snapshot: Snapshot { state }

    // MARK: - Per-frame work

    func process(frame: ARFrame) {
        guard isRunning, let volume else { return }
        guard frame.capturedDepthData != nil else { return }
        let timestamp = frame.capturedDepthDataTimestamp
        guard timestamp != lastDepthTimestamp else { return }
        lastDepthTimestamp = timestamp

        guard let anchor = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, anchor.isTracked else {
            state.trackingFace = false
            state.guidance = "Bring the patient's face into view and keep the whole face in frame."
            onUpdate?(state)
            return
        }
        guard let depthFrame = DepthFrame.make(from: frame, faceAnchor: anchor, wantsColor: true) else { return }

        let ambient = frame.lightEstimate?.ambientIntensity ?? 1000
        let distance = depthFrame.faceDistance
        let yaw = depthFrame.faceYawDegrees
        let pitch = depthFrame.facePitchDegrees

        state.trackingFace = true
        state.distanceCentimetres = distance * 100
        state.yawDegrees = yaw
        state.pitchDegrees = pitch
        state.lightIsLow = ambient < 300

        var accept = true
        if distance < minimumWorkingDistance {
            state.guidance = "Too close — back off to about 30 cm."
            accept = false
        } else if distance > maximumWorkingDistance {
            state.guidance = "Too far — move in to about 30 cm."
            accept = false
        } else if abs(yaw) > 75 {
            state.guidance = "Come back toward the front of the face."
            accept = false
        } else if state.lightIsLow {
            state.guidance = "Add light — the texture will be muddy at this level."
        } else {
            state.guidance = "Arc slowly around the face, keeping the eyes in frame."
        }

        guard accept else {
            state.rejectedFrames += 1
            onUpdate?(state)
            return
        }

        let result = volume.integrate(depthFrame, refinePose: true, hasData: state.integratedFrames > 4)
        if result.accepted {
            state.integratedFrames += 1
            distanceSamples.append(distance)
            if result.poseCorrectionMillimetres > 0 { poseCorrections.append(result.poseCorrectionMillimetres) }
            let yawBin = Int(((yaw + 70) / 10).rounded(.down))
            if yawBin >= 0, yawBin < CoverageBins.yawCount { state.yawBins.insert(yawBin) }
            let pitchBin = Int(((pitch + 30) / 10).rounded(.down))
            if pitchBin >= 0, pitchBin < CoverageBins.pitchCount { state.pitchBins.insert(pitchBin) }
            writeKeyframeIfNeeded(frame: frame, yaw: yaw)
        } else {
            state.rejectedFrames += 1
        }
        onUpdate?(state)
    }

    /// Saves an upright reference photograph the first time each 30° yaw milestone is hit.
    /// Clinicians want the frontal, three-quarter and profile views alongside the mesh.
    private func writeKeyframeIfNeeded(frame: ARFrame, yaw: Float) {
        let milestones: [Int] = [-60, -30, 0, 30, 60]
        guard let bin = milestones.first(where: { abs(yaw - Float($0)) < 5 }),
              !capturedKeyframeBins.contains(bin),
              let directory = keyframeDirectory else { return }

        let image = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else { return }
        let url = directory.appendingPathComponent(String(format: "yaw%+04d.jpg", bin))
        try? jpeg.write(to: url, options: [.atomic, .completeFileProtection])

        capturedKeyframeBins.insert(bin)
        if !state.keyframeURLs.contains(url) { state.keyframeURLs.append(url) }
    }
}

/// Owns the ARKit session and the published state the capture screen renders.
@MainActor
final class ScanController: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case scanning
        case reconstructing
        case finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var guidance = "Hold the phone 30–35 cm from the face."
    @Published private(set) var trackingFace = false
    @Published private(set) var distanceCentimetres: Float = 0
    @Published private(set) var yawDegrees: Float = 0
    @Published private(set) var pitchDegrees: Float = 0
    @Published private(set) var integratedFrames = 0
    @Published private(set) var rejectedFrames = 0
    @Published private(set) var yawBinsCovered: Set<Int> = []
    @Published private(set) var pitchBinsCovered: Set<Int> = []
    @Published private(set) var lightIsLow = false
    @Published private(set) var reconstructionProgress: Double = 0

    @Published var resultMesh: ScanMesh?
    @Published var resultTexture: Data?
    @Published var resultQuality = CaptureQuality()
    @Published var keyframeURLs: [URL] = []

    let session = ARSession()

    var yawCoverageDegrees: Float { Float(yawBinsCovered.count) * 10 }
    var pitchCoverageDegrees: Float { Float(pitchBinsCovered.count) * 10 }

    /// 110° of yaw and 40° of pitch is a complete sweep for prosthetic work.
    var coverageFraction: Double {
        let yaw = min(Double(yawBinsCovered.count) / 11.0, 1)
        let pitch = min(Double(pitchBinsCovered.count) / 4.0, 1)
        return yaw * 0.65 + pitch * 0.35
    }

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    private let engine = FusionEngine()
    private let workQueue = DispatchQueue(label: "com.hypercoachlab.archscan.fusion", qos: .userInitiated)
    private var voxelSizeMillimetres: Float = 1.2

    override init() {
        super.init()
        engine.onUpdate = { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: FusionEngine.Snapshot) {
        trackingFace = snapshot.trackingFace
        guidance = snapshot.guidance
        distanceCentimetres = snapshot.distanceCentimetres
        yawDegrees = snapshot.yawDegrees
        pitchDegrees = snapshot.pitchDegrees
        lightIsLow = snapshot.lightIsLow
        integratedFrames = snapshot.integratedFrames
        rejectedFrames = snapshot.rejectedFrames
        yawBinsCovered = snapshot.yawBins
        pitchBinsCovered = snapshot.pitchBins
        keyframeURLs = snapshot.keyframeURLs
    }

    // MARK: - Lifecycle

    func start(voxelSizeMillimetres: Float, keyframeDirectory: URL?) {
        guard ScanController.isSupported else {
            phase = .failed("This device has no TrueDepth camera. ArchScan needs Face ID hardware; the iPhone 15 Pro Max is the reference device.")
            return
        }
        resetState()
        self.voxelSizeMillimetres = voxelSizeMillimetres
        if let keyframeDirectory {
            try? FileManager.default.createDirectory(at: keyframeDirectory, withIntermediateDirectories: true)
        }

        let engine = self.engine
        let voxel = voxelSizeMillimetres
        workQueue.async { engine.begin(voxelSizeMillimetres: voxel, keyframeDirectory: keyframeDirectory) }

        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = true
        if ARFaceTrackingConfiguration.supportsWorldTracking {
            configuration.isWorldTrackingEnabled = false
        }
        session.delegate = self
        session.delegateQueue = workQueue
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        phase = .scanning
    }

    /// `ARSCNView` takes ownership of whatever session it is handed; re-asserting the
    /// delegate after the preview attaches keeps depth frames coming to the engine.
    func reassertDelegate() {
        if session.delegate !== self {
            session.delegate = self
            session.delegateQueue = workQueue
        }
    }

    func cancel() {
        session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        let engine = self.engine
        workQueue.async { _ = engine.takeVolume() }
        resetState()
    }

    private func resetState() {
        integratedFrames = 0
        rejectedFrames = 0
        yawBinsCovered = []
        pitchBinsCovered = []
        reconstructionProgress = 0
        resultMesh = nil
        resultTexture = nil
        resultQuality = CaptureQuality()
        keyframeURLs = []
        phase = .idle
    }

    // MARK: - Reconstruction

    func finishAndReconstruct() {
        guard phase == .scanning else { return }
        session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .reconstructing

        let engine = self.engine
        let voxel = voxelSizeMillimetres
        let yawCoverage = yawCoverageDegrees
        let pitchCoverage = pitchCoverageDegrees

        workQueue.async { [weak self] in
            let snapshot = engine.snapshot
            let corrections = engine.poseCorrections
            let distances = engine.distanceSamples
            guard let volume = engine.takeVolume() else {
                Task { @MainActor in self?.phase = .failed("The scan was not running.") }
                return
            }

            let raw = SurfaceExtractor.extract(from: volume) { value in
                Task { @MainActor in self?.reconstructionProgress = value * 0.7 }
            }
            guard !raw.isEmpty else {
                Task { @MainActor in
                    self?.phase = .failed("Nothing was reconstructed. Move in closer, keep the face in frame, and sweep more slowly.")
                }
                return
            }
            let mesh = MeshPostProcess.finish(raw)
            Task { @MainActor in self?.reconstructionProgress = 0.85 }
            let texture = TextureAtlas.bake(mesh)

            var quality = CaptureQuality()
            quality.integratedFrames = snapshot.integratedFrames
            quality.rejectedFrames = snapshot.rejectedFrames
            quality.voxelSizeMillimetres = voxel
            quality.yawCoverageDegrees = yawCoverage
            quality.pitchCoverageDegrees = pitchCoverage
            quality.vertexCount = mesh.vertexCount
            quality.triangleCount = mesh.triangleCount
            quality.surfaceAreaSquareCentimetres = mesh.surfaceArea * 10000
            quality.medianPoseCorrectionMillimetres = medianValue(corrections)
            quality.meanDistanceCentimetres = distances.isEmpty
                ? 0 : distances.reduce(0, +) / Float(distances.count) * 100

            Task { @MainActor in
                guard let self else { return }
                self.resultMesh = mesh
                self.resultTexture = texture?.jpeg
                self.resultQuality = quality
                self.keyframeURLs = snapshot.keyframeURLs
                self.reconstructionProgress = 1
                self.phase = .finished
            }
        }
    }
}

// MARK: - ARSessionDelegate

extension ScanController: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        engine.process(frame: frame)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.phase = .failed(error.localizedDescription)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.guidance = "Session interrupted — it will resume when the app comes back."
        }
    }
}

private func medianValue(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}
