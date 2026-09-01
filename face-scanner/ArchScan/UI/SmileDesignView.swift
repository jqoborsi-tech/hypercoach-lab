import SwiftUI
import PhotosUI
import simd

/// Builds a smile design over a photograph.
///
/// The flow is deliberately in three stages — mark the face, trace the lip opening,
/// then adjust the design — because each stage constrains the next. Nothing is
/// invented: the tooth positions come from the marks and the numbers, so a change to
/// the design is a change to something the lab can build.
struct SmileDesignView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore
    @Environment(\.dismiss) private var dismiss

    @State var design: SmileDesignRecord
    @State private var sourceImage: UIImage?
    @State private var preview: UIImage?
    @State private var stage: Stage = .marks
    @State private var showingBefore = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var isRendering = false
    @State private var renderTask: Task<Void, Never>?
    @State private var exportURL: URL?
    @State private var errorMessage: String?

    enum Stage: String, CaseIterable, Identifiable {
        case marks = "Marks"
        case lips = "Lip line"
        case design = "Design"
        var id: String { rawValue }
    }

    /// The draggable marks, in the order the clinician places them.
    private enum Handle: String, CaseIterable, Identifiable {
        case pupilRight, pupilLeft, midline, incisalEdge, commissureRight, commissureLeft
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pupilRight:      return "Right pupil"
            case .pupilLeft:       return "Left pupil"
            case .midline:         return "Facial midline"
            case .incisalEdge:     return "Incisal edge level"
            case .commissureRight: return "Right commissure"
            case .commissureLeft:  return "Left commissure"
            }
        }
        var hint: String {
            switch self {
            case .pupilRight, .pupilLeft:
                return "Centre of each pupil. Sets the horizontal the smile is levelled to, and the scale."
            case .midline:
                return "A point on the facial midline — the philtrum is the usual one."
            case .incisalEdge:
                return "Where the incisal edges of the centrals should sit. The single most consequential decision here."
            case .commissureRight, .commissureLeft:
                return "The corners of the mouth. Sets the smile width the tooth series is fitted into."
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            controls
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle(design.title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("Choose photograph", systemImage: "photo")
                    }
                    Button { save(share: true) } label: { Label("Save and share", systemImage: "square.and.arrow.up") }
                    Button { save(share: false) } label: { Label("Save to case", systemImage: "tray.and.arrow.down") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { load() }
        .onChange(of: photoSelection) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let displayed = showingBefore ? sourceImage : (preview ?? sourceImage) {
                    let rect = SmileDesignView.fittedRect(image: displayed.size, in: proxy.size)
                    Image(uiImage: displayed)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)

                    if !showingBefore {
                        switch stage {
                        case .marks:  markHandles(in: rect)
                        case .lips:   lipHandles(in: rect)
                        case .design: EmptyView()
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40)).foregroundStyle(Palette.muted)
                        Text("Choose a full-smile photograph to design over.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                        PhotosPicker(selection: $photoSelection, matching: .images) {
                            Text("Choose photograph").font(.subheadline.weight(.semibold))
                        }
                    }
                }
                if isRendering {
                    ProgressView().tint(Palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                }
            }
            .overlay(alignment: .topLeading) {
                if sourceImage != nil {
                    Button {
                        showingBefore.toggle()
                    } label: {
                        Text(showingBefore ? "Before" : "After")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func markHandles(in rect: CGRect) -> some View {
        ForEach(Handle.allCases) { handle in
            let point = position(of: handle)
            Circle()
                .strokeBorder(Palette.accent, lineWidth: 2)
                .background(Circle().fill(Palette.accent.opacity(0.25)))
                .frame(width: 26, height: 26)
                .position(x: rect.minX + point.x * rect.width,
                          y: rect.minY + point.y * rect.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let normalised = CGPoint(
                                x: min(max((value.location.x - rect.minX) / rect.width, 0), 1),
                                y: min(max((value.location.y - rect.minY) / rect.height, 0), 1))
                            setPosition(normalised, for: handle)
                            scheduleRender()
                        })
        }
    }

    private func lipHandles(in rect: CGRect) -> some View {
        ForEach(Array(design.parameters.lipContour.enumerated()), id: \.offset) { index, point in
            Circle()
                .strokeBorder(Palette.warn, lineWidth: 2)
                .background(Circle().fill(Palette.warn.opacity(0.25)))
                .frame(width: 22, height: 22)
                .position(x: rect.minX + point.x * rect.width,
                          y: rect.minY + point.y * rect.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let normalised = CGPoint(
                                x: min(max((value.location.x - rect.minX) / rect.width, 0), 1),
                                y: min(max((value.location.y - rect.minY) / rect.height, 0), 1))
                            design.parameters.lipContour[index] = normalised
                            scheduleRender()
                        })
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("Stage", selection: $stage) {
                ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)

            ScrollView {
                switch stage {
                case .marks:  markControls
                case .lips:   lipControls
                case .design: designControls
                }
            }
            .frame(height: 216)
        }
        .padding(.vertical, 8)
    }

    private var markControls: some View {
        VStack(spacing: 10) {
            Card(title: "Place the six marks") {
                ForEach(Handle.allCases) { handle in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(handle.title).font(.caption.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(handle.hint).font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            Card(title: "Scale") {
                Text(design.parameters.interpupillaryIsMeasured
                     ? String(format: "Using %.1f mm interpupillary distance measured from this case's facial scan, so every millimetre in the design is real.", design.parameters.interpupillaryMillimetres)
                     : "No facial scan in this case, so the design assumes a 63 mm interpupillary distance — the population average. Capture a facial scan and the millimetres become measured rather than assumed.")
                    .font(.caption)
                    .foregroundStyle(design.parameters.interpupillaryIsMeasured ? Palette.good : Palette.warn)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private var lipControls: some View {
        Card(title: "Trace the lip opening") {
            Text("Drag the amber points onto the inner border of the lips. The design is clipped to this outline, which is what keeps the teeth inside the mouth instead of painted over the lips.")
                .font(.caption).foregroundStyle(Palette.muted)
            Button("Reset to the default outline") {
                design.parameters.lipContour = SmileRenderer.defaultLipContour(parameters: design.parameters)
                scheduleRender()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.accent)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
    }

    private var designControls: some View {
        VStack(spacing: 10) {
            Card(title: "Proportions") {
                slider("Central incisor width",
                       value: $design.parameters.centralWidthMillimetres,
                       range: 7.0...11.0, unit: "mm")
                slider("Width : length",
                       value: $design.parameters.widthToLengthRatio,
                       range: 0.68...0.92, unit: "")
                slider("Smile arc depth",
                       value: $design.parameters.smileArcDepthMillimetres,
                       range: 0...3, unit: "mm")
                Text(String(format: "Central length %.1f mm · lateral %.1f mm · canine %.1f mm",
                            design.parameters.centralWidthMillimetres / design.parameters.widthToLengthRatio,
                            design.parameters.centralWidthMillimetres * 0.618,
                            design.parameters.centralWidthMillimetres * 0.618 * 0.618))
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            Card(title: "Appearance") {
                Picker("Shade", selection: $design.parameters.shade) {
                    ForEach(SmileDesignParameters.ToothShade.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: design.parameters.shade) { _, _ in scheduleRender() }

                Toggle("Level to the interpupillary line", isOn: $design.parameters.levelToInterpupillary)
                    .tint(Palette.accent)
                    .onChange(of: design.parameters.levelToInterpupillary) { _, _ in scheduleRender() }
                Toggle("Include premolars", isOn: $design.parameters.includePremolars)
                    .tint(Palette.accent)
                    .onChange(of: design.parameters.includePremolars) { _, _ in scheduleRender() }
            }
            Card(title: "This is a simulation") {
                Text("Every render carries the simulation watermark and it cannot be turned off. Patients remember a rendered smile as a promise, and this is a proposal built from proportions — not a prediction of a clinical outcome.")
                    .font(.caption2).foregroundStyle(Palette.muted)
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 12)
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Palette.muted)
                Spacer()
                Text(unit.isEmpty ? String(format: "%.2f", value.wrappedValue)
                                  : String(format: "%.1f %@", value.wrappedValue, unit))
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.ink)
            }
            Slider(value: value, in: range)
                .tint(Palette.accent)
                .onChange(of: value.wrappedValue) { _, _ in scheduleRender() }
        }
    }

    // MARK: - Geometry helper

    static func fittedRect(image: CGSize, in bounds: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func position(of handle: Handle) -> CGPoint {
        switch handle {
        case .pupilRight:      return design.parameters.pupilRight
        case .pupilLeft:       return design.parameters.pupilLeft
        case .midline:         return design.parameters.midline
        case .incisalEdge:     return design.parameters.incisalEdge
        case .commissureRight: return design.parameters.commissureRight
        case .commissureLeft:  return design.parameters.commissureLeft
        }
    }

    private func setPosition(_ point: CGPoint, for handle: Handle) {
        switch handle {
        case .pupilRight:      design.parameters.pupilRight = point
        case .pupilLeft:       design.parameters.pupilLeft = point
        case .midline:         design.parameters.midline = point
        case .incisalEdge:     design.parameters.incisalEdge = point
        case .commissureRight: design.parameters.commissureRight = point
        case .commissureLeft:  design.parameters.commissureLeft = point
        }
    }

    // MARK: - Loading and rendering

    private func load() {
        if sourceImage == nil, !design.photoFileName.isEmpty {
            sourceImage = store.loadSmileDesignImage(caseID: caseID, fileName: design.photoFileName)
        }
        // Borrow the measured interpupillary distance from the case's facial scan, which
        // is what turns a photograph into something measurable.
        if let patientCase = store.caseByID(caseID) {
            for capture in patientCase.captures {
                let map = capture.landmarkMap
                if let right = map[.pupilRight], let left = map[.pupilLeft] {
                    design.parameters.interpupillaryMillimetres = Double(simd_distance(right, left)) * 1000
                    design.parameters.interpupillaryIsMeasured = true
                    break
                }
            }
        }
        if design.parameters.lipContour.isEmpty {
            design.parameters.lipContour = SmileRenderer.defaultLipContour(parameters: design.parameters)
        }
        scheduleRender()
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        photoSelection = nil
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "That photograph could not be read."
            return
        }
        sourceImage = image
        design.photoFileName = ""
        if let saved = store.saveSmileDesign(design, photo: data, render: nil, to: caseID) {
            design = saved
        }
        // Start the central width from the smile the photo actually shows.
        let width = design.parameters.intercommissuralMillimetres(in: image.size)
        design.parameters.centralWidthMillimetres =
            SmileDesignParameters.suggestedCentralWidth(intercommissuralMillimetres: width)
        design.parameters.lipContour = SmileRenderer.defaultLipContour(parameters: design.parameters)
        scheduleRender()
    }

    /// Re-renders at preview resolution, cancelling any render already in flight so a
    /// dragged slider does not queue up a dozen full renders.
    private func scheduleRender() {
        guard let sourceImage else { return }
        renderTask?.cancel()
        let parameters = design.parameters
        let practice = store.caseByID(caseID)?.displayCode
        renderTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            isRendering = true
            let rendered = await Task.detached(priority: .userInitiated) {
                SmileRenderer.render(photo: sourceImage, parameters: parameters,
                                     practiceName: practice, maxDimension: 1100)
            }.value
            guard !Task.isCancelled else { return }
            preview = rendered
            isRendering = false
        }
    }

    private func save(share: Bool) {
        guard let sourceImage else { return }
        isRendering = true
        let parameters = design.parameters
        let practice = store.caseByID(caseID)?.displayCode
        Task { @MainActor in
            let rendered = await Task.detached(priority: .userInitiated) {
                SmileRenderer.render(photo: sourceImage, parameters: parameters, practiceName: practice)
            }.value
            isRendering = false
            guard let rendered, let data = rendered.jpegData(compressionQuality: 0.94) else {
                errorMessage = "The design could not be rendered."
                return
            }
            design.parameters = parameters
            if let saved = store.saveSmileDesign(design, photo: nil, render: data, to: caseID) {
                design = saved
            }
            if share {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("smile-design-\(design.id.uuidString.prefix(8)).jpg")
                try? data.write(to: url)
                exportURL = url
            }
        }
    }
}
