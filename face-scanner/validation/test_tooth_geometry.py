"""Port of SmileDesignParameters.teeth() and SmileRenderer.toothOutline(), drawn to a
PNG so the arrangement can actually be looked at before it ships."""
import math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

CENTRAL_W = 8.6
W_TO_L = 0.80
ARC_DEPTH = 1.2
EMBRASURE = 0.018
INCLUDE_CANINES = True
INCLUDE_PREMOLARS = True

def teeth():
    central = CENTRAL_W
    lateral = central*0.618
    canine = lateral*0.618
    # The golden ratio describes central:lateral:canine. Continuing it past the canine
    # gives 1.2 mm premolars, which no mouth has; posteriors foreshorten more gently.
    p1 = canine*0.75
    p2 = p1*0.72
    widths = [("central",central,False,False), ("lateral",lateral,False,False)]
    if INCLUDE_CANINES: widths.append(("canine",canine,True,False))
    if INCLUDE_PREMOLARS:
        widths.append(("first premolar",p1,False,True))
        widths.append(("second premolar",p2,False,True))
    lengths = {"central":central/W_TO_L, "lateral":central/W_TO_L*0.86, "canine":central/W_TO_L*0.96,
               "first premolar":central/W_TO_L*0.72, "second premolar":central/W_TO_L*0.64}
    gap = central*EMBRASURE
    cum=0.0; offs=[]
    for _,w,_,_ in widths:
        offs.append(cum+w/2); cum += w+gap
    half=max(cum,1)
    out=[]
    for side in (-1.0,1.0):
        for i,(name,w,is_can,is_post) in enumerate(widths):
            cx=side*offs[i]
            nrm=abs(cx)/half
            out.append(dict(name=name,width=w,length=lengths[name],cx=cx,
                            edge_y=-ARC_DEPTH*nrm*nrm,canine=is_can,post=is_post))
    return sorted(out,key=lambda t:t["cx"]), half

def half_width_at(hw, u):
    """u = 0 at the incisal edge, 1 at the gingival margin. The tooth is widest at the
    contact point, about a third of the way up, not at its middle."""
    if u <= 0.30:
        return hw*(0.94 + (1.00-0.94)*(u/0.30))
    return hw*(1.00 + (0.87-1.00)*((u-0.30)/0.70))

def outline(t):
    """Anticlockwise-consistent loop: incisal edge left to right, up the right side,
    gingival right to left, down the left side. Mesial/distal only decides which corner
    is rounder and where the zenith sits — never the traversal order, which is what
    made the outline cross itself."""
    hw=t["width"]/2
    gy=t["edge_y"]-t["length"]
    ms = 1.0 if t["cx"]<0 else -1.0          # +1 when mesial is toward +x
    zx = t["cx"] - ms*t["width"]*0.10
    scallop = 0.25 if t["post"] else 0.55
    ih = half_width_at(hw, 0.0)

    def edge_y_at(x):
        if t["canine"]:
            # A real canine cusp is a low point, not a fang: about half a millimetre,
            # with a shorter mesial slope than distal.
            cusp = t["cx"] + ms*t["width"]*0.10
            d = (x-cusp)/max(ih,1e-3)
            slope = 0.62 if d*ms > 0 else 1.0
            return t["edge_y"] - abs(d)*slope*0.75
        if t["post"]:
            return t["edge_y"] - t["length"]*0.10*(1-4*((x-t["cx"])/t["width"])**2)
        e=(x-t["cx"])/hw
        corner = 0.42 if e*ms>0 else 0.72     # the distal corner is the rounder one
        return t["edge_y"] - (abs(e)**4)*corner

    pts=[]
    for s_ in range(17):                      # incisal edge, left to right
        x = t["cx"]-ih + 2*ih*(s_/16)
        pts.append((x, edge_y_at(x)))
    for s_ in range(1,13):                    # right proximal, incisal to gingival
        u=s_/12
        pts.append((t["cx"]+half_width_at(hw,u), t["edge_y"]+(gy-t["edge_y"])*u))
    for s_ in range(13):                      # gingival margin, right to left
        u=s_/12
        x = t["cx"]+half_width_at(hw,1.0) - 2*half_width_at(hw,1.0)*u
        f=(x-zx)/max(t["width"],1e-3)
        pts.append((x, gy-max(0, scallop*(1-4*f*f))))
    for s_ in range(1,12):                    # left proximal, gingival back to incisal
        u=1.0-s_/12
        pts.append((t["cx"]-half_width_at(hw,u), t["edge_y"]+(gy-t["edge_y"])*u))
    return pts

ts,half = teeth()
fig,ax=plt.subplots(figsize=(11,4.2),dpi=110)
ax.set_facecolor("#1a0d0d")
for t in ts:
    p=outline(t)
    shade = "#eeeadf" if not t["post"] else "#b9b3a6"
    if t["canine"]: shade="#e6e0d2"
    ax.add_patch(Polygon(p, closed=True, facecolor=shade, edgecolor="#5a4a3f", linewidth=0.8))
# reference lines
ax.axhline(0, color="#4fb477", lw=0.8, ls="--", label="incisal reference (midline)")
ax.axvline(0, color="#6aa3d9", lw=0.8, ls="--", label="facial midline")
xs=[t["cx"] for t in ts]
ax.plot(xs,[t["edge_y"] for t in ts],"o-",color="#d9942b",ms=3,lw=1,label="smile arc (incisal edges)")
ax.set_xlim(-half-3, half+3); ax.set_ylim(-14, 4)
ax.invert_yaxis(); ax.set_aspect("equal")
ax.set_xlabel("mm from facial midline    (patient's right ← → patient's left)")
ax.set_ylabel("mm")
ax.legend(loc="lower right", fontsize=7)
ax.set_title(f"ArchScan tooth series — central {CENTRAL_W} mm, W:L {W_TO_L}, arc {ARC_DEPTH} mm")
plt.tight_layout(); plt.savefig("/tmp/claude-0/-home-user-hypercoach-lab/69f805ef-44b0-504f-ae00-a11563b1fc24/scratchpad/smile_geom.png")

print(f"{'tooth':17} {'width':>6} {'length':>7} {'centre x':>9} {'edge y':>7}")
for t in ts:
    print(f"{t['name']:17} {t['width']:6.2f} {t['length']:7.2f} {t['cx']:9.2f} {t['edge_y']:7.2f}")
print()
print(f"canine-to-canine span : {2*max(abs(t['cx'])+t['width']/2 for t in ts if t['canine']):.1f} mm")
print(f"full span (to 2nd PM) : {2*max(abs(t['cx'])+t['width']/2 for t in ts):.1f} mm")
print(f"central W:L           : {CENTRAL_W/(CENTRAL_W/W_TO_L):.3f}")
