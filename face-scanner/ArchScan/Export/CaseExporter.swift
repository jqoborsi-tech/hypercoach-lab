import Foundation
import simd

struct ExportOptions {
    var includeOBJ = true
    var includePLY = true
    var includeSTL = true
    var includeReferencePlanes = true
    var includeKeyframes = true
    var includeRegistrationMarkers = true
    var alignToClinicalFrame = true
    /// Export in the reference capture's frame so the case's scans land superimposed.
    var superimposeOntoReference = true
}

/// Assembles one capture into a folder of CAD-ready files and zips it for AirDrop,
/// Files or e-mail.
enum CaseExporter {

    static let generator = "ArchScan 1.0"

    struct Output {
        var zipURL: URL
        var folderURL: URL
        var fileNames: [String]
        var warnings: [String]
    }

    static func export(patientCase: PatientCase,
                       capture: ScanCapture,
                       mesh rawMesh: ScanMesh,
                       textureJPEG: Data?,
                       keyframes: [URL],
                       clinicalPhotos: [URL],
                       referenceCapture: ScanCapture?,
                       options: ExportOptions) throws -> Output {

        let stamp = filenameStamp(capture.createdAt)
        let baseName = sanitize("\(patientCase.displayCode)_\(capture.kind.rawValue)_\(stamp)")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchScanExport-\(UUID().uuidString.prefix(8))/\(baseName)", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // --- Scale correction from the calibration reference -----------------------
        let rawAnalysis = capture.analysis()
        let scale = rawAnalysis.scaleCorrection
        var mesh = rawMesh.scaled(by: scale)
        var landmarks = capture.landmarkMap
        if scale != 1 {
            for (key, value) in landmarks { landmarks[key] = value * scale }
        }

        var registrationPoints = capture.registrationPoints
        if scale != 1 {
            for index in registrationPoints.indices { registrationPoints[index].position *= scale }
        }

        var analysis = ClinicalAnalysis.compute(landmarks: landmarks, calibration: .none)
        var frameTransform: simd_float4x4?
        var frameDescription = "Raw scanner frame: origin at the ARKit face anchor (just behind the nose), +X patient's left, +Y superior, +Z anterior."
        var superimposition: Superimposition.Result?

        if options.alignToClinicalFrame {
            var transform: simd_float4x4?

            // Preferred: land in the reference capture's frame, so every scan of this
            // patient opens superimposed on the others. The fit uses only upper-face
            // landmarks, which do not move between a rest scan and a smile scan.
            if options.superimposeOntoReference,
               let referenceCapture,
               referenceCapture.id != capture.id,
               let referenceFrame = referenceCapture.analysis().frame,
               let alignment = Superimposition.align(sourceLandmarks: landmarks,
                                                     referenceLandmarks: referenceCapture.landmarkMap) {
                superimposition = alignment
                transform = referenceFrame.transform * alignment.transform
                frameDescription = String(format: "Clinical frame of the reference capture (%@), so this scan is superimposed on it. Fitted on %d upper-face landmarks, RMS %.2f mm, worst %.2f mm. Axes: +X patient's left, +Y superior, +Z anterior, millimetres.",
                                          referenceCapture.kind.title, alignment.landmarksUsed.count,
                                          alignment.rmsMillimetres, alignment.maximumErrorMillimetres)
            } else if let frame = analysis.frame {
                transform = frame.transform
                frameDescription = "Clinical frame. Origin: \(frame.originDescription) Axes: \(frame.axesDescription)"
            }

            if let transform {
                frameTransform = transform
                mesh = mesh.transformed(by: transform)
                for (key, value) in landmarks {
                    let h = transform * SIMD4<Float>(value.x, value.y, value.z, 1)
                    landmarks[key] = SIMD3<Float>(h.x, h.y, h.z)
                }
                for index in registrationPoints.indices {
                    let p = registrationPoints[index].position
                    let h = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                    registrationPoints[index].position = SIMD3<Float>(h.x, h.y, h.z)
                }
                analysis = ClinicalAnalysis.compute(landmarks: landmarks, calibration: .none)
            }
        }

        var warnings = analysis.warnings
        if scale != 1 {
            warnings.append(String(format: "A uniform scale correction of %.4f was applied from the calibration reference.", scale))
        }
        if let superimposition, superimposition.rmsMillimetres > 1.5 {
            warnings.append(String(format: "Superimposition onto the reference capture has an RMS of %.2f mm. Re-check the upper-face landmarks on both captures before trusting the overlay.", superimposition.rmsMillimetres))
        }
        if registrationPoints.count < 3 {
            warnings.append("Fewer than three registration points. The lab needs at least three, well spread, to align this scan to the intraoral scan.")
        }

        // --- Geometry --------------------------------------------------------------
        var fileNames: [String] = []
        let header = [
            "\(generator) facial scan",
            "Case \(patientCase.displayCode) — \(capture.kind.title)",
            "Captured \(ISO8601DateFormatter().string(from: capture.createdAt))",
            frameDescription
        ]

        if options.includeOBJ {
            try MeshIO.writeOBJ(mesh, to: folder, name: baseName, textureJPEG: textureJPEG, header: header)
            fileNames.append("\(baseName).obj")
            if textureJPEG != nil {
                fileNames.append("\(baseName).mtl")
                fileNames.append("\(baseName).jpg")
            }
        }
        if options.includePLY {
            try MeshIO.writePLY(mesh, to: folder.appendingPathComponent("\(baseName).ply"), comments: header)
            fileNames.append("\(baseName).ply")
        }
        if options.includeSTL {
            try MeshIO.writeSTL(mesh, to: folder.appendingPathComponent("\(baseName).stl"), title: header[1])
            fileNames.append("\(baseName).stl")
        }
        if options.includeReferencePlanes, !analysis.planes.isEmpty {
            try MeshIO.writePlanesSTL(analysis.planes, to: folder.appendingPathComponent("\(baseName)_reference-planes.stl"))
            fileNames.append("\(baseName)_reference-planes.stl")
        }

        // --- Registration markers for the merge ------------------------------------
        if options.includeRegistrationMarkers, !registrationPoints.isEmpty {
            let ordered = registrationPoints.sorted { $0.index < $1.index }
            try MeshIO.writeMarkersOBJ(ordered.map { ($0.markerName, $0.label, $0.position) },
                                       to: folder.appendingPathComponent("\(baseName)_registration-points.obj"),
                                       radius: 0.0015,
                                       header: header)
            try MeshIO.writeMarkersSTL(ordered.map { $0.position },
                                       to: folder.appendingPathComponent("\(baseName)_registration-points.stl"),
                                       radius: 0.0015,
                                       title: "ArchScan registration points (mm)")
            fileNames.append("\(baseName)_registration-points.obj")
            fileNames.append("\(baseName)_registration-points.stl")
        }

        // --- Landmarks and measurements -------------------------------------------
        let json = landmarkJSON(patientCase: patientCase, capture: capture, landmarks: landmarks,
                                registrationPoints: registrationPoints,
                                analysis: analysis, rawAnalysis: rawAnalysis, scale: scale,
                                frameTransform: frameTransform, frameDescription: frameDescription,
                                superimposition: superimposition, mesh: mesh, warnings: warnings)
        let jsonData = try JSONSerialization.data(withJSONObject: json,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try jsonData.write(to: folder.appendingPathComponent("landmarks.json"), options: .atomic)
        fileNames.append("landmarks.json")

        let report = reportText(patientCase: patientCase, capture: capture, analysis: analysis,
                                rawAnalysis: rawAnalysis, scale: scale, mesh: mesh,
                                frameDescription: frameDescription, warnings: warnings)
        try report.data(using: .utf8)?.write(to: folder.appendingPathComponent("scan-report.txt"), options: .atomic)
        fileNames.append("scan-report.txt")

        try importNotes(baseName: baseName)
            .data(using: .utf8)?
            .write(to: folder.appendingPathComponent("READ-ME-FIRST.txt"), options: .atomic)
        fileNames.append("READ-ME-FIRST.txt")

        try labHandoff(baseName: baseName, capture: capture, registrationPoints: registrationPoints)
            .data(using: .utf8)?
            .write(to: folder.appendingPathComponent("LAB-HANDOFF.txt"), options: .atomic)
        fileNames.append("LAB-HANDOFF.txt")

        // --- Reference photographs -------------------------------------------------
        if options.includeKeyframes, !keyframes.isEmpty {
            let photoFolder = folder.appendingPathComponent("photos", isDirectory: true)
            try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
            for url in keyframes {
                let destination = photoFolder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: destination)
            }
            fileNames.append("photos/ (\(keyframes.count) reference images)")
        }
        if options.includeKeyframes, !clinicalPhotos.isEmpty {
            let clinicalFolder = folder.appendingPathComponent("photos/clinical", isDirectory: true)
            try FileManager.default.createDirectory(at: clinicalFolder, withIntermediateDirectories: true)
            for url in clinicalPhotos {
                try? FileManager.default.copyItem(at: url,
                                                  to: clinicalFolder.appendingPathComponent(url.lastPathComponent))
            }
            fileNames.append("photos/clinical/ (\(clinicalPhotos.count) clinical photographs)")
        }

        let zipURL = try zip(folder)
        return Output(zipURL: zipURL, folderURL: folder, fileNames: fileNames, warnings: warnings)
    }

    // MARK: - JSON

    private static func landmarkJSON(patientCase: PatientCase,
                                     capture: ScanCapture,
                                     landmarks: [LandmarkID: SIMD3<Float>],
                                     registrationPoints: [RegistrationPoint],
                                     analysis: ClinicalAnalysis,
                                     rawAnalysis: ClinicalAnalysis,
                                     scale: Float,
                                     frameTransform: simd_float4x4?,
                                     frameDescription: String,
                                     superimposition: Superimposition.Result?,
                                     mesh: ScanMesh,
                                     warnings: [String]) -> [String: Any] {

        func mmArray(_ v: SIMD3<Float>) -> [Double] {
            [Double(v.x) * 1000, Double(v.y) * 1000, Double(v.z) * 1000]
        }

        var landmarkList: [[String: Any]] = []
        for id in LandmarkID.pickingOrder {
            guard let p = landmarks[id] else { continue }
            let mm = mmArray(p)
            landmarkList.append([
                "id": id.rawValue,
                "label": id.displayName,
                "x": mm[0], "y": mm[1], "z": mm[2]
            ])
        }

        var planeList: [[String: Any]] = []
        for plane in analysis.planes {
            planeList.append([
                "key": plane.key,
                "label": plane.label,
                "point": mmArray(plane.point),
                "normal": [Double(plane.normal.x), Double(plane.normal.y), Double(plane.normal.z)],
                "note": plane.note
            ])
        }

        var measurementList: [[String: Any]] = []
        for m in analysis.measurements {
            var entry: [String: Any] = ["key": m.key, "label": m.label,
                                        "value": (m.value * 1000).rounded() / 1000, "unit": m.unit]
            if let note = m.note { entry["note"] = note }
            measurementList.append(entry)
        }
        if let calibrationError = rawAnalysis.measurement("calibration_error") {
            measurementList.append(["key": "calibration_error_before_correction",
                                    "label": "Calibration error before correction",
                                    "value": (calibrationError.value * 1000).rounded() / 1000,
                                    "unit": "mm"])
        }

        let superimpositionRMS: Any = superimposition.map { Double($0.rmsMillimetres) } ?? NSNull()
        var registrationList: [[String: Any]] = []
        for point in registrationPoints.sorted(by: { $0.index < $1.index }) {
            let mm = mmArray(point.position)
            registrationList.append([
                "marker": point.markerName,
                "label": point.label,
                "x": mm[0], "y": mm[1], "z": mm[2]
            ])
        }

        var frame: [String: Any] = ["description": frameDescription, "units": "millimetres"]
        if let t = frameTransform {
            // Row-major 4x4. The rotation block is dimensionless; the translation
            // column is written in millimetres to match the exported geometry.
            var rows: [[Double]] = []
            for r in 0..<4 {
                rows.append([Double(t.columns.0[r]), Double(t.columns.1[r]),
                             Double(t.columns.2[r]), Double(t.columns.3[r]) * (r == 3 ? 1 : 1000)])
            }
            frame["transform_from_scanner_frame_row_major"] = rows
            frame["name"] = "clinical"
        } else {
            frame["name"] = "scanner"
        }

        let bounds = mesh.bounds
        return [
            "generator": generator,
            "schema": "archscan.landmarks/1",
            "case_code": patientCase.displayCode,
            "capture": [
                "id": capture.id.uuidString,
                "kind": capture.kind.rawValue,
                "kind_label": capture.kind.title,
                "captured_at": ISO8601DateFormatter().string(from: capture.createdAt),
                "note": capture.note
            ],
            "units": "millimetres",
            "scale_correction_applied": Double(scale),
            "coordinate_frame": frame,
            "landmarks": landmarkList,
            "registration": [
                "target": capture.registrationTarget.rawValue,
                "target_label": capture.registrationTarget.title,
                "points": registrationList,
                "superimposed_onto_reference": superimposition != nil,
                "superimposition_rms_mm": superimpositionRMS,
                "superimposition_landmarks": superimposition?.landmarksUsed.map { $0.rawValue } ?? []
            ],
            "reference_planes": planeList,
            "measurements": measurementList,
            "quality": [
                "integrated_frames": capture.quality.integratedFrames,
                "rejected_frames": capture.quality.rejectedFrames,
                "voxel_size_mm": Double(capture.quality.voxelSizeMillimetres),
                "yaw_coverage_deg": Double(capture.quality.yawCoverageDegrees),
                "pitch_coverage_deg": Double(capture.quality.pitchCoverageDegrees),
                "vertices": mesh.vertexCount,
                "triangles": mesh.triangleCount,
                "median_pose_correction_mm": Double(capture.quality.medianPoseCorrectionMillimetres),
                "bounding_box_mm": [
                    "min": mmArray(bounds.min),
                    "max": mmArray(bounds.max)
                ]
            ],
            "warnings": warnings,
            "disclaimer": "Research and laboratory use. Not a medical device and not cleared by any regulator. Verify scale against a physical reference before using this scan for anything irreversible."
        ]
    }

    // MARK: - Human-readable report

    private static func reportText(patientCase: PatientCase,
                                   capture: ScanCapture,
                                   analysis: ClinicalAnalysis,
                                   rawAnalysis: ClinicalAnalysis,
                                   scale: Float,
                                   mesh: ScanMesh,
                                   frameDescription: String,
                                   warnings: [String]) -> String {
        var lines: [String] = []
        lines.append("\(generator) — facial scan report")
        lines.append(String(repeating: "=", count: 58))
        lines.append("Case:          \(patientCase.displayCode)")
        lines.append("Capture:       \(capture.kind.title)")
        lines.append("Captured:      \(DateFormatter.localizedString(from: capture.createdAt, dateStyle: .medium, timeStyle: .short))")
        if !capture.note.isEmpty { lines.append("Note:          \(capture.note)") }
        lines.append("")
        lines.append("Geometry")
        lines.append("--------")
        lines.append("Vertices:      \(mesh.vertexCount)")
        lines.append("Triangles:     \(mesh.triangleCount)")
        lines.append(String(format: "Surface area:  %.1f cm²", mesh.surfaceArea * 10000))
        lines.append(String(format: "Voxel size:    %.2f mm", capture.quality.voxelSizeMillimetres))
        lines.append("Frames fused:  \(capture.quality.integratedFrames) (rejected \(capture.quality.rejectedFrames))")
        lines.append(String(format: "Yaw coverage:  %.0f°   Pitch coverage: %.0f°",
                            capture.quality.yawCoverageDegrees, capture.quality.pitchCoverageDegrees))
        lines.append(String(format: "Median pose correction: %.2f mm", capture.quality.medianPoseCorrectionMillimetres))
        if scale != 1 { lines.append(String(format: "Scale correction applied: %.4f", scale)) }
        lines.append("")
        lines.append("Coordinate frame")
        lines.append("----------------")
        lines.append(frameDescription)
        lines.append("")
        lines.append("Measurements")
        lines.append("------------")
        for m in analysis.measurements {
            let value = m.unit.isEmpty ? String(format: "%.3f", m.value)
                                       : String(format: "%.2f", m.value) + " " + m.unit
            lines.append(pad(m.label, to: 46) + value)
            if let note = m.note { lines.append("    \(note)") }
        }
        if !capture.registrationPoints.isEmpty {
            lines.append("")
            lines.append("Registration points for the merge")
            lines.append("---------------------------------")
            lines.append("Target: \(capture.registrationTarget.title)")
            for point in capture.registrationPoints.sorted(by: { $0.index < $1.index }) {
                lines.append("  \(point.markerName)  \(point.label)")
            }
            lines.append("Exported as \(capture.registrationPoints.count) named markers. See LAB-HANDOFF.txt.")
        }
        if !analysis.planes.isEmpty {
            lines.append("")
            lines.append("Reference planes (also written as reference-planes.stl)")
            lines.append("-------------------------------------------------------")
            for plane in analysis.planes {
                lines.append("\(plane.label): \(plane.note)")
            }
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Warnings")
            lines.append("--------")
            for warning in warnings { lines.append("• \(warning)") }
        }
        lines.append("")
        lines.append("Research and laboratory use. Not a medical device and not cleared by any")
        lines.append("regulator. Confirm the scale against a physical reference of known length")
        lines.append("before this scan drives anything irreversible.")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func importNotes(baseName: String) -> String {
        """
        ArchScan export — what is in this folder
        ========================================

        \(baseName).obj      Textured mesh. The format every face-scan import expects.
        \(baseName).mtl      Material file. Keep it next to the .obj.
        \(baseName).jpg      Texture map. Keep it next to the .obj.
        \(baseName).ply      Same mesh, binary PLY with per-vertex colour.
        \(baseName).stl      Same mesh, geometry only, for implant planning software.
        \(baseName)_reference-planes.stl
                             Camper's, Frankfort, mid-sagittal, interpupillary and
                             anterior occlusal planes as thin quads, in the same
                             coordinate system as the face.
        \(baseName)_registration-points.obj
                             The points the lab aligns to, one named group per point
                             (P1, P2, …) so each keeps its identity in CAD.
        \(baseName)_registration-points.stl
                             The same markers as plain geometry.
        landmarks.json       Landmark coordinates, registration points, plane equations
                             and measurements.
        scan-report.txt      The same numbers, readable.
        LAB-HANDOFF.txt      How to merge this with the intraoral scan and the CBCT.
                             Read this one first if you are the laboratory.
        photos/              Reference stills pulled from the sweep, at the yaw
                             milestones, so the views match the mesh exactly.
        photos/clinical/     The full-resolution clinical photograph series, if the
                             clinician attached one.

        Units are millimetres in every file. The mesh, the planes and the landmarks
        share one coordinate system, so they line up when imported together.

        exocad (Smile Creator / Full Denture)
          Import the .obj as the face scan. Load the .mtl and .jpg from the same folder
          so the texture comes with it, then align to the model scan on the retracted
          capture. Import reference-planes.stl as an additional object if you want the
          ala–tragus line on screen while you set the occlusal plane.

        3Shape Dental System
          Add the .ply (or .obj) as a face scan attachment, then use the three-point
          alignment against the intraoral scan. Vertex colour rides along in the PLY.

        Blue Sky Plan / Nemotec / implant planning
          Import the .stl as a surface object and register it to the CBCT with the
          landmark set. landmarks.json lists every point in the same frame.

        Registering to an intraoral scan and a CBCT
          See LAB-HANDOFF.txt. The short version: the intraoral scan is the master,
          the CBCT registers to it on the teeth or the radiographic markers, and this
          face scan registers to it on the markers in the registration-points file.
          Use the retracted, bite-fork or prosthesis-in capture — a rest capture shows
          no teeth and cannot be registered.

        Research and laboratory use. Not a medical device.
        """
    }

    // MARK: - Lab handoff

    private static func labHandoff(baseName: String,
                                   capture: ScanCapture,
                                   registrationPoints: [RegistrationPoint]) -> String {
        var markerLines = registrationPoints.sorted { $0.index < $1.index }
            .map { "  \($0.markerName)  \($0.label)" }
            .joined(separator: "\n")
        if markerLines.isEmpty { markerLines = "  (none set — see the warning below)" }

        return """
        MERGING THIS FACE SCAN — instructions for the laboratory
        ========================================================

        Capture type : \(capture.kind.title)
        Registration : \(capture.registrationTarget.title)
        Markers      :
        \(markerLines)

        Merge in this order. It matters.
        --------------------------------
        1. INTRAORAL SCAN is the master. It is the most accurate object in the case
           (tens of microns), so everything else moves onto it — never the reverse.

        2. CBCT to intraoral scan. Register the DICOM volume to the intraoral scan on
           the teeth, or on the radiographic markers if a scan appliance was used. In a
           fully edentulous case use the appliance or the fiducials; there is nothing
           on an edentulous ridge in a CBCT reliable enough to register a prosthetic
           plan against.

        3. FACE SCAN to intraoral scan. Use the registration markers in
           \(baseName)_registration-points.obj. Each marker is a named group (P1, P2, …)
           at the point the clinician picked, so you can snap to its centre. Pick the
           same points on the intraoral scan and run a three-point alignment, then let
           the software refine with a best-fit restricted to that region.

        Do NOT register the face scan directly to the CBCT soft-tissue surface. The
        lips are commonly distorted during a CBCT, and the soft-tissue reconstruction
        is not accurate enough to carry a smile design.

        Why the markers rather than the teeth themselves
        -----------------------------------------------
        Wet enamel scatters the infrared pattern this scanner projects, so tooth
        surfaces are the noisiest geometry in a face scan — which is exactly what you
        would otherwise be registering against. If the capture type above says
        "Bite fork / scan flag", the markers sit on a rigid object of known geometry
        and the alignment is flag-to-flag, which is far more trustworthy. If it says
        "Visible teeth", inspect those teeth in the mesh before relying on them; if
        they look soft or pitted, ask for a re-scan with a flag.

        Superimposed captures
        ---------------------
        Where a case has several captures (rest, smile, retracted, prosthesis in),
        each is exported in the same coordinate frame, fitted on upper-face landmarks
        that do not move between them. Load them together and they will already be
        superimposed: no second alignment step, and the lip and tooth movement between
        them is real, not registration error. The fit residual is recorded in
        landmarks.json under registration.superimposition_rms_mm — anything above about
        1.5 mm means the landmarks need re-checking before you trust the overlay.

        For the smile design
        --------------------
        scan-report.txt carries the numbers the design is judged on: incisal plane cant
        against the interpupillary line, dental midline deviation and angulation,
        incisal display at rest, gingival display at full smile, smile arc against the
        lower lip, and buccal corridor. The reference planes STL puts the interpupillary,
        Camper's, Frankfort, mid-sagittal and anterior occlusal planes in the scene with
        the face, in the same coordinates.

        Units are millimetres in every file. Research and laboratory use; not a medical
        device.
        """
    }

    // MARK: - Zipping

    private static func zip(_ folder: URL) throws -> URL {
        var coordinatorError: NSError?
        var thrownError: Error?
        var result: URL?

        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinatorError) { zippedURL in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(folder.lastPathComponent).zip")
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: zippedURL, to: destination)
                result = destination
            } catch {
                thrownError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let thrownError { throw thrownError }
        guard let result else { throw ExportError.zipFailed }
        return result
    }

    enum ExportError: Error, LocalizedError {
        case zipFailed
        var errorDescription: String? { "Could not package the export folder." }
    }

    // MARK: - Naming

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned)
    }

    private static func filenameStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }
}
