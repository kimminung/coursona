#!/bin/zsh
# 블렌더 내보내기 결과(Template 폴더, 초상과 같은 계약) → 앱 번들용 Default.coursonatemplate (stored zip).
# 초상의 tools/make_default_template.sh 와 같은 방식. EyesMouth.usdz(눈알 2개 + 치아·잇몸·혀·입안)도 넣는다 —
# 처음엔 "코르소나는 눈·입 구멍을 캡으로 닫으니 분리 엔티티가 필요 없다" 고 뺐지만, 입체감 v2(2026-10-06)에서
# 시선 따라 도는 진짜 눈알과 입을 벌리면 보이는 입안을 위해 다시 넣었다(캡은 그 뒤에서 투명해진다 — BustEntity.attachEyesMouth).
# 사용: tools/make_default_template.sh <Template 폴더> [출력 경로]
set -e
SRC="${1:?Template 폴더}"
OUT="${2:-$(dirname "$0")/../coursona/coursona/Resources/Templates/Default.coursonatemplate}"
TMP=$(mktemp -d)
mkdir -p "$TMP/t"
for f in template.json bust.mesh Template.usdz EyesMouth.usdz library.json; do [ -f "$SRC/$f" ] && cp "$SRC/$f" "$TMP/t/"; done
[ -d "$SRC/clips" ] && cp -R "$SRC/clips" "$TMP/t/clips"
mkdir -p "$TMP/t/textures" && cp "$SRC"/textures/*.png "$TMP/t/textures/" 2>/dev/null || true
mkdir -p "$TMP/t/source" && cp "$SRC"/source/ARFaceGeometry_LICENSE.txt "$TMP/t/source/" 2>/dev/null || true
python3 - "$TMP/t" "$OUT" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(out), exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
    for root, _, files in os.walk(src):
        for f in sorted(files):
            p = os.path.join(root, f); z.write(p, os.path.relpath(p, src))
print("wrote", out, os.path.getsize(out) // 1024, "KB")
PY
rm -rf "$TMP"
