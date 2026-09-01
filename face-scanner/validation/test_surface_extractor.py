"""Port of SurfaceExtractor.emit / extract, run against an analytic sphere SDF.
Checks: manifoldness, outward winding, and radial accuracy."""
import math
from collections import defaultdict

TETS = [[0,7,1,3],[0,7,3,2],[0,7,2,6],[0,7,6,4],[0,7,4,5],[0,7,5,1]]
CORNERS = [(0,0,0),(1,0,0),(0,1,0),(1,1,0),(0,0,1),(1,0,1),(0,1,1),(1,1,1)]

N = 24
VS = 1.0/ N * 4.0            # voxel size
ORIGIN = (-2.0,-2.0,-2.0)
R = 1.0

def centre(i,j,k):
    return (ORIGIN[0]+(i+0.5)*VS, ORIGIN[1]+(j+0.5)*VS, ORIGIN[2]+(k+0.5)*VS)

def sdf(p):                  # negative inside, positive outside — same convention as the app
    return math.sqrt(p[0]**2+p[1]**2+p[2]**2) - R

nx = ny = nz = N
positions=[]; indices=[]; vmap={}

def emit(tet, values, pos, cellidx):
    inside=[c for c in tet if values[c] < 0]
    outside=[c for c in tet if values[c] >= 0]
    if not inside or not outside: return
    ic=[0,0,0]
    for c in inside:
        for k in range(3): ic[k]+=pos[c][k]
    ic=[x/len(inside) for x in ic]

    def vertex(a,b):
        ia,ib=cellidx[a],cellidx[b]
        key=(ia,ib) if ia<ib else (ib,ia)
        if key in vmap: return vmap[key]
        fa,fb=values[a],values[b]
        t = fa/(fa-fb) if fa!=fb else 0.5
        t=max(0.0,min(1.0,t))
        p=tuple(pos[a][k]+(pos[b][k]-pos[a][k])*t for k in range(3))
        idx=len(positions); positions.append(p); vmap[key]=idx
        return idx

    def tri(i0,i1,i2):
        a,b,c=positions[i0],positions[i1],positions[i2]
        e1=[b[k]-a[k] for k in range(3)]; e2=[c[k]-a[k] for k in range(3)]
        n=[e1[1]*e2[2]-e1[2]*e2[1], e1[2]*e2[0]-e1[0]*e2[2], e1[0]*e2[1]-e1[1]*e2[0]]
        cen=[(a[k]+b[k]+c[k])/3-ic[k] for k in range(3)]
        if sum(n[k]*cen[k] for k in range(3))>=0: indices.extend([i0,i1,i2])
        else: indices.extend([i0,i2,i1])

    if len(inside)==1:
        a=inside[0]; tri(vertex(a,outside[0]),vertex(a,outside[1]),vertex(a,outside[2]))
    elif len(inside)==3:
        a=outside[0]; tri(vertex(a,inside[0]),vertex(a,inside[1]),vertex(a,inside[2]))
    else:
        v0=vertex(inside[0],outside[0]); v1=vertex(inside[0],outside[1])
        v2=vertex(inside[1],outside[1]); v3=vertex(inside[1],outside[0])
        tri(v0,v1,v2); tri(v0,v2,v3)

for k in range(nz-1):
    for j in range(ny-1):
        for i in range(nx-1):
            vals=[]; pos=[]; cid=[]
            neg=0
            for c in range(8):
                o=CORNERS[c]; ci,cj,ck=i+o[0],j+o[1],k+o[2]
                p=centre(ci,cj,ck); v=sdf(p)
                vals.append(v); pos.append(p); cid.append((ck*ny+cj)*nx+ci)
                if v<0: neg+=1
            if neg==0 or neg==8: continue
            for t in TETS: emit(t,vals,pos,cid)

# --- checks -------------------------------------------------------------
tris=len(indices)//3
edge=defaultdict(int)
for t in range(tris):
    a,b,c=indices[3*t],indices[3*t+1],indices[3*t+2]
    for (u,v) in ((a,b),(b,c),(c,a)):
        edge[(u,v) if u<v else (v,u)]+=1
counts=defaultdict(int)
for e,n in edge.items(): counts[n]+=1

vol=0.0
for t in range(tris):
    a,b,c=[positions[indices[3*t+m]] for m in range(3)]
    vol += (a[0]*(b[1]*c[2]-b[2]*c[1]) - a[1]*(b[0]*c[2]-b[2]*c[0]) + a[2]*(b[0]*c[1]-b[1]*c[0]))/6.0

# consistent orientation: every directed edge used at most once
directed=defaultdict(int)
for t in range(tris):
    a,b,c=indices[3*t],indices[3*t+1],indices[3*t+2]
    for e in ((a,b),(b,c),(c,a)): directed[e]+=1
bad_dir=sum(1 for e,n in directed.items() if n>1)

radii=[math.sqrt(p[0]**2+p[1]**2+p[2]**2) for p in positions]
print(f"vertices={len(positions)} triangles={tris}")
print(f"edge incidence histogram (should be all 2): {dict(counts)}")
print(f"directed edges used more than once (should be 0): {bad_dir}")
print(f"signed volume={vol:.5f}  analytic={4/3*math.pi*R**3:.5f}  ratio={vol/(4/3*math.pi*R**3):.4f}")
print(f"radius min={min(radii):.4f} max={max(radii):.4f} mean={sum(radii)/len(radii):.4f} (target {R})")
