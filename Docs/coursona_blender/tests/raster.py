"""오프라인 미리보기용 소프트웨어 래스터라이저 — 정사영, z-버퍼, 알파 테스트 텍스처, SDF 몸통 레이마칭."""
import numpy as np
import proxy_bust as PB

LIGHT = np.array([-0.35, -0.8, 0.6])
LIGHT = LIGHT / np.linalg.norm(LIGHT)


def camera(view):
    presets = {"front": (0.0, 0.0), "back": (180.0, 0.0), "side": (90.0, 0.0), "left": (-90.0, 0.0),
               "three_quarter": (35.0, 12.0), "below": (0.0, -30.0), "above": (0.0, 35.0)}
    az, el = presets[view] if isinstance(view, str) else view
    az, el = np.radians(az), np.radians(el)
    # 정면(az=0)에서 카메라는 −Y 쪽에 있고 +Y 를 본다
    f = np.array([np.sin(az) * np.cos(el) * -1.0, np.cos(az) * np.cos(el), -np.sin(el) * -1.0 * -1.0])
    f = np.array([-np.sin(az) * np.cos(el), np.cos(az) * np.cos(el), -np.sin(el)])
    up0 = np.array([0.0, 0.0, 1.0])
    r = np.cross(f, up0)
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    return f, r, u


def render(meshes, view, center=(0, 0, 0.42), half=(0.17, 0.2), px=520, body=True, body_color=(0.80, 0.80, 0.80),
           bg=(0.93, 0.93, 0.95), sdf=None):
    sdf = sdf or PB.sdf
    f, r, u = camera(view)
    c = np.asarray(center, float)
    W = px
    H = int(px * half[1] / half[0])
    xs = (np.arange(W) + 0.5) / W * 2 * half[0] - half[0]
    ys = half[1] - (np.arange(H) + 0.5) / H * 2 * half[1]
    X, Y = np.meshgrid(xs, ys)
    img = np.ones((H, W, 3)) * np.asarray(bg)
    zbuf = np.full((H, W), np.inf)
    if body:
        O = c + X[..., None] * r + Y[..., None] * u - f * 0.6
        O = O.reshape(-1, 3)
        t = np.zeros(len(O))
        alive = np.ones(len(O), bool)
        hit = np.zeros(len(O), bool)
        for _ in range(110):
            idx = np.where(alive)[0]
            if len(idx) == 0:
                break
            d = sdf(O[idx] + t[idx, None] * f)
            h = d < 2e-4
            hit[idx[h]] = True
            alive[idx[h]] = False
            t[idx[~h]] += np.maximum(d[~h] * 0.9, 2e-4)
            far = t > 1.3
            alive &= ~far
        hp = O[hit] + t[hit, None] * f
        g = PB.grad(hp)
        n = g / np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-9)
        lam = np.clip(n @ LIGHT, 0, 1)
        bc = body_color(hp) if callable(body_color) else np.asarray(body_color)[None]
        col = bc * (0.45 + 0.55 * lam[:, None])
        flat = img.reshape(-1, 3)
        zf = zbuf.reshape(-1)
        flat[hit] = col
        zf[hit] = t[hit] - 0.6
        img = flat.reshape(H, W, 3)
        zbuf = zf.reshape(H, W)
    for m in meshes:
        V = m["verts"]
        sx = (V - c) @ r
        sy = (V - c) @ u
        sz = (V - c) @ f
        pxs = (sx + half[0]) / (2 * half[0]) * W - 0.5
        pys = (half[1] - sy) / (2 * half[1]) * H - 0.5
        tex = m.get("texture")
        tint = np.asarray(m.get("tint", (1, 1, 1)), float)
        base = np.asarray(m.get("color", (0.5, 0.5, 0.5)), float)
        mat_cols = m.get("mat_colors")
        for fi, face in enumerate(m["faces"]):
            uvs = m["loop_uv"][fi] if tex is not None else None
            for k in range(1, len(face) - 1):
                tri = (face[0], face[k], face[k + 1])
                tuv = (uvs[0], uvs[k], uvs[k + 1]) if uvs is not None else None
                x0, y0 = pxs[list(tri)], pys[list(tri)]
                minx, maxx = int(max(np.floor(x0.min()), 0)), int(min(np.ceil(x0.max()), W - 1))
                miny, maxy = int(max(np.floor(y0.min()), 0)), int(min(np.ceil(y0.max()), H - 1))
                if minx > maxx or miny > maxy:
                    continue
                gx, gy = np.meshgrid(np.arange(minx, maxx + 1), np.arange(miny, maxy + 1))
                (ax, bx, cx), (ay, by, cy) = x0, y0
                den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
                if abs(den) < 1e-12:
                    continue
                w0 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
                w1 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
                w2 = 1 - w0 - w1
                inside = (w0 >= -1e-6) & (w1 >= -1e-6) & (w2 >= -1e-6)
                if not inside.any():
                    continue
                zz = w0 * sz[tri[0]] + w1 * sz[tri[1]] + w2 * sz[tri[2]]
                sel = inside & (zz < zbuf[gy, gx])
                if not sel.any():
                    continue
                pa, pb, pc = V[tri[0]], V[tri[1]], V[tri[2]]
                nrm = np.cross(pb - pa, pc - pa)
                nrm /= max(np.linalg.norm(nrm), 1e-12)
                lam = abs(float(nrm @ LIGHT)) if m.get("two_sided", True) else max(float(nrm @ LIGHT), 0.0)
                shade = 0.42 + 0.58 * lam
                if tex is not None:
                    uu = w0 * tuv[0][0] + w1 * tuv[1][0] + w2 * tuv[2][0]
                    vv = w0 * tuv[0][1] + w1 * tuv[1][1] + w2 * tuv[2][1]
                    th, tw = tex.shape[:2]
                    tx = np.clip((uu * (tw - 1)).astype(int), 0, tw - 1)
                    ty = np.clip(((1 - vv) * (th - 1)).astype(int), 0, th - 1)
                    a = tex[ty, tx, 3]
                    sel &= a > m.get("alpha_cut", 0.45)
                    if not sel.any():
                        continue
                    if m.get("face_colors") is not None:
                        col = np.ones_like(uu)[..., None] * np.asarray(m["face_colors"][fi])[None, None, :] * shade
                    else:
                        col = tex[ty, tx, 0][..., None] * tint[None, None, :] * shade
                    img[gy[sel], gx[sel]] = np.clip(col[sel], 0, 1)
                else:
                    if m.get("face_colors") is not None:
                        cc = np.asarray(m["face_colors"][fi], float)
                    else:
                        cc = base if mat_cols is None else np.asarray(mat_cols[m["mat_index"][fi]], float)
                    img[gy[sel], gx[sel]] = np.clip(cc * shade, 0, 1)
                zbuf[gy[sel], gx[sel]] = zz[sel]
    return (img * 255).astype(np.uint8)


def sheet(meshes, views, path, **kw):
    from PIL import Image, ImageDraw
    tiles = []
    for v in views:
        im = Image.fromarray(render(meshes, v, **kw))
        ImageDraw.Draw(im).text((8, 6), v if isinstance(v, str) else str(v), fill=(40, 40, 40))
        tiles.append(im)
    W = sum(t.width for t in tiles)
    H = max(t.height for t in tiles)
    out = Image.new("RGB", (W, H), (255, 255, 255))
    x = 0
    for t in tiles:
        out.paste(t, (x, 0))
        x += t.width
    out.save(path)
    return path


def overlay(assets_img, body_img, alpha=0.10):
    """내보내기 기본값 미리보기: 에셋 렌더를 몸통 렌더 위에 불투명도 alpha 로 얹는다(바뀐 화소만)."""
    a = assets_img.astype(np.float32)
    b = body_img.astype(np.float32)
    mask = (np.abs(a - b).sum(-1) > 6)[..., None]
    out = np.where(mask, b * (1 - alpha) + a * alpha, b)
    return np.clip(out, 0, 255).astype(np.uint8)
