"""유령 룩 목업: 렌더 → 실루엣 마스크 → 가장자리 블러 + 전체 반투명 + 하단 페이드 → 따뜻한 실내 배경 위 합성."""
import numpy as np
from PIL import Image, ImageFilter

def ghost(rgb_u8, bg_rgb=(237, 237, 242), opacity=0.86, edge_blur=9, fade_from=0.72, fade_to=0.98):
    img = Image.fromarray(rgb_u8)
    arr = np.asarray(img).astype(np.int16)
    mask = (np.abs(arr - np.array(bg_rgb)).sum(-1) > 18).astype(np.uint8) * 255
    m = Image.fromarray(mask).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(edge_blur))
    a = np.asarray(m).astype(np.float32) / 255.0 * opacity
    h = a.shape[0]
    rows = np.arange(h)[:, None] / h
    fade = 1.0 - np.clip((rows - fade_from) / (fade_to - fade_from), 0, 1) ** 1.4
    a = a * fade
    blurred = np.asarray(img.filter(ImageFilter.GaussianBlur(1.2))).astype(np.float32) / 255.0
    yy, xx = np.mgrid[0:h, 0:a.shape[1]]
    bg = np.stack([0.86 - 0.10 * yy / h + 0.02 * xx / a.shape[1], 0.80 - 0.10 * yy / h, 0.70 - 0.08 * yy / h], -1)
    bg += 0.06 * np.exp(-(((xx / a.shape[1]) - 0.3) ** 2 + ((yy / h) - 0.25) ** 2) / 0.08)[..., None]
    out = blurred * a[..., None] + np.clip(bg, 0, 1) * (1 - a[..., None])
    return (np.clip(out, 0, 1) * 255).astype(np.uint8)
