# ArchScan — TrueDepth facial scanner for full-arch surgery and prosthetics

A native iOS app for the iPhone 15 Pro Max (any Face ID device works; the 15 Pro Max
is the reference) that fuses TrueDepth frames into a metric 3D facial scan and writes
it out as **CAD-ready files in millimetres**, together with a landmark file, the
anatomical reference planes, and a measurement report.

Built for the full-arch workflow: face scan → landmark → reference planes → export →
register against the intraoral scan and the CBCT in your planning software.

---

## What it produces

Every export is a folder (zipped for AirDrop / Files / e-mail):

| File | What it is |
|---|---|
| `<case>.obj` + `.mtl` + `.jpg` | Textured mesh. The standard face-scan import for exocad Smile Creator and Full Denture. |
| `<case>.ply` | Same mesh, binary PLY with per-vertex colour, for 3Shape. |
| `<case>.stl` | Geometry only, for Blue Sky Plan / Nemotec / implant planning. |
| `<case>_reference-planes.stl` | Camper's, Frankfort, mid-sagittal and interpupillary planes as thin quads, in the same coordinate system as the face. |
| `landmarks.json` | Every landmark in mm, plane equations, measurements, quality figures, the frame transform. |
| `scan-report.txt` | The same numbers, readable. |
| `photos/` | Frontal, three-quarter and profile stills pulled from the sweep. |

Units are millimetres everywhere. The mesh, the planes and the landmarks share one
coordinate system, so they line up when imported together.

**Coordinate frame.** With both pupils placed, the export is rotated into a clinical
frame: origin on the facial midline at the interpupillary midpoint, **+X patient's
left, +Y superior (normal of the Frankfort horizontal), +Z anterior** — right-handed,
never mirrored. The 4×4 transform is written into `landmarks.json` so it is
reversible. Turn the option off to export in raw scanner coordinates instead.

## Measurements it computes

Interpupillary distance and cant · intercommissural width and cant · lip line versus
interpupillary line · bizygomatic width and the Berry-index central incisor width ·
alar width · lower and middle facial heights and their ratio (vertical dimension) ·
Camper's plane versus Frankfort horizontal · midline deviation of stomion, gnathion
and the dental midline.

## How it works

1. **Capture.** `ARFaceTrackingConfiguration` gives a head pose per frame and the
   TrueDepth depth map at ~15 Hz. Every depth sample is transformed into
   *face-anchor space*, so the operator arcs the phone around the patient and the
   frames land in register without any explicit stitching step.
2. **Fusion.** `TSDFVolume` walks a short band along each viewing ray and accumulates
   a truncated signed distance field plus colour, weighted by incidence angle and
   range. Grazing hits and depth discontinuities are rejected.
3. **Pose refinement.** ARKit's face pose jitters by around a millimetre, which would
   blur the fusion. Each frame is re-registered against the accumulated volume by a
   Gauss-Newton minimisation of the SDF itself (KinectFusion-style direct tracking),
   with the correction rejected if it exceeds a few millimetres.
4. **Reconstruction.** Marching *tetrahedra* over the volume — six tets per cell, four
   cases each — which cannot produce the ambiguous-face holes the marching-cubes table
   is known for. Then largest-component selection, Taubin λ/μ smoothing (which does not
   shrink the surface, unlike plain Laplacian), area-weighted normals, and a
   cylindrical unwrap.
5. **Texture.** The accumulated per-voxel colour is rasterised into a 2048² atlas over
   those UVs and written as a JPEG next to the OBJ.

## Building it

Requires a Mac with Xcode 16 or newer and an iPhone with a TrueDepth camera.

```
open face-scanner/ArchScan.xcodeproj
```

1. Select the **ArchScan** target → *Signing & Capabilities* → set your team. A free
   personal Apple ID works; change `PRODUCT_BUNDLE_IDENTIFIER` to something unique
   (e.g. `com.yourname.archscan`).
2. Pick your iPhone as the run destination and press Run. The Simulator cannot do
   face tracking.
3. On first launch, trust the developer certificate under
   *Settings → General → VPN & Device Management*.

The project uses Xcode's synchronised file groups, so new files added to the
`ArchScan/` folder are picked up without editing the project file.

## Scanning protocol

1. Patient upright, Frankfort horizontal roughly parallel to the floor, eyes on the lens.
2. Even, diffuse light from both sides. No hard shadow across the midline.
3. Phone in portrait, 30–35 cm away, front camera toward the patient.
4. Start front-on, arc slowly to the patient's right ear, back through centre, out to
   the left ear. Tilt up and down about 20° on the way so the brow and the chin are
   both seen.
5. The patient holds still and holds the expression. A swallow or a blink-driven
   expression change blurs the fusion.

The dial fills as yaw bins are covered; 110° of sweep is a complete scan.

### Capture types

`Rest` (vertical dimension reference) · `Full smile` (incisal display, smile line) ·
`Retracted` (the one that registers to the intraoral scan) · `Bite fork / scan flag` ·
`Prosthesis in` (compare lower facial height against rest) · `Post-op`.

### Registering to the intraoral scan

Use the retracted or prosthesis-in capture. Pick three widely separated points on the
visible teeth or on the scan flag, and the same three on the intraoral scan. A
rest-position capture shows no teeth and will not register reliably.

## Accuracy, and checking it

TrueDepth resolves roughly 0.5–1 mm on skin at 30 cm. That is enough for facial
reference planes, tooth-position aesthetics and soft-tissue context. It is not an
intraoral scanner and it is not CBCT — tooth surfaces and bone come from those.

The app has a **scale check** built in: place `Calibration A` and `Calibration B` on
the ends of a physical reference of known length (a printed sticker on the forehead, a
ruler, a marked bite fork), enter the true distance, and the app reports the error in
mm and per cent. It can apply a uniform correction to the export, and the uncorrected
error is still recorded in `landmarks.json` and the report. Do this before any scan
drives something irreversible. Interpupillary distance outside roughly 58–68 mm is the
other quick tell that something is wrong.

## Privacy

Scans stay in the app container with complete file protection, so they are unreadable
while the phone is locked. Nothing is uploaded; the only way data leaves is an export
you share yourself. Identify cases with a code rather than a patient name — the UI
nudges toward this, but it does not stop you.

## Regulatory status

Research and laboratory use. ArchScan is **not a medical device**, is not FDA-cleared
or CE-marked, and makes no diagnostic claim. Clinical decisions stay with the
clinician.
