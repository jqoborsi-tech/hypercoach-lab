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

**`test_clinical_frame.py`** — synthetic landmarks placed in a known anatomical pose,
rotated into an arbitrary scanner frame, then run through the frame construction. The
basis determinant is exactly +1 (**a −1 would mirror the scan**, which for a
prosthetic would be a catastrophe), the pupils land symmetric about x = 0, the midline
landmarks land on x = 0, superior and anterior come out the right way round, and the
interpupillary distance is preserved to the last digit.
