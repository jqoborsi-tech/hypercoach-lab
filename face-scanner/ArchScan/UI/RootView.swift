import SwiftUI

struct RootView: View {

    @EnvironmentObject private var store: CaseStore
    @State private var newCaseCode = ""
    @State private var newCaseNote = ""
    @State private var showingNewCase = false
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if !ScanController.isSupported {
                        Card {
                            Text("No TrueDepth camera on this device. ArchScan can open and export existing scans, but it cannot capture.")
                                .font(.footnote).foregroundStyle(Palette.warn)
                        }
                    }

                    Button("New case") { showingNewCase = true }
                        .buttonStyle(PrimaryButtonStyle())

                    if store.cases.isEmpty {
                        Card(title: "Getting started") {
                            Text("A case holds the scans for one patient. The full-arch workflow normally wants a rest capture, a smile capture and a retracted capture; the retracted one is what registers against the intraoral scan.")
                                .font(.footnote).foregroundStyle(Palette.muted)
                        }
                    }

                    ForEach(store.cases) { item in
                        NavigationLink {
                            CaseDetailView(caseID: item.id).environmentObject(store)
                        } label: {
                            Card {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.displayCode).font(.headline).foregroundStyle(Palette.ink)
                                        Text("\(item.captures.count) scan\(item.captures.count == 1 ? "" : "s") · \(DateFormatter.localizedString(from: item.createdAt, dateStyle: .short, timeStyle: .none))")
                                            .font(.caption).foregroundStyle(Palette.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete case", role: .destructive) { store.delete(caseID: item.id) }
                        }
                    }
                }
                .padding(16)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("ArchScan")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAbout = true } label: { Image(systemName: "info.circle") }
                }
            }
            .sheet(isPresented: $showingNewCase) { newCaseSheet }
            .sheet(isPresented: $showingAbout) { AboutView() }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
    }

    private var newCaseSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Case code", text: $newCaseCode)
                    TextField("Note", text: $newCaseNote, axis: .vertical)
                } header: {
                    Text("Identify the case")
                } footer: {
                    Text("Use a code, not a patient name. Scans stay on this device, encrypted while it is locked, and nothing is uploaded anywhere.")
                }
            }
            .navigationTitle("New case")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewCase = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        store.createCase(code: newCaseCode.trimmingCharacters(in: .whitespaces),
                                         note: newCaseNote)
                        newCaseCode = ""
                        newCaseNote = ""
                        showingNewCase = false
                    }
                    .disabled(newCaseCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "What this is") {
                        Text("ArchScan fuses TrueDepth frames into a metric 3D face scan and writes it out as OBJ, PLY and STL in millimetres, with a landmark file and the anatomical reference planes, for full-arch prosthetic and surgical planning.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    Card(title: "Accuracy") {
                        Text("The TrueDepth sensor resolves roughly 0.5–1 mm at 30 cm on skin. That is enough for facial reference planes, tooth-position aesthetics and soft-tissue context. It is not an intraoral scanner and it is not CBCT: tooth surfaces and bone must come from those. Always run the scale check against a physical reference before a scan drives anything irreversible.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    Card(title: "Registration") {
                        Text("Register the retracted or prosthesis-in capture to the intraoral scan using three widely separated points on the visible teeth or on a scan flag. A rest capture shows no teeth and will not register reliably.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    Card(title: "Privacy") {
                        Text("Everything stays in the app container with complete file protection. Nothing leaves the device until you share an export yourself. Identify cases with a code rather than a name.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    Card(title: "Regulatory") {
                        Text("Research and laboratory use. ArchScan is not a medical device, is not cleared or CE-marked, and makes no diagnostic claim. Clinical decisions stay with the clinician.")
                            .font(.footnote).foregroundStyle(Palette.warn)
                    }
                }
                .padding(16)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("About ArchScan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
