"""Port of Superimposition.rigidTransform + dominantEigenvector4.
Recovers a known rigid transform from corresponding points."""
import math, random
import numpy as np

def dominant_eig4(inp):
    a=list(inp); v=[0.0]*16
    for i in range(4): v[i*4+i]=1.0
    for _ in range(64):
        off=sum(a[p*4+q]**2 for p in range(4) for q in range(p+1,4))
        if off<1e-18: break
        for p in range(4):
            for q in range(p+1,4):
                apq=a[p*4+q]
                if abs(apq)<1e-20: continue
                theta=(a[q*4+q]-a[p*4+p])/(2*apq)
                t=(1.0 if theta>=0 else -1.0)/(abs(theta)+math.sqrt(theta*theta+1))
                c=1/math.sqrt(t*t+1); s=t*c
                for k in range(4):
                    akp,akq=a[k*4+p],a[k*4+q]
                    a[k*4+p]=c*akp-s*akq; a[k*4+q]=s*akp+c*akq
                for k in range(4):
                    apk,aqk=a[p*4+k],a[q*4+k]
                    a[p*4+k]=c*apk-s*aqk; a[q*4+k]=s*apk+c*aqk
                for k in range(4):
                    vkp,vkq=v[k*4+p],v[k*4+q]
                    v[k*4+p]=c*vkp-s*vkq; v[k*4+q]=s*vkp+c*vkq
    best=max(range(4), key=lambda i:a[i*4+i])
    vec=[v[best],v[4+best],v[8+best],v[12+best]]
    n=math.sqrt(sum(x*x for x in vec))
    return [x/n for x in vec]

def rigid(src,tgt):
    src=np.array(src); tgt=np.array(tgt)
    cs=src.mean(0); ct=tgt.mean(0)
    S=src-cs; T=tgt-ct
    sxx=(S[:,0]*T[:,0]).sum(); sxy=(S[:,0]*T[:,1]).sum(); sxz=(S[:,0]*T[:,2]).sum()
    syx=(S[:,1]*T[:,0]).sum(); syy=(S[:,1]*T[:,1]).sum(); syz=(S[:,1]*T[:,2]).sum()
    szx=(S[:,2]*T[:,0]).sum(); szy=(S[:,2]*T[:,1]).sum(); szz=(S[:,2]*T[:,2]).sum()
    N=[sxx+syy+szz, syz-szy, szx-sxz, sxy-syx,
       syz-szy, sxx-syy-szz, sxy+syx, szx+sxz,
       szx-sxz, sxy+syx, -sxx+syy-szz, syz+szy,
       sxy-syx, szx+sxz, syz+szy, -sxx-syy+szz]
    q=dominant_eig4(N)                      # (w, x, y, z)
    w,x,y,z=q
    R=np.array([
      [1-2*(y*y+z*z), 2*(x*y-z*w),   2*(x*z+y*w)],
      [2*(x*y+z*w),   1-2*(x*x+z*z), 2*(y*z-x*w)],
      [2*(x*z-y*w),   2*(y*z+x*w),   1-2*(x*x+y*y)]])
    t=ct-R@cs
    return R,t

random.seed(7); np.random.seed(7)
# a plausible stable-landmark spread, in metres
pts=np.array([[-0.031,0.025,0.055],[0.031,0.025,0.055],[-0.030,0.010,0.052],[0.030,0.010,0.052],
              [-0.072,0.012,-0.035],[0.072,0.012,-0.035],[0.0,0.042,0.062],[0.0,0.028,0.058],
              [0.0,0.002,0.086],[-0.017,-0.006,0.068],[0.017,-0.006,0.068],[0.0,-0.010,0.072]])
ax=np.array([0.2,0.7,-0.4]); ax/=np.linalg.norm(ax); th=0.6
K=np.array([[0,-ax[2],ax[1]],[ax[2],0,-ax[0]],[-ax[1],ax[0],0]])
Rtrue=np.eye(3)+math.sin(th)*K+(1-math.cos(th))*K@K
ttrue=np.array([0.02,-0.05,0.31])
tgt=(pts@Rtrue.T)+ttrue

R,t=rigid(pts,tgt)
print("rotation recovered (max abs error):", np.abs(R-Rtrue).max())
print("translation recovered (max abs error, mm):", np.abs(t-ttrue).max()*1000)
print("det(R) =", round(np.linalg.det(R),9), "(must be +1, not -1)")

# with realistic landmark-picking noise
noise=np.random.normal(0,0.0008,pts.shape)      # 0.8 mm sd picking error
R2,t2=rigid(pts,tgt+noise)
res=(pts@R2.T+t2)-(tgt+noise)
print(f"with 0.8 mm picking noise -> RMS residual {np.sqrt((res**2).sum(1).mean())*1000:.3f} mm, "
      f"rotation error {np.degrees(np.arccos(np.clip((np.trace(R2@Rtrue.T)-1)/2,-1,1))):.3f} deg")
