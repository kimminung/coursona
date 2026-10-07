import os, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
import proxy_bust as PB
import hair_geometry as HG
import tech_data as TD


def run(out_dir):
    t0 = time.time()
    PB.set_sex("female")                      # 긴 머리 에셋 → 여성 두상
    scalp = PB.scalp_mesh()
    patch = PB.patch_points()
    surf = PB.ProxySurface()
    hair = HG.build_hair(scalp, patch, surf, PB.HEAD_C, chin_z=0.334, brow_z=0.462)
    V = hair["verts"]
    d = np.array([PB.sdf(v) for v in V])
    print("verts", len(V), "faces", len(hair["faces"]), "min clearance mm %.2f" % (d.min() * 1000),
          "below 1mm:", int((d < 0.001).sum()), "time %.1fs" % (time.time() - t0))
    print("z range", V[:, 2].min().round(3), V[:, 2].max().round(3), "x range", V[:, 0].min().round(3), V[:, 0].max().round(3))
    np.savez(os.path.join(out_dir, "hair_proxy.npz"), V=V, F=np.array([f for f in hair["faces"]], dtype=object),
             S=np.array(hair["strands"], dtype=object), allow_pickle=True)
    render(hair, scalp, out_dir)
    tech(hair, surf, out_dir)
    return hair


def tech(hair, surf, out_dir):
    """테크 데이터 확인: 머리 presence(흰 1 → 검정 0), 스플랫 셸 바깥 겹의 flow(방향 → RGB)."""
    import raster as R2
    from PIL import Image as I2
    t0 = time.time()
    shell = HG.build_shell(hair["strands"], surf, PB.HEAD_C)
    print("shell", shell["stats"], "min clear mm %.2f" % (min(PB.sdf(v) for v in shell["verts"][::7]) * 1000), "%.1fs" % (time.time() - t0))
    V = hair["verts"]
    pres = TD.presence(V, PB.HEAD_C)
    fc = [np.repeat(0.12 + 0.86 * pres[list(f)].mean(), 3) for f in hair["faces"]]
    tex = np.asarray(I2.open(os.path.join(os.path.dirname(HERE), "textures", "T_Hair_LongWave_base.png"))).astype(np.float32) / 255.0
    hm = dict(verts=V, faces=hair["faces"], loop_uv=hair["loop_uv"], texture=tex, face_colors=fc)
    outer = [f for f in shell["faces"] if shell["layer"][f[0]] == shell["layer"].max()]
    fl = shell["flow"]
    sc = [np.clip(0.5 + 0.5 * fl[list(f)].mean(axis=0) * np.array([1, -1, -1]), 0, 1) for f in outer]
    sm = dict(verts=shell["verts"], faces=outer, face_colors=sc, two_sided=True)
    tiles = []
    for v in ("front", "side", "back"):
        tiles.append(R2.render([hm], v, center=(0, 0.0, 0.40), half=(0.17, 0.2), px=300))
    for v in ("front", "side", "back"):
        tiles.append(R2.render([sm], v, center=(0, 0.0, 0.40), half=(0.17, 0.2), px=300))
    W = sum(t.shape[1] for t in tiles); Hh = tiles[0].shape[0]
    sheet = I2.new("RGB", (W, Hh), (255, 255, 255)); x = 0
    for t in tiles:
        sheet.paste(I2.fromarray(t), (x, 0)); x += t.shape[1]
    sheet.save(os.path.join(out_dir, "tech_hair_presence_shell.png"))
    print("tech saved")


def render(hair, scalp, out_dir):
    from PIL import Image
    import raster
    tex = np.asarray(Image.open(os.path.join(os.path.dirname(HERE), "textures", "T_Hair_LongWave_base.png"))).astype(np.float32) / 255.0
    tint = np.array([0.80, 0.80, 0.80]) / 0.63        # 색을 뺀 무채색(연회색) 상태
    mesh = dict(verts=hair["verts"], faces=hair["faces"], loop_uv=hair["loop_uv"], texture=tex, tint=tint)
    p = raster.sheet([mesh], ["front", "three_quarter", "side", "back"], os.path.join(out_dir, "hair_proxy_views.png"),
                     center=(0, 0.0, 0.40), half=(0.17, 0.2), px=420)
    import raster as R2
    from PIL import Image as I2
    heads = []
    for sx in ("female", "male"):
        PB.set_sex(sx)
        heads.append(R2.render([], "front", center=(0, 0, 0.40), half=(0.17, 0.2), px=300))
        heads.append(R2.render([], "side", center=(0, 0, 0.40), half=(0.17, 0.2), px=300))
    PB.set_sex("female")
    W = sum(h.shape[1] for h in heads); Hh = heads[0].shape[0]
    sheet = I2.new("RGB", (W, Hh), (255, 255, 255)); x = 0
    for h in heads:
        sheet.paste(I2.fromarray(h), (x, 0)); x += h.shape[1]
    sheet.save(os.path.join(out_dir, "proxy_heads_female_male.png"))
    # 유령 룩 목업(앱 합성 목표): 여성 두상 + 머리, 정면·¾
    import ghost_mock as GM
    PB.set_sex("female")
    tiles = []
    for v in ("front", "three_quarter"):
        full = R2.render([mesh], v, center=(0, 0.0, 0.40), half=(0.17, 0.2), px=420)
        blank = R2.render([], v, center=(0, 0.0, 0.40), half=(0.17, 0.2), px=420, body=False)
        tiles.append(R2.overlay(full, blank, 0.10))     # 내보내기 기본값: 피부·머리 모두 무채색 10%
        tiles.append(GM.ghost(full))                    # 앱 유령 룩 목표(색은 앱이 사진에서 입힘)
    W = sum(t.shape[1] for t in tiles); Hh = tiles[0].shape[0]
    gs = I2.new("RGB", (W, Hh), (255, 255, 255)); x = 0
    for t in tiles:
        gs.paste(I2.fromarray(t), (x, 0)); x += t.shape[1]
    gs.save(os.path.join(out_dir, "persona_ghost_mock.png"))
    print("saved", p)


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(HERE), "previews")
    os.makedirs(out, exist_ok=True)
    run(out)
