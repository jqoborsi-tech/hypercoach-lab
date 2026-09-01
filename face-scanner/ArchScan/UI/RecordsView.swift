import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The records checklist. The point of the screen is the missing column, not the
/// present one: it should be obvious at a glance what still has to be collected before
/// this case can be planned.
struct RecordsView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore

    @State private var group: RecordKind.Group = .extraoral
    @State private var activeKind: RecordKind?
    @State private var cameraMode: CameraPicker.Mode = .photo
    @State private var showingCamera = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var showingMeshImporter = false
    @State private var showingCBCTImporter = false
    @State private var noteKind: RecordKind?
    @State private var noteDraft = ""
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var thumbnails: [UUID: UIImage] = [:]

    private var patientCase: PatientCase? { store.caseByID(caseID) }

    var body: some View {
        ScrollView {
            if let patientCase {
                VStack(spacing: 12) {
                    progressCard(patientCase)

                    Picker("Group", selection: $group) {
                        ForEach(RecordKind.Group.allCases) { Text(shortTitle($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    ForEach(RecordKind.inGroup(group)) { kind in
                        RecordRow(kind: kind,
                                  entries: patientCase.records(of: kind),
                                  captureCount: kind == .facialScan ? patientCase.captures.count : 0,
                                  thumbnails: thumbnails,
                                  onAction: { handle($0, kind: kind) })
                    }
                }
                .padding(16)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Records")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { refreshThumbnails() }
        .overlay { if let busyMessage { busyOverlay(busyMessage) } }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(mode: cameraMode) { data, ext in
                guard let kind = activeKind else { return }
                store.addRecord(kind, data: data, fileExtension: ext, to: caseID)
                refreshThumbnails()
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: Binding(get: { photoPickerActive }, set: { if !$0 { photoPickerKind = nil } }),
                      selection: $photoSelection, matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { _, item in
            guard let item, let kind = photoPickerKind else { return }
            Task { await importFromLibrary(item, kind: kind) }
        }
        .fileImporter(isPresented: $showingMeshImporter, allowedContentTypes: [.data]) { result in
            handleMeshImport(result)
        }
        .fileImporter(isPresented: $showingCBCTImporter, allowedContentTypes: [.folder]) { result in
            handleCBCTImport(result)
        }
        .sheet(item: $noteKind) { kind in noteSheet(kind) }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
                                                            set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @State private var photoPickerKind: RecordKind?
    private var photoPickerActive: Bool { photoPickerKind != nil }

    // MARK: - Header

    private func progressCard(_ patientCase: PatientCase) -> some View {
        let progress = patientCase.recordsProgress
        return Card(title: "Case readiness") {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().stroke(Palette.line, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: progress.essentialFraction)
                        .stroke(progress.isReadyToPlan ? Palette.good : Palette.warn,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(progress.essentialPresent)")
                            .font(.title3.bold().monospacedDigit())
                        Text("of \(progress.essentialTotal)").font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
                .frame(width: 74, height: 74)

                VStack(alignment: .leading, spacing: 4) {
                    Text(progress.summary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(progress.isReadyToPlan ? Palette.good : Palette.ink)
                    Text("\(progress.present) of \(progress.total) records overall")
                        .font(.caption).foregroundStyle(Palette.muted)
                    if !progress.isReadyToPlan {
                        Text(patientCase.missingEssentials.prefix(4).map(\.title).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Palette.warn).lineLimit(2)
                    }
                }
            }
        }
    }

    private func shortTitle(_ group: RecordKind.Group) -> String {
        switch group {
        case .extraoral: return "Face"
        case .intraoral: return "Intraoral"
        case .video:     return "Video"
        case .digital:   return "Scans"
        case .notes:     return "Notes"
        }
    }

    private func busyOverlay(_ message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Palette.accent)
                Text(message).font(.footnote).foregroundStyle(Palette.ink)
            }
            .padding(24)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Notes

    private func noteSheet(_ kind: RecordKind) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note", text: $noteDraft, axis: .vertical).lineLimit(4...12)
                } header: {
                    Text(kind.title)
                } footer: {
                    Text(kind.guidance)
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { noteKind = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.addNoteRecord(kind, note: noteDraft, to: caseID)
                        noteDraft = ""
                        noteKind = nil
                    }
                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions

    private func handle(_ action: RecordRow.Action, kind: RecordKind) {
        activeKind = kind
        switch action {
        case .camera:
            cameraMode = kind.medium == .video ? .video : .photo
            showingCamera = true
        case .library:
            photoPickerKind = kind
        case .importFile:
            if kind.medium == .dicom { showingCBCTImporter = true } else { showingMeshImporter = true }
        case .note:
            noteDraft = patientCase?.records(of: kind).first?.note ?? ""
            noteKind = kind
        case .delete(let entry):
            store.deleteRecord(entry, from: caseID)
            refreshThumbnails()
        }
    }

    private func importFromLibrary(_ item: PhotosPickerItem, kind: RecordKind) async {
        photoPickerKind = nil
        photoSelection = nil
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = "That item could not be read."
            return
        }
        let ext = kind.medium == .video ? "mov" : "jpg"
        store.addRecord(kind, data: data, fileExtension: ext, to: caseID)
        refreshThumbnails()
    }

    private func handleMeshImport(_ result: Result<URL, Error>) {
        guard let kind = activeKind else { return }
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            busyMessage = "Reading \(url.lastPathComponent)…"
            Task.detached(priority: .userInitiated) {
                do {
                    let imported = try MeshImporter.load(from: url)
                    let bounds = imported.mesh.bounds
                    let extent = (bounds.max - bounds.min) * 1000
                    let metadata: [String: String] = [
                        "format": imported.detectedFormat,
                        "unit": imported.assumedUnit,
                        "vertices": "\(imported.mesh.vertexCount)",
                        "triangles": "\(imported.mesh.triangleCount)",
                        "size_mm": String(format: "%.1f x %.1f x %.1f", extent.x, extent.y, extent.z)
                    ]
                    await MainActor.run {
                        store.importRecord(kind, from: url, metadata: metadata, to: caseID)
                        busyMessage = nil
                        if !imported.warnings.isEmpty { errorMessage = imported.warnings.joined(separator: "\n") }
                    }
                } catch {
                    await MainActor.run {
                        busyMessage = nil
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func handleCBCTImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            busyMessage = "Reading the DICOM series…"
            Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let series = try DICOMReader.readSeries(in: url)
                    let first = series.slices[0]
                    var metadata: [String: String] = [
                        "slices": "\(series.slices.count)",
                        "matrix": "\(first.columns) x \(first.rows)",
                        "pixel_spacing_mm": String(format: "%.3f", first.columnSpacing),
                        "modality": series.info.modality,
                        "manufacturer": series.info.manufacturer
                    ]
                    if series.info.carriesPatientIdentifiers {
                        metadata["contains_patient_identifiers"] = "yes"
                    }
                    await MainActor.run {
                        store.importRecord(.cbct, from: url, metadata: metadata, to: caseID)
                        busyMessage = nil
                        if series.info.carriesPatientIdentifiers {
                            errorMessage = "These DICOM files carry the patient's name or ID in their headers. They stay on this device and are not included in an export unless you explicitly add them."
                        }
                    }
                } catch {
                    await MainActor.run {
                        busyMessage = nil
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func refreshThumbnails() {
        guard let patientCase else { return }
        var built: [UUID: UIImage] = [:]
        for entry in patientCase.records where entry.kind.medium == .photo {
            if let existing = thumbnails[entry.id] { built[entry.id] = existing; continue }
            if let image = store.thumbnail(for: entry, caseID: caseID) { built[entry.id] = image }
        }
        thumbnails = built
    }
}

// MARK: - One row

struct RecordRow: View {
    enum Action {
        case camera, library, importFile, note
        case delete(RecordEntry)
    }

    let kind: RecordKind
    let entries: [RecordEntry]
    let captureCount: Int
    let thumbnails: [UUID: UIImage]
    let onAction: (Action) -> Void

    @State private var expanded = false

    private var isPresent: Bool { !entries.isEmpty || captureCount > 0 }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isPresent ? "checkmark.circle.fill" : (kind.isEssential ? "exclamationmark.circle" : "circle"))
                    .foregroundStyle(isPresent ? Palette.good : (kind.isEssential ? Palette.warn : Palette.muted))
                    .font(.system(size: 18))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        if kind.isEssential {
                            Text("essential").font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Palette.warn.opacity(0.18), in: Capsule())
                                .foregroundStyle(Palette.warn)
                        }
                    }
                    if expanded || !isPresent {
                        Text(kind.guidance).font(.caption2).foregroundStyle(Palette.muted)
                    }
                    if kind == .facialScan, captureCount > 0 {
                        Text("\(captureCount) scan\(captureCount == 1 ? "" : "s") captured")
                            .font(.caption2).foregroundStyle(Palette.good)
                    }
                    ForEach(entries) { entry in
                        entryLine(entry)
                    }
                }

                Spacer(minLength: 4)
                menu
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }
        }
    }

    @ViewBuilder
    private func entryLine(_ entry: RecordEntry) -> some View {
        HStack(spacing: 8) {
            if let image = thumbnails[entry.id] {
                Image(uiImage: image)
                    .resizable().scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption2).foregroundStyle(Palette.ink).lineLimit(3)
                }
                if !entry.metadata.isEmpty {
                    Text(entry.metadata.sorted { $0.key < $1.key }
                            .map { "\($0.key.replacingOccurrences(of: "_", with: " ")): \($0.value)" }
                            .joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(3)
                }
            }
        }
        .padding(.top, 2)
    }

    private var menu: some View {
        Menu {
            switch kind.medium {
            case .photo:
                Button { onAction(.camera) } label: { Label("Take photo", systemImage: "camera") }
                Button { onAction(.library) } label: { Label("Choose from library", systemImage: "photo") }
            case .video:
                Button { onAction(.camera) } label: { Label("Record video", systemImage: "video") }
                Button { onAction(.library) } label: { Label("Choose from library", systemImage: "photo") }
            case .mesh:
                Button { onAction(.importFile) } label: { Label("Import STL / PLY / OBJ", systemImage: "square.and.arrow.down") }
            case .dicom:
                Button { onAction(.importFile) } label: { Label("Import DICOM folder", systemImage: "folder") }
            case .note:
                Button { onAction(.note) } label: { Label("Write note", systemImage: "square.and.pencil") }
            case .facialScan:
                EmptyView()
            }
            if !entries.isEmpty {
                Divider()
                ForEach(entries) { entry in
                    Button(role: .destructive) { onAction(.delete(entry)) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
        } label: {
            Image(systemName: kind.medium == .facialScan ? "faceid" : "plus.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(kind.medium == .facialScan ? Palette.muted : Palette.accent)
        }
        .disabled(kind.medium == .facialScan)
    }
}
