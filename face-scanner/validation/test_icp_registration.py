"""Port of ICPRegistration.align: trimmed point-to-plane ICP with a best-iterate rule,
an inlier floor and a drift guard. Two scenarios:
  A. a normal registration -> must recover the known transform,
  B. a degenerate one (bad picks, mostly non-overlapping) -> must be REJECTED rather
     than returned with a flattering RMS.
"""
import numpy as np, math
np.random.seed(11)
CELL = 0.0015
MIN_INLIERS = 0.40

def arch(n, jitter=0.0, seed=None):
    rng = np.random.default_rng(seed)
    t = rng.uniform(-1.15, 1.15, n)
    v = rng.uniform(0, 1, n)
    # tooth-scale relief: cusps and interproximal grooves, ~1.5 mm peak to trough
    relief = 0.00075*np.sin(t*26.0) + 0.00045*np.sin(t*61.0) + 0.0004*np.cos(t*13.0)
    x = 0.048*np.sin(t*1.35)
    z = 0.030*np.cos(t*1.35) - 0.014
    y = 0.010*v + relief*(1.0-0.4*v)
    p = np.stack([x, y, z], 1)
    nrm = np.stack([np.sin(t*1.35), np.full(n,0.55), np.cos(t*1.35)], 1)
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
    if jitter: p = p + jitter*rng.normal(0,1,(n,3))
    return p, nrm, t

target_pts, target_nrm, target_t = arch(16000, seed=1)
grid = {}
for i,k in enumerate(map(tuple, np.floor(target_pts/CELL).astype(np.int64))):
    grid.setdefault(k, []).append(i)
grid = {k: np.array(v) for k,v in grid.items()}

def nearest(p, radius):
    c = np.floor(p/CELL).astype(np.int64)
    span = max(1, int(math.ceil(radius/CELL)))
    best, bd = -1, radius
    for dz in range(-span,span+1):
        for dy in range(-span,span+1):
            for dx in range(-span,span+1):
                b = grid.get((c[0]+dx, c[1]+dy, c[2]+dz))
                if b is None: continue
                dd = np.linalg.norm(target_pts[b]-p, axis=1)
                m = dd.argmin()
                if dd[m] < bd: bd, best = dd[m], b[m]
    return (best, bd) if best>=0 else None

def expmap(w,t):
    th=np.linalg.norm(w); Rm=np.eye(3)
    if th>1e-8:
        a=w/th; K=np.array([[0,-a[2],a[1]],[a[2],0,-a[0]],[-a[1],a[0],0]])
        Rm=np.eye(3)+math.sin(th)*K+(1-math.cos(th))*K@K
    T=np.eye(4); T[:3,:3]=Rm; T[:3,3]=t; return T

def horn(s,t_):
    cs,ct=s.mean(0),t_.mean(0); S,T_=s-cs,t_-ct
    H=S.T@T_; U,_,Vt=np.linalg.svd(H); d=np.sign(np.linalg.det(Vt.T@U.T))
    Rm=Vt.T@np.diag([1,1,d])@U.T
    T=np.eye(4); T[:3,:3]=Rm; T[:3,3]=ct-Rm@cs; return T

def drift(a,b):
    d = b @ np.linalg.inv(a)
    ang = math.degrees(math.acos(np.clip((np.trace(d[:3,:3])-1)/2,-1,1)))
    return np.linalg.norm(d[:3,3])*1000, ang

def icp(src_pts, T0):
    samples = src_pts[::max(1,len(src_pts)//6000)]
    T = T0.copy(); rejection = 0.008; last=None
    best = (np.inf, None, 0.0, np.inf); iters=0
    for it in range(40):
        iters=it+1
        A=np.zeros((6,6)); b=np.zeros(6); rows=[]
        for p in samples:
            q = T[:3,:3]@p + T[:3,3]
            hit = nearest(q, rejection)
            if hit is None: continue
            idx,_=hit; n=target_nrm[idx]
            rows.append((q, n, float(np.dot(q-target_pts[idx], n))))
        if len(rows)<100: break
        mags=np.sort([abs(r[2]) for r in rows]); cut=mags[int(len(mags)*0.8)]
        used=0; sq=0.0
        for q,n,res in rows:
            if abs(res)>cut: continue
            j=np.concatenate([np.cross(q,n), n])
            A+=np.outer(j,j); b-=j*res; sq+=res*res; used+=1
        if used<50: break
        try: xi=np.linalg.solve(A+np.eye(6)*1e-12, b)
        except np.linalg.LinAlgError: break
        w,tt = xi[:3], xi[3:]
        if np.linalg.norm(tt)>0.05 or np.linalg.norm(w)>0.5: break
        T = expmap(w,tt) @ T
        rms=math.sqrt(sq/used); frac=used/len(samples)
        if frac>=MIN_INLIERS and rms<best[0]:
            best=(rms, T.copy(), frac, mags[len(mags)//2])
        if last is not None and abs(last-rms)<1e-9: break
        last=rms; rejection=max(0.0012, rejection*0.92)
    return best, iters

def scenario(name, pick_indices, keep_fraction, pick_error, expect_trust):
    ax = np.array([0.25,-0.8,0.55]); ax/=np.linalg.norm(ax); th = math.radians(6.5)
    K = np.array([[0,-ax[2],ax[1]],[ax[2],0,-ax[0]],[-ax[1],ax[0],0]])
    R_true = np.eye(3)+math.sin(th)*K+(1-math.cos(th))*K@K
    t_true = np.array([0.0032,-0.0021,0.0045])

    rng = np.random.default_rng(5)
    src0, _, src_t = arch(11000, jitter=0.00006, seed=2)
    order = np.argsort(src_t)
    src0, src_t = src0[order], src_t[order]
    keep = rng.uniform(0,1,len(src0)) < keep_fraction
    src0, src_t = src0[keep], src_t[keep]
    blob = rng.normal(0,0.0015,(500,3)) + np.array([0.02,0.006,0.012])
    src_all = np.vstack([src0, blob])
    src_pts = src_all @ R_true.T + t_true

    picks = [pick_indices[0]%len(src0), pick_indices[1]%len(src0), pick_indices[2]%len(src0)]
    srcP = src_pts[picks]
    tgtP = ((srcP - t_true) @ R_true) + rng.normal(0, pick_error, (3,3))
    T0 = horn(srcP, tgtP)

    Rt=np.eye(4); Rt[:3,:3]=R_true; Rt[:3,3]=t_true
    def err(T):
        c=T@Rt
        return math.degrees(math.acos(np.clip((np.trace(c[:3,:3])-1)/2,-1,1))), np.linalg.norm(c[:3,3])*1000
    (rms, T, frac, med), iters = icp(src_pts, T0)

    print(f"--- {name}")
    if T is None:
        print("    no iterate met the 40% inlier floor -> REJECTED")
        ok = (expect_trust == False)
        print("    PASS" if ok else "    FAIL"); return ok
    r0,t0 = err(T0); r1,t1 = err(T)
    dmm, ddeg = drift(T0, T)
    trusted = (rms*1000 < 0.6) and (frac >= 0.40) and (dmm < 4.0) and (ddeg < 6.0)
    print(f"    coarse from 3 picks : {r0:.2f} deg, {t0:.2f} mm off")
    print(f"    after ICP ({iters:2d} iters): {r1:.3f} deg, {t1:.3f} mm off")
    print(f"    RMS {rms*1000:.3f} mm | inliers {frac*100:.0f}% | drift {dmm:.2f} mm / {ddeg:.2f} deg")
    print(f"    verdict: {'TRUSTED' if trusted else 'REJECTED'}   (expected {'TRUSTED' if expect_trust else 'REJECTED'})")
    accurate = (r1 < 0.5 and t1 < 0.5)
    ok = (trusted == expect_trust) and (not trusted or accurate)
    print("    PASS" if ok else "    FAIL")
    return ok

a = scenario("A. good picks, 85% overlap, 0.5 mm picking error",
             [50, 4000, 8000], 0.85, 0.0005, expect_trust=True)
b = scenario("B. clustered picks, 25% overlap, 2 mm picking error",
             [100, 130, 160], 0.25, 0.0020, expect_trust=False)
print()
print("ALL SCENARIOS BEHAVED CORRECTLY" if (a and b) else "PROBLEM REMAINS")
