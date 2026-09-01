import SwiftUI

struct CaseDetailView: View {

    let caseID: UUID
    @EnvironmentObject private var store: CaseStore
    @State private var showingCapture = false
    @State private var editingNote = false

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
        .fullScreenCover(isPresented: $showingCapture) {
            if let patientCase {
                CaptureView(patientCase: patientCase).environmentObject(store)
            }
        }
    }

    private var suggestedSequence: [String] {
        [
            "Rest / natural — the vertical dimension reference.",
            "Full smile — incisal display and the smile line.",
            "Retracted — the capture that registers against the intraoral scan.",
            "Prosthesis in — compare the lower facial height against the rest scan."
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
                    Text("\(capture.placedCoreCount)/\(LandmarkID.coreSet.count) landmarks · \(capture.quality.triangleCount) triangles")
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
