"""T_Hair_LongWave_base.png 생성기 — 회색 RGB + 알파(스트레이트), 앱에서 곱셈 틴트.

numpy 만 쓴다(블렌더 내장 파이썬에서도 돈다). 저장은 PIL(맥 파이썬) 또는 bpy(블렌더) 중 있는 쪽.

레이아웃 (UV, 블렌더 규약: v=1 이 이미지 맨 위)
  카드 칸 6개: u ∈ [k/8, (k+1)/8], k = 0..5. 가닥 뿌리 = 위(v=1), 끝 = 아래(v=0).
    0 dense   1 medium   2 wavy   3 wispy(잔머리)   4 split(끝 갈라짐)   5 fine(뿌리 덮개)
  캡 칸: u ∈ [0.75, 1.0]. v ∈ [0.25, 1] 불투명, v < 0.25 는 헤어라인 쪽으로 성기게 사라짐.
    캡 UV 의 v 는 '헤어라인에서 떨어진 거리'(0 = 헤어라인, 1 = 정수리 쪽).

틴트 기준: 알파 가중 평균 회색 ≈ 0.66 (report()['mean_gray'] 로 확인). 앱 틴트 = 목표색 / 평균회색.
"""
import numpy as np

SIZE = 2048
CELL_COUNT = 8
CARD_CELLS = {"dense": 0, "medium": 1, "wavy": 2, "wispy": 3, "split": 4, "fine": 5}
CAP_U0, CAP_U1 = 0.75, 1.0
CAP_SOLID_V = 0.25


def card_cell_u(name):
    k = CARD_CELLS[name]
    return (k / CELL_COUNT, (k + 1) / CELL_COUNT)


def _over(C, A, c, a):
    """스트레이트 알파 'over' 합성(가닥을 뒤→앞 순서로 쌓는다). C/c 는 (h,w) 또는 (h,w,3)."""
    if C.ndim == 3:
        a3, A3 = a[..., None], A[..., None]
        out_a = a + A * (1.0 - a)
        num = c * a3 + C * A3 * (1.0 - a3)
        out_c = np.where(out_a[..., None] > 1e-6, num / np.maximum(out_a[..., None], 1e-6), C)
        return out_c, out_a
    out_a = a + A * (1.0 - a)
    num = c * a + C * A * (1.0 - a)
    out_c = np.where(out_a > 1e-6, num / np.maximum(out_a, 1e-6), C)
    return out_c, out_a


def _render_cell(rng, h, w, n, width_px, alpha_rng, gray_rng, env0, env1, wobble_amp,
                 wobble_len, len_rng, split=False, coherent_wave=0.0, root_dark=0.30, body_alpha=0.0, mode="base"):
    """한 칸(h x w)을 가닥 n 개로 그린다. 반환: (C, A) float32.
    mode='base' → 회색 1채널. mode='mask' → (R 뿌리→끝 0→1, G 가닥 id, B 하이라이트 밝기) 3채널."""
    C = np.full((h, w), 0.6, np.float32) if mode == "base" else np.full((h, w, 3), 0.5, np.float32)
    A = np.zeros((h, w), np.float32)
    rows = np.arange(h, dtype=np.float32)
    t = rows / (h - 1)                       # 0 뿌리 → 1 끝
    xs = np.arange(w, dtype=np.float32)[None, :]
    env = env0 + (env1 - env0) * t ** 1.6    # 반폭(칸 폭 비율)
    cx = w * 0.5
    wave_phase = rng.uniform(0, 2 * np.pi)
    if body_alpha > 0:
        # 덩어리 몸통: 가닥 사이를 메우는 불투명 층(끝으로 갈수록 사라짐) — 카드가 '머리 덩어리'로 읽히게
        jag = np.convolve(rng.normal(0, 1, w + 16), np.ones(5) / 5, mode="same")[8:8 + w][None, :]
        bx = cx + (coherent_wave * np.clip(t * 1.4, 0, 1) * np.sin(2 * np.pi * rows / (h * 0.42) + wave_phase)
                   if coherent_wave > 0 else 0.0)
        hw = (env * w * 0.80)[:, None] * (1.0 + 0.12 * jag)
        d = np.abs(xs - (bx[:, None] if np.ndim(bx) else bx)) / np.maximum(hw, 1.0)
        prof = np.clip(1.0 - d, 0.0, 1.0) ** 0.6
        tip = np.clip((0.86 - t) / 0.30, 0.0, 1.0) ** 1.3
        if split:
            tip = tip * np.clip((0.62 - t) / 0.12, 0.0, 1.0)
        a_body = (body_alpha * tip)[:, None] * prof
        g_body = np.mean(gray_rng) * 0.82 * (1.0 - root_dark * np.exp(-t / 0.06))
        if mode == "base":
            cb = np.broadcast_to(g_body[:, None], a_body.shape).astype(np.float32)
        else:
            cb = np.stack([np.broadcast_to(t[:, None], a_body.shape), np.full(a_body.shape, 0.5), np.full(a_body.shape, 0.5)], -1).astype(np.float32)
        C, A = _over(C, A, cb, a_body.astype(np.float32))
    # 잔머리(flyaway): 덩어리 바깥으로 삐져나오는 아주 가는 가닥 — 실루엣을 부드럽게
    n_fly = max(3, n // 14)
    order = list(rng.permutation(n)) + [-1] * n_fly
    for j in order:
        fly = j < 0
        s = rng.uniform(-1.0, 1.0)
        s = np.sign(s) * abs(s) ** (0.5 if fly else 0.8)   # 가장자리에 덜 몰리게(잔머리는 바깥쪽)
        L = rng.uniform(*len_rng) if not fly else rng.uniform(0.35, 0.95)
        wid = rng.uniform(*width_px) if not fly else rng.uniform(0.7, 1.1)
        a0 = rng.uniform(*alpha_rng) if not fly else rng.uniform(0.2, 0.45)
        g = rng.uniform(*gray_rng)
        if rng.random() < 0.12:
            g = min(1.0, g * 1.22)           # 햇빛 받은 밝은 가닥(하이라이트)
        sid = rng.random()                   # 마스크 G: 가닥 id
        amp = rng.uniform(0.3, 1.0) * wobble_amp
        lam = rng.uniform(0.7, 1.3) * wobble_len
        ph = rng.uniform(0, 2 * np.pi)
        off = s * env * (w * (1.35 if fly else 1.0))
        if split:
            side = 1.0 if s >= 0 else -1.0
            sp = np.clip((t - 0.55) / 0.45, 0.0, 1.0) ** 1.5
            off = off + side * sp * 0.16 * w - s * sp * env * w * 0.35
        x = cx + off + amp * np.sin(2 * np.pi * rows / lam + ph)
        if coherent_wave > 0:
            x = x + coherent_wave * np.clip(t * 1.4, 0, 1) * np.sin(2 * np.pi * rows / (h * 0.42) + wave_phase)
        # 길이 마스크 + 끝 가늘어짐
        fade = np.clip((L - t) / 0.08, 0.0, 1.0) ** 1.2
        thin = 0.55 + 0.45 * np.clip((L - t) / max(L, 1e-3), 0, 1)
        sig = np.maximum(wid * thin * 0.5, 0.35)
        prof = np.exp(-((xs - x[:, None]) / sig[:, None]) ** 2)
        a = (a0 * fade)[:, None] * prof
        bal = 1.0 + 0.20 * (t - 0.4)                             # 발레아주: 끝으로 갈수록 밝게
        shade = g * bal * (1.0 - root_dark * np.exp(-t / 0.06))  # 뿌리 쪽 어둡게
        hl = 1.0 + 0.10 * np.sin(2 * np.pi * rows / rng.uniform(380, 700) + ph)  # 은은한 결
        if mode == "base":
            c = np.clip((shade * hl)[:, None] * np.ones_like(prof), 0, 1)
        else:
            c = np.stack([np.broadcast_to(t[:, None], prof.shape), np.full(prof.shape, sid),
                          np.broadcast_to(np.clip(0.5 + 0.5 * (hl - 1.0) * 5, 0, 1)[:, None], prof.shape)], -1)
        C, A = _over(C, A, c.astype(np.float32), a.astype(np.float32))
    return C, A


def _render_cap(rng, h, w, mode="base"):
    """캡 칸: 위 75% 불투명 결, 아래 25% 는 헤어라인 쪽으로 성기게 사라짐."""
    C = np.full((h, w), 0.52, np.float32) if mode == "base" else np.full((h, w, 3), 0.5, np.float32)
    if mode == "mask":
        C[..., 0] = 0.3
    solid_rows = int(h * (1.0 - CAP_SOLID_V))            # 위에서부터 이 행까지 불투명
    rows = np.arange(h, dtype=np.float32)
    base_a = np.ones(h, np.float32)
    edge = (rows - solid_rows) / (h - solid_rows)        # 0..1 (헤어라인 쪽 구간)
    base_a = np.where(rows < solid_rows, 1.0, np.clip(1.0 - edge * 1.15, 0, 1) ** 2.2)
    A = np.repeat(base_a[:, None], w, axis=1).astype(np.float32)
    xs = np.arange(w, dtype=np.float32)[None, :]
    for _ in range(260):
        xc = rng.uniform(0, w)
        wid = rng.uniform(1.2, 2.6)
        g = rng.uniform(0.42, 0.9)
        end = rng.uniform(0.80, 1.0)                     # 헤어라인 구간 안에서 끝나는 지점(t)
        t = rows / (h - 1)
        fade = np.clip((end - t) / 0.05, 0, 1)
        xw = xc + 2.0 * np.sin(2 * np.pi * rows / rng.uniform(250, 600) + rng.uniform(0, 6.28))
        prof = np.exp(-((xs - xw[:, None]) / (wid * 0.5)) ** 2)
        a = (0.85 * fade)[:, None] * prof
        if mode == "base":
            cc = np.full_like(prof, g, dtype=np.float32)
        else:
            cc = np.stack([np.full(prof.shape, 0.3), np.full(prof.shape, rng.random()), np.full(prof.shape, 0.5)], -1).astype(np.float32)
        C, A = _over(C, A, cc, a.astype(np.float32))
    return C, A


def _dilate_color(C, A, iters=24):
    """알파 0 영역의 RGB 를 이웃 가닥색으로 채운다(밉맵·필터링 시 테두리 번짐 방지)."""
    C = C.copy()
    W = (A > 0.02).astype(np.float32)
    for _ in range(iters):
        num = np.zeros_like(C)
        den = np.zeros_like(C)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                num += np.roll(np.roll(C * W, dy, 0), dx, 1)
                den += np.roll(np.roll(W, dy, 0), dx, 1)
        fill = (W < 0.5) & (den > 0)
        C[fill] = num[fill] / den[fill]
        W = np.maximum(W, fill.astype(np.float32))
    return C


def generate(size=SIZE, seed=20261007, mode="base"):
    """RGBA float32 (size, size, 4), 행 0 = 이미지 맨 위(v=1).
    mode='base': 회색 RGB + 알파(틴트용). mode='mask': R 뿌리→끝, G 가닥 id, B 하이라이트 + 같은 알파
    (초상 T_Hair_Atlas_mask 채널 규약과 같은 뜻 — 앱이 뿌리 어둡게/가닥별 색 변화에 쓸 수 있다)."""
    rng = np.random.default_rng(seed)
    h = size
    cw = size // CELL_COUNT
    C = np.full((h, size), 0.6, np.float32) if mode == "base" else np.full((h, size, 3), 0.5, np.float32)
    A = np.zeros((h, size), np.float32)
    specs = {
        # n, width_px, alpha, gray, env0, env1, wobble_amp, wobble_len, len_rng, split, coherent, body
        "dense":  (130, (1.6, 2.8), (0.75, 1.0), (0.48, 0.95), 0.46, 0.16, 2.0, 520, (0.86, 1.0), False, 0.0, 0.97),
        "medium": (100, (1.4, 2.4), (0.70, 1.0), (0.48, 0.97), 0.42, 0.13, 2.5, 480, (0.80, 1.0), False, 0.0, 0.90),
        "wavy":   (95, (1.4, 2.4), (0.70, 1.0), (0.50, 0.97), 0.40, 0.14, 2.0, 500, (0.82, 1.0), False, 9.0, 0.88),
        "wispy":  (34, (0.9, 1.5), (0.40, 0.80), (0.52, 0.98), 0.47, 0.30, 5.0, 420, (0.55, 1.0), False, 4.0, 0.0),
        "split":  (100, (1.4, 2.4), (0.70, 1.0), (0.48, 0.97), 0.44, 0.12, 2.0, 500, (0.80, 1.0), True, 0.0, 0.88),
        "fine":   (150, (1.0, 1.8), (0.80, 1.0), (0.45, 0.90), 0.48, 0.30, 1.5, 560, (0.90, 1.0), False, 0.0, 0.97),
    }
    for name, k in CARD_CELLS.items():
        n, wpx, ar, gr, e0, e1, wa, wl, lr, sp, cohe, body = specs[name]
        c, a = _render_cell(rng, h, cw, n, wpx, ar, gr, e0, e1, wa, wl, lr, split=sp, coherent_wave=cohe,
                            body_alpha=body, mode=mode)
        C[:, k * cw:(k + 1) * cw] = c
        A[:, k * cw:(k + 1) * cw] = a
    u0 = int(CAP_U0 * size)
    c, a = _render_cap(rng, h, size - u0, mode=mode)
    C[:, u0:] = c
    A[:, u0:] = a
    rgba = np.empty((h, size, 4), np.float32)
    if mode == "base":
        C = _dilate_color(C, A)
        rgba[..., 0] = rgba[..., 1] = rgba[..., 2] = np.clip(C, 0, 1)
    else:
        for k in range(3):
            rgba[..., k] = np.clip(_dilate_color(np.ascontiguousarray(C[..., k]), A), 0, 1)
    rgba[..., 3] = np.clip(A, 0, 1)
    return rgba


def report(rgba):
    A = rgba[..., 3]
    g = rgba[..., 0]
    cw = rgba.shape[1] // CELL_COUNT
    cov = {name: float((A[:, k * cw:(k + 1) * cw] > 0.5).mean()) for name, k in CARD_CELLS.items()}
    u0 = int(CAP_U0 * rgba.shape[1])
    cov["cap"] = float((A[:, u0:] > 0.5).mean())
    return {"mean_gray": float((g * A).sum() / max(A.sum(), 1e-6)), "coverage_alpha_gt_0.5": cov}


def save_png_pil(rgba, path):
    from PIL import Image
    arr = (np.clip(rgba, 0, 1) * 255.0 + 0.5).astype(np.uint8)
    Image.fromarray(arr, "RGBA").save(path, optimize=True)


def save_png_bpy(rgba, path, name="T_Hair_LongWave_base"):
    """블렌더 안에서 저장(bpy 이미지는 행 0 = 맨 아래라 뒤집는다)."""
    import bpy
    h, w = rgba.shape[:2]
    img = bpy.data.images.get(name) or bpy.data.images.new(name, w, h, alpha=True)
    if img.size[0] != w or img.size[1] != h:
        img.scale(w, h)
    img.pixels.foreach_set(np.ascontiguousarray(rgba[::-1]).ravel())
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    return img


if __name__ == "__main__":
    import sys, time
    out = sys.argv[1] if len(sys.argv) > 1 else "T_Hair_LongWave_base.png"
    t0 = time.time()
    tex = generate()
    save_png_pil(tex, out)
    print(out, report(tex), "%.1fs" % (time.time() - t0))
    mask = generate(mode="mask")
    mpath = out.replace("_base.png", "_mask.png")
    save_png_pil(mask, mpath)
    print(mpath, "%.1fs" % (time.time() - t0))
