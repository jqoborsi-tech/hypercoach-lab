"""Port of ClinicalAnalysis's frame construction, on synthetic landmarks placed in a
known anatomical pose, to confirm the export is oriented and NOT mirrored."""
import numpy as np

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

def orth(v,axis):
    r=v-axis*np.dot(v,axis); return r/np.linalg.norm(r)

# Synthetic head, deliberately tipped and rolled so the maths has to do real work.
# Anatomical truth: patient's left = +X, superior = +Y, anterior = +Z in "true" space.
true={
 "pupil_right":[-31,25,55],"pupil_left":[31,25,55],
 "orbitale_right":[-30,10,52],"orbitale_left":[30,10,52],
 "tragus_right":[-72,12,-35],"tragus_left":[72,12,-35],
 "glabella":[0,42,62],"nasion":[0,28,58],"pronasale":[0,2,86],
 "alare_right":[-17,-6,68],"alare_left":[17,-6,68],
 "subnasale":[0,-10,72],"stomion":[0,-32,66],"gnathion":[0,-72,50],
 "cheilion_right":[-24,-31,58],"cheilion_left":[24,-31,58],
}
# Rotate + translate into an arbitrary "scanner" frame.
ax=np.array([0.3,0.8,0.5]); ax/=np.linalg.norm(ax); th=0.9
K=np.array([[0,-ax[2],ax[1]],[ax[2],0,-ax[0]],[-ax[1],ax[0],0]])
Rr=np.eye(3)+np.sin(th)*K+(1-np.cos(th))*K@K
t=np.array([13.0,-40.0,220.0])
L={k: Rr@np.array(v,float)+t for k,v in true.items()}

midline=[L[k] for k in ["glabella","nasion","pronasale","subnasale","stomion","gnathion"]]
superior=(L["glabella"]-L["gnathion"]); superior/=np.linalg.norm(superior)

sp,sn=fit_plane(midline)
if np.dot(sn, L["pupil_left"]-L["pupil_right"])<0: sn=-sn
sn=orth(sn,superior)

fp,fn=fit_plane([L["tragus_right"],L["tragus_left"],L["orbitale_right"],L["orbitale_left"]])
if np.dot(fn,superior)<0: fn=-fn

up=fn
left=orth(L["pupil_left"]-L["pupil_right"], up)
anterior=np.cross(left,up)
origin=(L["pupil_left"]+L["pupil_right"])/2
origin=origin-sn*np.dot(origin-sp,sn)

Rf=np.column_stack([left,up,anterior])
print("determinant of the basis (must be +1, a -1 would mirror the scan):", round(np.linalg.det(Rf),6))
T=Rf.T
out={k: T@(v-origin) for k,v in L.items()}

def show(k): 
    p=out[k]; return f"{k:16} x={p[0]:7.2f} y={p[1]:7.2f} z={p[2]:7.2f}"
for k in ["pupil_right","pupil_left","gnathion","pronasale","tragus_right","tragus_left","stomion","glabella"]:
    print(show(k))
print()
print("checks")
print(" pupils symmetric about x=0:", round(out['pupil_right'][0]+out['pupil_left'][0],4))
print(" midline points near x=0   :", [round(out[k][0],2) for k in ['glabella','nasion','subnasale','stomion','gnathion']])
print(" gnathion below glabella   :", out['gnathion'][1] < out['glabella'][1])
print(" nose anterior to tragi    :", out['pronasale'][2] > out['tragus_right'][2])
print(" pupil_left is +X (patient's left):", out['pupil_left'][0] > 0)
d=np.linalg.norm(out['pupil_left']-out['pupil_right'])
print(f" interpupillary distance preserved: {d:.2f} mm (input 62.00)")
