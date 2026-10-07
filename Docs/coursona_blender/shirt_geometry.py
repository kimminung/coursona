"""Shoulders_shirt 형상 — Bust 어깨·가슴 영역을 띄운 셸 + 칼라(스탠드·접힘·리프, 앞 포인트) + 절단면 안쪽 접기.

numpy 만 쓴다. 표면 질의 인터페이스(hair_geometry 와 같음) + ray():
    surface.nearest(p) -> (q, n, d)
    surface.ray(origin, direction, max_d) -> (hit, normal, index, dist) 또는 None
좌표: 블렌더 월드(Z-up, 얼굴 −Y, 피사체 왼쪽 +X, 미터).
"""
import math
import numpy as np

try:
    from . import tech_data as TD
except Exception:
    import tech_data as TD

DEFAULTS = dict(
    body_offset=0.0035,          # 셔츠 몸판: 피부에서 3.5 mm
    body_min_clear=0.0028,
    smooth_iters=6, smooth_lambda=0.45,   # 쇄골 오목 등 해부 굴곡을 천처럼 덮기
    tuck_clear=0.0008,           # 아래·팔 절단면 안쪽 접기 높이
    stand_h_front=0.018, stand_h_back=0.024, stand_rows=4,
    stand_clear0=0.0045, stand_clear1=0.0055,
    fold=0.0025,
    leaf_rows=6, leaf_off0=0.0085, leaf_off1=0.0125, leaf_tilt=0.35,
    leaf_back=0.030, point_extra=0.030, point_theta=0.40, point_width=0.17,
    notch=0.016, notch_width=0.10,
    # 디테일: 플래킷(단추 덧단)·단추·옷 주름·등 요크 솔기
    placket_half=0.016, placket_lift=0.0016, placket_ridge=0.0004, placket_rows=16,
    button_r=0.0055, button_h=0.0013, button_pitch=0.085, button_first=0.024, button_seg=14,
    wrinkle_amp=0.0007, yoke_drop=0.070, yoke_amp=0.0006, yoke_width=0.0035,
)


def _norm(v):
    return v / np.maximum(np.linalg.norm(v, axis=-1, keepdims=True), 1e-12)


def push_out(p, need, surface, iters=3):
    for _ in range(iters):
        q, n, d = surface.nearest(p)
        if d >= need - 1e-5:
            break
        p = q + n * need
    return p


def boundary_loops(faces):
    edges = {}
    for f in faces:
        for a, b in zip(f, f[1:] + f[:1]):
            k = (min(a, b), max(a, b))
            edges[k] = edges.get(k, 0) + 1
    adj = {}
    for (a, b), c in edges.items():
        if c == 1:
            adj.setdefault(a, []).append(b)
            adj.setdefault(b, []).append(a)
    loops, seen = [], set()
    for s in adj:
        if s in seen:
            continue
        loop, prev, cur = [s], None, s
        seen.add(s)
        while True:
            nxt = [v for v in adj[cur] if v != prev and (v not in seen or (v == s and len(loop) > 2))]
            if not nxt or nxt[0] == s:
                break
            prev, cur = cur, nxt[0]
            loop.append(cur)
            seen.add(cur)
        if len(loop) >= 3:
            loops.append(loop)
    return loops


def laplacian(V, faces, iters, lam, fixed):
    nb = [set() for _ in range(len(V))]
    for f in faces:
        for a, b in zip(f, f[1:] + f[:1]):
            nb[a].add(b)
            nb[b].add(a)
    V = V.copy()
    for _ in range(iters):
        avg = np.array([V[list(s)].mean(axis=0) if s else V[i] for i, s in enumerate(nb)])
        V = np.where(fixed[:, None], V, V + lam * (avg - V))
    return V


def collar_heights(theta, P):
    c = 0.5 * (1 - math.cos(theta))           # 0 앞 → 1 뒤
    h_stand = P["stand_h_front"] + (P["stand_h_back"] - P["stand_h_front"]) * c
    a = abs(theta)
    h_leaf = (P["leaf_back"]
              + P["point_extra"] * math.exp(-((a - P["point_theta"]) / P["point_width"]) ** 2)
              - P["notch"] * math.exp(-(theta / P["notch_width"]) ** 2))
    return h_stand, max(h_leaf, 0.008)


def _ray_hit(surface, origin, d, max_d=0.25):
    r = surface.ray(origin, d, max_d)
    if r is None:
        return None, None
    hit, n = np.asarray(r[0]), np.asarray(r[1])
    if np.dot(n, d) < 0:          # 축(몸 안)에서 바깥으로 쏘므로 바깥 법선은 d 와 같은 쪽
        n = -n
    return hit, n


def build_collar(loop_pts, surface, P):
    """loop_pts: 목둘레 고리(셸 정점, 앞=θ 0 기준 오름차순 정렬됨). 반환: rows(list of (2n,3)), thetas, center."""
    n = len(loop_pts)
    c = loop_pts[:, :2].mean(axis=0)
    mids = []
    for k in range(n):
        mids.append(loop_pts[k])
        mids.append(0.5 * (loop_pts[k] + loop_pts[(k + 1) % n]))
    base = np.asarray(mids)                                   # (2n,3) — 행 0 을 2배 해상도로
    th = np.arctan2(base[:, 0] - c[0], -(base[:, 1] - c[1]))
    rows = []
    prev = base.copy()
    K, M = P["stand_rows"], P["leaf_rows"]
    hs = np.array([collar_heights(t, P)[0] for t in th])
    hl = np.array([collar_heights(t, P)[1] for t in th])
    dirs = np.stack([np.sin(th), -np.cos(th), np.zeros_like(th)], axis=1)
    for r in range(1, K + 1):
        cur = np.empty_like(base)
        for j in range(len(base)):
            z = base[j, 2] + hs[j] * r / K
            hit, nn = _ray_hit(surface, np.array([c[0], c[1], z]), dirs[j])
            clear = P["stand_clear0"] + (P["stand_clear1"] - P["stand_clear0"]) * r / K
            cur[j] = hit + nn * clear if hit is not None else prev[j] + np.array([0, 0, hs[j] / K])
        rows.append(cur)
        prev = cur
    top = prev
    fold = top + dirs * P["fold"] + np.array([0.0, 0.0, 0.0012])
    rows.append(fold)
    # 리프: 접힘 아래 피부 위를 '정해진 길이'만큼 걸어 내려간다(목 → 어깨·가슴). 광선 방식은 어깨 경사에서
    # 멀리 튀어 망토처럼 퍼졌다(대리 흉상 미리보기에서 확인) — 표면 걷기로 칼라가 목둘레에 붙어 있게 한다.
    walk = []
    for j in range(len(base)):
        q, nn, _ = surface.nearest(top[j])
        walk.append(q)
    walk = np.asarray(walk)
    ds = hl / M
    for m in range(1, M + 1):
        cur = np.empty_like(base)
        s = m / M
        off = P["leaf_off0"] + (P["leaf_off1"] - P["leaf_off0"]) * s ** 1.5
        for j in range(len(base)):
            q, nn, _ = surface.nearest(walk[j])
            radial = np.array([walk[j][0] - c[0], walk[j][1] - c[1], 0.0])
            radial /= max(np.linalg.norm(radial), 1e-9)
            want = np.array([0.0, 0.0, -1.0]) + P["leaf_tilt"] * radial
            tdir = want - nn * np.dot(want, nn)
            if np.linalg.norm(tdir) < 1e-6:
                tdir = radial
            tdir /= np.linalg.norm(tdir)
            q2, n2, _ = surface.nearest(walk[j] + tdir * ds[j])
            walk[j] = q2
            cur[j] = push_out(q2 + n2 * off, off * 0.9, surface)
        rows.append(cur)
    return rows, th, c


def _vertex_normals(V, faces):
    N = np.zeros_like(V)
    for f in faces:
        for i in range(1, len(f) - 1):
            a, b, c = f[0], f[i], f[i + 1]
            n = np.cross(V[b] - V[a], V[c] - V[a])
            N[a] += n
            N[b] += n
            N[c] += n
    return _norm(N)


def build_placket(surface, c, z_top, z_bottom, P):
    """앞 중심 단추 덧단: 몸판 위 1.6 mm 띄운 3열 띠(가운데가 0.4 mm 더 솟음). 반환 V, faces, 중심선 점·법선."""
    rows = []
    for z in np.linspace(z_top, z_bottom, P["placket_rows"]):
        r = surface.ray(np.array([c[0], c[1], z]), np.array([0.0, -1.0, 0.0]), 0.3)
        if r is None:
            continue
        hit, n = np.asarray(r[0]), np.asarray(r[1])
        if np.dot(n, [0, -1, 0]) < 0:
            n = -n
        off = P["body_offset"] + P["placket_lift"]
        pts = []
        for dx, lift in ((-P["placket_half"], off), (0.0, off + P["placket_ridge"]), (P["placket_half"], off)):
            e = hit + np.array([dx, 0.0, 0.0])
            q, nn, _ = surface.nearest(e)
            pts.append(push_out(q + nn * lift, lift * 0.9, surface))
        rows.append((np.asarray(pts), hit, n))
    V = np.concatenate([r[0] for r in rows])
    F = []
    for i in range(len(rows) - 1):
        for cidx in range(2):
            a = i * 3 + cidx
            F.append((a, a + 1, a + 4, a + 3))
    centers = [(r[1], r[2]) for r in rows]
    return V, F, centers


def build_button(center, n, P):
    """단추: 바닥 고리 → 윗면 고리(살짝 작게) → 돔 중심. 바깥을 보는 감김."""
    n = _norm(np.asarray(n, float))
    up = np.array([0.0, 0.0, 1.0])
    t1 = _norm(np.cross(n, up))
    t2 = np.cross(n, t1)
    seg, r, h = P["button_seg"], P["button_r"], P["button_h"]
    V = []
    for k in range(seg):
        a = 2 * math.pi * k / seg
        V.append(center + t1 * (r * math.cos(a)) + t2 * (r * math.sin(a)))
    for k in range(seg):
        a = 2 * math.pi * k / seg
        V.append(center + n * h + t1 * (0.92 * r * math.cos(a)) + t2 * (0.92 * r * math.sin(a)))
    V.append(center + n * (h + 0.0005))
    V = np.asarray(V)
    F = []
    for k in range(seg):
        k1 = (k + 1) % seg
        F.append((k, k1, seg + k1, seg + k))
        F.append((seg + k, seg + k1, 2 * seg))
    out = []
    for f in F:
        Pf = V[list(f)]
        nrm = np.cross(Pf[1] - Pf[0], Pf[2] - Pf[0])
        out.append(tuple(f) if np.dot(nrm, Pf.mean(axis=0) - center) >= 0 else tuple(f[::-1]))
    return V, out


def orient_faces(V, faces, surface):
    out = []
    for f in faces:
        P = V[list(f)]
        ctr = P.mean(axis=0)
        nrm = np.zeros(3)
        for i in range(1, len(f) - 1):
            nrm += np.cross(P[i] - P[0], P[i + 1] - P[0])
        q, n, d = surface.nearest(ctr)
        out.append(tuple(f[::-1]) if np.dot(nrm, n) < 0 else tuple(f))
    return out


SEX_PRESETS = {  # 칼라·단추 치수(남성은 스탠드·리프·단추가 조금 크다)
    "male": dict(stand_h_front=0.020, stand_h_back=0.026, leaf_back=0.032, point_extra=0.033, button_r=0.0060),
    "female": dict(stand_h_front=0.017, stand_h_back=0.023, leaf_back=0.028, point_extra=0.027, button_r=0.0052),
}


def build_shirt(bust_V, bust_F, bust_N, region_mask, surface, params=None, log=print, sex="male"):
    """반환 dict: verts, faces, src(정점별 원본 Bust 정점, 새 정점은 -1), kind(0 몸판, 1 접기, 2 칼라, 3 플래킷, 4 단추), loop_uv, stats."""
    P = dict(DEFAULTS)
    P.update(SEX_PRESETS[sex])
    if params:
        P.update(params)
    body_f = [f for f in bust_F if all(region_mask[i] for i in f)]
    used = sorted({i for f in body_f for i in f})
    remap = {v: k for k, v in enumerate(used)}
    F = [tuple(remap[i] for i in f) for f in body_f]
    src = np.array(used)
    V = bust_V[src] + bust_N[src] * P["body_offset"]
    loops = boundary_loops(F)
    if not loops:
        raise RuntimeError("어깨 영역에 경계 고리가 없다(목둘레를 못 찾음)")
    loops.sort(key=lambda L: -V[L, 2].mean())
    neck = loops[0]
    fixed = np.zeros(len(V), bool)
    for L in loops:
        fixed[L] = True
    V = laplacian(V, F, P["smooth_iters"], P["smooth_lambda"], fixed)
    # 옷 주름(저주파 노이즈)과 등 요크 솔기(가로 능선) — 천이 몸에 그대로 붙은 '페인트' 느낌을 없앤다
    Nsh = _vertex_normals(V, F)
    cxy = V[neck][:, :2].mean(axis=0)
    thv = np.arctan2(V[:, 0] - cxy[0], -(V[:, 1] - cxy[1]))
    z_back = V[neck][np.argmax(np.abs(np.arctan2(V[neck][:, 0] - cxy[0], -(V[neck][:, 1] - cxy[1]))))][2]
    wr = (np.sin(41 * V[:, 0] + 1.3) * np.sin(27 * V[:, 2] + 0.7) * 0.7
          + 0.5 * np.sin(23 * V[:, 0] - 31 * V[:, 2] + 2.1) + 0.3 * np.sin(57 * V[:, 0] + 13 * V[:, 1]))
    disp = P["wrinkle_amp"] * wr
    dz = V[:, 2] - (z_back - P["yoke_drop"])
    yoke = np.exp(-(dz / P["yoke_width"]) ** 2) * (np.abs(thv) > 1.75)
    disp = disp + P["yoke_amp"] * yoke
    disp = np.where(fixed, 0.0, disp)
    V = V + Nsh * disp[:, None]
    V = np.array([push_out(v, P["body_min_clear"], surface) for v in V])
    kind = [0] * len(V)
    verts = [V]
    faces = list(F)
    srcs = list(src)
    base = len(V)
    n_body_f = len(faces)
    # 아래·팔 절단면: 안쪽으로 접어 틈을 닫는다
    tuck_n = 0
    for L in loops[1:]:
        ring = []
        for vi in L:
            s = src[vi]
            ring.append(bust_V[s] + bust_N[s] * P["tuck_clear"])
            srcs.append(s)
            kind.append(1)
        verts.append(np.asarray(ring))
        m = len(L)
        for k in range(m):
            a, b = L[k], L[(k + 1) % m]
            faces.append((a, b, base + (k + 1) % m, base + k))
        base += m
        tuck_n += m
    n_tuck_f = len(faces) - n_body_f
    # 칼라: 목둘레 고리를 θ 오름차순으로
    loopV = V[neck]
    c = loopV[:, :2].mean(axis=0)
    th = np.unwrap(np.arctan2(loopV[:, 0] - c[0], -(loopV[:, 1] - c[1])))
    if th[-1] < th[0]:
        neck = neck[::-1]
        loopV = V[neck]
    rows, th2, cc = build_collar(loopV, surface, P)
    n = len(neck)
    row_idx = []
    for R in rows:
        verts.append(R)
        row_idx.append(np.arange(base, base + len(R)))
        srcs += [-1] * len(R)
        kind += [2] * len(R)
        base += len(R)
    r1 = row_idx[0]
    for k in range(n):
        a, b = neck[k], neck[(k + 1) % n]
        cc0, d, e = r1[2 * k], r1[2 * k + 1], r1[(2 * k + 2) % (2 * n)]
        faces += [(a, b, d), (a, d, cc0), (b, e, d)]
    for ra, rb in zip(row_idx[:-1], row_idx[1:]):
        m = len(ra)
        for j in range(m):
            faces.append((ra[j], ra[(j + 1) % m], rb[(j + 1) % m], rb[j]))
    mat_index = [0] * len(faces)
    n_collar_f = len(faces) - n_body_f - n_tuck_f
    fkind = [0] * n_body_f + [1] * n_tuck_f + [2] * n_collar_f
    # 플래킷 + 단추(앞 중심), 칼라 스탠드 단추
    j_front = int(np.argmin(np.abs(th2)))
    z_neck_front = float(loopV[np.argmin(np.abs(th))][2]) if len(loopV) else float(rows[0][j_front][2])
    z_bottom = float(V[:, 2].min()) + 0.012
    PV, PF, centers = build_placket(surface, cc, z_neck_front - 0.004, z_bottom, P)
    if len(PF):
        verts.append(PV)
        faces += [tuple(i + base for i in f) for f in PF]
        mat_index += [0] * len(PF)
        fkind += [3] * len(PF)
        srcs += [-1] * len(PV)
        kind += [3] * len(PV)
        base += len(PV)
        zc = np.array([c0[2] for c0, _ in centers])
        zb = z_neck_front - P["button_first"]
        n_btn = 0
        while zb > z_bottom + 0.012:
            i = int(np.argmin(np.abs(zc - zb)))
            hit, nrm = centers[i]
            off = P["body_offset"] + P["placket_lift"] + P["placket_ridge"] + 0.0008
            BV, BF = build_button(hit + nrm * off, nrm, P)
            verts.append(BV)
            faces += [tuple(i2 + base for i2 in f) for f in BF]
            mat_index += [1] * len(BF)
            fkind += [4] * len(BF)
            srcs += [-1] * len(BV)
            kind += [4] * len(BV)
            base += len(BV)
            n_btn += 1
            zb -= P["button_pitch"]
        # 칼라 스탠드 가운데 단추(잠근 카라)
        top = rows[P["stand_rows"] - 1][j_front]
        stand_mid = top - np.array([0.0, 0.0, 0.5 * collar_heights(0.0, P)[0]])
        bdir = np.array([np.sin(th2[j_front]), -np.cos(th2[j_front]), 0.0])
        BV, BF = build_button(stand_mid + bdir * 0.0026, bdir, P)
        verts.append(BV)
        faces += [tuple(i2 + base for i2 in f) for f in BF]
        mat_index += [1] * len(BF)
        fkind += [4] * len(BF)
        srcs += [-1] * len(BV)
        kind += [4] * len(BV)
        base += len(BV)
        n_btn += 1
    else:
        n_btn = 0
    Vall = np.concatenate(verts)
    keep_mat = list(mat_index)
    oriented = orient_faces(Vall, faces, surface)
    faces = [f if k == 0 else f0 for f, f0, k in zip(oriented, faces, keep_mat)]   # 단추는 자체 감김 유지
    mat_index = keep_mat
    # 삼각화((a,b,c)+(a,c,d)) 후 (머티리얼, 종류) 순으로 정렬 → 슬롯·영역이 연속 구간이 된다
    faces, _, mat_index, fkind = TD.triangulate(faces, None, mat_index, fkind)
    order = sorted(range(len(faces)), key=lambda i: (mat_index[i], fkind[i]))
    faces = [faces[i] for i in order]
    mat_index = [mat_index[i] for i in order]
    fkind = [fkind[i] for i in order]
    KIND_NAMES = ["body", "tuck", "collar", "placket", "buttons"]
    face_kind = [KIND_NAMES[k] for k in fkind]
    # UV: u = 둘레 각도(앞 0.5), v = 높이 0(아래 끝)…1(칼라 위) — 앱 하단 페이드용
    zmin, zmax = Vall[:, 2].min(), Vall[:, 2].max()
    ang = np.arctan2(Vall[:, 0] - cc[0], -(Vall[:, 1] - cc[1]))
    u = 0.5 + ang / (2 * np.pi)
    v = (Vall[:, 2] - zmin) / max(zmax - zmin, 1e-6)
    loop_uv = []
    for f in faces:
        us = [u[i] for i in f]
        if max(us) - min(us) > 0.5:
            us = [x + 1.0 if x < 0.5 else x for x in us]
        loop_uv.append([(us[k], v[i]) for k, i in enumerate(f)])
    stats = dict(verts=len(Vall), faces=len(faces), body_verts=len(V), tuck_verts=tuck_n,
                 collar_verts=int(sum(len(R) for R in rows)), neck_loop=n, cut_loops=len(loops) - 1,
                 placket_verts=int(len(PV)) if len(PF) else 0, buttons=n_btn,
                 z_range=(float(zmin), float(zmax)))
    log("shirt: %s" % stats)
    stats["triangles"] = len(faces)
    return dict(verts=Vall, faces=faces, src=np.array(srcs), kind=np.array(kind), loop_uv=loop_uv,
                mat_index=mat_index, face_kind=face_kind, stats=stats, neck_center=cc)
