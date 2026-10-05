# ChosangCore 포맷 (2차 계약, 2026-10-03)

모두 little-endian, 정렬 없음. 문자열은 `u32 길이 + UTF-8`. 좌표는 흉상 공간(m, Y-up, 얼굴 +Z, 왼쪽 +X). 블렌더(Z-up, 얼굴 −Y)에서 **USD(x, y, z) = 블렌더(x, z, −y)**.

## `bust.mesh` (BustMeshFile, CBM1 v2) — 항상 Template.usdz 와 함께

| 구간 | 내용 |
|---|---|
| header | magic `CBM1`(4) · version u32 = 2 · vertexCount u32 · triangleCount u32 · shapeCount u32 · jointCount u32 · flags u32 (bit0 normals, bit1 코너 UV) |
| positions | f32 × 3 × V (Basis 셰이프 = 중립) |
| normals | f32 × 3 × V (flags bit0) |
| uvs | f32 × 2 × V — 정점당 첫 루프 UV (호환용; 솔기 정점은 부정확) |
| cornerUVs | f32 × 2 × 3 × T (flags bit1) — 삼각형 코너 순서의 루프 UV. **렌더·텍스처는 이것을 쓴다**(`BustTemplate.makeRenderMesh()` 가 (정점, UV) 쌍으로 정점을 분할하고 `sourceIndex` 로 원본을 가리킨다) |
| indices | u32 × 3 × T — 다각형을 팬으로 쪼갠 것: 사각형 (a,b,c,d) → (a,b,c)+(a,c,d). 앞 2304개 = 패치 1152 사각형 |
| shapes | shapeCount × { name, f32 × 3 × V } — 중립 대비 델타, 이름은 ARKit 52 (순서 = ARKit 52 순서) |
| skin | V × { u16 × 4 joints, f32 × 4 weights } — joints 는 아래 조인트 순서 인덱스, 합 1 |
| joints | jointCount × { name, parent i32(-1 = 루트), restWorld f32 × 16 (열 우선, 흉상 공간) } — 순서 Root, Spine, Neck, Head, Eye_L, Eye_R |

v1(코너 UV 없음)도 읽는다. 패치 정점(0…1219)은 Apple OBJ 와 위치·순서가 같아야 하며(검증기 `patch.position`), 삼각형 SHA-256 = `ARKitFaceTopology.patchTrianglesABCACDSHA256`.

## `template.json` (TemplateManifest, schema 2)

| 키 | 내용 |
|---|---|
| id, version, generator | 템플릿 식별 (`chosang-bust@1.0`), 블렌더 버전 |
| vertexCount, triangleCount, patchVertexCount(1220), patchFaceCount(1152) | 수 |
| objSHA256, patchQuadsSHA256, patchTrianglesSHA256, patchTriangleHash | Apple OBJ 파일 · 사각형(OBJ 순서, int32 LE) · (a,b,c)+(a,c,d) 삼각형 SHA-256, 메시 패치 삼각형 FNV-1a 64 |
| objToTemplate {scale[1], translate[3]} | OBJ(mm) → 흉상: `usd = obj × scale + translate` |
| landmarks {이름: 정점 id} | eye_left_inner/outer, eye_right_inner/outer, nose_tip, mouth_left/right, chin, ear_top_left/right, shoulder_left/right (필수) + lip_upper_mid, lip_lower_mid, brow_inner_left/right (선택) |
| groups {이름: [id]} | ARKitFace, Scalp, EarL, EarR, Neck(가중치 > 0), Shoulders, LipInner, LidInner |
| groupWeights {이름: [w]} | Neck·Root·Head 스킨 가중치 (groups 순서) |
| patchLoops {eye_left[24], eye_right[24], mouth[36], outer[56]} | OBJ 경계 루프 |
| uvRegions {이름: [u0,v0,u1,v1]} | face, head_neck, ear_L, ear_R, torso, lid_L, lid_R, lip |
| symmetryMap [i32] | X 미러 최근접 정점 (없으면 −1) |
| eyeL, eyeR, eyeRadius, eyeSpacing | 눈알 중심·반지름·간격 |
| mouthCenter, chinY, crownY | 측정값 (입 루프 평균 등) |
| jawPivot, jawOpenDegrees, jawOpenTranslate | 턱 리그 (Mouth_Inner·수염 동기화) |
| boneRest {이름: [x,y,z]}, boneParents | 뼈 레스트 위치·부모 |
| shapeKeys[52], shapeMaxDisplacementMM, mouthInnerShapes[5] | 셰이프 목록·최대 변위·Mouth_Inner 셰이프 |
| libraryObjects, clips, textures, previz, uvSeamVertexCount | 라이브러리 이름 · 클립 이름 · 텍스처 파일 · 프리비즈 카메라 · 솔기 정점 수 |

## `library.json` ([LibraryEntry])

`{name, kind(hair|glasses|beard|shoulders), bone, tintable, vertexCount, faceCount, materials, textures{base,mask,cap}, skinGroups, bustIndex?(수염: 셸 정점 → Bust 정점), noseBridge?(안경)}`

## `identity.bin` (Identity)

| 구간 | 내용 |
|---|---|
| header | magic `CHID` · version u32=1 · templateID · templateVersion |
| positions | u32 V · f32 × 3 × V (원본 정점 공간, 분할 전) |
| scale | f32 |
| eyes | eyeL f32×3 · eyeR f32×3 · radius f32 |
| patchDeltas | u32 count · count × { name, u32 n, f32 × 3 × n } |
| quality | u32 jsonLength · FitQuality JSON (0 이면 없음) |

## 캡처 번들 (폴더)

`meta.json`(`CaptureBundleMeta`) + `shot-<i>.jpg` + `depth-<i>.f32`(헤더 없음, `depthWidth × depthHeight` Float32 row-major, m). 단위·좌표계 규약은 `CaptureBundle.swift` 머리말.

## `clips/<name>.json` (SampledClip)

```json
{ "name": "bow", "fps": 30, "frames": 46, "loop": false,
  "bones": { "Neck": [[qx,qy,qz,qw,px,py,pz], ...], "Head": [...], "Eye_L": [...], "Eye_R": [...] },
  "shapes": { "eyeLookDownLeft": [0, 0.1, ...], "jawOpen": [...] } }
```
프레임 0…L 을 **끝 프레임 포함**해 굽는다(frames = L+1, 길이 = L/fps). 루프 클립은 첫 = 끝 프레임. 뼈 값은 흉상 공간에서 그 뼈의 레스트 피벗(boneRest) 기준 회전(사원수 xyzw)·이동(m) — 부모 회전 미포함. 앱 합성: Neck → Head → Eye, `T_bone(p) = P + R(p − P) + t`. 안 쓰는(항등) 뼈·셰이프 트랙은 생략.
