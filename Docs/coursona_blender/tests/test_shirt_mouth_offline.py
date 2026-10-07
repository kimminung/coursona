import os, sys, math, time
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT); sys.path.insert(0, HERE)
import proxy_bust as PB, shirt_geometry as SG, eyes_mouth_geometry as EM, raster, tech_data as TD
from PIL import Image

class Surf(PB.ProxySurface):
    def ray(self, origin, direction, max_d):
        d = np.asarray(direction, float); d /= np.linalg.norm(d); o = np.asarray(origin, float)
        inside = PB.sdf(o) < 0
        t_prev, t = 0.0, 0.0
        for _ in range(500):
            s = float(PB.sdf(o + t * d))
            if (s >= 0) == inside:
                break
            t_prev = t
            t += max(abs(s) * 0.9, 2e-4)
            if t > max_d:
                return None
        a, b = t_prev, t
        for _ in range(24):
            m = (a + b) / 2
            if (PB.sdf(o + m * d) < 0) == inside: a = m
            else: b = m
        hit = o + b * d
        g = PB.grad(hit); n = g / np.linalg.norm(g)
        return hit, n, 0, b

PB.set_sex("male")                          # 셔츠·입·눈 → 남성 두상
surf = Surf()
out = os.path.join(ROOT, "previews")
P = dict(SG.DEFAULTS)
NAVY = np.array([0x1E, 0x2A, 0x44]) / 255.0
# ---- 칼라 + 플래킷 + 단추
th = np.linspace(-np.pi, np.pi, 56, endpoint=False)
loop = []
for t in th:
    z = 0.262 + 0.010 * (1 - math.cos(t)) / 2
    hit, n, _, _ = surf.ray(np.array([0, 0.012, z]), np.array([math.sin(t), -math.cos(t), 0.0]), 0.3)
    loop.append(hit + n * 0.0035)
loop = np.asarray(loop)
t0 = time.time()
rows, th2, c = SG.build_collar(loop, surf, P)
n = len(loop); V = [loop]; base = n; idx = []
for R in rows:
    V.append(R); idx.append(np.arange(base, base + len(R))); base += len(R)
F = []; r1 = idx[0]
for k in range(n):
    a, b = k, (k + 1) % n; c0, d, e = r1[2*k], r1[2*k+1], r1[(2*k+2) % (2*n)]
    F += [(a, b, d), (a, d, c0), (b, e, d)]
for ra, rb in zip(idx[:-1], idx[1:]):
    m = len(ra)
    for j in range(m):
        F.append((ra[j], ra[(j+1) % m], rb[(j+1) % m], rb[j]))
Vc = np.concatenate(V); Fc = SG.orient_faces(Vc, F, surf)
j_front = int(np.argmin(np.abs(th2)))
PV, PF, centers = SG.build_placket(surf, c, 0.262 - 0.004, 0.02, P)
btn_V, btn_F = [], []; off = 0
zc = np.array([c0[2] for c0, _ in centers]); zb = 0.262 - P["button_first"]
while zb > 0.032:
    i = int(np.argmin(np.abs(zc - zb))); hit, nrm = centers[i]
    BV, BF = SG.build_button(hit + nrm * (P["body_offset"] + P["placket_lift"] + P["placket_ridge"] + 0.0008), nrm, P)
    btn_V.append(BV); btn_F += [tuple(x + off for x in f) for f in BF]; off += len(BV); zb -= P["button_pitch"]
top = rows[P["stand_rows"] - 1][j_front]; bdir = np.array([np.sin(th2[j_front]), -np.cos(th2[j_front]), 0.0])
BV, BF = SG.build_button(top - np.array([0, 0, 0.5 * SG.collar_heights(0.0, P)[0]]) + bdir * 0.0026, bdir, P)
btn_V.append(BV); btn_F += [tuple(x + off for x in f) for f in BF]
btn_V = np.concatenate(btn_V)
cv = Vc[n:]; sd = PB.sdf(cv); sdp = PB.sdf(PV)
print("collar verts %d min clear %.2f mm | placket verts %d min clear %.2f mm | buttons %d | %.1fs" % (len(cv), sd.min()*1000, len(PV), sdp.min()*1000, len(btn_F)//(2*P['button_seg']), time.time()-t0))
def body_col(Pts):
    tt = np.arctan2(Pts[:, 0], -(Pts[:, 1] - 0.012)); zn = 0.262 + 0.010 * (1 - np.cos(tt)) / 2
    wr = 0.04 * (np.sin(41 * Pts[:, 0] + 1.3) * np.sin(27 * Pts[:, 2] + 0.7))
    shirt = Pts[:, 2] < zn
    return np.where(shirt[:, None], NAVY * 1.6 * (1 + wr)[:, None], np.array([0.87, 0.72, 0.62]))
GRAY = (0.80, 0.80, 0.80)
meshes = [dict(verts=Vc, faces=Fc, color=GRAY, two_sided=True), dict(verts=PV, faces=PF, color=(0.84, 0.84, 0.84), two_sided=True),
          dict(verts=btn_V, faces=btn_F, color=(0.70, 0.70, 0.70), two_sided=True)]
skin = lambda Pts: np.tile(np.array([0.80, 0.80, 0.80]), (len(Pts), 1))   # 살색 부위도 무채색
tiles = []
for v in ("front", "three_quarter", "side"):
    full = raster.render(meshes, v, center=(0, 0.0, 0.30), half=(0.20, 0.17), px=380, body_color=skin)
    tiles.append(Image.fromarray(full))
blank = raster.render([], "front", center=(0, 0.0, 0.30), half=(0.20, 0.17), px=380, body=False)
full = raster.render(meshes, "front", center=(0, 0.0, 0.30), half=(0.20, 0.17), px=380, body_color=skin)
tiles.append(Image.fromarray(raster.overlay(full, blank, 0.10)))   # 내보내기 기본값: 피부·셔츠 10%
Wt = sum(t.width for t in tiles); Ht = max(t.height for t in tiles)
sh = Image.new("RGB", (Wt, Ht), (255, 255, 255)); x = 0
for t in tiles:
    sh.paste(t, (x, 0)); x += t.width
sh.save(os.path.join(out, "shirt_collar_proxy_views.png"))
# ---- presence(테크 데이터): 몸통·칼라·플래킷, 흰 1 → 검정 0
HC = PB.HEAD_C
pres_col = lambda Pts: np.repeat((0.12 + 0.86 * TD.presence(Pts, HC))[:, None], 3, axis=1)
def fcol(Vx, Fx):
    pr = TD.presence(Vx, HC)
    return [np.repeat(0.12 + 0.86 * pr[list(f)].mean(), 3) for f in Fx]
pm = [dict(verts=Vc, faces=Fc, face_colors=fcol(Vc, Fc), two_sided=True), dict(verts=PV, faces=PF, face_colors=fcol(PV, PF), two_sided=True)]
pt = [raster.render(pm, v, center=(0, 0.0, 0.26), half=(0.22, 0.26), px=300, body_color=pres_col) for v in ("front", "side", "back")]
Wt = sum(t.shape[1] for t in pt); sh2 = Image.new("RGB", (Wt, pt[0].shape[0]), (255, 255, 255)); x = 0
for t in pt:
    sh2.paste(Image.fromarray(t), (x, 0)); x += t.shape[1]
sh2.save(os.path.join(out, "tech_shirt_presence.png")); print("presence saved")
# ---- 안구(텍스처) + 입안(치아 텍스처)
Ve, Fe, me, uve = EM.eyeball()
iris_tex = np.asarray(Image.open(os.path.join(ROOT, "textures", "T_Eye_Iris_base.png"))).astype(np.float32) / 255.
scl_tex = np.asarray(Image.open(os.path.join(ROOT, "textures", "T_Eye_Sclera_base.png"))).astype(np.float32) / 255.
teeth_tex = np.asarray(Image.open(os.path.join(ROOT, "textures", "T_Teeth_base.png"))).astype(np.float32) / 255.
ec = np.array([0.032, -0.078, 0.44])
def sub(V, F, UV, mask, tex, shift):
    fs = [f for f, m in zip(F, mask) if m]; uv = [u for u, m in zip(UV, mask) if m]
    return dict(verts=V + shift, faces=fs, loop_uv=uv, texture=tex, alpha_cut=-1.0, two_sided=False)
eye_meshes = [sub(Ve, Fe, uve, me == 0, scl_tex, ec), sub(Ve, Fe, uve, me != 0, iris_tex, ec)]
print("eyeball verts %d faces %d slots=%s" % (len(Ve), len(Fe), np.bincount(me, minlength=3).tolist()))
mc = np.array([0.0, -0.090, 0.380])
Vm, Fm, part, mat, jw, tongue, luv, meta = EM.mouth_inner(mc, 0.026, -0.093, sex="male")
Vp, Fp, partp, matp, jwp, tgp, luvp, metap = EM.mouth_inner(mc, 0.026, -0.093, sex="male", protrusion=0.004)
print("protrusion 4 mm: incisor tilt %.1f deg, front y %.4f → %.4f" % (metap["incisor_tilt_deg"], Vm[:, 1].min(), Vp[:, 1].min()))
print("mouth_inner verts %d tris %d all_tri %s parts %s" % (len(Vm), len(Fm), meta["triangles"], np.bincount(part).tolist()))
piv = np.array([0.0, mc[1] + 0.075, mc[2] + 0.035]); a = math.radians(18)
Rm = np.array([[1, 0, 0], [0, math.cos(a), -math.sin(a)], [0, math.sin(a), math.cos(a)]])
Vopen = EM.apply_rigid(Vm, Rm, piv - Rm @ piv, jw)
cols = {0: (0.86, 0.86, 0.86), 1: (0.74, 0.74, 0.74), 2: (0.78, 0.78, 0.78), 3: (0.45, 0.45, 0.45)}   # 색 뺀 상태
def mouth_meshes(V, F=None, M=None):
    F = Fm if F is None else F
    M = mat if M is None else M
    return [dict(verts=V, faces=F, mat_index=list(M), mat_colors=cols, two_sided=False)]
eye_meshes = [dict(verts=Ve + ec, faces=Fe, mat_index=list(me), mat_colors={0: (0.86, 0.86, 0.86), 1: (0.70, 0.70, 0.70), 2: (0.30, 0.30, 0.30)}, two_sided=False)]
tiles = [raster.render(mouth_meshes(Vm), "front", center=mc, half=(0.034, 0.024), px=360, body=False),
         raster.render(mouth_meshes(Vopen), "front", center=mc - [0, 0, 0.008], half=(0.034, 0.024), px=360, body=False),
         raster.render(mouth_meshes(Vm), "side", center=mc, half=(0.034, 0.024), px=360, body=False),
         raster.render(mouth_meshes(Vp, Fp, matp), "side", center=mc, half=(0.034, 0.024), px=360, body=False),
         raster.render(eye_meshes, "front", center=ec, half=(0.016, 0.0113), px=360, body=False),
         raster.render(eye_meshes, (40.0, 10.0), center=ec, half=(0.016, 0.0113), px=360, body=False)]
W = sum(t.shape[1] for t in tiles); H = max(t.shape[0] for t in tiles)
sheet = Image.new("RGB", (W, H), (255, 255, 255)); x = 0
for t in tiles:
    sheet.paste(Image.fromarray(t), (x, 0)); x += t.shape[1]
sheet.save(os.path.join(out, "mouth_eye_preview.png")); print("saved previews")
