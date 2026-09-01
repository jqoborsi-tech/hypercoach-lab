# hypercoach-lab

A small lab of self-contained apps.

| Path | What it is |
|---|---|
| `index.html` | HYPERCOACH V2 — hypertrophy training coach (web app). |
| `poker-coach/` | Poker coach (web app). |
| `face-scanner/` | **ArchScan** — native iOS records collector for All-on-X and full-mouth rehabilitation. Photo and video record checklist, TrueDepth facial scanning, intraoral scan and CBCT import with registration, and parametric smile design over a photograph. Exports OBJ/PLY/STL in millimetres with landmarks, reference planes and the markers the lab merges against. See [`face-scanner/README.md`](face-scanner/README.md). |
| `face-scan/` | ArchScan Viewer — browser viewer for those exports. Reads OBJ/PLY/STL plus `landmarks.json`, checks the scale, and shows the landmarks and registration markers. Everything stays local. |

ArchScan is for research and laboratory use. It is not a medical device.
