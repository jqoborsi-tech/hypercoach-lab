# ArchScan — TrueDepth facial scanner for smile design and full-arch work

A native iOS app for the iPhone 15 Pro Max (any Face ID device works; the 15 Pro Max
is the reference) that fuses TrueDepth frames into a metric 3D facial scan and writes
it out as **CAD-ready files in millimetres**, with the landmark set, anatomical
reference planes, smile-design measurements, and the registration markers the
laboratory needs to merge it.

The chain this is built for: **face scan → intraoral scan → CBCT.** The intraoral scan
is the master; the CBCT registers to it; the face scan registers to it. ArchScan's job
is to arrive at the lab already carrying everything that merge needs.

---

## What it produces

Every export is a folder (zipped for AirDrop / Files / e-mail), all in **millimetres**:

| File | What it is |
|---|---|
| `<case>.obj` + `.mtl` + `.jpg` | Textured mesh. The standard face-scan import for exocad Smile Creator and Full Denture. |
| `<case>.ply` | Same mesh, binary PLY with per-vertex colour, for 3Shape. |
| `<case>.stl` | Geometry only, for Blue Sky Plan / Nemotec. |
| `<case>_reference-planes.stl` | Camper's, Frankfort, mid-sagittal, interpupillary and anterior occlusal planes as quads, in the same coordinates as the face. |
| `<case>_registration-points.obj` | The merge markers, **one named group per point** (`P1`, `P2`, …) so each keeps its identity in CAD. Also written as STL. |
| `landmarks.json` | Landmarks, registration points, plane equations, measurements, quality figures, the frame transform. |
| `scan-report.txt` | The same numbers, readable. |
| `LAB-HANDOFF.txt` | The merge order and what to align to what. Written for the technician. |
| `photos/` | Frontal, three-quarter and profile stills pulled from the sweep. |
| `photos/clinical/` | The full-resolution photograph series, if the clinician attached one. |

## Smile design

Place the dental landmarks — incisal edges of both centrals, canine tips, gingival
zeniths, the upper lip line at full smile, the lower lip curve, the buccal corridors —
and the app reports what the design is actually judged on:

- **Incisal plane cant against the interpupillary line.** The number the eye reads.
  Under about 1° is imperceptible; past 2–3° the set-up looks tipped even when every
  tooth is right.
- **Dental midline** deviation from the facial midline *and its angulation* — a canted
  midline is more noticeable than a displaced one.
- **Incisal display at rest** (measure it on the rest capture) and **gingival display
  at full smile**.
- **Smile arc against the lower lip** — the incisal curve depth minus the lip curve
  depth. Near zero is consonant; negative is the flattened, aged pattern a design
  usually sets out to correct.
- **Buccal corridor** as a share of smile width, and its left-right asymmetry.
- Clinical crown lengths, intercanine width, estimated central incisor width with the
  golden-proportion apparent widths for lateral and canine.
- Ricketts E-line for the upper and lower lip, if the profile points are placed.

Because everything is derived from a metric scan, these are measurements rather than
proportions read off a photograph.

### Superimposed captures

A smile design is a comparison — rest against smile, existing against proposed. Pick
one capture as the reference and every other capture in the case exports **in that
capture's coordinate frame**, fitted on upper-face landmarks (pupils, orbitale, tragi,
nasion, glabella, alae) that do not move between them. Lips, chin and teeth are
excluded from the fit, so what you see moving between the scans is real movement, not
registration error. The app shows the fit RMS before you export and warns above 1.5 mm.

## Merging with the intraoral scan and the CBCT

**Order matters, and it is in `LAB-HANDOFF.txt` with every export:**

1. **Intraoral scan is the master.** It is the most accurate object in the case, so
   everything moves onto it, never the reverse.
2. **CBCT to intraoral scan**, on the teeth or on radiographic markers. In a fully
   edentulous case use the appliance or fiducials — there is nothing on an edentulous
   ridge in a CBCT reliable enough to carry a prosthetic plan.
3. **Face scan to intraoral scan**, using the registration markers.

Do *not* register the face scan directly to the CBCT soft-tissue surface: the lips are
commonly distorted during a CBCT and that surface is not accurate enough to carry a
smile design.

### Why registration markers, and not just "align on the teeth"

Wet enamel scatters the infrared pattern the TrueDepth projector throws, so tooth
surfaces are the *noisiest* geometry in any structured-light face scan — and they are
exactly what you would otherwise be registering against. ArchScan handles this by
making the registration explicit:

- **Scan flag / bite fork (the reliable route, and the default).** Capture with the
  flag seated, put the markers on its corners or printed features. The flag is a rigid
  object of known geometry, so the lab aligns flag-to-flag instead of trusting the
  teeth.
- **Visible teeth.** Markers on incisal edges and canine cusp tips. Inspect those teeth
  in the mesh first — if they look soft or pitted, re-scan with a flag.
- **Custom.** Stickers, a jig, an appliance: anything present in both scans.

The points are picked by tapping the mesh, exported as named markers the technician can
snap to, and the export warns if there are fewer than three.

## Which iPhone 15 Pro Max hardware this uses, and which it does not

| Capability | Used | Why |
|---|---|---|
| TrueDepth projector + IR camera | **Yes**, native depth resolution, every frame at ~15 Hz | The only sensor on the phone that measures a face metrically. |
| Front RGB camera | **Yes**, at full sensor resolution, no downsampling | For smile design the texture is a deliverable — shade, incisal translucency, the gingival margin. Colour is weighted by the cube of the incidence angle so frontal, in-focus views dominate. |
| ARKit face tracking | **Yes** | Head pose per frame, which is what lets the operator move instead of the patient. |
| A17 Pro | **Yes** | Fusion and per-frame pose refinement run in real time on it. |
| LiDAR (rear) | **No, deliberately** | 256×192 at roughly centimetre accuracy — an order of magnitude coarser than TrueDepth on a face. Including it would make the scan worse, not better. |
| 48 MP main camera | **Not for geometry or texture** | It cannot be registered to a TrueDepth scan without a manual pose solve, which would inject error into the one thing that has to stay metric. Use it in the Camera app for the clinical photograph series and attach those shots to the case — they export alongside the scan. |
| Neural Engine | **No** | Nothing in the pipeline is a learned model; it is all measurement and geometry. |

## How it works

1. **Capture.** `ARFaceTrackingConfiguration` gives a head pose per frame and the
   TrueDepth map at ~15 Hz. Every depth sample is transformed into *face-anchor space*,
   so the operator arcs the phone around the patient and the frames land in register
   without any stitching step.
2. **Fusion.** A truncated signed distance volume, updated along a short band on each
   viewing ray, weighted by incidence angle and range. Grazing hits and depth
   discontinuities are rejected.
3. **Pose refinement.** ARKit's face pose jitters by around a millimetre, which would
   blur the fusion. Each frame is re-registered against the accumulated volume by
   Gauss-Newton minimisation of the SDF itself, with the correction rejected if it
   exceeds a few millimetres.
4. **Reconstruction.** Marching *tetrahedra* — six tets per cell, four cases each —
   which cannot produce the ambiguous-face holes the marching-cubes table is known for.
   Then largest-component selection, Taubin λ/μ smoothing (which does not shrink the
   surface, unlike plain Laplacian), area-weighted normals, cylindrical unwrap.
5. **Texture.** The accumulated colour is rasterised into a 4096² atlas over those UVs,
   bled outward along the coverage frontier so bilinear filtering in CAD cannot pull
   background across a triangle edge, and written as a JPEG next to the OBJ.

## Building it

Requires a Mac with Xcode 16 or newer and an iPhone with a TrueDepth camera.

```
open face-scanner/ArchScan.xcodeproj
```

1. Select the **ArchScan** target → *Signing & Capabilities* → set your team. A free
   personal Apple ID works; change `PRODUCT_BUNDLE_IDENTIFIER` to something unique.
2. Pick your iPhone as the run destination and press Run. The Simulator cannot do face
   tracking.
3. On first launch, trust the developer certificate under
   *Settings → General → VPN & Device Management*.

The project uses Xcode's synchronised file groups, so files added to `ArchScan/` are
picked up without editing the project file.

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

`Rest` (vertical dimension, incisal display at rest) · `Full smile` (lip line, gingival
display, smile arc) · `Retracted` (registers to the intraoral scan) · `Bite fork / scan
flag` · `Prosthesis in` · `Post-op`.

## Accuracy, and checking it

TrueDepth resolves roughly 0.5–1 mm on skin at 30 cm. That is enough for facial
reference planes, tooth-position aesthetics and soft-tissue context. It is not an
intraoral scanner and it is not CBCT — tooth surfaces and bone come from those, which
is the whole point of the merge.

The app has a **scale check** built in: place `Calibration A` and `Calibration B` on the
ends of a physical reference of known length, enter the true distance, and it reports
the error in mm and per cent. It can apply a uniform correction to the export, and the
uncorrected error stays in `landmarks.json` and the report. Do this before any scan
drives something irreversible. Interpupillary distance outside roughly 58–68 mm is the
other quick tell that something is wrong.

## Privacy

Scans stay in the app container with complete file protection, unreadable while the
phone is locked. Nothing is uploaded; the only way data leaves is an export you share.
Identify cases with a code rather than a patient name.

## Regulatory status

Research and laboratory use. ArchScan is **not a medical device**, is not FDA-cleared or
CE-marked, and makes no diagnostic claim. Clinical decisions stay with the clinician.
