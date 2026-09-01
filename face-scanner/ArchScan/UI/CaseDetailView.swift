import SwiftUI
import PhotosUI
import ImageIO
import UIKit

struct CaseDetailView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore
    @State private var showingCapture = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    @State private var clinicalPhotos: [URL] = []
    @State private var thumbnails: [URL: UIImage] = [:]

    private var patientCase: PatientCase? { store.caseByID(caseID) }

    var body: some View {
        ScrollView {
            if let patientCase {
                VStack(spacing: 12) {
                    Card(title: "Case") {
                        Text(patientCase.displayCode).font(.title3.bold()).foregroundStyle(Palette.ink)
                        Text(DateFormatter.localizedString(from: patientCase.createdAt,
                                                           dateStyle: .medium, timeStyle: .short))
                            .font(.caption).foregroundStyle(Palette.muted)
                        if !patientCase.note.isEmpty {
                            Text(patientCase.note).font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }

                    Button("New scan") { showingCapture = true }
                        .buttonStyle(PrimaryButtonStyle())

                    clinicalPhotoCard

                    if patientCase.captures.isEmpty {
                        Card(title: "Suggested sequence") {
                            ForEach(suggestedSequence, id: \.self) { line in
                                Text("• \(line)").font(.footnote).foregroundStyle(Palette.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    ForEach(patientCase.captures) { capture in
                        NavigationLink {
                            ReviewView(caseID: caseID, capture: capture)
                                .environmentObject(store)
                        } label: {
                            captureRow(capture)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete scan", role: .destructive) {
                                store.deleteCapture(capture, from: caseID)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Case")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .task { refreshClinicalPhotos() }
        .fullScreenCover(isPresented: $showingCapture) {
            if let patientCase {
                CaptureView(patientCase: patientCase).environmentObject(store)
            }
        }
    }

    /// The photo series is shot with the phone's own camera app — 48 MP, the 5x lens for
    /// the retracted views — and attached here, rather than through a camera this app
    /// would have to reimplement worse. The photos travel with the scan in the export.
    private var clinicalPhotoCard: some View {
        Card(title: "Clinical photographs (\(clinicalPhotos.count))") {
            Text("Shoot the series in the Camera app at full resolution, then attach them here. They go into photos/clinical/ in the export, alongside the scan.")
                .font(.footnote).foregroundStyle(Palette.muted)
            if !clinicalPhotos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(clinicalPhotos, id: \.self) { url in
                            if let image = thumbnails[url] {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .contextMenu {
                                        Button("Remove", role: .destructive) {
                                            store.deleteClinicalPhoto(at: url)
                                            refreshClinicalPhotos()
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            PhotosPicker(selection: $photoSelection, maxSelectionCount: 24, matching: .images) {
                Text(isImportingPhotos ? "Importing…" : "Attach photographs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.accent)
            }
            .disabled(isImportingPhotos)
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                isImportingPhotos = true
                Task {
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            store.addClinicalPhoto(data, to: caseID)
                        }
                    }
                    photoSelection = []
                    refreshClinicalPhotos()
                    isImportingPhotos = false
                }
            }
        }
    }

    private func refreshClinicalPhotos() {
        clinicalPhotos = store.clinicalPhotoURLs(caseID: caseID)
        // Thumbnails come from ImageIO rather than a full decode — these are 48 MP files.
        var built: [URL: UIImage] = [:]
        for url in clinicalPhotos {
            if let existing = thumbnails[url] { built[url] = existing; continue }
            if let image = CaseDetailView.thumbnail(at: url, maxPixel: 192) { built[url] = image }
        }
        thumbnails = built
    }

    static func thumbnail(at url: URL, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private var suggestedSequence: [String] {
        [
            "Rest / natural — the vertical dimension reference, and incisal display at rest.",
            "Full smile — lip line, gingival display and the smile arc.",
            "Retracted or bite fork — the capture that registers against the intraoral scan.",
            "Prosthesis in — compare lower facial height and incisal display against the rest scan."
        ]
    }

    private func captureRow(_ capture: ScanCapture) -> some View {
        Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(capture.kind.title).font(.headline).foregroundStyle(Palette.ink)
                    Text(DateFormatter.localizedString(from: capture.createdAt,
                                                       dateStyle: .short, timeStyle: .short))
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text("\(capture.placedCoreCount)/\(LandmarkID.coreSet.count) facial · \(capture.placedSmileCount)/\(LandmarkID.smileSet.count) smile · \(capture.registrationPoints.count) reg.")
                        .font(.caption2).foregroundStyle(Palette.muted)
                    Text("\(capture.quality.triangleCount) triangles")
                        .font(.caption2).foregroundStyle(Palette.muted)
                    if !capture.note.isEmpty {
                        Text(capture.note).font(.caption2).foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    QualityBadge(quality: capture.quality)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
