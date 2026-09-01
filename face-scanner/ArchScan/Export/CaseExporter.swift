import Foundation
import simd

struct ExportOptions {
    var includeOBJ = true
    var includePLY = true
    var includeSTL = true
    var includeReferencePlanes = true
    var includeKeyframes = true
    var alignToClinicalFrame = true
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

        var analysis = ClinicalAnalysis.compute(landmarks: landmarks, calibration: .none)
        var frameTransform: simd_float4x4?
        var frameDescription = "Raw scanner frame: origin at the ARKit face anchor (just behind the nose), +X patient's left, +Y superior, +Z anterior."

        if options.alignToClinicalFrame, let frame = analysis.frame {
            frameTransform = frame.transform
            frameDescription = "Clinical frame. Origin: \(frame.originDescription) Axes: \(frame.axesDescription)"
            mesh = mesh.transformed(by: frame.transform)
            for (key, value) in landmarks {
                let h = frame.transform * SIMD4<Float>(value.x, value.y, value.z, 1)
                landmarks[key] = SIMD3<Float>(h.x, h.y, h.z)
            }
            analysis = ClinicalAnalysis.compute(landmarks: landmarks, calibration: .none)
        }

        var warnings = analysis.warnings
        if scale != 1 {
            warnings.append(String(format: "A uniform scale correction of %.4f was applied from the calibration reference.", scale))
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

        // --- Landmarks and measurements -------------------------------------------
        let json = landmarkJSON(patientCase: patientCase, capture: capture, landmarks: landmarks,
                                analysis: analysis, rawAnalysis: rawAnalysis, scale: scale,
                                frameTransform: frameTransform, frameDescription: frameDescription,
                                mesh: mesh, warnings: warnings)
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

        let zipURL = try zip(folder)
        return Output(zipURL: zipURL, folderURL: folder, fileNames: fileNames, warnings: warnings)
    }

    // MARK: - JSON

    private static func landmarkJSON(patientCase: PatientCase,
                                     capture: ScanCapture,
                                     landmarks: [LandmarkID: SIMD3<Float>],
                                     analysis: ClinicalAnalysis,
                                     rawAnalysis: ClinicalAnalysis,
                                     scale: Float,
                                     frameTransform: simd_float4x4?,
                                     frameDescription: String,
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
                             Camper's, Frankfort, mid-sagittal and interpupillary planes
                             as thin quads in the same coordinate system as the face.
        landmarks.json       Landmark coordinates, plane equations and measurements.
        scan-report.txt      The same numbers, readable.
        photos/              Reference photographs pulled from the sweep.

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

        Registering to an intraoral scan
          Use the retracted or prosthesis-in capture. Pick three widely separated
          points on the visible teeth or on the scan flag, and use the same three on
          the intraoral scan. A rest-position capture has no teeth showing and will
          not register reliably.

        Research and laboratory use. Not a medical device.
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
