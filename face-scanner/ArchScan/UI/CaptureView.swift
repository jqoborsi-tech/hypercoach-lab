import SwiftUI
import ARKit
import SceneKit

/// Live camera preview. The controller owns the session; this view only renders it.
struct ARPreviewView: UIViewRepresentable {
    let controller: ScanController

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = controller.session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.scene = SCNScene()
        view.isUserInteractionEnabled = false
        controller.reassertDelegate()
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        controller.reassertDelegate()
    }
}

struct CaptureView: View {

    let patientCase: PatientCase
    @EnvironmentObject private var store: CaseStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var controller = ScanController()
    @State private var kind: CaptureKind = .rest
    @State private var voxelSize: Float = 1.2
    @State private var note = ""
    @State private var captureID = UUID()
    @State private var saveError: String?

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            switch controller.phase {
            case .idle:              setup
            case .scanning:          scanning
            case .reconstructing:    reconstructing
            case .finished:          result
            case .failed(let message): failure(message)
            }
        }
        .preferredColorScheme(.dark)
        .alert("Could not save", isPresented: Binding(get: { saveError != nil },
                                                      set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Setup

    private var setup: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack {
                    Text("New scan").font(.title2.bold())
                    Spacer()
                    Button("Close") { dismiss() }.foregroundStyle(Palette.muted)
                }
                .padding(.top, 8)

                Card(title: "Capture type") {
                    Picker("Capture", selection: $kind) {
                        ForEach(CaptureKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Palette.accent)
                    Text(kind.protocolNote)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }

                Card(title: "Resolution") {
                    Picker("Voxel size", selection: $voxelSize) {
                        Text("Fine — 1.0 mm").tag(Float(1.0))
                        Text("Standard — 1.2 mm").tag(Float(1.2))
                        Text("Fast — 1.6 mm").tag(Float(1.6))
                    }
                    .pickerStyle(.segmented)
                    Text(resolutionNote)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                }

                Card(title: "Operator protocol") {
                    ForEach(Array(protocolSteps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).").foregroundStyle(Palette.accent).monospacedDigit()
                            Text(step).foregroundStyle(Palette.ink)
                        }
                        .font(.footnote)
                    }
                }

                Card(title: "Note (optional)") {
                    TextField("e.g. wax rim in, VDO +2 mm", text: $note, axis: .vertical)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                }

                if !ScanController.isSupported {
                    Card {
                        Text("This device has no TrueDepth camera, so scanning is unavailable.")
                            .foregroundStyle(Palette.bad)
                            .font(.footnote)
                    }
                }

                Button("Start scan") {
                    captureID = UUID()
                    controller.start(voxelSizeMillimetres: voxelSize,
                                     keyframeDirectory: store.keyframeDirectory(caseID: patientCase.id,
                                                                               captureID: captureID))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!ScanController.isSupported)

                Text("Research and laboratory use. Not a medical device. Verify the scale against a physical reference before this scan drives anything irreversible.")
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private var resolutionNote: String {
        switch voxelSize {
        case 1.0: return "Highest detail and the largest files. Roughly 140 MB of working memory."
        case 1.6: return "Quickest to reconstruct. Good for a rest-position reference, light on detail."
        default:  return "The default. Resolves the incisal edges and the ala–tragus line without a long reconstruction."
        }
    }

    private var protocolSteps: [String] {
        [
            "Seat the patient upright, Frankfort horizontal roughly parallel to the floor, eyes on the lens.",
            "Even, diffuse light on both sides of the face. No hard shadow across the midline.",
            "Hold the phone 30–35 cm away, portrait, front camera toward the patient.",
            "Start front-on, then arc slowly to the patient's right ear, back through centre, and out to the left ear.",
            "Tilt up and down about 20° on the way through so the chin and the brow both get seen.",
            "The patient holds still and holds the expression. Swallowing or a blinked expression blurs the fusion."
        ]
    }

    // MARK: - Scanning

    private var scanning: some View {
        ZStack {
            ARPreviewView(controller: controller).ignoresSafeArea()

            VStack {
                VStack(spacing: 10) {
                    Text(controller.guidance)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())

                    HStack(spacing: 18) {
                        metric(String(format: "%.0f cm", controller.distanceCentimetres),
                               "distance",
                               tint: distanceTint)
                        metric("\(controller.integratedFrames)", "frames", tint: .white)
                        metric(String(format: "%.0f°", controller.pitchCoverageDegrees), "pitch", tint: .white)
                    }
                }
                .padding(.top, 12)

                Spacer()

                CoverageDial(yawBins: controller.yawBinsCovered,
                             pitchBins: controller.pitchBinsCovered,
                             currentYaw: controller.yawDegrees)
                    .padding(.bottom, 6)

                HStack(spacing: 12) {
                    Button("Cancel") { controller.cancel(); dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Build mesh") { controller.finishAndReconstruct() }
                        .buttonStyle(PrimaryButtonStyle(tint: controller.integratedFrames >= 25 ? Palette.accent : Palette.card2))
                        .disabled(controller.integratedFrames < 25)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private var distanceTint: Color {
        let d = controller.distanceCentimetres
        if d < 22 || d > 48 { return Palette.bad }
        if d < 26 || d > 42 { return Palette.warn }
        return Palette.good
    }

    private func metric(_ value: String, _ label: String, tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .frame(minWidth: 62)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Reconstructing

    private var reconstructing: some View {
        VStack(spacing: 18) {
            ProgressView(value: controller.reconstructionProgress)
                .tint(Palette.accent)
                .frame(maxWidth: 260)
            Text("Building the surface…").font(.headline).foregroundStyle(Palette.ink)
            Text("Extracting the iso-surface, smoothing, then baking the texture atlas.")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var result: some View {
        if let mesh = controller.resultMesh {
            VStack(spacing: 0) {
                MeshSceneView(mesh: mesh,
                              textureJPEG: controller.resultTexture,
                              landmarks: [],
                              activeLandmark: nil,
                              showTexture: true,
                              onPick: { _ in })
                    .frame(maxHeight: .infinity)

                ScrollView {
                    VStack(spacing: 12) {
                        Card(title: "Scan quality") {
                            HStack {
                                QualityBadge(quality: controller.resultQuality)
                                Spacer()
                                Text("\(controller.resultQuality.triangleCount) triangles")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                            StatRow(label: "Sweep coverage",
                                    value: String(format: "%.0f° yaw · %.0f° pitch",
                                                  controller.resultQuality.yawCoverageDegrees,
                                                  controller.resultQuality.pitchCoverageDegrees))
                            StatRow(label: "Frames fused", value: "\(controller.resultQuality.integratedFrames)")
                            StatRow(label: "Surface area",
                                    value: String(format: "%.0f cm²", controller.resultQuality.surfaceAreaSquareCentimetres))
                            StatRow(label: "Median pose correction",
                                    value: String(format: "%.2f mm", controller.resultQuality.medianPoseCorrectionMillimetres))
                        }
                        HStack(spacing: 12) {
                            Button("Rescan") { controller.cancel() }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("Save to case") { save(mesh: mesh) }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .padding(16)
                }
                .frame(maxHeight: 330)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Text("Scan failed").font(.title3.bold()).foregroundStyle(Palette.ink)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Try again") { controller.cancel() }.buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(24)
    }

    // MARK: - Saving

    private func save(mesh: ScanMesh) {
        var capture = ScanCapture()
        capture.id = captureID
        capture.kind = kind
        capture.note = note
        capture.quality = controller.resultQuality
        do {
            try store.addCapture(capture,
                                 mesh: mesh,
                                 textureJPEG: controller.resultTexture,
                                 to: patientCase.id)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
