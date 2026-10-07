"""Hair_long_wave 형상 — 두피 캡 + 웨이브 가닥 카드. numpy 만 쓴다(블렌더 밖에서도 테스트 가능).

좌표: 블렌더 월드(Z-up, 얼굴 −Y, 피사체 왼쪽 +X, 미터). 표면 질의는 `surface` 객체가 맡는다:
    surface.nearest(p)            -> (q, n, d)   q 최근접점, n 바깥 법선, d 부호 거리(바깥 +)
    surface.ray_down(p, max_d)    -> 아래(−Z)로 첫 충돌까지 거리, 없으면 None
블렌더에서는 BVHTree 로, 테스트에서는 해석적 SDF 로 구현한다(coursona_common.BVHSurface / tests/proxy_bust.py).

층(layers): inner / mid / outer(볼륨) + frame(얼굴을 감싸는 앞머리) + baby(헤어라인 잔머리).
반환 메시: verts (N,3) 월드 좌표, faces [tuple], loop_uv [(u,v)...] 면 꼭짓점 순서대로.
"""
import math
import numpy as np

try:
    from . import hair_texture as HT  # 패키지로 불릴 때
    from . import tech_data as TD
except Exception:  # 단독 실행·블렌더 sys.path 실행
    import hair_texture as HT
    import tech_data as TD

LAYERS = (
    dict(name="inner", h0=0.0040, count=100, width=0.026, cells=("fine", "dense"), curl=0.04, min_d=0.010, pref="low", length=None, twist=0.0),
    dict(name="mid",   h0=0.0085, count=112, width=0.023, cells=("dense", "medium", "wavy", "split"), curl=0.10, min_d=0.010, pref="any", length=None, twist=0.18),
    dict(name="outer", h0=0.0135, count=88, width=0.018, cells=("medium", "wavy", "split", "wispy"), curl=0.12, min_d=0.012, pref="high", length=None, twist=0.25),
    dict(name="frame", h0=0.0050, count=12, width=0.015, cells=("medium", "wavy"), curl=0.08, min_d=0.009, pref="frame", length=0.30, twist=0.12),
    dict(name="baby",  h0=0.0022, count=70, width=0.007, cells=("wispy",), curl=0.0, min_d=0.006, pref="hairline", length=0.055, twist=0.0),
)

DEFAULTS = dict(
    seed=7,
    cap_offset=0.0015,          # 캡: 두피에서 1.5 mm
    root_offset=0.0024,         # 카드 뿌리 줄: 캡 바로 위
    layers=LAYERS,
    part_x=0.005,               # 가르마: 정중선에서 피사체 왼쪽(+X) 5 mm — 정중앙보다 자연스럽다
    volume_gain=0.011,          # 길이 3→14 cm 구간에서 바깥으로 더 뜸(볼륨)
    hug_above_dz=0.035,         # 머리 중심 높이 + 이 값 위에서는 두피를 따라 붙임
    step=0.006,
    max_len=0.36,
    len_jitter=(0.86, 1.0),
    tip_clear=0.018,            # 끝은 바로 아래 표면(어깨·등·칼라)에서 1.8 cm 위에서 멈춤
    min_z=0.24,
    a_line=0.06,                # 귀 아래에서 바깥으로 퍼지는 정도
    wave_start=0.09, wave_amp=0.011, wave_len=0.095, wave_out=0.22,   # 볼 높이부터 큰 S 웨이브
    crown_flatten=0.5,          # 정수리 근처 띄움 배율(카드가 가시처럼 서는 것 방지)
    segments=20,
    part_gap=0.0045,            # 가르마 양옆 뿌리 금지 폭
    face_margin=0.004,
    card_min_clear=0.0025,      # 카드 정점 최소 간격(Bust 기준)
    uv_inset=0.0035,
    width_wobble=0.05,          # 카드 폭이 길이를 따라 살짝 숨 쉬는 정도
    max_lateral=0.125,          # 머리 중심에서 옆으로 이보다 멀리 나가지 않는다(어깨 밖으로 삐치는 가닥 방지)
)


def _norm(v, axis=-1):
    n = np.linalg.norm(v, axis=axis, keepdims=True)
    return v / np.maximum(n, 1e-12)


def _smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def push_out(p, need, surface, iters=3):
    """표면 바깥 need 거리까지 민다. 접힘(귀·턱 밑)에서는 이웃 면 때문에 한 번으로 모자라 반복."""
    for _ in range(iters):
        q, n, d = surface.nearest(p)
        if d >= need - 1e-5:
            break
        p = q + n * need
    return p


class FaceZone:
    """얼굴 패치 정점(ARKit 1220)으로 만든 '머리카락 금지 영역' — 높이별 반폭과 뒤쪽 경계."""

    def __init__(self, patch_pts, chin_z, brow_z, margin):
        self.z0, self.dz = float(patch_pts[:, 2].min()), 0.004
        nb = int((patch_pts[:, 2].max() - self.z0) / self.dz) + 1
        self.hw = np.zeros(nb)
        self.back = np.full(nb, -1.0)
        idx = ((patch_pts[:, 2] - self.z0) / self.dz).astype(int).clip(0, nb - 1)
        for b in range(nb):
            m = idx == b
            if m.any():
                self.hw[b] = np.abs(patch_pts[m, 0]).max()
                self.back[b] = patch_pts[m, 1].max()
        for arr in (self.hw, self.back):   # 빈 칸 채우기
            good = np.where(arr > -0.99)[0] if arr is self.back else np.where(arr > 0)[0]
            if len(good):
                arr[:] = np.interp(np.arange(nb), good, arr[good])
        self.chin_z, self.brow_z, self.margin = chin_z, brow_z, margin

    def limits(self, z):
        b = int(np.clip((z - self.z0) / self.dz, 0, len(self.hw) - 1))
        return self.hw[b] + self.margin, self.back[b]

    def steer(self, p, s):
        """(강제 x, 조향 세기). 얼굴 앞 영역이면 x 를 옆으로 민다."""
        z = p[2]
        if z < self.chin_z - 0.03 or z > self.brow_z + 0.045:
            return None, 0.0
        hw, back = self.limits(min(z, self.brow_z))
        if p[1] > back:          # 귀 뒤쪽은 자유
            return None, 0.0
        if abs(p[0]) >= hw:
            return None, 0.0
        strength = (hw - abs(p[0])) / max(hw, 1e-6)
        hard = z <= self.brow_z
        return (s * hw if hard else None), strength


def sample_roots(tris, weights, n, min_dist, rng, reject=None):
    """면적×선호 가중 무작위 + 최소 간격(다트 던지기)."""
    a = np.linalg.norm(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=1) * 0.5
    w = a * weights
    if w.sum() <= 0:
        return np.zeros((0, 3))
    w = w / w.sum()
    out = []
    tries = 0
    while len(out) < n and tries < n * 400:
        tries += 1
        t = rng.choice(len(tris), p=w)
        r1, r2 = rng.random(), rng.random()
        if r1 + r2 > 1:
            r1, r2 = 1 - r1, 1 - r2
        p = tris[t, 0] + r1 * (tris[t, 1] - tris[t, 0]) + r2 * (tris[t, 2] - tris[t, 0])
        if reject is not None and reject(p):
            continue
        if out and np.min(np.linalg.norm(np.asarray(out) - p, axis=1)) < min_dist:
            continue
        out.append(p)
    return np.asarray(out) if out else np.zeros((0, 3))


def simulate_strand(root, s, surface, face, P, layer, rng, head_c, L_target):
    """뿌리 → 끝 중심선. 빗질 방향 + 중력 + 두피 띄움 + 얼굴 회피 + 어깨 위 정지."""
    q, n, d = surface.nearest(root)
    up = np.array([0.0, 0.0, 1.0])
    X = np.array([1.0, 0.0, 0.0])
    Y = np.array([0.0, 1.0, 0.0])
    front = root[1] < head_c[1] - 0.045
    back = root[1] > head_c[1] + 0.02
    name = layer["name"]
    if name == "baby":
        comb = s * X * 0.9 + Y * 0.9 - up * 0.25      # 헤어라인 잔머리: 뒤·옆으로 쓸어 넘김
    elif name == "frame":
        comb = s * X * 0.30 + Y * 0.05 - up * 1.0     # 얼굴 옆으로 곧장 떨어지는 앞머리
    elif front:
        comb = s * X * 1.5 + Y * 0.55 - up * 0.35
    elif back:
        comb = s * X * 0.04 + Y * 0.18 - up * 1.0     # 뒤는 가르마 없이 곧게
    else:
        comb = s * X * 1.1 + Y * 0.10 - up * 0.55
    comb = comb - n * np.dot(comb, n)
    direc = _norm(comb)
    pts = [q + n * P["root_offset"]]
    p = pts[0].copy()
    L = 0.0
    hug_z = head_c[2] + P["hug_above_dz"]
    ear_z = head_c[2] - 0.02
    layer_h = layer["h0"]
    for _ in range(int(P["max_len"] / P["step"]) + 4):
        wg = 0.22 + 0.78 * _smoothstep(0.0, 0.11, L)
        if name == "baby":
            wg *= 0.35                                 # 잔머리는 두피를 따라간다(중력 약하게)
        radial = np.array([p[0] - head_c[0], p[1] - head_c[1], 0.0])
        radial = _norm(radial)
        spread = radial * P["a_line"] * _smoothstep(ear_z, ear_z - 0.09, p[2])
        direc = _norm(direc * (1 - 0.35 * wg) + (-up) * 0.35 * wg + spread)
        lat0 = p[0] - head_c[0]
        if abs(lat0) > P["max_lateral"] - 0.03:          # 옆으로 많이 나간 가닥은 부드럽게 안쪽으로 되돌린다
            direc = _norm(direc - X * np.sign(lat0) * 0.9 * (abs(lat0) - (P["max_lateral"] - 0.03)) / 0.03)
        fx, st = face.steer(p, s)
        if st > 0:
            direc = _norm(direc + X * s * 1.6 * st)
        p_new = p + direc * P["step"]
        L += P["step"]
        top = P["crown_flatten"] + (1 - P["crown_flatten"]) * _smoothstep(head_c[2] + 0.10, head_c[2], p_new[2])
        h = layer_h * top * _smoothstep(0.0, 0.025, L) + P["root_offset"] * (1 - _smoothstep(0.0, 0.025, L))
        if name != "baby":
            h += P["volume_gain"] * _smoothstep(0.03, 0.14, L)
        q, n, d = surface.nearest(p_new)
        if d < h:
            p_new = push_out(q + n * h, h, surface)
        elif d > h + 0.006 and (p_new[2] > hug_z or name == "baby"):
            p_new = p_new + (q + n * h - p_new) * 0.5
        fx, st = face.steer(p_new, s)
        if fx is not None:
            p_new[0] = fx
            q, n, d = surface.nearest(p_new)
            if d < h:
                p_new = q + n * h
        lat = p_new[0] - head_c[0]
        if abs(lat) > P["max_lateral"]:
            p_new[0] = head_c[0] + np.sign(lat) * P["max_lateral"]
        direc = _norm(p_new - p)
        p = p_new
        pts.append(p.copy())
        if L >= L_target or p[2] <= P["min_z"]:
            break
        dist_down = surface.ray_down(p, 0.2)
        if dist_down is not None and dist_down < P["tip_clear"] and L > 0.06:
            break
    return np.asarray(pts)


def resample(pts, n_seg):
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    s = np.concatenate([[0], np.cumsum(seg)])
    if s[-1] < 1e-6:
        return np.repeat(pts[:1], n_seg + 1, axis=0), s[-1]
    t = np.linspace(0, s[-1], n_seg + 1)
    out = np.stack([np.interp(t, s, pts[:, k]) for k in range(3)], axis=1)
    return out, s[-1]


def add_waves(pts, head_c, P, phase, amp_scale, lam):
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    L = np.concatenate([[0], np.cumsum(seg)])
    t = _norm(np.gradient(pts, axis=0))
    o = pts.copy()
    o[:, 0] -= head_c[0]
    o[:, 1] -= head_c[1]
    o[:, 2] = 0.0
    o = _norm(o - t * np.sum(o * t, axis=1, keepdims=True))
    b = _norm(np.cross(t, o))
    A = P["wave_amp"] * amp_scale * _smoothstep(P["wave_start"], P["wave_start"] + 0.08, L)
    ph = 2 * np.pi * L / lam + phase
    return pts + (A * np.sin(ph))[:, None] * b + (A * np.cos(ph) * P["wave_out"])[:, None] * o


def enforce_clearance(pts, surface, h, keep_first=True, face=None, s=1.0):
    out = pts.copy()
    for i in range(1 if keep_first else 0, len(out)):
        hi = h[i] if np.ndim(h) else h
        out[i] = push_out(out[i], hi, surface)
        if face is not None:
            fx, _ = face.steer(out[i], s)
            if fx is not None:
                out[i][0] = fx
    return out


def build_cap(cap_v, cap_n, cap_faces, boundary_mask, head_c, P, surface=None):
    """두피 그룹 면을 1.5 mm 띄운 불투명 캡. UV: u = 좌우(정규화 x), v = 헤어라인에서의 거리."""
    V = cap_v + cap_n * P["cap_offset"]
    if surface is not None:                      # 오목한 곳·접힘에서 법선 오프셋이 모자라면 보정
        for i in range(len(V)):
            V[i] = push_out(V[i], P["cap_offset"], surface)
    bpts = cap_v[boundary_mask]
    if len(bpts) == 0:
        dist = np.full(len(V), 0.1)
    else:
        dist = np.array([np.min(np.linalg.norm(bpts - v, axis=1)) for v in cap_v])
    d0, dmax = 0.02, max(float(dist.max()), 0.03)
    v_coord = np.where(dist < d0, HT.CAP_SOLID_V * dist / d0,
                       HT.CAP_SOLID_V + (1 - HT.CAP_SOLID_V) * np.clip((dist - d0) / (dmax - d0), 0, 1))
    rx = cap_v[:, 0] - head_c[0]
    ry = cap_v[:, 1] - head_c[1]
    u01 = 0.5 + 0.49 * rx / np.maximum(np.hypot(rx, ry), 1e-6)
    inset = P["uv_inset"]
    u = HT.CAP_U0 + inset + (HT.CAP_U1 - HT.CAP_U0 - 2 * inset) * u01
    v = inset + (1 - 2 * inset) * v_coord
    loop_uv = [[(u[i], v[i]) for i in f] for f in cap_faces]
    return V, list(cap_faces), loop_uv, dist


def build_card(center, head_c, width, curl, cell, flip, P, surface, twist=0.0, wobble_phase=0.0):
    """중심선 → 3열 카드. 길이를 따라 살짝 비틀리고(twist) 폭이 숨 쉰다(width_wobble) — 빛 받는 면이 다양해진다."""
    n = len(center) - 1
    t = _norm(np.gradient(center, axis=0))
    o = center.copy()
    o[:, 0] -= head_c[0]
    o[:, 1] -= head_c[1]
    o[:, 2] = (center[:, 2] - head_c[2]) * 0.35
    o = _norm(o - t * np.sum(o * t, axis=1, keepdims=True))
    b = _norm(np.cross(t, o))
    k = np.arange(n + 1) / n
    ang = twist * k
    b2 = np.cos(ang)[:, None] * b + np.sin(ang)[:, None] * o
    o2 = -np.sin(ang)[:, None] * b + np.cos(ang)[:, None] * o
    w = width * (1 - 0.38 * k ** 1.3) * (1 + P["width_wobble"] * np.sin(2 * np.pi * k * 2.3 + wobble_phase))
    curl_k = curl * _smoothstep(0.0, 0.2, k)           # 뿌리에서는 휨 0 → 두피 파고듦 방지
    left = center - b2 * (w / 2)[:, None] - o2 * (curl_k * w)[:, None]
    right = center + b2 * (w / 2)[:, None] - o2 * (curl_k * w)[:, None]
    V = np.stack([left, center, right], axis=1).reshape(-1, 3)   # 행마다 [L, C, R]
    for i in range(len(V)):
        need = P["root_offset"] if i < 3 else P["card_min_clear"]
        V[i] = push_out(V[i], need, surface)
    u0, u1 = HT.card_cell_u(cell)
    u0 += P["uv_inset"]
    u1 -= P["uv_inset"]
    us = [u0, (u0 + u1) / 2, u1]
    if flip:
        us = us[::-1]
    faces, uvs = [], []
    for r in range(n):
        for c in range(2):
            a = r * 3 + c
            quad = (a, a + 1, a + 4, a + 3)       # 아래 줄로 감김
            fuv = [(us[c], 1 - r / n), (us[c + 1], 1 - r / n), (us[c + 1], 1 - (r + 1) / n), (us[c], 1 - (r + 1) / n)]
            pa, pb, pc = V[quad[0]], V[quad[1]], V[quad[2]]
            nrm = np.cross(pb - pa, pc - pa)
            if np.dot(nrm, o2[r]) < 0:             # 바깥을 보게
                quad = quad[::-1]
                fuv = fuv[::-1]
            faces.append(quad)
            uvs.append(fuv)
    return V, faces, uvs


def build_hair(scalp, patch_pts, surface, head_c, chin_z, brow_z, params=None, log=print):
    """scalp: dict(v=(N,3), n=(N,3), faces=[tuple], boundary=(N,) bool). 반환: dict(verts, faces, loop_uv, stats)."""
    P = dict(DEFAULTS)
    if params:
        P.update(params)
    rng = np.random.default_rng(P["seed"])
    face = FaceZone(patch_pts, chin_z, brow_z, P["face_margin"])
    part = head_c[0] + P["part_x"]

    capV, capF, capUV, bdist = build_cap(scalp["v"], scalp["n"], scalp["faces"], scalp["boundary"], head_c, P, surface)
    verts = [capV]
    faces = list(capF)
    loop_uv = list(capUV)
    face_layer = ["cap"] * len(capF)
    strands = []
    base = len(capV)

    tri = []
    for f in scalp["faces"]:
        for i in range(1, len(f) - 1):
            tri.append((f[0], f[i], f[i + 1]))
    tri = np.asarray(tri)
    tris = scalp["v"][tri]
    tz = tris[:, :, 2].mean(axis=1)
    ty = tris[:, :, 1].mean(axis=1)
    tx = tris[:, :, 0].mean(axis=1)
    tb = bdist[tri].min(axis=1)                      # 삼각형의 헤어라인까지 거리

    def part_reject(p):
        return abs(p[0] - part) < P["part_gap"] and p[1] < head_c[1] + 0.03 and p[2] > head_c[2] + 0.03

    stats = dict(cards=0, strands_short=0, layers={})
    for layer in P["layers"]:
        pref = layer["pref"]
        if pref == "high":
            wts = 0.3 + _smoothstep(head_c[2] - 0.02, head_c[2] + 0.08, tz)
        elif pref == "low":
            wts = 0.3 + _smoothstep(head_c[2] + 0.08, head_c[2] - 0.02, tz)
        elif pref == "hairline":   # 헤어라인 1.6 cm 안, 앞·옆만
            wts = _smoothstep(0.016, 0.002, tb) * (ty < head_c[1] + 0.03)
        elif pref == "frame":      # 가르마 옆 앞 헤어라인
            wts = (_smoothstep(0.03, 0.004, tb) * (ty < head_c[1] - 0.045)
                   * (np.abs(tx - part) > 0.008) * (np.abs(tx - part) < 0.05))
        else:
            wts = np.ones(len(tris))
        roots = sample_roots(tris, np.asarray(wts, float), layer["count"], layer["min_d"], rng,
                             reject=None if pref in ("hairline", "frame") else part_reject)
        made = 0
        if len(roots) == 0:
            stats["layers"][layer["name"]] = 0
            continue
        clump_c = roots[rng.choice(len(roots), size=max(2, len(roots) // 5), replace=False)]
        clump_phase = rng.uniform(0, 2 * np.pi, len(clump_c))
        clump_lam = P["wave_len"] * rng.uniform(0.85, 1.15, len(clump_c))
        for r in roots:
            s = 1.0 if r[0] - part > 0.002 else (-1.0 if r[0] - part < -0.002 else rng.choice([-1.0, 1.0]))
            Lmax = layer["length"] or P["max_len"]
            Lt = Lmax * rng.uniform(*P["len_jitter"])
            cl = simulate_strand(r, s, surface, face, P, layer, rng, head_c, Lt)
            if len(cl) < 4:
                stats["strands_short"] += 1
                continue
            ci = int(np.argmin(np.linalg.norm(clump_c - r, axis=1)))
            amp = rng.uniform(0.7, 1.15) * (0.25 if layer["name"] == "baby" else 1.0)
            wav = add_waves(cl, head_c, P, clump_phase[ci] + rng.normal(0, 0.35), amp, clump_lam[ci])
            Ls = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(wav, axis=0), axis=1))])
            hmin = np.maximum(P["root_offset"], layer["h0"] * 0.85 * _smoothstep(0.0, 0.03, Ls))
            wav = enforce_clearance(wav, surface, hmin, face=face, s=s)
            nseg = P["segments"] if layer["name"] != "baby" else 6
            cen, Ltot = resample(wav, nseg)
            if Ltot < (0.02 if layer["name"] == "baby" else 0.05):
                stats["strands_short"] += 1
                continue
            cell = layer["cells"][int(rng.integers(len(layer["cells"])))]
            tw = layer["twist"] * rng.uniform(-1.0, 1.0)
            V, F, UV = build_card(cen, head_c, layer["width"] * rng.uniform(0.85, 1.15), layer["curl"], cell,
                                  bool(rng.integers(2)), P, surface, twist=tw, wobble_phase=rng.uniform(0, 6.28))
            verts.append(V)
            faces += [tuple(i + base for i in f) for f in F]
            loop_uv += UV
            face_layer += [layer["name"]] * len(F)
            strands.append(cen)
            base += len(V)
            made += 1
        stats["layers"][layer["name"]] = made
        stats["cards"] += made
    V = np.concatenate(verts)
    tris, tri_uv, tri_layer = TD.triangulate(faces, loop_uv, face_layer)   # (a,b,c)+(a,c,d)
    stats.update(verts=len(V), triangles=len(tris), cap_triangles=2 * len(capF))
    log("hair: %s" % stats)
    return dict(verts=V, faces=tris, loop_uv=tri_uv, face_layer=tri_layer, strands=strands, stats=stats)


def build_shell(strands, surface, head_c, n_th=72, n_ph=40, fracs=(0.30, 0.65, 1.0), clear=0.0025, log=print):
    """스플랫 바인딩용 머리 볼륨 셸 — 머리 중심 구면 격자(극각 φ × 방위 θ)에서
    안쪽 = 두피(머리 중심에서 쏜 광선의 첫 충돌), 바깥 = 가닥 중심선 최대 반지름(부드럽게)으로 잡고
    그 사이에 셸 3겹(fracs)을 둔다. 모두 삼각형, 겹치지 않는 고유 UV(셸마다 u 칸 하나), 정점별 가닥 방향(flow).
    반환 dict(verts, faces, uv(정점별), flow, layer, normal, stats)."""
    c = np.asarray(head_c, float)
    pts = np.concatenate(strands)
    tans = _norm(np.concatenate([np.gradient(sv, axis=0) for sv in strands]))
    d = pts - c
    R = np.linalg.norm(d, axis=1)
    ph = np.arccos(np.clip(d[:, 2] / np.maximum(R, 1e-9), -1, 1))
    th = np.arctan2(d[:, 0], -d[:, 1])
    ph0, ph_max = 0.06, float(min(np.percentile(ph, 99.5) + 0.04, 2.9))
    ci = np.clip(((ph - ph0) / (ph_max - ph0) * n_ph).astype(int), 0, n_ph - 1)
    cj = np.clip(((th + np.pi) / (2 * np.pi) * n_th).astype(int), 0, n_th - 1)
    Rout = np.zeros((n_ph, n_th))
    cnt = np.zeros((n_ph, n_th), int)
    np.add.at(cnt, (ci, cj), 1)
    np.maximum.at(Rout, (ci, cj), R)
    mask = cnt > 0
    for _ in range(2):                                    # 작은 구멍 메우기(닫힘), θ 는 순환
        dil = mask.copy()
        dil[1:] |= mask[:-1]
        dil[:-1] |= mask[1:]
        dil |= np.roll(mask, 1, 1) | np.roll(mask, -1, 1)
        ero = dil.copy()
        ero[1:] &= dil[:-1]
        ero[:-1] &= dil[1:]
        ero &= np.roll(dil, 1, 1) & np.roll(dil, -1, 1)
        mask = ero | mask
    mask[:3, :] = True                                    # 정수리는 항상 덮음
    # 갇힌 빈 칸 메우기: 빈 칸 연결 성분 중 맨 아래 행에 닿지 않고 작은(< 60칸) 것 = 구멍(얼굴 개구부는 남음)
    empty = ~mask
    seen = np.zeros_like(empty)
    for i0 in range(n_ph):
        for j0 in range(n_th):
            if not empty[i0, j0] or seen[i0, j0]:
                continue
            comp, stack, touches = [], [(i0, j0)], False
            seen[i0, j0] = True
            while stack:
                i, j = stack.pop()
                comp.append((i, j))
                touches |= i == n_ph - 1
                for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    a, b = i + di, (j + dj) % n_th
                    if 0 <= a < n_ph and empty[a, b] and not seen[a, b]:
                        seen[a, b] = True
                        stack.append((a, b))
            if not touches and len(comp) < 60:
                for i, j in comp:
                    mask[i, j] = True
    known = cnt > 0
    for _ in range(40):                                   # 빈 칸 반지름 = 이웃 평균
        nb = np.zeros_like(Rout)
        nc = np.zeros_like(Rout)
        for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            sh = np.roll(np.roll(Rout * known, di, 0), dj, 1)
            sk = np.roll(np.roll(known, di, 0), dj, 1)
            if di == 1:
                sh[0], sk[0] = 0, False
            if di == -1:
                sh[-1], sk[-1] = 0, False
            nb += sh
            nc += sk
        fill = (~known) & (nc > 0)
        Rout[fill] = nb[fill] / nc[fill]
        known = known | fill
    for _ in range(3):                                    # 부드럽게
        sm = Rout.copy()
        sm[1:-1] = (Rout[:-2] + 2 * Rout[1:-1] + Rout[2:]) / 4
        Rout = (np.roll(sm, 1, 1) + 2 * sm + np.roll(sm, -1, 1)) / 4
    phs = ph0 + (ph_max - ph0) * np.arange(n_ph + 1) / n_ph
    ths = -np.pi + 2 * np.pi * np.arange(n_th + 1) / n_th           # 마지막 열 = 첫 열 위치(UV 솔기용 복제)
    used = np.zeros((n_ph + 1, n_th + 1), bool)
    for i in range(n_ph):
        for j in range(n_th):
            if mask[i, j]:
                used[i:i + 2, j:j + 2] = True
    dirs = np.zeros((n_ph + 1, n_th + 1, 3))
    rin = np.zeros((n_ph + 1, n_th + 1))
    rout = np.zeros((n_ph + 1, n_th + 1))
    for i in range(n_ph + 1):
        for j in range(n_th + 1):
            p_, t_ = phs[i], ths[j]
            dv = np.array([np.sin(p_) * np.sin(t_), -np.sin(p_) * np.cos(t_), np.cos(p_)])
            dirs[i, j] = dv
            if not used[i, j]:
                continue
            hit = surface.ray(c, dv, 0.4)
            rin[i, j] = hit[3] if hit is not None else 0.08
            cells = [Rout[a % n_ph, b % n_th] for a in (i - 1, i) for b in (j - 1, j) if 0 <= a < n_ph]
            rout[i, j] = max(np.mean(cells), rin[i, j] + clear + 0.004)
    K = len(fracs)
    V, F, UV, LAYER, NRM = [], [], [], [], []
    for k, fr in enumerate(fracs):
        idx = -np.ones((n_ph + 1, n_th + 1), int)
        for i in range(n_ph + 1):
            for j in range(n_th + 1):
                if not used[i, j]:
                    continue
                r = rin[i, j] + clear + (rout[i, j] - rin[i, j] - clear) * fr
                pnt = push_out(c + dirs[i, j] * r, clear, surface)
                idx[i, j] = len(V)
                V.append(pnt)
                UV.append(((k + j / n_th) / K, 1.0 - (i + 1) / (n_ph + 1)))
                LAYER.append(k)
                NRM.append(dirs[i, j])
        pole = len(V)
        r0 = np.mean([np.linalg.norm(V[idx[0, j]] - c) for j in range(n_th) if idx[0, j] >= 0])
        V.append(c + np.array([0.0, 0.0, 1.0]) * r0)
        UV.append(((k + 0.5) / K, 1.0))
        LAYER.append(k)
        NRM.append(np.array([0.0, 0.0, 1.0]))
        for j in range(n_th):
            if idx[0, j] >= 0 and idx[0, j + 1] >= 0:
                F.append((pole, idx[0, j], idx[0, j + 1]))
        for i in range(n_ph):
            for j in range(n_th):
                if not mask[i, j]:
                    continue
                a, b, cc, dd = idx[i, j], idx[i, j + 1], idx[i + 1, j + 1], idx[i + 1, j]
                if min(a, b, cc, dd) < 0:
                    continue
                F += [(a, b, cc), (a, cc, dd)]
    V = np.asarray(V)
    NRM = np.asarray(NRM)
    F2 = []
    for f in F:                                           # 바깥(머리 중심 반대)을 보게
        P3 = V[list(f)]
        n = np.cross(P3[1] - P3[0], P3[2] - P3[0])
        F2.append(f if np.dot(n, P3.mean(axis=0) - c) >= 0 else (f[0], f[2], f[1]))
    flow = np.zeros_like(V)
    for s0 in range(0, len(V), 512):                      # 가장 가까운 가닥 6점의 방향(뿌리→끝) 평균
        blk = V[s0:s0 + 512]
        d2 = ((blk[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
        nn = np.argpartition(d2, 6, axis=1)[:, :6]
        fl = tans[nn].mean(axis=1)
        nrm = NRM[s0:s0 + 512]
        fl = fl - nrm * np.sum(fl * nrm, axis=1, keepdims=True)
        flow[s0:s0 + 512] = _norm(fl)
    stats = dict(verts=len(V), triangles=len(F2), layers=K, grid=(n_ph, n_th), covered_cells=int(mask.sum()))
    log("hair shell: %s" % stats)
    return dict(verts=V, faces=F2, uv=np.asarray(UV), flow=flow, layer=np.asarray(LAYER), normal=NRM, stats=stats)
