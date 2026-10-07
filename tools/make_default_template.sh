#!/bin/zsh
# 블렌더 내보내기 결과(Template 폴더, 초상과 같은 계약) → 앱 번들용 Default.coursonatemplate (stored zip).
# 초상의 tools/make_default_template.sh 와 같은 방식. EyesMouth.usdz(눈알 2개 + 치아·잇몸·혀·입안)도 넣는다 —
# 처음엔 "코르소나는 눈·입 구멍을 캡으로 닫으니 분리 엔티티가 필요 없다" 고 뺐지만, 입체감 v2(2026-10-06)에서
# 시선 따라 도는 진짜 눈알과 입을 벌리면 보이는 입안을 위해 다시 넣었다(캡은 그 뒤에서 투명해진다 — BustEntity.attachEyesMouth).
# 사용: tools/make_default_template.sh <Template 폴더> [출력 경로]
set -e
SRC="${1:?Template 폴더}"
OUT="${2:-$(dirname "$0")/../coursona/Resources/Templates/Default.coursonatemplate}"
TMP=$(mktemp -d)
mkdir -p "$TMP/t"
# coursona_assets.json(테크 매니페스트, Docs/AssetContract.md §4)·coursona_build_report.json 도 같이 — 앱 로더(D-309)가 매니페스트를 단일 진입점으로 읽는다.
for f in template.json bust.mesh Template.usdz EyesMouth.usdz library.json coursona_assets.json coursona_build_report.json; do [ -f "$SRC/$f" ] && cp "$SRC/$f" "$TMP/t/"; done
[ -d "$SRC/clips" ] && cp -R "$SRC/clips" "$TMP/t/clips"
# library/<name>.usdz — export_chosang.py 는 라이브러리 오브젝트(Hair_*, Shoulders_* …)를 Template.usdz 가 아니라 여기로 낸다.
# 매니페스트 에셋 중 Template.usdz 에 없는 프림은 앱이 이 폴더에서 같은 이름의 usdz 를 찾는다(TemplateStore.libraryUSDZURL).
# 19종 전부 넣으면 67 MB 라, 매니페스트(coursona_assets.json)가 가리키는 프림의 usdz 만 담는다(없으면 전부).
if [ -d "$SRC/library" ]; then
  mkdir -p "$TMP/t/library"
  if [ -f "$SRC/coursona_assets.json" ]; then
    for name in $(python3 -c "import json,sys; m=json.load(open(sys.argv[1])); print(' '.join(a.get('prim', k) for k, a in m.get('assets', {}).items()))" "$SRC/coursona_assets.json"); do
      [ -f "$SRC/library/$name.usdz" ] && cp "$SRC/library/$name.usdz" "$TMP/t/library/"
    done
  else
    cp "$SRC"/library/*.usdz "$TMP/t/library/" 2>/dev/null || true
  fi
fi
[ -d "$SRC/hosts" ] && cp -R "$SRC/hosts" "$TMP/t/hosts"
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
