"""앱(테크)이 받기 쉬운 형태로 에셋 데이터를 정리하는 공통 함수 — numpy 만(블렌더 밖에서도 테스트 가능).

- presence(): 정적 존재 마스크(0..1). 정면 1 → 옆 ≈0.46 → 뒤 0, 가슴 아래로 0. uv1.x 에 굽고, 앱은 같은 식으로도 계산 가능.
- triangulate(): (a,b,c,d) → (a,b,c)+(a,c,d) — 검증기 패치 분할 규약과 같다. 면별 값·꼭짓점별 UV 를 같이 나눈다.
- topology_hash(): sha256(int32 LE [정점 수] + 삼각형 인덱스) — 스플랫 바인딩·로드 검사용.
- face_ranges(): 면 라벨 → 연속 구간 {라벨: [시작, 끝)}.
- to_usd(): 블렌더 (x, y, z) → 계약/USD (x, z, −y).
"""
import hashlib
import numpy as np

PRESENCE_VERSION = "presence/v1"
PRESENCE = dict(face_dir=(0.0, -1.0), facing_lo=-0.30, facing_hi=0.35, z_lo=0.06, z_hi=0.20, height_scale=0.60)


def _ss(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def presence(V, head_c, P=PRESENCE):
    """V: (N,3) 블렌더 좌표. facing = 머리 중심축에서 바깥 수평 방향과 정면(−Y)의 내적."""
    V = np.asarray(V, float)
    d = V[:, :2] - np.asarray(head_c[:2], float)
    n = np.linalg.norm(d, axis=1)
    facing = np.where(n > 1e-6, (d @ np.asarray(P["face_dir"], float)) / np.maximum(n, 1e-6), 1.0)
    return _ss(P["facing_lo"], P["facing_hi"], facing) * _ss(P["z_lo"], P["z_hi"], V[:, 2])


def height01(V, P=PRESENCE):
    return np.clip(np.asarray(V, float)[:, 2] / P["height_scale"], 0.0, 1.0)


def triangulate(faces, loop_uv=None, *per_face):
    """반환: (tris, tri_loop_uv 또는 None, *복제된 면별 리스트)."""
    tris, uvs = [], ([] if loop_uv is not None else None)
    outs = [[] for _ in per_face]
    for i, f in enumerate(faces):
        f = tuple(f)
        parts = [(0, 1, 2)] if len(f) == 3 else [(0, k, k + 1) for k in range(1, len(f) - 1)]
        for a, b, c in parts:
            tris.append((f[a], f[b], f[c]))
            if uvs is not None:
                uv = loop_uv[i]
                uvs.append([uv[a], uv[b], uv[c]])
            for k, lst in enumerate(per_face):
                outs[k].append(lst[i])
    return (tris, uvs, *outs)


def topology_hash(n_verts, tris):
    arr = np.asarray([n_verts] + [i for t in tris for i in t], dtype="<i4")
    return hashlib.sha256(arr.tobytes()).hexdigest()


def face_ranges(labels):
    """연속 구간. 같은 라벨이 끊겨 있으면 구간 목록으로."""
    out, start = {}, 0
    for i in range(1, len(labels) + 1):
        if i == len(labels) or labels[i] != labels[start]:
            out.setdefault(str(labels[start]), []).append([start, i])
            start = i
    return {k: (v[0] if len(v) == 1 else v) for k, v in out.items()}


def to_usd(V):
    V = np.asarray(V, float)
    return np.stack([V[:, 0], V[:, 2], -V[:, 1]], axis=1)
