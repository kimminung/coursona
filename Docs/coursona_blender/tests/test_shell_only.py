"""저장된 가닥(hair_proxy.npz 의 S)으로 셸만 다시 만들고 테크 패널을 그린다(머리 전체 재생성 없이)."""
import os, sys, time
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, os.path.dirname(HERE)); sys.path.insert(0, HERE)
import proxy_bust as PB, hair_geometry as HG, raster
from PIL import Image
PB.set_sex("female")
d = np.load(os.path.join(os.path.dirname(HERE), "previews", "hair_proxy.npz"), allow_pickle=True)
strands = list(d["S"])
t0 = time.time()
shell = HG.build_shell(strands, PB.ProxySurface(), PB.HEAD_C)
print("shell", shell["stats"], "%.1fs" % (time.time() - t0))
outer = [f for f in shell["faces"] if shell["layer"][f[0]] == shell["layer"].max()]
sc = [np.clip(0.5 + 0.5 * shell["flow"][list(f)].mean(axis=0) * np.array([1, -1, -1]), 0, 1) for f in outer]
sm = dict(verts=shell["verts"], faces=outer, face_colors=sc, two_sided=True)
tiles = [raster.render([sm], v, center=(0, 0.0, 0.40), half=(0.17, 0.2), px=300) for v in ("front", "side", "back", "three_quarter")]
W = sum(t.shape[1] for t in tiles); sheet = Image.new("RGB", (W, tiles[0].shape[0]), (255, 255, 255)); x = 0
for t in tiles:
    sheet.paste(Image.fromarray(t), (x, 0)); x += t.shape[1]
sheet.save(os.path.join(os.path.dirname(HERE), "previews", "tech_shell_flow.png")); print("saved")
