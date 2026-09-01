"""Port of the smile-design measurements from ClinicalAnalysis.compute, run against a
synthetic case built with KNOWN deviations, in an arbitrarily rotated scanner frame.
Every assertion below is about the sign and magnitude a clinician would read."""
import numpy as np, math

def fit_plane(pts):
    pts=np.array(pts,float); c=pts.mean(0); r=pts-c
    xx,yy,zz=(r[:,0]**2).sum(),(r[:,1]**2).sum(),(r[:,2]**2).sum()
    xy,xz,yz=(r[:,0]*r[:,1]).sum(),(r[:,0]*r[:,2]).sum(),(r[:,1]*r[:,2]).sum()
    dX,dY,dZ=yy*zz-yz*yz, xx*zz-xz*xz, xx*yy-xy*xy
    dmax=max(dX,dY,dZ)
    if dmax==dX: n=np.array([dX, xz*yz-xy*zz, xy*yz-xz*yy])
    elif dmax==dY: n=np.array([xz*yz-xy*zz, dY, xy*xz-yz*xx])
    else: n=np.array([xy*yz-xz*yy, xy*xz-yz*xx, dZ])
    return c, n/np.linalg.norm(n)
def orth(v,a): r=v-a*np.dot(v,a); return r/np.linalg.norm(r)

# Truth, in anatomical coordinates: +X patient's left, +Y superior, +Z anterior (mm).
INCISAL_CANT_DEG = 3.0        # patient's LEFT central higher by 3 degrees
MIDLINE_SHIFT    = 2.0        # dental midline 2 mm to the patient's LEFT
INCISAL_DISPLAY  = 4.0        # incisal edge 4 mm below stomion at rest
GINGIVAL_DISPLAY = 2.0        # 2 mm of gingiva showing above the zeniths

half = 4.2                                  # half the inter-incisal-edge span
dy = half * math.tan(math.radians(INCISAL_CANT_DEG))
true = {
 "pupil_right":[-31,25,55], "pupil_left":[31,25,55],
 "orbitale_right":[-30,10,52], "orbitale_left":[30,10,52],
 "tragus_right":[-72,10,-35], "tragus_left":[72,10,-35],
 "glabella":[0,42,62], "nasion":[0,28,58], "pronasale":[0,2,86],
 "alare_right":[-17,-6,68], "alare_left":[17,-6,68], "subnasale":[0,-10,72],
 "cheilion_right":[-24,-31,58], "cheilion_left":[24,-31,58],
 "stomion":[0,-32,66], "gnathion":[0,-72,50],
 # dental: shifted left, canted left-side-up, 4 mm below stomion
 "incisal_midpoint":  [MIDLINE_SHIFT,        -32-INCISAL_DISPLAY,      70],
 "incisal_edge_right":[MIDLINE_SHIFT-half,   -32-INCISAL_DISPLAY-dy,   70],
 "incisal_edge_left": [MIDLINE_SHIFT+half,   -32-INCISAL_DISPLAY+dy,   70],
 "canine_tip_right":  [MIDLINE_SHIFT-14,     -32-INCISAL_DISPLAY+1.5,  66],
 "canine_tip_left":   [MIDLINE_SHIFT+14,     -32-INCISAL_DISPLAY+1.5,  66],
 # zeniths 10 mm above the edges; upper lip 2 mm above the zeniths => 2 mm gingival display
 "gingival_zenith_right":[MIDLINE_SHIFT-half, -32-INCISAL_DISPLAY-dy+10, 68],
 "gingival_zenith_left": [MIDLINE_SHIFT+half, -32-INCISAL_DISPLAY+dy+10, 68],
 "upper_lip_low_point":  [MIDLINE_SHIFT,      -32-INCISAL_DISPLAY+10+GINGIVAL_DISPLAY, 69],
 "lower_lip_midpoint":   [0,                  -32-9,                    64],
 "buccal_corridor_right":[-19,-31,56], "buccal_corridor_left":[19,-31,56],
}
# Rotate/translate into an arbitrary scanner frame (mm -> metres like the app).
ax=np.array([-0.4,0.6,0.7]); ax/=np.linalg.norm(ax); th=-0.75
K=np.array([[0,-ax[2],ax[1]],[ax[2],0,-ax[0]],[-ax[1],ax[0],0]])
R=np.eye(3)+math.sin(th)*K+(1-math.cos(th))*K@K
t=np.array([-0.05,0.08,0.27])
L={k: R@(np.array(v,float)/1000.0)+t for k,v in true.items()}

superior=(L["glabella"]-L["gnathion"]); superior/=np.linalg.norm(superior)
# vertical = Frankfort normal, exactly as the app now does it
_,fn=fit_plane([L["tragus_right"],L["tragus_left"],L["orbitale_right"],L["orbitale_left"]])
if np.dot(fn,superior)<0: fn=-fn
superior=fn
midline=[L[k] for k in ["glabella","nasion","pronasale","subnasale","stomion","gnathion"]]
sp,sn=fit_plane(midline)
if np.dot(sn,L["pupil_left"]-L["pupil_right"])<0: sn=-sn
sn=orth(sn,superior)
left_axis=sn

def cant(a,b):
    d=L[b]-L[a]; d/=np.linalg.norm(d)
    return math.degrees(math.asin(np.clip(np.dot(d,superior),-1,1)))

incisal_cant   = cant("incisal_edge_right","incisal_edge_left")
pupil_cant     = cant("pupil_right","pupil_left")
diverge        = incisal_cant - pupil_cant
gingival       = np.dot(L["upper_lip_low_point"]-(L["gingival_zenith_right"]+L["gingival_zenith_left"])/2, superior)*1000
display        = np.dot(L["stomion"]-L["incisal_midpoint"], superior)*1000
canine_mid     = (L["canine_tip_right"]+L["canine_tip_left"])/2
incisal_depth  = np.dot(canine_mid-L["incisal_midpoint"], superior)*1000
comm_mid       = (L["cheilion_right"]+L["cheilion_left"])/2
lip_depth      = np.dot(comm_mid-L["lower_lip_midpoint"], superior)*1000
midline_dev    = np.dot(L["incisal_midpoint"]-sp, sn)*1000
axis           = (L["gingival_zenith_right"]+L["gingival_zenith_left"])/2 - L["incisal_midpoint"]
angulation     = math.degrees(math.atan2(np.dot(axis,left_axis), np.dot(axis,superior)))
smile_w        = np.linalg.norm(L["cheilion_right"]-L["cheilion_left"])*1000
vis_w          = np.linalg.norm(L["buccal_corridor_right"]-L["buccal_corridor_left"])*1000
corridor_ratio = (smile_w-vis_w)/smile_w*100

def check(name, got, want, tol, meaning):
    ok = abs(got-want) <= tol
    print(f"{'OK ' if ok else 'BAD'} {name:34} {got:+8.3f}  expected {want:+7.3f}   {meaning}")
    return ok

print(f"(scanner frame is rotated {math.degrees(abs(th)):.0f}deg from anatomical; all figures recovered from landmarks alone)\n")
allok = all([
 check("incisal plane cant",      incisal_cant,  +3.0, 0.05, "positive = patient's LEFT central higher"),
 check("incisal vs interpupillary",diverge,      +3.0, 0.05, "eyes are level, so divergence = the cant"),
 check("incisal display at rest", display,       +4.0, 0.05, "positive = edge visible below the lip line"),
 check("gingival display",        gingival,      +2.0, 0.05, "positive = gingiva showing above the zeniths"),
 check("incisal curve depth",     incisal_depth, +1.5, 0.05, "positive = centrals hang below the canines"),
 check("lower lip curve depth",   lip_depth,    +10.0, 0.05, "positive = lip midline below the commissures"),
 check("dental midline deviation",midline_dev,   +2.0, 0.05, "positive = displaced to the patient's LEFT"),
 check("dental midline angulation",angulation,    0.0, 0.35, "crowns upright here, so ~0"),
 check("buccal corridor ratio",   corridor_ratio, (48-38)/48*100, 0.3, "10 mm of corridor on a 48 mm smile"),
])
print("\nALL SIGNS AND MAGNITUDES CORRECT" if allok else "\nSIGN ERROR PRESENT")
