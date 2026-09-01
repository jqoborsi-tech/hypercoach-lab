import SwiftUI
import UIKit
import simd

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ReviewView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore

    @State var capture: ScanCapture
    @State private var mesh: ScanMesh?
    @State private var texture: Data?
    @State private var activeLandmark: LandmarkID? = LandmarkID.pickingOrder.first
    @State private var showTexture = true
    @State private var panel: Panel = .landmarks
    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportSummary: String?
    @State private var errorMessage: String?
    @State private var calibrationText = ""
    @State private var options = ExportOptions()

    enum Panel: String, CaseIterable, Identifiable {
        case landmarks = "Landmarks"
        case measurements = "Measurements"
        case export = "Export"
        var id: String { rawValue }
    }

    private var analysis: ClinicalAnalysis { capture.analysis() }

    var body: some View {
        VStack(spacing: 0) {
            if let mesh {
                MeshSceneView(mesh: mesh,
                              textureJPEG: texture,
                              landmarks: capture.landmarks,
                              activeLandmark: activeLandmark,
                              showTexture: showTexture,
                              onPick: place)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            showTexture.toggle()
                        } label: {
                            Image(systemName: showTexture ? "photo.fill" : "circle.grid.cross")
                                .padding(9)
                                .background(.black.opacity(0.5), in: Circle())
                                .foregroundStyle(.white)
                        }
                        .padding(12)
                    }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }

            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView {
                switch panel {
                case .landmarks:    landmarkPanel
                case .measurements: measurementPanel
                case .export:       exportPanel
                }
            }
            .frame(height: 320)
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(capture.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { load() }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Landmarks

    private var landmarkPanel: some View {
        VStack(spacing: 12) {
            Card(title: "Place landmarks") {
                if let activeLandmark {
                    Text(activeLandmark.displayName).font(.headline).foregroundStyle(Palette.ink)
                    Text(activeLandmark.guidance).font(.footnote).foregroundStyle(Palette.muted)
                    HStack(spacing: 10) {
                        Text(capture.landmarkMap[activeLandmark] != nil ? "Tap the mesh to move it" : "Tap the mesh to place it")
                            .font(.caption)
                            .foregroundStyle(Palette.accent)
                        Spacer()
                        if capture.landmarkMap[activeLandmark] != nil {
                            Button("Clear") {
                                capture.removeLandmark(activeLandmark)
                                persist()
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Palette.bad)
                        }
                    }
                }
                Text("\(capture.placedCoreCount) of \(LandmarkID.coreSet.count) core landmarks placed")
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }

            Card(title: "Landmark set") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                    ForEach(LandmarkID.pickingOrder, id: \.self) { id in
                        let placed = capture.landmarkMap[id] != nil
                        Button {
                            activeLandmark = id
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: placed ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                                Text(id.displayName).font(.caption2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(activeLandmark == id ? Palette.accent.opacity(0.25) : Palette.card2,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .foregroundStyle(placed ? Palette.good : Palette.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Card(title: "Scale check") {
                Text("Place Calibration A and B on the ends of a reference of known length — a printed sticker on the forehead, a ruler, or a marked bite fork — then enter that length.")
                    .font(.footnote).foregroundStyle(Palette.muted)
                HStack {
                    TextField("True distance (mm)", text: $calibrationText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.ink)
                    Button("Set") {
                        capture.calibration.expectedMillimetres = Double(calibrationText) ?? 0
                        persist()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.accent)
                }
                Toggle("Apply the correction to exports", isOn: Binding(
                    get: { capture.calibration.applyScaleToExports },
                    set: { capture.calibration.applyScaleToExports = $0; persist() }))
                    .font(.footnote)
                    .tint(Palette.accent)
                if let measured = analysis.measurement("calibration_measured"),
                   let error = analysis.measurement("calibration_error_percent") {
                    StatRow(label: "Measured", value: String(format: "%.2f mm", measured.value))
                    StatRow(label: "Error", value: String(format: "%+.2f %%", error.value),
                            tint: abs(error.value) < 1 ? Palette.good : Palette.warn)
                }
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Measurements

    private var measurementPanel: some View {
        VStack(spacing: 12) {
            if analysis.measurements.isEmpty {
                Card {
                    Text("Place the pupils, tragi, orbitale points, alae, commissures, subnasale and gnathion to get the full measurement set.")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
            } else {
                Card(title: "Measurements") {
                    ForEach(analysis.measurements, id: \.key) { m in
                        StatRow(label: m.label,
                                value: m.unit.isEmpty ? String(format: "%.3f", m.value)
                                                      : String(format: "%.2f %@", m.value, m.unit))
                    }
                }
            }
            if !analysis.planes.isEmpty {
                Card(title: "Reference planes") {
                    ForEach(analysis.planes, id: \.key) { plane in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plane.label).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text(plane.note).font(.caption2).foregroundStyle(Palette.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !analysis.warnings.isEmpty {
                Card(title: "Warnings") {
                    ForEach(analysis.warnings, id: \.self) { warning in
                        Text("• \(warning)").font(.caption).foregroundStyle(Palette.warn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Export

    private var exportPanel: some View {
        VStack(spacing: 12) {
            Card(title: "Files to write") {
                Toggle("OBJ + MTL + texture (exocad)", isOn: $options.includeOBJ).tint(Palette.accent)
                Toggle("PLY with vertex colour (3Shape)", isOn: $options.includePLY).tint(Palette.accent)
                Toggle("STL (implant planning)", isOn: $options.includeSTL).tint(Palette.accent)
                Toggle("Reference planes STL", isOn: $options.includeReferencePlanes).tint(Palette.accent)
                Toggle("Reference photographs", isOn: $options.includeKeyframes).tint(Palette.accent)
            }
            Card(title: "Orientation") {
                Toggle("Align to the clinical reference frame", isOn: $options.alignToClinicalFrame)
                    .tint(Palette.accent)
                Text(options.alignToClinicalFrame
                     ? "The mesh is rotated so +X is the patient's left, +Y superior along the Frankfort normal, +Z anterior, with the origin on the facial midline between the pupils. Needs both pupils placed."
                     : "The mesh is exported in raw scanner coordinates, centred on the ARKit face anchor.")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            if let exportSummary {
                Card(title: "Last export") {
                    Text(exportSummary).font(.caption).foregroundStyle(Palette.muted)
                }
            }
            Button {
                runExport()
            } label: {
                if isExporting { ProgressView().tint(.black) } else { Text("Export scan") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isExporting || mesh == nil)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func load() {
        guard mesh == nil else { return }
        mesh = store.loadMesh(caseID: caseID, capture: capture)
        texture = store.loadTexture(caseID: caseID, capture: capture)
        if capture.calibration.expectedMillimetres > 0 {
            calibrationText = String(format: "%.2f", capture.calibration.expectedMillimetres)
        }
        options.alignToClinicalFrame = capture.alignToClinicalFrame
    }

    private func place(_ position: SIMD3<Float>) {
        guard let activeLandmark else { return }
        capture.setLandmark(activeLandmark, position: position)
        persist()
        // Step to the next unplaced landmark so the operator can work through the set.
        if let next = LandmarkID.pickingOrder.first(where: { capture.landmarkMap[$0] == nil }) {
            self.activeLandmark = next
        }
    }

    private func persist() {
        capture.alignToClinicalFrame = options.alignToClinicalFrame
        store.updateCapture(capture, in: caseID)
    }

    private func runExport() {
        guard let mesh, let patientCase = store.caseByID(caseID) else { return }
        isExporting = true
        persist()
        let capture = self.capture
        let texture = self.texture
        let keyframes = store.keyframeURLs(caseID: caseID, captureID: capture.id)
        var options = self.options
        options.alignToClinicalFrame = self.options.alignToClinicalFrame

        Task.detached(priority: .userInitiated) {
            do {
                let output = try CaseExporter.export(patientCase: patientCase,
                                                     capture: capture,
                                                     mesh: mesh,
                                                     textureJPEG: texture,
                                                     keyframes: keyframes,
                                                     options: options)
                await MainActor.run {
                    self.exportSummary = output.fileNames.joined(separator: "\n")
                    self.exportURL = output.zipURL
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isExporting = false
                }
            }
        }
    }
}
