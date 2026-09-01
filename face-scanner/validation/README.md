# Geometry validation

The geometry that decides whether an ArchScan export is trustworthy — the iso-surface
extraction, the TSDF fusion and deprojection, and the clinical reference frame — is
ported line-for-line into these scripts and checked against analytic ground truth.
They are not the app; they are how the algorithms were verified independently of a
device.

```
python3 test_surface_extractor.py    # marching tetrahedra vs. an analytic sphere
python3 test_fusion_pipeline.py      # synthetic depth camera -> TSDF -> mesh (needs numpy)
python3 test_clinical_frame.py       # landmark -> reference frame (needs numpy)
python3 test_smile_design.py         # smile-design measurements, signs and magnitudes
python3 test_superimposition.py      # rigid alignment between captures
python3 test_icp_registration.py     # CBCT-to-intraoral registration, good and degenerate
python3 test_tooth_geometry.py       # the smile-design tooth series, drawn to a PNG
```

What they assert, and the results at the time of writing:

**`test_surface_extractor.py`** — a sphere meshed by the six-tetrahedra decomposition.
Every edge is shared by exactly two triangles, no directed edge repeats (consistent
winding), the signed volume is positive (outward-facing) and within 1.4 % of analytic
at a deliberately coarse 6-voxels-per-radius, and V − E + F = 2. This is why the app
uses marching tetrahedra instead of the marching-cubes table: no ambiguous-face holes,
and the winding falls out of the per-tetrahedron orientation without a repair pass.

**`test_fusion_pipeline.py`** — a 50 mm sphere rendered as z-depth from seven camera
poses through the same intrinsics, deprojected with `DepthFrame.deproject`'s exact
convention, fused by the ray-band TSDF update, and meshed:

```
reconstructed radius: mean 50.087 mm, sd 0.242 mm (truth 50.0)
diameter error       : +0.174 mm at a 2 mm voxel
winding              : outward
non-manifold edges   : 0 (1924 boundary edges, as expected for a partial sweep)
```

A sign error anywhere in the deprojection, the camera-to-face transform, or the
truncated-distance normalisation would show up here as a wrong radius or an inverted
surface. It does not.

**`test_smile_design.py`** — a synthetic case built with known deviations (3° incisal
cant with the patient's left side up, 2 mm dental midline shift to the left, 4 mm
incisal display, 2 mm gingival display, a 20.8 % buccal corridor), rotated 43° into an
arbitrary scanner frame, then measured from the landmarks alone. Every figure comes
back exact, with the sign a clinician would read.

This test earned its place: it caught a real defect. Vertical measurements were being
projected onto the glabella–gnathion axis, which leans with the profile, so part of any
anterior-posterior offset leaked into figures like incisal display — 3.56 mm reported
for a true 4.00 mm. The vertical reference is now the Frankfort normal, which is the
horizontal a cant is actually judged against, and the same case now reads 4.000 mm.

**`test_superimposition.py`** — recovers a known rigid transform from corresponding
landmarks via Horn's quaternion method: rotation to 4e-11, translation to 2 nanometres,
determinant exactly +1 (a reflection here would mirror one capture against another).
With 0.8 mm of simulated landmark-picking noise it degrades to a 1.27 mm RMS residual
and 0.7° of rotation error, which is the honest floor for how well two captures can be
superimposed by hand-placed points.

**`test_icp_registration.py`** — a synthetic dental arch with tooth-scale relief,
displaced by a known transform, with sensor noise, 15 % of the surface missing and a
scatter blob standing in for a restoration artefact. Two scenarios:

```
A. good picks, 85% overlap   -> 0.143 deg / 0.180 mm residual, RMS 0.052 mm, 78% inliers -> TRUSTED
B. clustered picks, 25% overlap -> no iterate meets the 40% inlier floor          -> REJECTED
```

This test caught the worst defect in the project. The first implementation reported a
**0.37 mm RMS on an alignment that was 25 mm wrong** — ICP had slid the arch along its
own smooth surface, and every residual it could see was tiny. A low RMS on a small
patch of surface proves nothing. The registration now has to satisfy three independent
conditions before it is offered as usable: close fit, at least 40 % of the surface
matched, and refinement that stayed near the operator's own point picks. It also keeps
the best iterate rather than the last, because ICP can slide downhill into a worse pose
while its residuals keep shrinking.

**`test_tooth_geometry.py`** — draws the tooth series and outlines to a PNG so the
arrangement can be looked at rather than reasoned about. It found two things reasoning
had missed: the tooth outlines crossed themselves on one side of the mouth (the
traversal order was driven by mesial/distal, which flips between sides), and continuing
the golden proportion past the canine produced 1.2 mm premolars. Both are fixed; the
proximal profile is now widest at the contact point rather than the middle, which is
what closes the interproximal wedges.

**`test_clinical_frame.py`** — synthetic landmarks placed in a known anatomical pose,
rotated into an arbitrary scanner frame, then run through the frame construction. The
basis determinant is exactly +1 (**a −1 would mirror the scan**, which for a
prosthetic would be a catastrophe), the pupils land symmetric about x = 0, the midline
landmarks land on x = 0, superior and anterior come out the right way round, and the
interpupillary distance is preserved to the last digit.
