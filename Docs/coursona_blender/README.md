# coursona_blender — Persona 재현 에셋 블렌더 작업 패키지

> 앱(테크)이 받는 것은 `AssetContract.md`(리포의 `Docs/AssetContract.md` 로 복사)와 생성되는 `Template/coursona_assets.json` 이 정본이다.

코르소나 Bust .blend 에 세 가지를 만든다(Bust·Armature 는 수정하지 않음).

| 작업 | 오브젝트 | 스크립트 |
|---|---|---|
| 1 | `Hair_long_wave` (Library_Hair) — 긴 웨이브, Head 강체, 회색+알파 틴트 텍스처 | `add_hair_long_wave.py` |
| 2 | `Shoulders_shirt` (Library_Shoulders) — 네이비 카라 셔츠, Root·Neck 스킨 | `add_shoulders_shirt.py` |
| 3 | `Eye_L` · `Eye_R` · `Mouth_Inner` — 이름으로 찾을 수 있는 강체 메시, 셰이프키 5개 | `fix_eyes_mouth.py` |

`run_all.py` 가 진단 → 셔츠 → 머리(셔츠·칼라까지 피해서) → 눈·입 → 검사 보고서를 한 번에 돈다.

## 계약(TemplateValidator.swift, 2차 계약)에서 나온 규칙
- 이름 `^(Hair|Glasses|Beard|Shoulders)_[a-z0-9_]+$`. `Hair_long_wave`·`Shoulders_shirt` 는 계약 목록에 있어 **이미 있을 수 있다** → 실행 전에 `backup_before_coursona_<시각>.blend` 사본을 저장하고 같은 이름으로 교체한다(이전 상태는 보고서 `replaced`).
- 스켈레톤은 Root > Spine > Neck > Head > {Eye_L, Eye_R} 뿐 → **뼈를 추가하지 않는다**. Mouth_Inner 는 Head 에 강체.
- 눈 뼈 머리 = 눈알 중심(0.5 mm). 메시 중심이 0.5–3 mm 어긋나면 메시를 뼈 머리로 옮기고, 더 크면 옮기지 않고 보고.
- 커스텀 속성은 `chosang_*` 와 `coursona_*` 두 접두사로 같은 값을 쓴다(내보내기 스크립트가 어느 쪽을 읽든 동작).
- 내보내기는 기존 `export_coursona.py` 를 CLI 로(`--no-usdz` 금지, Apply Modifiers OFF). 스크립트가 자동으로 돌리지 않는다.

## 블렌더 쪽 Claude 에게 보낼 요청문
```
~/Desktop/coursona_blender 패키지로 코르소나 Bust 블렌더 파일에 Persona 재현 에셋 3종을 만들어줘. Bust·Armature 는 수정하지 말고 뼈도 추가하지 마.
1) 블렌더 파이썬에서:
   import sys; sys.path.insert(0, "/Users/<사용자>/Desktop/coursona_blender")
   import importlib, run_all; importlib.reload(run_all); print(run_all.main(export=False))
2) 출력의 '요약'과 Template/coursona_build_report.json 을 보여줘. pass 가 아닌 항목은 원인과 같이.
3) Material Preview 로 정면·¾·측면을 렌더해서 보여줘(첨부 Persona 레퍼런스와 비교할 것).
4) 문제 없으면 export_coursona.py 를 평소처럼 CLI 로 실행(--no-usdz 금지, Apply Modifiers OFF) 후
   import inspect_usdz; inspect_usdz.inspect("<Template 폴더>/Template.usdz") 결과를 보여줘.
5) inspect 에서 강체 에셋이 SkelRoot 아래라 문제가 나오면 run_all.main(attach_mode="CHILD_OF") 로 다시 하고 4 반복.
6) 바뀐 파일 목록(Template.usdz, textures/*.png, library.json, coursona_assets.json, hosts/*.json, 백업 .blend)을 알려줘.
```

## 투명한 틀 원칙(기본값)
모든 에셋 머티리얼은 **색을 뺀 무채색 연회색(0.8) + Alpha 0.10**(90% 투명)으로 나간다(`asset_opacity=0.10, colorless=True`).
텍스처는 Base Color 에 연결하지 않고 파일 + `coursona_textures` 속성으로만 전달한다(앱 폴백용).
살색 부위(Bust 의 Skin 머티리얼)도 `skin_carrier=True`(기본)로 같은 무채색 10% 가 된다 — 머티리얼 값만 바꾸고 메시·리그·그룹·UV·셰이프키는 그대로.
색과 윤곽은 앱이 트루뎁스 정점으로 코드에서 만들므로 미리보기 대리 두상은 둥근 타원체 하나다(이마·턱·코·입술 볼륨 없음, 남녀 차이는 머리폭·목·어깨뿐). 블렌더 에셋은 형태·배치·실루엣만 주고, 색과 불투명도는 앱이
사진 기반 페르소나로 입힌 뒤 유령 룩(반투명 + 가장자리 블러 + 하단 페이드)으로 합성한다. 머리 알파 텍스처는 BSDF 에
연결하지 않고 실루엣 마스크로만 전달한다(커스텀 속성 `coursona_silhouette = alpha:T_Hair_LongWave_base.png`).
블렌더 뷰포트는 표시 알파 0.15 로 유령처럼 보인다. 형태만 확인하려면 `run_all.main(asset_opacity=1.0)`.

## 옵션
- `sex`: `"male"`(기본) / `"female"` — 셔츠 칼라·단추 치수와 생성형 치아 비율. 머리카락은 여성 스타일 그대로.
- `asset_opacity`: 0.10(기본) … 1.0(불투명 확인용). `colorless=False` 면 색·텍스처를 다시 연결한다.
- `mouth_protrusion`: 입(치열·잇몸·혀·입안) 돌출(m). 0.004 = 4 mm 앞으로, 앞니 8° 순측 기울기. 세부는 `eyes_mouth_geometry.mouth_inner(overjet, overbite, tilt_per_mm)`.
- 미리보기 대리 두상: `tests/proxy_bust.set_sex("female"|"male")` — 둥근 타원체, 서양인 평균 머리폭·목 둘레·어깨폭만 반영.
- `attach_mode`: `BONE`(계약 기본, 뼈 부모) · `CHILD_OF`(부모 없음 + Child Of, USD 에서 SkelRoot 밖) · `ORIGIN` · 헤어 전용 `SKIN_HEAD`(Head 100% 스킨 비상 경로).
- 형태 조정: `add_hair_long_wave.run(params={"tip_clear": 0.025, "wave_len": 0.11})`, `add_shoulders_shirt.run(params={"body_offset": 0.004})`. 기본값은 `hair_geometry.DEFAULTS`, `shirt_geometry.DEFAULTS`.
- `template_dir=` 로 Template 폴더를 지정(기본: .blend 옆 `Template/`, 없으면 Template.usdz 가 있는 폴더 탐색).

## 파일
| 파일 | 내용 |
|---|---|
| `coursona_common.py` | 장면 찾기, Basis 레스트 좌표, BVH 표면, LBS 포즈 7종 관통 검사, 백업, library.json, 내보내기 실행 |
| `hair_geometry.py` · `hair_texture.py` | 헤어 캡·카드 생성(numpy), 텍스처 생성기 |
| `shirt_geometry.py` | 셔츠 셸·칼라(스탠드·접힘·리프)·절단면 접기 |
| `eyes_mouth_geometry.py` | 눈알(39고리×64, 삼각형, 홍채 접시), 입안 생성기(삼각형·치아 해부·교두·잇몸 스캘럽·설유두), Kabsch, 홍채·공막·치아 텍스처 |
| `inspect_usdz.py` | 내보낸 USDZ 프림·스킨·블렌드셰이프·머티리얼 검사(pxr) |
| `tech_data.py` | presence 식, 삼각화((a,b,c)+(a,c,d)), 위상 해시, 면 구간, USD 좌표 변환 |
| `AssetContract.md` | 테크 계약: 파일·매니페스트·presence 식·스플랫 호스트·플랫폼 경로·로드 검사 |
| `textures/T_Hair_LongWave_base.png` | 2048² 회색+알파(평균 회색 0.63 → 앱 틴트 = 목표색 ÷ 0.63) |
| `textures/T_Hair_LongWave_mask.png` | R 뿌리→끝, G 가닥 id, B 하이라이트(초상 _mask 규약, 앱 선택 사용) |
| `textures/T_Eye_Iris_base.png` · `T_Eye_Sclera_base.png` | 홍채(섬유·크립트·림벌 링, UV 반지름 0.46), 공막(뒤쪽 혈관) — Eye_L/R 슬롯 1·0 |
| `textures/T_Teeth_base.png` | 치아 세로 그라데이션(치경 노란빛 → 절단연 푸른빛) — 생성형 Mouth_Inner 치아 슬롯 |
| `previews/` | 대리 흉상 오프라인 렌더(실제 Bust 아님) |
| `tests/` | 대리 흉상·래스터라이저·오프라인 테스트(`python3 tests/test_hair_offline.py`) |

## 알려진 한계
- 실제 Bust 에서는 아직 한 번도 돌리지 않았다. 형태·간격은 Chosang 비율의 대리 흉상에서만 확인했다.
- library.json 최상위 형태와 export_coursona.py 의 CLI 인자는 미확인(파일이 없으면 배열로 만든다).
- 생성형 입안(Mouth_Inner 가 없을 때만)은 단순화된 치아 모델이다. 초상 .blend 의 기존 Mouth_Inner 가 있으면 그것을 쓴다.
