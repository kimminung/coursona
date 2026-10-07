# 코르소나 에셋 계약 — 앱(테크)이 받는 것

Persona 재현 에셋(Hair_long_wave · Shoulders_shirt · Eye_L · Eye_R · Mouth_Inner)을 앱이 읽고 쓰는 방법을 한곳에 정리한다.
블렌더 쪽은 `coursona_blender/run_all.py` 가 만들고, 앱 쪽 근거는 이 문서다. 디자인 근거는 디자인 PRD(Claude Doc), 태스크는 `Tasks.md` D 절.
`Docs/AssetContract.md` 로 리포에 두는 것을 전제로 쓴다.

## 1. 원칙

1. **블렌더 에셋은 색 없는 틀이다.** 모든 머티리얼은 무채색 연회색(0.8), 불투명도 0.10으로 나온다. Bust 피부 머티리얼도 같다(`skin_carrier`). 텍스처는 Base Color 에 연결하지 않는다.
2. **색·윤곽·불투명도는 앱이 코드로 정한다.** 얼굴 윤곽은 트루뎁스 정점, 색은 사진 투영·틴트·스플랫, 유령 룩(반투명·경계 블러·하단 페이드)은 합성 단계에서 만든다.
3. **앱이 계산할 수 있는 값은 데이터와 식을 둘 다 준다.** presence(정적 존재 마스크)는 uv1 에 구워 두고, 같은 식도 아래에 적는다. uv1 을 못 읽는 경로에서는 식으로 계산한다.
4. **위상은 고정이다.** 스플랫 바인딩과 캐시는 삼각형 번호에 묶이므로, 로드할 때 `topologyHash` 를 확인하고 다르면 바인딩을 다시 만든다.

## 2. 파일

| 경로(Template/ 기준) | 내용 | 누가 쓰나 |
| --- | --- | --- |
| `Template.usdz` | Bust + 라이브러리 + 눈·입 메시. 기존 export_coursona.py 가 만든다 | 앱 로드 |
| `library.json` | 검증기 계약 항목(+ `triangleCount`, `topologyHash`) | TemplateValidator, 라이브러리 선택 UI |
| `coursona_assets.json` | **테크 매니페스트**: 에셋별 부착·머티리얼 역할·UV 의미·면 구간·해시·플랫폼별 경로 | 앱 로더(단일 진입점) |
| `hosts/SplatHost_Hair_long_wave.json` | 머리 스플랫 호스트(셸 3겹) — 위치·법선·가닥 방향·UV·겹 번호·삼각형 | SplatBinder(macOS) |
| `textures/T_Hair_LongWave_base.png` | 회색 RGB + 알파(실루엣). 평균 회색 0.63 → 틴트 = 목표색 ÷ 0.63 | 헤어 실루엣·폴백 색 |
| `textures/T_Hair_LongWave_mask.png` | R 뿌리→끝, G 가닥 id, B 하이라이트 | 선택 사용 |
| `textures/T_Eye_Iris_base.png` · `T_Eye_Sclera_base.png` · `T_Teeth_base.png` | 사진 투영이 없을 때의 폴백 색 | 눈·입 |
| `coursona_build_report.json` | 블렌더 검사 결과(관통·간격·포즈 7종) | 사람 확인용 |

## 3. 좌표

- 블렌더: Z-up, 얼굴 −Y, 피사체 왼쪽 +X, m.
- USD·앱(계약): Y-up, 얼굴 +Z, 피사체 왼쪽 +X, m. **USD (x, y, z) = 블렌더 (x, z, −y)**.
- `hosts/*.json` 의 위치·법선·방향은 이미 USD 좌표(템플릿 공간, 레스트)다. 피팅의 닮음변환은 다른 에셋과 똑같이 적용한다.

## 4. coursona_assets.json

```json
{
  "schema": "coursona-assets/1",
  "coords": {"usd": "USD (x, y, z) = 블렌더 (x, z, −y)"},
  "presence": {"version": "presence/v1", "facing_lo": -0.30, "facing_hi": 0.35, "z_lo": 0.06, "z_hi": 0.20, "height_scale": 0.60},
  "bust": {"opacity": 0.1, "presence": "앱이 bust.mesh 정점으로 계산", "faceContour": "트루뎁스 정점"},
  "assets": {
    "Hair_long_wave": {
      "prim": "Hair_long_wave", "kind": "hair",
      "attach": {"mode": "rigid", "bone": "Head"},
      "material": {"opacity": 0.1, "colorless": true, "slots": [{"name": "M_Hair_LongWave", "role": "hair"}]},
      "textures": {"base": "T_Hair_LongWave_base.png", "mask": "T_Hair_LongWave_mask.png"},
      "uvSets": {"UVMap": "uv0 — 가닥 아틀라스(겹침)", "CoursonaData": "uv1 — (presence, height01)"},
      "vertexCount": 0, "triangleCount": 0, "topologyHash": "sha256…",
      "faceRanges": {"cap": [0, 0], "inner": [0, 0], "mid": [0, 0], "outer": [0, 0], "frame": [0, 0], "baby": [0, 0]},
      "splatHost": "hosts/SplatHost_Hair_long_wave.json", "splatHostHash": "sha256…",
      "platform": {"iOS": "메시 틀", "macOS": "splatHost 에 바인딩"}
    }
  }
}
```

에셋별 요약(값은 생성 후 매니페스트가 정본):

| 에셋 | 부착 | 머티리얼 역할(슬롯 순) | uv0 의미 | 면 구간 | 스플랫 |
| --- | --- | --- | --- | --- | --- |
| Hair_long_wave | 강체 Head | hair | 가닥 아틀라스(카드끼리 겹침) | cap · inner · mid · outer · frame · baby | `hosts/SplatHost_Hair_long_wave.json` |
| Shoulders_shirt | 스킨 Root·Neck | cloth, buttons | u 둘레(정면 0.5), v 높이 | body · tuck · collar · placket · buttons | 자기 자신(body·collar 구간) |
| Eye_L / Eye_R | 강체 Eye_L / Eye_R, 오리진 = 눈알 중심 | sclera, iris, pupil | 홍채·동공 평면(가장자리 r 0.46), 공막 구면 | 슬롯별 | 안 함(메시 유지) |
| Mouth_Inner | 강체 Head + 블렌드셰이프 5 | teeth, gum, tongue, cavity | 치아 둘레·높이 | 슬롯별 | 안 함(메시 유지) |

## 5. presence(정적 존재 마스크)

uv1.x 에 정점별로 구워져 있다. 같은 값을 앱에서 계산할 때(블렌더 좌표 기준):

```
head_c   = Head 뼈 머리 + (0, 0, 0.09)            // USD: Head 조인트 + (0, 0.09, 0)
facing   = dot(normalize(p.xy − head_c.xy), (0, −1)) // USD: dot(normalize((p.x, p.z) − (c.x, c.z)), (0, +1))
presence = smoothstep(−0.30, 0.35, facing) · smoothstep(0.06, 0.20, p.z_blender)   // USD 에서는 p.y
height01 = clamp(p.z_blender / 0.60, 0, 1)
```

정면 1, 옆 ≈0.46, 뒤 0, 가슴 아래(높이 0.20 m 아래)로 0. 쓰는 곳:

- 불투명도: `opacity = baseOpacity × presence`(정면 외 사라짐, 하단 페이드)
- 경계 블러 강도: `blurRadius = mix(maxBlur, 0, presence)` — 얼굴은 선명, 가장자리만 흐림. 방사형(줌) 블러는 얼굴까지 번지므로 쓰지 않는다.
- 보는 각도에 따른 사라짐(프레넬)은 데이터가 아니라 셰이더에서: `edge = pow(1 − |dot(N, V)|, 2)`.

## 6. 스플랫 호스트(hosts/*.json)

| 키 | 형식 | 내용 |
| --- | --- | --- |
| `bone`, `headJointRest` | 문자열, [3] | 강체 부착 뼈와 레스트 조인트 위치(USD) |
| `vertexCount`, `triangleCount`, `topologyHash` | 수, 수, 문자열 | 바인딩 캐시 키 |
| `positions`, `normals` | [3N] | USD 좌표, 레스트 |
| `flow` | [3N] | 가닥 방향(뿌리→끝, 표면 접평면) — 스플랫 장축 초기 방향 |
| `uv` | [2N] | 겹마다 u 칸 하나, 겹치지 않음 → 캡처 사진 투영으로 초기 색 |
| `layer` | [N] | 0 안쪽 · 1 중간 · 2 바깥 |
| `triangles` | [3T] | 모두 삼각형, 바깥을 보는 감김 |

권장 바인딩: 삼각형마다 면적 비례 1–3개, 겹 0·1 은 불투명도 높게(볼륨), 겹 2 는 낮게(잔머리). 장축 = flow, 단축 = 셸 법선. 뒤통수처럼 캡처에 없는 곳은 셸 형태와 이웃 색으로 채운다.

## 7. 플랫폼별 경로

| | iOS·iPadOS(스플랫 없음) | macOS(스플랫) |
| --- | --- | --- |
| 머리 | 카드 메시: 틴트 + 실루엣 알파(threshold 0.45, 양면) + presence | 호스트 셸에 스플랫, 카드 메시 숨김 |
| 셔츠 | 메시: 어깨 사진 평균색 + presence | body·collar 구간에 스플랫, 단추는 메시 |
| 눈·입안 | 메시: 사진 투영, 없으면 폴백 텍스처 | 메시 유지 |
| 틀 메시 | 무채색 0.10 → 앱이 색·불투명도 지정 | **OcclusionMaterial** 로 바꿔 뒤쪽 스플랫이 비치지 않게 |
| 유령 룩 | 오프스크린 렌더 → presence 기반 경계 블러 → 불투명도 0.85 → 하단 페이드 → 합성 | 같음 |

## 8. 로드할 때 확인할 것

1. `coursona_assets.json` 의 `schema` 가 `coursona-assets/1` 인지.
2. 에셋 프림이 이름으로 잡히는지(`findEntity(named:)`). 안 잡히면 블렌더 쪽 `attach_mode="CHILD_OF"` 로 다시 만든다.
3. 메시 삼각형 수와 `topologyHash` 가 매니페스트와 같은지. RealityKit 은 UV 솔기에서 정점을 나누므로 **정점 수는 같지 않을 수 있다** — 비교는 삼각형 수와 해시(블렌더 기준)로 하고, 정점 대응이 필요하면 호스트 JSON 의 위치를 쓴다.
4. uv1(`CoursonaData`)이 MeshResource 에 있는지. 없으면 §5 식으로 계산한다.
5. 강체 에셋은 매 프레임 `attach.bone` 조인트 변환을 따라가게 한다(RigidAttach, Tasks D-301).
