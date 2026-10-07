"""오프라인 테스트용 대리 흉상 — Chosang 비율(턱 ≈0.334, 입 0.380, 눈 0.44, 이마 끝 0.507, 정수리 0.567, 목·어깨 경계 0.265).

set_sex('female' | 'male') 로 두상·목·어깨 비율을 바꾼다. 여성: 좁은 턱·광대·가는 목·좁고 처진 어깨.
남성: 넓고 각진 턱·턱끝·눈썹 융기·굵은 목·넓은 어깨. 둘 다 코·후두부(뒤통수) 볼륨이 있다.
해석적 SDF 로 nearest / ray_down 을 제공한다(블렌더의 BVHSurface 와 같은 인터페이스).
실제 Bust 와 모양이 같지 않으므로, 결과는 '알고리즘이 의도대로 도는지' 확인용이다.
"""
import numpy as np

# 서양인 성인 평균 인체계측(m): 머리폭 F 0.145 / M 0.153, 머리길이 0.185 / 0.195, 광대폭 0.130 / 0.140,
# 하악각폭 0.098 / 0.108, 코 돌출 0.019 / 0.022, 코 폭 0.031 / 0.035, 목 둘레 0.33 / 0.38, 어깨폭(견봉) 0.36 / 0.40.
# 계약 랜드마크(눈 0.44, 입 0.380, 턱 0.334, 정수리 0.567)는 그대로 둔다. features: (중심, 반지름, 녹임 k, 좌우 대칭 여부)
# 두상은 둥근 타원체 하나(이마·턱·코·입술 볼륨 없음). 색과 윤곽은 Xcode 가 트루뎁스 정점으로 코드에서 만든다.
# 남녀 차이는 머리폭·머리길이·목 둘레·어깨폭만. 계약 랜드마크(턱 0.334, 정수리 0.567, 눈 0.44, 입 0.380)는 그대로.
PRESETS = {
    "female": dict(
        head_c=(0.0, 0.006, 0.4505), head_r=(0.0725, 0.0925, 0.1165),
        features=[], lip_protrusion=0.0, lips_r=(0.024, 0.009, 0.011), face_y=-0.0865,
        neck_c=(0.0, 0.012, 0.0), neck_r=0.052, neck_top=0.40,
        torso_c=(0.0, 0.012, 0.105), torso_r=(0.190, 0.105, 0.145),
        ear_x=0.0765, ear_r=(0.010, 0.016, 0.0295), ear_z=0.432, patch_hw=0.066,
    ),
    "male": dict(
        head_c=(0.0, 0.006, 0.4505), head_r=(0.0765, 0.0975, 0.1165),
        features=[], lip_protrusion=0.0, lips_r=(0.026, 0.010, 0.012), face_y=-0.0915,
        neck_c=(0.0, 0.012, 0.0), neck_r=0.060, neck_top=0.40,
        torso_c=(0.0, 0.012, 0.115), torso_r=(0.210, 0.120, 0.150),
        ear_x=0.0805, ear_r=(0.012, 0.019, 0.031), ear_z=0.432, patch_hw=0.072,
    ),
}
P = dict(PRESETS["female"])
SEX = "female"
HEAD_C = np.array(P["head_c"])


def set_sex(sex, lip_protrusion=None):
    """두상 프리셋 선택. lip_protrusion(m)으로 입 돌출을 바꿀 수 있다(기본 F 8 mm / M 9 mm)."""
    global P, SEX, HEAD_C
    P = dict(PRESETS[sex])
    if lip_protrusion is not None:
        P["lip_protrusion"] = float(lip_protrusion)
    SEX = sex
    HEAD_C = np.array(P["head_c"])
    return P


def _ell(p, c, r):
    q = (p - np.asarray(c)) / np.asarray(r)
    k0 = np.linalg.norm(q, axis=-1)
    k1 = np.linalg.norm(q / np.asarray(r), axis=-1)
    return k0 * (k0 - 1.0) / np.maximum(k1, 1e-9)


def _capsule_z(p, c, z0, z1, rad):
    q = p - np.asarray(c)
    z = np.clip(q[..., 2], z0 - c[2], z1 - c[2])
    d = q.copy()
    d[..., 2] = q[..., 2] - z
    return np.linalg.norm(d, axis=-1) - rad


def _smin(a, b, k):
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0, 1)
    return b * (1 - h) + a * h - k * h * (1 - h)


def sdf(p):
    p = np.asarray(p, float)
    d = _ell(p, P["head_c"], P["head_r"])
    for name, c, r, k, mirror in P["features"]:
        if mirror:
            d = _smin(d, _ell(p, c, r), k)
            d = _smin(d, _ell(p, (-c[0], c[1], c[2]), r), k)
        else:
            d = _smin(d, _ell(p, c, r), k)
    # 입 돌출(입술 둔덕): 가장 앞점이 face_y − lip_protrusion 에 오도록 중심을 반지름만큼 뒤로
    if P["lip_protrusion"] > 0:                                           # 기본 0: 매끈한 얼굴면
        lips = (0.0, P["face_y"] - P["lip_protrusion"] + P["lips_r"][1], 0.380)
        d = _smin(d, _ell(p, lips, P["lips_r"]), 0.025)
    d = _smin(d, _capsule_z(p, P["neck_c"], 0.22, P["neck_top"], P["neck_r"]), 0.03)
    d = _smin(d, _ell(p, P["torso_c"], P["torso_r"]), 0.04)
    ex, ez = P["ear_x"], P["ear_z"]
    d = np.minimum(d, _ell(p, (ex, 0.012, ez), P["ear_r"]))
    d = np.minimum(d, _ell(p, (-ex, 0.012, ez), P["ear_r"]))
    d = np.maximum(d, -(p[..., 2] - 0.0))      # 바닥 절단
    return d


def grad(p, eps=1e-4):
    p = np.asarray(p, float)
    g = np.zeros_like(p)
    for k in range(3):
        e = np.zeros(3)
        e[k] = eps
        g[..., k] = (sdf(p + e) - sdf(p - e)) / (2 * eps)
    return g


class ProxySurface:
    def nearest(self, p):
        p = np.asarray(p, float)
        q = p.copy()
        for _ in range(3):
            d = sdf(q)
            g = grad(q)
            n = g / max(np.linalg.norm(g), 1e-9)
            q = q - d * n
        d = float(sdf(p))
        g = grad(q)
        n = g / max(np.linalg.norm(g), 1e-9)
        return q, n, d

    def ray(self, origin, direction, max_d):
        d = np.asarray(direction, float)
        d = d / np.linalg.norm(d)
        o = np.asarray(origin, float)
        inside = sdf(o) < 0
        t_prev, t = 0.0, 0.0
        for _ in range(500):
            s_ = float(sdf(o + t * d))
            if (s_ >= 0) == inside:
                break
            t_prev = t
            t += max(abs(s_) * 0.9, 2e-4)
            if t > max_d:
                return None
        a, b = t_prev, t
        for _ in range(24):
            m = (a + b) / 2
            if (sdf(o + m * d) < 0) == inside:
                a = m
            else:
                b = m
        hit = o + b * d
        g = grad(hit)
        return hit, g / np.linalg.norm(g), 0, b

    def ray_down(self, p, max_d):
        t = 0.0
        p = np.asarray(p, float)
        for _ in range(96):
            d = float(sdf(p - np.array([0, 0, t])))
            if d < 2e-4:
                return t
            t += max(d * 0.9, 4e-4)
            if t > max_d:
                return None
        return None


def project(pts, it=6):
    q = np.asarray(pts, float).copy()
    for _ in range(it):
        d = sdf(q)
        g = grad(q)
        n = g / np.maximum(np.linalg.norm(g, axis=-1, keepdims=True), 1e-9)
        q = q - d[..., None] * n
    return q


def hairline_z(phi):
    xs = [0.0, 0.9, 1.6, 2.2, 2.6, np.pi]
    zs = [0.505, 0.472, 0.462, 0.432, 0.398, 0.392]
    return np.interp(np.abs(phi), xs, zs)


def scalp_mesh(n_th=44, n_ph=72):
    th = np.linspace(0.02, 0.62 * np.pi, n_th)
    ph = np.linspace(-np.pi, np.pi, n_ph, endpoint=False)
    T, Ph = np.meshgrid(th, ph, indexing="ij")
    r = np.asarray(P["head_r"]) * 1.03
    pts = np.stack([r[0] * np.sin(T) * np.sin(Ph), -r[1] * np.sin(T) * np.cos(Ph), r[2] * np.cos(T)], -1) + HEAD_C
    pts = project(pts.reshape(-1, 3)).reshape(n_th, n_ph, 3)
    phi = np.arctan2(pts[..., 0], -(pts[..., 1] - HEAD_C[1]))
    inside = pts[..., 2] > hairline_z(phi)
    idx = -np.ones((n_th, n_ph), int)
    V = []
    for i in range(n_th):
        for j in range(n_ph):
            if inside[i, j]:
                idx[i, j] = len(V)
                V.append(pts[i, j])
    V = np.asarray(V)
    F = []
    cnt = np.zeros(len(V), int)
    for i in range(n_th - 1):
        for j in range(n_ph):
            a, b, c, d = idx[i, j], idx[i, (j + 1) % n_ph], idx[i + 1, (j + 1) % n_ph], idx[i + 1, j]
            if min(a, b, c, d) >= 0:
                F.append((a, d, c, b))
                for v in (a, b, c, d):
                    cnt[v] += 1
    g = grad(V)
    N = g / np.linalg.norm(g, axis=1, keepdims=True)
    used = cnt > 0
    boundary = (cnt < 4) & used
    boundary[idx[0][idx[0] >= 0]] = False
    return dict(v=V, n=N, faces=F, boundary=boundary)


def patch_points(n=3000, seed=1):
    rng = np.random.default_rng(seed)
    out = []
    r = np.asarray(P["head_r"]) * 1.05
    while len(out) < n:
        th = rng.uniform(0.35 * np.pi, 0.95 * np.pi)
        ph = rng.uniform(-1.1, 1.1)
        p = np.array([r[0] * np.sin(th) * np.sin(ph), -r[1] * np.sin(th) * np.cos(ph), r[2] * np.cos(th)]) + HEAD_C
        p = project(p[None])[0]
        if 0.334 <= p[2] <= 0.507 and abs(p[0]) < P["patch_hw"] and p[1] < -0.02:
            out.append(p)
    return np.asarray(out)


def body_mesh(res=0.006):
    xs = np.arange(-0.24, 0.24, res)
    ys = np.arange(-0.14, 0.15, res)
    zs = np.arange(0.0, 0.58, res)
    X, Y, Z = np.meshgrid(xs, ys, zs, indexing="ij")
    Pq = np.stack([X, Y, Z], -1).reshape(-1, 3)
    d = sdf(Pq)
    m = np.abs(d) < res * 0.6
    return Pq[m]
