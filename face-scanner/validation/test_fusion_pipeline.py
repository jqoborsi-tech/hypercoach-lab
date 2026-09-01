"""End-to-end port of DepthFrame.deproject + TSDFVolume.integrate + SurfaceExtractor,
run against a synthetic sphere of known size seen from several camera poses.
If the sign conventions or the deprojection were wrong, the reconstructed diameter
would not match the truth."""
import numpy as np, math
from collections import defaultdict

TRUE_R = 0.050                      # 50 mm sphere, in metres like the app
CENTRE = np.array([0.0, 0.0, 0.0])
VS = 0.002                          # 2 mm voxels
TRUNC = VS * 3.5
LO = np.array([-0.09,-0.09,-0.09]); HI = np.array([0.09,0.09,0.09])
N = np.ceil((HI-LO)/VS).astype(int); nx,ny,nz = map(int,N)
sdf = np.zeros(nx*ny*nz, np.float32); wgt = np.zeros(nx*ny*nz, np.float32)

W=H=140; FX=FY=180.0; CX=CY=70.0

def look_at(eye, target):
    """ARKit-style camera basis: +x right, +y up, +z toward the viewer (camera looks -z)."""
    z = eye-target; z/=np.linalg.norm(z)
    x = np.cross(np.array([0,1.0,0]), z); x/=np.linalg.norm(x)
    y = np.cross(z,x)
    T=np.eye(4); T[:3,0]=x; T[:3,1]=y; T[:3,2]=z; T[:3,3]=eye
    return T

def render_and_integrate(cam_to_face):
    R=cam_to_face[:3,:3]; o=cam_to_face[:3,3]
    xs,ys=np.meshgrid(np.arange(W),np.arange(H))
    u=(xs+0.5-CX)/FX; v=(ys+0.5-CY)/FY
    dir_cam=np.stack([u,-v,-np.ones_like(u)],-1)
    dir_cam/=np.linalg.norm(dir_cam,axis=-1,keepdims=True)
    dir_face=dir_cam@R.T
    oc=o-CENTRE
    b=2*(dir_face@oc); c=oc@oc-TRUE_R**2
    disc=b*b-4*c
    hit=disc>0
    t=np.full_like(b,np.nan)
    t[hit]=(-b[hit]-np.sqrt(disc[hit]))/2
    hit &= (t>0)
    # z-depth in the camera frame, exactly what AVDepthData reports
    hit_cam=dir_cam*t[...,None]
    depth=np.where(hit,-hit_cam[...,2],0.0)

    # ---- deproject exactly as DepthFrame.deproject does -------------------
    valid=depth>0.05
    d=depth[valid]
    xc=(xs[valid]+0.5-CX)*d/FX; yc=(ys[valid]+0.5-CY)*d/FY
    p_cam=np.stack([xc,-yc,-d],-1)
    surface=p_cam@R.T+o
    ray=surface-o; ray/=np.linalg.norm(ray,axis=1,keepdims=True)

    step=VS*0.7; steps=int(math.ceil(TRUNC/step))
    for s in range(-steps,steps+1):
        along=s*step
        q=surface+ray*along
        g=(q-LO)/VS
        ok=np.all((g>=0)&(g<np.array([nx,ny,nz])),axis=1)
        gi=g[ok].astype(int)
        idx=(gi[:,2]*ny+gi[:,1])*nx+gi[:,0]
        value=np.clip(-along/TRUNC,-1,1)
        w=1.0
        old=wgt[idx]; new=old+w
        # weighted running average, same update rule as the app
        np.add.at(sdf,idx,0)                       # force index materialisation
        sdf[idx]=(sdf[idx]*old+value*w)/new
        wgt[idx]=new

for angle in [-60,-30,0,30,60]:
    a=math.radians(angle)
    eye=CENTRE+np.array([math.sin(a)*0.30, 0.0, math.cos(a)*0.30])
    render_and_integrate(look_at(eye,CENTRE))
for angle in [-25,25]:
    a=math.radians(angle)
    eye=CENTRE+np.array([0.0, math.sin(a)*0.30, math.cos(a)*0.30])
    render_and_integrate(look_at(eye,CENTRE))

# ---- extract with the marching-tetrahedra port -------------------------
TETS=[[0,7,1,3],[0,7,3,2],[0,7,2,6],[0,7,6,4],[0,7,4,5],[0,7,5,1]]
CORN=[(0,0,0),(1,0,0),(0,1,0),(1,1,0),(0,0,1),(1,0,1),(0,1,1),(1,1,1)]
sdf3=sdf.reshape(nz,ny,nx); w3=wgt.reshape(nz,ny,nx)
positions=[]; indices=[]; vmap={}
def emit(tet,values,pos,cid):
    inside=[c for c in tet if values[c]<0]; outside=[c for c in tet if values[c]>=0]
    if not inside or not outside: return
    ic=np.mean([pos[c] for c in inside],axis=0)
    def vertex(a,b):
        ia,ib=cid[a],cid[b]; key=(ia,ib) if ia<ib else (ib,ia)
        if key in vmap: return vmap[key]
        fa,fb=values[a],values[b]; t=fa/(fa-fb) if fa!=fb else .5; t=max(0,min(1,t))
        p=pos[a]+(pos[b]-pos[a])*t; idx=len(positions); positions.append(p); vmap[key]=idx; return idx
    def tri(i0,i1,i2):
        a,b,c=positions[i0],positions[i1],positions[i2]
        n=np.cross(b-a,c-a)
        if np.dot(n,(a+b+c)/3-ic)>=0: indices.extend([i0,i1,i2])
        else: indices.extend([i0,i2,i1])
    if len(inside)==1:
        a=inside[0]; tri(vertex(a,outside[0]),vertex(a,outside[1]),vertex(a,outside[2]))
    elif len(inside)==3:
        a=outside[0]; tri(vertex(a,inside[0]),vertex(a,inside[1]),vertex(a,inside[2]))
    else:
        v0=vertex(inside[0],outside[0]); v1=vertex(inside[0],outside[1])
        v2=vertex(inside[1],outside[1]); v3=vertex(inside[1],outside[0])
        tri(v0,v1,v2); tri(v0,v2,v3)

MINW=0.5
for k in range(nz-1):
    for j in range(ny-1):
        for i in range(nx-1):
            if w3[k,j,i]<MINW: continue
            vals=[];pos=[];cid=[];neg=0;ok=True
            for c in range(8):
                o=CORN[c]; ci,cj,ck=i+o[0],j+o[1],k+o[2]
                if w3[ck,cj,ci]<MINW: ok=False;break
                val=sdf3[ck,cj,ci]*TRUNC
                vals.append(val)
                pos.append(LO+(np.array([ci,cj,ck])+0.5)*VS)
                cid.append((ck*ny+cj)*nx+ci)
                if val<0: neg+=1
            if not ok or neg==0 or neg==8: continue
            for t in TETS: emit(t,vals,pos,cid)

P=np.array(positions)
radii=np.linalg.norm(P-CENTRE,axis=1)
tris=len(indices)//3
vol=0.0
for t in range(tris):
    a,b,c=[positions[indices[3*t+m]] for m in range(3)]
    vol+=np.dot(a,np.cross(b,c))/6
edge=defaultdict(int)
for t in range(tris):
    a,b,c=indices[3*t],indices[3*t+1],indices[3*t+2]
    for (x,y) in ((a,b),(b,c),(c,a)): edge[(x,y) if x<y else (y,x)]+=1

print(f"vertices={len(P)}  triangles={tris}")
print(f"reconstructed radius: mean={radii.mean()*1000:.3f} mm  sd={radii.std()*1000:.3f} mm  (truth {TRUE_R*1000:.1f} mm)")
print(f"diameter error: {(radii.mean()-TRUE_R)*2000:+.3f} mm")
print(f"signed volume sign (must be positive = outward winding): {vol:+.3e}")
print(f"non-manifold edges (should be 0): {sum(1 for e,n in edge.items() if n!=2)}")
