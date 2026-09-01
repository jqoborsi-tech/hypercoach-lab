import SwiftUI
import simd

/// Registers the CBCT to the intraoral scan.
///
/// The intraoral scan is the master — it is the most accurate object in the case — so
/// the CBCT surface is what moves. Registration is three picked point pairs followed by
/// ICP refinement, and the result is only offered as usable when it fits closely, sees
/// enough of the surface, and stayed near where it was put. Fully automatic
/// registration is not attempted: on a CBCT with restorations, scatter makes it fail
/// quietly, and a quietly wrong merge is the worst thing this app could produce.
struct CBCTAlignView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore
    @Environment(\.dismiss) private var dismiss

    @State private var stage: Stage = .load
    @State private var preset: CBCTVolume.Preset = .enamel
    @State private var threshold: Double = 1800
    @State private var cbctSurface: ScanMesh?
    @State private var scanMesh: ScanMesh?
    @State private var scanKind: RecordKind = .intraoralScanUpper
    @State private var cbctPoints: [SIMD3<Float>] = []
    @State private var scanPoints: [SIMD3<Float>] = []
    @State private var result: ICPRegistration.Result?
    @State private var busy: String?
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var volumeSummary: [String] = []

    enum Stage: String, CaseIterable, Identifiable {
        case load = "Load"
        case pickCBCT = "CBCT points"
        case pickScan = "Scan points"
        case result = "Result"
        var id: String { rawValue }
    }

    private var patientCase: PatientCase? { store.caseByID(caseID) }

    var body: some View {
        VStack(spacing: 0) {
            viewport
            Picker("Stage", selection: $stage) {
                ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                switch stage {
                case .load:     loadPanel
                case .pickCBCT: pickPanel(isCBCT: true)
                case .pickScan: pickPanel(isCBCT: false)
                case .result:   resultPanel
                }
            }
            .frame(height: 268)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("CBCT alignment")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .overlay { if let busy { busyOverlay(busy) } }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Viewport

    @ViewBuilder
    private var viewport: some View {
        let showCBCT = stage == .pickCBCT || stage == .load
        let primary = showCBCT ? cbctSurface : scanMesh
        if let primary {
            MeshSceneView(mesh: primary,
                          textureJPEG: nil,
                          landmarks: [],
                          registrationPoints: markers(showCBCT ? cbctPoints : scanPoints),
                          activeLandmark: nil,
                          showTexture: false,
                          overlayMesh: stage == .result ? cbctSurface : nil,
                          overlayTransform: result?.transform ?? matrix_identity_float4x4,
                          onPick: { point in
                              if stage == .pickCBCT { cbctPoints.append(point) }
                              if stage == .pickScan { scanPoints.append(point) }
                          })
                .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cube.transparent").font(.system(size: 38)).foregroundStyle(Palette.muted)
                Text(showCBCT ? "Extract a surface from the CBCT to begin."
                              : "Import an intraoral scan for this case.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func markers(_ points: [SIMD3<Float>]) -> [RegistrationPoint] {
        points.enumerated().map { RegistrationPoint(index: $0.offset + 1, label: "P\($0.offset + 1)", position: $0.element) }
    }

    private func busyOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView(value: progress).tint(Palette.accent).frame(width: 180)
                Text(message).font(.footnote).foregroundStyle(Palette.ink)
            }
            .padding(24)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Panels

    private var loadPanel: some View {
        VStack(spacing: 10) {
            Card(title: "Surface to extract") {
                Picker("Preset", selection: $preset) {
                    ForEach(CBCTVolume.Preset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: preset) { _, new in threshold = Double(new.value) }
                Text(preset.note).font(.caption2).foregroundStyle(Palette.muted)
                HStack {
                    Text("Threshold").font(.caption).foregroundStyle(Palette.muted)
                    Spacer()
                    Text("\(Int(threshold))").font(.caption.monospacedDigit()).foregroundStyle(Palette.ink)
                }
                Slider(value: $threshold, in: -900...3000).tint(Palette.accent)
                Text("CBCT grey values are not true Hounsfield units — they shift with field of view and exposure — so treat the preset as a starting point and judge the surface, not the number.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            if !volumeSummary.isEmpty {
                Card(title: "Volume") {
                    ForEach(volumeSummary, id: \.self) { line in
                        Text(line).font(.caption2).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Card(title: "Intraoral scan") {
                Picker("Arch", selection: $scanKind) {
                    Text("Upper").tag(RecordKind.intraoralScanUpper)
                    Text("Lower").tag(RecordKind.intraoralScanLower)
                }
                .pickerStyle(.segmented)
                .onChange(of: scanKind) { _, _ in loadScan() }
                Text(scanMesh == nil ? "Not imported yet." :
                        "\(scanMesh?.triangleCount ?? 0) triangles loaded.")
                    .font(.caption2)
                    .foregroundStyle(scanMesh == nil ? Palette.warn : Palette.good)
            }
            Button("Extract CBCT surface") { extractSurface() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func pickPanel(isCBCT: Bool) -> some View {
        let points = isCBCT ? cbctPoints : scanPoints
        return VStack(spacing: 10) {
            Card(title: isCBCT ? "Points on the CBCT surface" : "The same points on the scan") {
                Text(isCBCT
                     ? "Tap three or more features you can also find on the intraoral scan — cusp tips and incisal edges are the usual choices. Spread them out; three points in a line cannot define a rotation."
                     : "Tap the same features, in the same order. Order matters: P1 on the CBCT pairs with P1 here.")
                    .font(.caption).foregroundStyle(Palette.muted)
                HStack {
                    Text("\(points.count) placed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(points.count >= 3 ? Palette.good : Palette.warn)
                    Spacer()
                    Button("Undo last") {
                        if isCBCT { if !cbctPoints.isEmpty { cbctPoints.removeLast() } }
                        else { if !scanPoints.isEmpty { scanPoints.removeLast() } }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.accent)
                    .disabled(points.isEmpty)
                    Button("Clear") {
                        if isCBCT { cbctPoints.removeAll() } else { scanPoints.removeAll() }
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.bad)
                    .disabled(points.isEmpty)
                }
            }
            if !isCBCT {
                Button("Align") { runAlignment() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(cbctPoints.count < 3 || scanPoints.count != cbctPoints.count)
                if cbctPoints.count != scanPoints.count {
                    Text("Place the same number of points on both — \(cbctPoints.count) on the CBCT, \(scanPoints.count) here.")
                        .font(.caption2).foregroundStyle(Palette.warn)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var resultPanel: some View {
        if let result {
            VStack(spacing: 10) {
                Card(title: "Registration") {
                    HStack {
                        Text(result.quality)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(result.isTrustworthy ? Palette.good : Palette.bad)
                        Spacer()
                    }
                    StatRow(label: "Point-to-plane RMS", value: String(format: "%.3f mm", result.rmsMillimetres),
                            tint: result.rmsMillimetres < 0.3 ? Palette.good : Palette.warn)
                    StatRow(label: "Median deviation", value: String(format: "%.3f mm", result.medianMillimetres))
                    StatRow(label: "Surface matched", value: String(format: "%.0f %%", result.inlierFraction * 100),
                            tint: result.inlierFraction >= 0.4 ? Palette.good : Palette.bad)
                    StatRow(label: "Moved from your picks",
                            value: String(format: "%.2f mm · %.2f°", result.driftMillimetres, result.driftDegrees),
                            tint: result.driftMillimetres < 4 ? Palette.good : Palette.bad)
                    StatRow(label: "Iterations", value: "\(result.iterations)\(result.converged ? " (converged)" : "")")
                }
                Card(title: "What these numbers mean") {
                    Text("A low RMS on its own proves nothing: a small patch of surface can always find somewhere comfortable to sit. It is trustworthy only when the fit is close, most of the surface found a match, and refinement stayed near the points you picked. All three have to hold.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                }
                Button(result.isTrustworthy ? "Save this alignment" : "Save anyway") {
                    saveTransform(result)
                }
                .buttonStyle(result.isTrustworthy ? PrimaryButtonStyle() : PrimaryButtonStyle(tint: Palette.warn))
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        } else {
            Card {
                Text("Run the alignment once both point sets are placed.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            .padding(12)
        }
    }

    // MARK: - Work

    private func loadScan() {
        guard let patientCase,
              let entry = patientCase.records(of: scanKind).first,
              let url = store.url(for: entry, caseID: caseID) else {
            scanMesh = nil
            return
        }
        busy = "Reading the intraoral scan…"
        progress = 0.3
        Task.detached(priority: .userInitiated) {
            do {
                let imported = try MeshImporter.load(from: url)
                await MainActor.run {
                    scanMesh = imported.mesh
                    busy = nil
                }
            } catch {
                await MainActor.run {
                    busy = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func extractSurface() {
        guard let patientCase,
              let entry = patientCase.records(of: .cbct).first,
              let folder = store.url(for: entry, caseID: caseID) else {
            errorMessage = "Import a CBCT for this case first."
            return
        }
        busy = "Reading the DICOM series…"
        progress = 0
        let level = Float(threshold)

        Task.detached(priority: .userInitiated) {
            do {
                let series = try DICOMReader.readSeries(in: folder) { value in
                    Task { @MainActor in progress = value * 0.3 }
                }
                await MainActor.run { busy = "Building the volume…" }
                let volume = try CBCTVolume.load(slices: series.slices, info: series.info) { value in
                    Task { @MainActor in progress = 0.3 + value * 0.3 }
                }
                volume.threshold = level
                let fieldOfView = volume.fieldOfViewMillimetres
                let summary = [
                    "\(series.slices.count) slices, \(volume.nx)×\(volume.ny)×\(volume.nz) working grid",
                    String(format: "Voxel %.2f × %.2f × %.2f mm%@",
                           volume.voxelSizeMillimetres.x, volume.voxelSizeMillimetres.y, volume.voxelSizeMillimetres.z,
                           volume.downsampleFactor > 1 ? " (subsampled \(volume.downsampleFactor)×)" : ""),
                    String(format: "Field of view %.0f × %.0f × %.0f mm", fieldOfView.x, fieldOfView.y, fieldOfView.z),
                    volume.info.manufacturer.isEmpty ? "" : "Scanner: \(volume.info.manufacturer)"
                ].filter { !$0.isEmpty }

                await MainActor.run { busy = "Extracting the surface…" }
                let raw = SurfaceExtractor.extract(from: volume) { value in
                    Task { @MainActor in progress = 0.6 + value * 0.35 }
                }
                guard !raw.isEmpty else {
                    await MainActor.run {
                        busy = nil
                        errorMessage = "Nothing crossed that threshold. Lower it for bone, raise it for enamel only."
                    }
                    return
                }
                var mesh = MeshPostProcess.keepLargestComponent(raw)
                MeshPostProcess.recomputeNormals(&mesh)

                await MainActor.run {
                    cbctSurface = mesh
                    volumeSummary = summary + ["\(mesh.triangleCount) triangles at threshold \(Int(level))"]
                    busy = nil
                    stage = .pickCBCT
                }
            } catch {
                await MainActor.run {
                    busy = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runAlignment() {
        guard let cbctSurface, let scanMesh else { return }
        busy = "Registering…"
        progress = 0
        let sourcePoints = cbctPoints
        let targetPoints = scanPoints

        Task.detached(priority: .userInitiated) {
            let outcome = ICPRegistration.alignWithCorrespondences(
                source: cbctSurface,
                sourcePoints: sourcePoints,
                target: scanMesh,
                targetPoints: targetPoints) { value in
                    Task { @MainActor in progress = value }
                }
            await MainActor.run {
                busy = nil
                if let outcome {
                    result = outcome
                    stage = .result
                } else {
                    errorMessage = "The surfaces did not overlap enough to register. Check that the points are on the same features and that the CBCT surface actually shows the teeth."
                }
            }
        }
    }

    private func saveTransform(_ result: ICPRegistration.Result) {
        guard let patientCase, var entry = patientCase.records(of: .cbct).first else { return }
        let t = result.transform
        let values = (0..<4).flatMap { column -> [Float] in
            let c = t[column]
            return [c.x, c.y, c.z, c.w]
        }
        entry.metadata["registration_target"] = scanKind.rawValue
        entry.metadata["registration_rms_mm"] = String(format: "%.3f", result.rmsMillimetres)
        entry.metadata["registration_inliers"] = String(format: "%.0f%%", result.inlierFraction * 100)
        entry.metadata["registration_trustworthy"] = result.isTrustworthy ? "yes" : "no"
        entry.metadata["registration_matrix_column_major"] =
            values.map { String(format: "%.6f", $0) }.joined(separator: " ")
        store.updateRecord(entry, in: caseID)
        dismiss()
    }
}
