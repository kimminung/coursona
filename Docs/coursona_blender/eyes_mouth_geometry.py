"""Eye_L/Eye_R 안구, Mouth_Inner(치아·잇몸·혀·입안) 생성기, 턱 셰이프키용 강체 맞춤(Kabsch), 눈·치아 텍스처. numpy 만 쓴다.

좌표: 블렌더 월드(Z-up, 얼굴 −Y, 피사체 왼쪽 +X, 미터). 안구는 오리진 = 눈알 중심, 앞 = −Y.
UV: 홍채·동공 면 = 앞쪽 평면 투영(홍채 반지름 → 0.46), 공막 면 = (방위각, 앞극에서의 극각).
"""
import math
import numpy as np

EYE_R = 0.012
PUPIL_DEG = math.degrees(math.asin(0.0020 / EYE_R))     # 동공 반지름 2.0 mm → 9.6°
IRIS_DEG = math.degrees(math.asin(0.0059 / EYE_R))      # 홍채 반지름 5.9 mm → 29.5°
SLOT_SCLERA, SLOT_IRIS, SLOT_PUPIL = 0, 1, 2
IRIS_UV_R = 0.46                                        # 홍채 가장자리가 놓이는 UV 반지름


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def eye_uv(p, r, slot):
    """정점 p(눈 중심 기준 로컬)의 UV. 홍채·동공: 평면 투영, 공막: 구면."""
    if slot in (SLOT_IRIS, SLOT_PUPIL):
        k = IRIS_UV_R / (r * math.sin(math.radians(IRIS_DEG)))
        return (0.5 + p[0] * k, 0.5 + p[2] * k)
    u = 0.5 + math.atan2(p[0], p[2]) / (2 * math.pi)
    v = math.acos(np.clip(-p[1] / r, -1, 1)) / math.pi
    return (u, v)


def eye_face_uvs(V, faces, mat, r):
    out = []
    for f, m in zip(faces, mat):
        uv = [eye_uv(V[i], r, m) for i in f]
        if m == SLOT_SCLERA:
            us = [a for a, _ in uv]
            if max(us) - min(us) > 0.5:
                uv = [(a + 1.0 if a < 0.5 else a, b) for a, b in uv]
        out.append(uv)
    return out


def _tri(faces, extra=None):
    """사각형을 삼각형 둘로. extra(면별 리스트들)도 같이 복제."""
    out, outs = [], [[] for _ in (extra or [])]
    for i, f in enumerate(faces):
        pieces = [f] if len(f) == 3 else [(f[0], f[1], f[2]), (f[0], f[2], f[3])]
        for pc in pieces:
            out.append(tuple(pc))
            for k, ex in enumerate(extra or []):
                outs[k].append(ex[i] if not isinstance(ex[i], list) else
                               ([ex[i][0], ex[i][1], ex[i][2]] if pc == (f[0], f[1], f[2]) or len(f) == 3 else [ex[i][0], ex[i][2], ex[i][3]]))
    return (out, *outs) if extra else out


EYE_RINGS = sorted(set([1.5, 3.0, 4.5, 6.0, 7.8, PUPIL_DEG, 11.5, 13.5, 15.5, 17.5, 19.5, 21.5, 23.5, 25.5, 27.5, IRIS_DEG,
                        31.5, 34.0, 37.0, 40.0, 44.0, 48.0, 53.0, 58.0, 64.0, 70.0, 77.0, 84.0, 92.0, 100.0, 108.0,
                        116.0, 124.0, 132.0, 140.0, 148.0, 156.0, 164.0, 172.0]))


def eyeball(r=EYE_R, seg=64, recess=0.0005):
    """앞 극(−Y) 기준 위도 고리 39개 × 64분할, 전부 삼각형. 동공·홍채 경계 고리를 정확히 맞추고,
    홍채는 구면보다 살짝(최대 recess) 들어간 접시 — 각막 없이도 깊이감이 나고 눈꺼풀 바깥으로는 절대 안 나간다.
    반환: V(로컬), faces(삼각형), mat_index, loop_uv."""
    rings = EYE_RINGS
    sin_i = math.sin(math.radians(IRIS_DEG))
    V = [np.array([0.0, -r + recess + 0.0002, 0.0])]          # 앞 극(동공 중심)은 가장 깊게
    for a in rings:
        t = math.radians(a)
        dish = 0.0
        if a < IRIS_DEG:
            f = 1.0 - (math.sin(t) / sin_i) ** 2
            dish = recess * f + (0.0002 * f if a < PUPIL_DEG else 0.0)
        for k in range(seg):
            p = 2 * math.pi * k / seg
            V.append(np.array([r * math.sin(t) * math.cos(p), -r * math.cos(t) + dish, r * math.sin(t) * math.sin(p)]))
    V.append(np.array([0.0, r, 0.0]))
    V = np.asarray(V)
    back = len(V) - 1
    F, ang = [], []
    for k in range(seg):
        F.append((0, 1 + (k + 1) % seg, 1 + k))
        ang.append(rings[0] / 2)
    for i in range(len(rings) - 1):
        a0, a1 = 1 + i * seg, 1 + (i + 1) * seg
        am = (rings[i] + rings[i + 1]) / 2
        for k in range(seg):
            k1 = (k + 1) % seg
            F.append((a0 + k, a0 + k1, a1 + k1))
            F.append((a0 + k, a1 + k1, a1 + k))
            ang += [am, am]
    last = 1 + (len(rings) - 1) * seg
    for k in range(seg):
        F.append((last + k, last + (k + 1) % seg, back))
        ang.append(176.0)
    F2 = []
    for f in F:
        P = V[list(f)]
        n = np.cross(P[1] - P[0], P[2] - P[0])
        F2.append(f if np.dot(n, P.mean(axis=0)) > 0 else tuple(f[::-1]))
    ang = np.asarray(ang)
    mat = np.where(ang < PUPIL_DEG, SLOT_PUPIL, np.where(ang < IRIS_DEG, SLOT_IRIS, SLOT_SCLERA))
    return V, F2, mat, eye_face_uvs(V, F2, mat, r)


def kabsch(A, B, w=None):
    """A→B 강체 변환(R, t): B ≈ A @ R.T + t."""
    w = np.ones(len(A)) if w is None else np.asarray(w, float)
    w = w / w.sum()
    ca, cb = (A * w[:, None]).sum(0), (B * w[:, None]).sum(0)
    H = ((A - ca) * w[:, None]).T @ (B - cb)
    U, S, Vt = np.linalg.svd(H)
    d = np.sign(np.linalg.det(Vt.T @ U.T))
    D = np.diag([1, 1, d])
    R = Vt.T @ D @ U.T
    return R, cb - R @ ca


def rot_angle_deg(R):
    return math.degrees(math.acos(np.clip((np.trace(R) - 1) / 2, -1, 1)))


# ------------------------------------------------------------------ 입안 생성(기존 Mouth_Inner 가 없을 때만)
# (이름, 폭 mm, 깊이 mm, 치관 높이 mm, 형태)
UPPER = [("CI", 8.6, 7.0, 10.5, "incisor"), ("LI", 6.6, 6.0, 9.0, "incisor"), ("C", 7.6, 7.5, 10.0, "canine"),
         ("PM1", 7.0, 8.5, 8.5, "premolar"), ("PM2", 6.8, 8.5, 8.0, "premolar"), ("M1", 10.0, 10.5, 7.5, "molar"),
         ("M2", 9.0, 10.0, 7.0, "molar")]
LOWER = [("CI", 5.3, 6.0, 9.0, "incisor"), ("LI", 5.9, 6.2, 9.0, "incisor"), ("C", 6.9, 7.5, 10.0, "canine"),
         ("PM1", 7.0, 7.5, 8.5, "premolar"), ("PM2", 7.2, 8.0, 8.0, "premolar"), ("M1", 11.0, 10.0, 7.5, "molar"),
         ("M2", 10.5, 10.0, 7.0, "molar")]
SHAPES = {  # 절단연 비율, 치경 비율, 첨두 길이, 순측 볼록, 절단연 두께 비율, 폭 지수(작을수록 모서리 둥긂), 교두 높이
    "incisor": dict(edge=1.00, cervix=0.78, tip=0.0003, bulge=0.0004, edge_depth=0.50, ew=0.75, cusp=0.0),
    "canine": dict(edge=0.62, cervix=0.85, tip=0.0012, bulge=0.0005, edge_depth=0.70, ew=0.65, cusp=0.0),
    "premolar": dict(edge=0.82, cervix=0.86, tip=0.0, bulge=0.0004, edge_depth=0.85, ew=0.65, cusp=0.0006),
    "molar": dict(edge=0.90, cervix=0.86, tip=0.0, bulge=0.0003, edge_depth=0.92, ew=0.6, cusp=0.0008),
}
SEX = {  # 치아 전체 비율, 절치 모서리(남성은 각지게), 첨두·교두 배율
    "male": dict(scale=1.05, ew_incisor=0.88, cusp=1.15),
    "female": dict(scale=0.97, ew_incisor=0.62, cusp=0.95),
}
PART_TEETH_U, PART_TEETH_L, PART_GUM_U, PART_GUM_L, PART_TONGUE, PART_CAVITY = range(6)
MAT_TEETH, MAT_GUM, MAT_TONGUE, MAT_CAVITY = range(4)


class Arch:
    """치열궁: x = a·sinψ, y = y0 + b·(1 − cosψ). 호 길이로 위치를 찾는다."""

    def __init__(self, a, b, y0):
        self.a, self.b, self.y0 = a, b, y0
        ps = np.linspace(0, 1.45, 600)
        pts = np.stack([a * np.sin(ps), y0 + b * (1 - np.cos(ps))], 1)
        self.ps = ps
        self.s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(pts, axis=0), axis=1))])

    def at(self, s, side=1.0):
        psi = np.interp(abs(s), self.s, self.ps)
        x = side * self.a * math.sin(psi)
        y = self.y0 + self.b * (1 - math.cos(psi))
        tx, ty = side * self.a * math.cos(psi), self.b * math.sin(psi)
        t = np.array([tx, ty]) / math.hypot(tx, ty)
        n = np.array([t[1], -t[0]]) * side       # 바깥(입술 쪽)
        if n[1] > 0:
            n = -n
        return np.array([x, y]), t, n, psi


def _orient_out(V, F, center_of):
    """면 법선이 center_of(면 중심) 에서 멀어지는 쪽을 보게(좌우 대칭 생성에서 감김이 뒤집히는 것 방지)."""
    out, flipped = [], []
    for f in F:
        P = V[list(f)]
        fc = P.mean(axis=0)
        n = np.cross(P[1] - P[0], P[2] - P[0])
        ok = np.dot(n, fc - center_of(fc)) >= 0
        out.append(tuple(f) if ok else tuple(f[::-1]))
        flipped.append(not ok)
    return out, flipped


def _tooth(center_xy, t, n, z_edge, w, d, h, upper, shape, sex="male", seg=16, rows=8, tilt_deg=0.0):
    """치아 하나(전부 삼각형): 치경→절단연 단면 변화 + 끝부분(절치 유두 / 송곳니 첨두 / 소구치·대구치 교두와 중심와).
    반환 V, F, loop_uv(u 둘레, v 0 절단연→1 치경)."""
    S = dict(SHAPES[shape])
    X = SEX[sex]
    if shape == "incisor":
        S["ew"] = X["ew_incisor"]
    S["tip"] *= X["cusp"]
    S["cusp"] *= X["cusp"]
    V, UV = [], []
    sgn = 1.0 if upper else -1.0

    def ring(scale, dscale, bulge, z, zmod=None):
        start = len(V)
        for k in range(seg):
            a = 2 * math.pi * k / seg
            cx, cy = math.cos(a), math.sin(a)
            ex = (abs(cx) ** S["ew"]) * np.sign(cx)
            ey = (abs(cy) ** 0.8) * np.sign(cy)
            off = t * (0.5 * w * ex * scale) + n * (0.5 * d * ey * scale * dscale + bulge)
            zz = z if zmod is None else z + zmod(a, k)
            V.append([center_xy[0] + off[0], center_xy[1] + off[1], zz])
        return start

    for r in range(rows + 1):
        s_ = r / rows
        z = z_edge + sgn * h * s_
        scale = (S["edge"] + (1 - S["edge"]) * _smoothstep(0.0, 0.45, s_)) * (1 - (1 - S["cervix"]) * _smoothstep(0.5, 1.0, s_))
        dscale = S["edge_depth"] + (1 - S["edge_depth"]) * _smoothstep(0.0, 0.5, s_)
        bulge = S["bulge"] * math.sin(math.pi * s_) + math.tan(math.radians(tilt_deg)) * h * (1.0 - s_)   # 순측 기울기(치경 기준)
        zmod = None
        if r == 0 and shape == "incisor":            # 절단연 유두 3개(mamelon): 가로로 0.12 mm 물결
            zmod = lambda a, k: -sgn * 0.00012 * (0.5 + 0.5 * math.cos(3 * a))
        ring(scale, dscale, bulge, z, zmod)
        for k in range(seg):
            UV.append((k / seg, s_))
    F = []
    for r in range(rows):
        for k in range(seg):
            a0, a1 = r * seg + k, r * seg + (k + 1) % seg
            F.append((a0, a1, a1 + seg))
            F.append((a0, a1 + seg, a0 + seg))
    if S["cusp"] > 0:                                 # 교합면: 안쪽 고리(교두 4개) + 중심와
        inner = ring(S["edge"] * 0.55, S["edge_depth"], 0.0, z_edge,
                     lambda a, k: -sgn * S["cusp"] * abs(math.cos(2 * (a - math.pi / 4))) ** 1.5)
        for k in range(seg):
            UV.append((k / seg, 0.0))
        for k in range(seg):
            k1 = (k + 1) % seg
            F.append((k, inner + k1, inner + k))
            F.append((k, k1, inner + k1))
        fossa = len(V)
        V.append([center_xy[0], center_xy[1], z_edge + sgn * 0.0003])
        UV.append((0.5, 0.0))
        for k in range(seg):
            F.append((inner + k, fossa, inner + (k + 1) % seg))
    else:                                              # 절치·송곳니: 끝점으로 모이는 부채
        tip = len(V)
        V.append([center_xy[0], center_xy[1], z_edge - sgn * S["tip"]])
        UV.append((0.5, 0.0))
        for k in range(seg):
            F.append((k, tip, (k + 1) % seg))
    V = np.asarray(V)
    F2, flipped = _orient_out(V, F, lambda fc: np.array([center_xy[0], center_xy[1], fc[2]]))
    luv = []
    for f in F2:
        uvs = [UV[i] for i in f]
        us = [u for u, _ in uvs]
        if max(us) - min(us) > 0.5:
            uvs = [(u + 1.0 if u < 0.5 else u, v) for u, v in uvs]
        luv.append(uvs)
    return V, F2, luv


def _band(side_pts, z_margin, z1, inner, outer):
    """잇몸 띠(전부 삼각형): 열마다 다른 치은 경계 z_margin(s)에서 z1 까지, 둥근 단면 10점."""
    V, F = [], []
    cols = len(side_pts)
    m = 10
    for (xy, t, n, s_arc), z0 in zip(side_pts, z_margin):
        h = z1 - z0
        prof = [(-outer, z0), (-outer * 1.08, z0 + 0.25 * h), (-outer * 1.10, z0 + 0.5 * h), (-outer * 1.0, z0 + 0.8 * h),
                (-outer * 0.6, z1), (0.0, z1 + (0.0005 if h > 0 else -0.0005)), (inner * 0.6, z1), (inner * 0.95, z0 + 0.7 * h),
                (inner, z0 + 0.35 * h), (inner * 0.9, z0)]
        for (o, z) in prof:
            p = xy + n * (-o)
            V.append([p[0], p[1], z])
    for i in range(cols - 1):
        for j in range(m - 1):
            a, b = i * m + j, (i + 1) * m + j
            F.append((a, b, b + 1))
            F.append((a, b + 1, a + 1))
    V = np.asarray(V)
    cent = V.reshape(cols, m, 3).mean(axis=1)

    def center_of(fc):
        return cent[int(np.argmin(np.linalg.norm(cent - fc, axis=1)))]
    F2, _ = _orient_out(V, F, center_of)
    return V, F2


def _ellipsoid(c, r, nu=20, nv=12, inward=False, keep=None):
    V, F = [], []
    for i in range(nv + 1):
        th = math.pi * i / nv
        for j in range(nu):
            ph = 2 * math.pi * j / nu
            V.append([c[0] + r[0] * math.sin(th) * math.cos(ph), c[1] + r[1] * math.sin(th) * math.sin(ph),
                      c[2] + r[2] * math.cos(th)])
    V = np.asarray(V)
    for i in range(nv):
        for j in range(nu):
            a, b = i * nu + j, i * nu + (j + 1) % nu
            f = (a, a + nu, b + nu, b)
            if keep is not None and not keep(V[list(f)].mean(axis=0)):
                continue
            for tri in ((f[0], f[1], f[2]), (f[0], f[2], f[3])):
                F.append(tri[::-1] if inward else tri)
    return V, F


def _scallop(s_abs, bounds, A, sign):
    """치은 경계: 치아 중심에서 A 만큼 솟고(위턱은 위로) 치간에서 0 — 페스툰."""
    for a, b in bounds:
        if a <= s_abs <= b:
            m, hw = (a + b) / 2, max((b - a) / 2, 1e-6)
            return sign * A * max(0.0, 1 - ((s_abs - m) / hw) ** 2)
    return 0.0


def mouth_inner(mouth_c, half_w, lip_back_y, scale=None, seed=5, sex="male",
                protrusion=0.0, overjet=0.0022, overbite=0.0020, tilt_per_mm=2.0):
    """반환: V, faces(전부 삼각형), part(면별), mat(면별), jaw_w(정점별 0 위턱…1 아래턱), tongue_mask, loop_uv, meta.
    sex: 'male'(치아 +5%, 절치 각짐, 교두 뚜렷) / 'female'(−3%, 절치 둥긂).
    protrusion: 입 전체(치열·잇몸·혀·입안)를 앞(−Y)으로 미는 양(m). 앞니는 1 mm 당 tilt_per_mm° 순측으로 기운다.
    overjet: 아래 치열이 위 치열보다 뒤에 놓이는 양(수평피개, m). overbite: 위 앞니가 아래 앞니를 덮는 양(수직피개, m)."""
    rng = np.random.default_rng(seed)
    s = scale if scale is not None else float(np.clip(half_w / 0.025, 0.85, 1.15))
    s *= SEX[sex]["scale"]
    y0 = lip_back_y + 0.0010 - protrusion
    zu = mouth_c[2] - 0.0005
    zl = zu + overbite
    tilt = tilt_per_mm * protrusion * 1000.0
    up = Arch(0.026 * s, 0.040 * s, y0)
    lo = Arch(0.024 * s, 0.038 * s, y0 + overjet)
    Vs, Fs, parts, mats, jaw, uvs = [], [], [], [], [], []
    base = 0

    def add(V, F, part, mat, jw, luv=None):
        nonlocal base
        Vs.append(V)
        Fs.extend(tuple(i + base for i in f) for f in F)
        parts.extend([part] * len(F))
        mats.extend([mat] * len(F))
        jaw.extend([jw] * len(V))
        uvs.extend(luv if luv is not None else [[(0.5, 0.5)] * len(f) for f in F])
        base += len(V)

    for arch, spec, zedge, upper in ((up, UPPER, zu, True), (lo, LOWER, zl, False)):
        bounds = []
        for side in (1.0, -1.0):
            sacc = 0.0
            for i, (nm, w, d, h, shape) in enumerate(spec):
                w, d, h = w * 0.001 * s, d * 0.001 * s, h * 0.001 * s
                xy, t, n, psi = arch.at(sacc + w / 2, side)
                if side > 0:
                    bounds.append((sacc, sacc + w))
                spee = 0.0022 * (psi / 1.2) ** 2 * (1 if upper else -1)
                # 자연스러운 어긋남: 축 회전 ±2°, 순설 방향 ±0.2 mm, 측절치는 0.3 mm 뒤로
                ang = math.radians(rng.normal(0, 2.0))
                t2 = np.array([t[0] * math.cos(ang) - t[1] * math.sin(ang), t[0] * math.sin(ang) + t[1] * math.cos(ang)])
                n2 = np.array([t2[1], -t2[0]]) * side
                if np.dot(n2, n) < 0:
                    n2 = -n2
                xy2 = xy + n * (rng.normal(0, 0.0002) - (0.0003 if nm == "LI" else 0.0))
                tdeg = tilt * (1.0 if shape == "incisor" else 0.5 if shape == "canine" else 0.0)
                V, F, luv = _tooth(xy2, t2, n2, zedge + spee, w * 0.96, d, h, upper, shape, sex=sex, tilt_deg=tdeg)
                add(V, F, PART_TEETH_U if upper else PART_TEETH_L, MAT_TEETH, 0.0 if upper else 1.0, luv)
                sacc += w
        pts = []
        total = arch.s[-1] * 0.93
        for k in np.linspace(-total, total, 97):
            xy, t, n, psi = arch.at(k, 1.0 if k >= 0 else -1.0)
            pts.append((xy, t, n, abs(k)))
        A = 0.0015 * s
        if upper:
            zm = [zu + 0.0075 * s + _scallop(sa, bounds, A, +1.0) for (_, _, _, sa) in pts]
            V, F = _band(pts, zm, zu + 0.0150 * s, 0.0045 * s, 0.0050 * s)
            add(V, F, PART_GUM_U, MAT_GUM, 0.0)
        else:
            zm = [zl - 0.0075 * s + _scallop(sa, bounds, A, -1.0) for (_, _, _, sa) in pts]
            V, F = _band(pts, zm, zl - 0.0150 * s, 0.0045 * s, 0.0050 * s)
            add(V, F, PART_GUM_L, MAT_GUM, 1.0)
    tc = np.array([0.0, y0 + 0.024 * s, zl - 0.0065])
    V, F = _ellipsoid(tc, (0.019 * s, 0.026 * s, 0.0085 * s), 40, 20)
    top = V[:, 2] > tc[2]
    sulcus = 0.0012 * np.clip(1 - (np.abs(V[:, 0]) / 0.0045) ** 2, 0, 1) * _smoothstep(tc[1] - 0.022 * s, tc[1] - 0.010 * s, V[:, 1])
    bumps = 0.00025 * (np.sin(V[:, 0] * 1900 + 0.7) * np.sin(V[:, 1] * 1700 + 1.9) + 0.5 * np.sin(V[:, 0] * 3100 - V[:, 1] * 2300))
    V[:, 2] -= np.where(top, sulcus - bumps * _smoothstep(0.0, 0.004, V[:, 2] - tc[2]), 0.0)   # 정중 설구 + 설유두 요철
    add(V, F, PART_TONGUE, MAT_TONGUE, 1.0)
    tongue = np.zeros(base, bool)
    tongue[base - len(V):] = True
    cc = np.array([0.0, y0 + 0.026 * s, mouth_c[2] - 0.002])
    V, F = _ellipsoid(cc, (0.031 * s, 0.033 * s, 0.022 * s), 32, 16, inward=True,
                      keep=lambda p: p[1] > y0 + 0.006)
    zmid = (zu + zl) / 2
    jw = np.clip((zmid - V[:, 2]) / 0.012, 0, 1)
    jw = jw * jw * (3 - 2 * jw)
    Vs.append(V)
    Fs.extend(tuple(i + base for i in f) for f in F)
    parts.extend([PART_CAVITY] * len(F))
    mats.extend([MAT_CAVITY] * len(F))
    jaw.extend(jw.tolist())
    uvs.extend([[(0.5, 0.5)] * len(f) for f in F])
    base += len(V)
    tongue = np.concatenate([tongue, np.zeros(len(V), bool)])
    return (np.concatenate(Vs), Fs, np.asarray(parts), np.asarray(mats), np.asarray(jaw), tongue, uvs,
            dict(scale=s, sex=sex, y0=y0, z_upper=zu, z_lower=zl, protrusion=protrusion, overjet=overjet, overbite=overbite,
                 incisor_tilt_deg=tilt, triangles=all(len(f) == 3 for f in Fs)))


def apply_rigid(V, R, t, w):
    """정점별 가중치 w 로 강체 변환을 섞는다(w=1 완전 이동)."""
    moved = V @ R.T + t
    return V + w[:, None] * (moved - V)


def tongue_out(V, tongue_mask, amount=0.016):
    out = V.copy()
    if not tongue_mask.any():
        return out
    T = V[tongue_mask]
    yb, yf = T[:, 1].max(), T[:, 1].min()
    f = np.clip((yb - T[:, 1]) / max(yb - yf, 1e-6), 0, 1) ** 1.5
    out[tongue_mask] = T + np.stack([np.zeros_like(f), -amount * f, -0.003 * f], 1)
    return out


# ------------------------------------------------------------------ 텍스처(홍채·공막·치아) — RGBA float32, 행 0 = 위
def iris_texture(size=1024, seed=11, base=(0.40, 0.54, 0.60), amber=(0.56, 0.47, 0.34)):
    """홍채: 섬유 결(각도 고주파), 크립트, 콜라레트 밝은 고리, 동공 가장자리 어두운 띠, 림벌 링. UV 반지름 0.46 = 홍채 끝."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size]
    u = (xx + 0.5) / size - 0.5
    v = 0.5 - (yy + 0.5) / size
    r = np.hypot(u, v) / IRIS_UV_R
    th = np.arctan2(v, u)
    pupil = 2.0 / 5.9
    fib = np.zeros_like(r)
    for k, a in ((37, 1.0), (53, 0.8), (71, 0.6), (89, 0.45), (131, 0.3)):
        ph = rng.uniform(0, 2 * np.pi)
        fib += a * np.sin(k * th + ph + 1.8 * r * np.sin(0.37 * k + ph))
    fib /= 3.15
    rad = 0.5 + 0.5 * np.sin(2 * np.pi * (r * 7.0 + 0.25 * np.sin(5 * th)))
    val = 0.70 + 0.22 * fib + 0.08 * (rad - 0.5)
    val += 0.14 * np.exp(-((r - 0.46) / 0.035) ** 2)                 # 콜라레트
    val -= 0.25 * _smoothstep(0.42, pupil, r) * (r > pupil)             # 동공 가장자리(루프) 어둡게
    for _ in range(46):                                                 # 크립트(어두운 타원 홈)
        rr, tt = rng.uniform(0.45, 0.80), rng.uniform(0, 2 * np.pi)
        cx, cy = rr * IRIS_UV_R * np.cos(tt), rr * IRIS_UV_R * np.sin(tt)
        sx, sy = rng.uniform(0.006, 0.014), rng.uniform(0.018, 0.045)
        du, dv = u - cx, v - cy
        ca, sa = np.cos(tt), np.sin(tt)
        a1, a2 = du * ca + dv * sa, -du * sa + dv * ca
        val -= rng.uniform(0.18, 0.32) * np.exp(-((a1 / sy) ** 2 + (a2 / sx) ** 2))
    val *= 1 - 0.62 * _smoothstep(0.84, 1.0, r)                         # 림벌 링
    mix = _smoothstep(pupil, 0.62, r)[..., None]
    col = np.asarray(amber) * (1 - mix) + np.asarray(base) * mix
    rgb = np.clip(col * val[..., None], 0, 1)
    rgb[r <= pupil * 0.985] = 0.01
    rgb[r > 1.0] = np.array([0.92, 0.90, 0.88])
    out = np.ones((size, size, 4), np.float32)
    out[..., :3] = rgb
    return out


def sclera_texture(size=1024, seed=12):
    """공막: 앞(v 작음)은 거의 흰색, 뒤로 갈수록 분홍빛. 뒤에서 앞으로 가늘어지는 혈관(v 0.26 아래에서 사라짐)."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size]
    v = (yy + 0.5) / size                      # 행 0 = v 1? 블렌더: 행 0 = v=1 → v = 1 - row
    v = 1.0 - v
    base_front, base_back = np.array([0.95, 0.94, 0.93]), np.array([0.86, 0.72, 0.70])
    mix = _smoothstep(0.2, 1.0, v)[..., None]
    rgb = base_front * (1 - mix) + base_back * mix
    rgb = rgb + rng.normal(0, 0.006, rgb.shape)
    A = np.zeros((size, size), np.float32)
    C = np.zeros((size, size, 3), np.float32)
    red = np.array([0.72, 0.22, 0.22])
    xs = np.arange(size)[None, :]
    ys = np.arange(size)[:, None]
    for _ in range(64):
        uu, vv = rng.uniform(0, 1), rng.uniform(0.70, 0.97)
        width = rng.uniform(2.2, 3.4)
        alpha = rng.uniform(0.45, 0.7)
        heading = rng.uniform(-0.25, 0.25)
        pts = []
        while vv > 0.22:
            pts.append((uu, vv))
            heading += rng.normal(0, 0.18)
            uu = (uu + 0.012 * math.sin(heading)) % 1.0
            vv -= 0.012 * (0.6 + 0.4 * abs(math.cos(heading)))
            if rng.random() < 0.04 and len(pts) > 4:
                heading += rng.choice([-0.9, 0.9])
        for i in range(len(pts) - 1):
            (u0, v0), (u1, v1) = pts[i], pts[i + 1]
            if abs(u1 - u0) > 0.5:
                continue
            tfrac = i / max(len(pts) - 1, 1)
            w = width * (1 - 0.65 * tfrac)
            a = alpha * (1 - tfrac) ** 1.4 * _smoothstep(0.22, 0.34, v1)
            x0, y0 = u0 * size, (1 - v0) * size
            x1, y1 = u1 * size, (1 - v1) * size
            dx, dy = x1 - x0, y1 - y0
            L2 = dx * dx + dy * dy + 1e-9
            tt = np.clip(((xs - x0) * dx + (ys - y0) * dy) / L2, 0, 1)
            d2 = (xs - (x0 + tt * dx)) ** 2 + (ys - (y0 + tt * dy)) ** 2
            prof = np.exp(-d2 / (2 * (w / 2) ** 2)) * a
            C = C * (1 - prof[..., None]) + red * prof[..., None]
            A = np.maximum(A, prof)
    rgb = rgb * (1 - A[..., None]) + C * A[..., None]
    out = np.ones((size, size, 4), np.float32)
    out[..., :3] = np.clip(rgb, 0, 1)
    return out


def teeth_texture(size=512, seed=13):
    """치아: v 0(절단연) 반투명한 푸른빛 → 가운데 흰색 → v 1(치경) 따뜻한 노란빛, 세로 에나멜 결·가는 가로줄."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:size, 0:size]
    v = 1.0 - (yy + 0.5) / size
    u = (xx + 0.5) / size
    inc, mid, cerv = np.array([0.80, 0.84, 0.86]), np.array([0.93, 0.91, 0.87]), np.array([0.87, 0.78, 0.64])
    m1 = _smoothstep(0.0, 0.14, v)[..., None]
    m2 = _smoothstep(0.55, 1.0, v)[..., None]
    rgb = inc * (1 - m1) + mid * m1
    rgb = rgb * (1 - m2) + cerv * m2
    streak = 0.03 * np.sin(2 * np.pi * u * 24 + 3 * np.sin(2 * np.pi * v * 2)) * (1 - v)
    lines = 0.015 * np.sin(2 * np.pi * v * 60) * _smoothstep(0.5, 0.2, v)
    rgb = rgb + (streak + lines + rng.normal(0, 0.006, (size, size)))[..., None]
    out = np.ones((size, size, 4), np.float32)
    out[..., :3] = np.clip(rgb, 0, 1)
    return out
