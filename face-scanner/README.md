# ArchScan — records collector for All-on-X and full-mouth rehabilitation

A native iOS app for the iPhone 15 Pro Max (any Face ID device works; the 15 Pro Max is
the reference) that collects the complete record set a full-arch case needs, captures a
metric 3D facial scan, imports the intraoral scan and the CBCT, registers them, and
builds a smile design over a photograph.

The chain it is built for: **face scan → intraoral scan → CBCT.** The intraoral scan is
the master; the CBCT registers to it; the face scan registers to it. ArchScan's job is
to arrive at the laboratory already carrying everything that merge needs.

## What it collects

A case is a checklist, not a folder. The screen shows what is still missing, and eleven
records are marked essential — without them a full-arch plan cannot responsibly start.

| Group | Records |
|---|---|
| Extraoral photos | Rest, full smile, retracted, both profiles, both three-quarters, 12 o'clock |
| Intraoral photos | Retracted frontal, both buccals, both occlusals, overjet/overbite |
| Video | Dynamic smile, phonetics ("Emma", "fifty-five", "Mississippi"), profile in function |
| Scans | Facial scan (captured here), intraoral upper/lower/bite (imported), CBCT (imported) |
| Notes | Shade, jaw relation, existing prosthesis |

Photos and video are shot through the system camera — the 48 MP main sensor and the 5×
telephoto for retracted views — rather than a worse capture UI rebuilt inside the app.

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

## Smile design from a photograph

Choose a full-smile photograph, place six marks — both pupils, the facial midline, the
incisal edge level, both commissures — trace the lip opening, and the app lays a tooth
series over it: golden-proportion apparent widths, a smile arc fitted to the corners of
the mouth, a scalloped gingival margin, and a cervical-to-incisal shade gradient with
incisal translucency.

**It is parametric, not generative.** Every tooth position comes from a measurable rule,
so the picture and the numbers handed to the lab are the same object, and moving a
slider changes something the laboratory can actually build. That is a different thing
from an AI render that produces a convincing image nobody can reproduce. See
[Generative alternatives](#generative-alternatives) below for what the other approach
would cost.

If the case has a facial scan with the pupils marked, the design borrows the **measured
interpupillary distance**, which is what turns a photograph into something metric —
every millimetre in the design is then real rather than assumed. Without a scan it
falls back to a 63 mm population average and says so, in amber.

Every render carries a **SIMULATION — NOT A CLINICAL OUTCOME** watermark that cannot be
switched off. A patient shown a rendered smile remembers it as a promise.

### Generative alternatives

An image-to-image model would produce something closer to a photograph than a
parametric render does. It is not built in, for two reasons worth stating plainly:
the patient's photograph would have to leave the device for a third-party server, which
for clinical records is a decision only the practice can make; and the output is a
plausible image rather than a plan — nothing about it constrains what the lab then
builds. The renderer is a separate, swappable stage, so wiring a cloud backend in later
is a contained change if you decide the trade is worth it.

## Facial measurements

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

## Importing and registering the CBCT

Export the CBCT as **uncompressed DICOM** and import the folder. The reader handles
Part 10 files and bare datasets, explicit and implicit VR little endian. A compressed
transfer syntax is reported as unsupported rather than decoded into something
plausible-looking — a silently wrong CBCT is far worse than one that refuses to load.

A full series is commonly 600–800 cubed at 16 bits, which is more than a phone should
hold, so the working volume is subsampled to fit while the original files stay
untouched on disk. Pick a threshold — enamel, bone, soft tissue — and the same marching
tetrahedra used for the facial scan extract a surface from it.

**Registration is three picked point pairs, then ICP refinement.** Fully automatic
registration is not attempted, and that is deliberate: on a CBCT with restorations,
scatter makes it fail quietly. The result is offered as usable only when three
independent conditions hold — a close fit, at least 40 % of the surface matched, and
refinement that stayed near the points you picked. A low RMS alone means nothing; a
small patch of surface can always find somewhere comfortable to sit. During development
this exact failure produced a 0.37 mm RMS on an alignment that was 25 mm wrong.

Import notes: the DICOM headers carry the patient's name, identifier and date of birth.
The series stays on the device and is **excluded from exports by default**; the derived
surfaces, the registration matrix and the geometry go instead.

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
| 48 MP main camera + 5× telephoto | **Yes, for the photo and video records** | Not for scan geometry or texture: it cannot be registered to a TrueDepth scan without a manual pose solve, which would inject error into the one thing that has to stay metric. The records screen shoots through the system camera so the full sensor and the telephoto are available for retracted and occlusal views. |
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
