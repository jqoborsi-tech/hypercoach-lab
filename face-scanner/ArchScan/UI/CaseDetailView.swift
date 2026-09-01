import SwiftUI

struct CaseDetailView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore
    @State private var showingCapture = false

    private var patientCase: PatientCase? { store.caseByID(caseID) }

    var body: some View {
        ScrollView {
            if let patientCase {
                VStack(spacing: 12) {
                    header(patientCase)
                    recordsLink(patientCase)
                    smileDesigns(patientCase)
                    facialScans(patientCase)
                }
                .padding(16)
            }
        }
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Case")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showingCapture) {
            if let patientCase {
                CaptureView(patientCase: patientCase).environmentObject(store)
            }
        }
    }

    // MARK: - Sections

    private func header(_ patientCase: PatientCase) -> some View {
        Card(title: "Case") {
            Text(patientCase.displayCode).font(.title3.bold()).foregroundStyle(Palette.ink)
            Text(DateFormatter.localizedString(from: patientCase.createdAt,
                                               dateStyle: .medium, timeStyle: .short))
                .font(.caption).foregroundStyle(Palette.muted)
            if !patientCase.note.isEmpty {
                Text(patientCase.note).font(.footnote).foregroundStyle(Palette.muted)
            }
        }
    }

    private func recordsLink(_ patientCase: PatientCase) -> some View {
        let progress = patientCase.recordsProgress
        return VStack(spacing: 12) {
            NavigationLink {
                RecordsView(caseID: caseID).environmentObject(store)
            } label: {
                Card(title: "Records") {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(Palette.line, lineWidth: 6)
                            Circle()
                                .trim(from: 0, to: progress.essentialFraction)
                                .stroke(progress.isReadyToPlan ? Palette.good : Palette.warn,
                                        style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(progress.essentialPresent)/\(progress.essentialTotal)")
                                .font(.caption2.bold().monospacedDigit())
                        }
                        .frame(width: 54, height: 54)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(progress.summary)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(progress.isReadyToPlan ? Palette.good : Palette.ink)
                            Text("Photos, video, scans, CBCT and notes")
                                .font(.caption2).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
            .buttonStyle(.plain)

            if patientCase.hasRecord(.cbct) {
                NavigationLink {
                    CBCTAlignView(caseID: caseID).environmentObject(store)
                } label: {
                    Card {
                        HStack {
                            Image(systemName: "cube.transparent").foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Align CBCT to the intraoral scan")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                                Text(cbctStatus(patientCase)).font(.caption2).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func cbctStatus(_ patientCase: PatientCase) -> String {
        guard let entry = patientCase.records(of: .cbct).first else { return "CBCT imported" }
        if let rms = entry.metadata["registration_rms_mm"],
           let trustworthy = entry.metadata["registration_trustworthy"] {
            return trustworthy == "yes"
                ? "Registered, \(rms) mm RMS"
                : "Registered but flagged — \(rms) mm RMS, review before use"
        }
        return "Not registered yet"
    }

    private func smileDesigns(_ patientCase: PatientCase) -> some View {
        VStack(spacing: 12) {
            NavigationLink {
                SmileDesignView(caseID: caseID, design: SmileDesignRecord())
                    .environmentObject(store)
            } label: {
                Card {
                    HStack {
                        Image(systemName: "wand.and.stars").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New smile design").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                            Text("Built from the interpupillary line, the facial midline and the tooth proportions")
                                .font(.caption2).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
            .buttonStyle(.plain)

            ForEach(patientCase.smileDesigns) { design in
                NavigationLink {
                    SmileDesignView(caseID: caseID, design: design).environmentObject(store)
                } label: {
                    Card {
                        HStack(spacing: 10) {
                            if let image = store.loadSmileDesignImage(caseID: caseID, fileName: design.renderFileName) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(design.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                                Text(DateFormatter.localizedString(from: design.createdAt,
                                                                   dateStyle: .short, timeStyle: .short))
                                    .font(.caption2).foregroundStyle(Palette.muted)
                                Text(String(format: "Central %.1f mm · W:L %.2f",
                                            design.parameters.centralWidthMillimetres,
                                            design.parameters.widthToLengthRatio))
                                    .font(.caption2).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete design", role: .destructive) {
                        store.deleteSmileDesign(design, from: caseID)
                    }
                }
            }
        }
    }

    private func facialScans(_ patientCase: PatientCase) -> some View {
        VStack(spacing: 12) {
            Button("New facial scan") { showingCapture = true }
                .buttonStyle(PrimaryButtonStyle())

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
                    ReviewView(caseID: caseID, capture: capture).environmentObject(store)
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
