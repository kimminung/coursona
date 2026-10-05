//
//  TemplateValidator.swift
//  CoursonaValidate
//
//  블렌더 산출물 계약 검사 — **2차 계약**(Blender-요청.md, 2026-10-03). 실패 항목은 "블렌더에서 무엇을 어떻게 고치라" 는 한국어 문장으로 낸다.
//  허용 오차의 기준값은 template.json 에 기록된 값이다(계약 고정값은 눈 간격 0.064·눈 높이 0.44 만). 입력은 TemplateFolder 가 만든다.
//

import Foundation
import simd
import CryptoKit
import CoursonaCore

public struct ValidationIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning, info }
    public var severity: Severity
    public var code: String
    public var message: String
    public init(_ severity: Severity, _ code: String, _ message: String) { self.severity = severity; self.code = code; self.message = message }
    public var description: String {
        let mark = severity == .error ? "❌" : (severity == .warning ? "⚠️" : "ℹ️")
        return "\(mark) [\(code)] \(message)"
    }
}

public struct ValidationInput: Sendable {
    public var manifest: TemplateManifest
    public var template: BustTemplate?
    public var clips: [SampledClip]
    public var previzNames: Set<String>
    public var library: [LibraryEntry]
    public var textures: Set<String>
    public var hasUSDZ: Bool
    public var hasBustMesh: Bool
    /// source/ARFaceGeometry.obj 의 1220 정점을 objToTemplate 로 옮긴 것 (있으면 패치 위치 검사)
    public var objPatchPositions: [SIMD3<Float>]?
    /// USDZ 에서 읽은 Bust 정점 (앱 검증 탭·--with-usdz) — bust.mesh 와 교차 확인
    public var usdzPositions: [SIMD3<Float>]?
    public var usdzShapeNames: [String]?

    public init(manifest: TemplateManifest, template: BustTemplate?, clips: [SampledClip], previzNames: Set<String>, library: [LibraryEntry] = [],
                textures: Set<String> = [], hasUSDZ: Bool, hasBustMesh: Bool, objPatchPositions: [SIMD3<Float>]? = nil,
                usdzPositions: [SIMD3<Float>]? = nil, usdzShapeNames: [String]? = nil) {
        self.manifest = manifest; self.template = template; self.clips = clips; self.previzNames = previzNames; self.library = library
        self.textures = textures; self.hasUSDZ = hasUSDZ; self.hasBustMesh = hasBustMesh; self.objPatchPositions = objPatchPositions
        self.usdzPositions = usdzPositions; self.usdzShapeNames = usdzShapeNames
    }
}

public enum TemplateValidator {
    // 계약 고정값
    static let eyeSpacingContract: Float = 0.064, eyeSpacingTol: Float = 0.003
    static let eyeHeightContract: Float = 0.44, eyeHeightTol: Float = 0.010
    static let shapeWarnMM: Float = 40, shapeErrorMM: Float = 60
    static let requiredLibrary = ["Glasses_round", "Glasses_square", "Glasses_thin", "Beard_stubble", "Beard_short", "Shoulders_tee", "Shoulders_shirt"]
    static let hairStyles = ["short_crop", "short_side", "medium_wave", "long_straight", "long_wave", "tied_low", "tied_high", "bangs_short", "bangs_medium", "bangs_long", "buzz", "bald_cap"]

    public static func validate(_ input: ValidationInput) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        let m = input.manifest
        let synthetic = m.isSynthetic
        func err(_ code: String, _ msg: String) { out.append(ValidationIssue(.error, code, msg)) }
        func warn(_ code: String, _ msg: String) { out.append(ValidationIssue(.warning, code, msg)) }
        func info(_ code: String, _ msg: String) { out.append(ValidationIssue(.info, code, msg)) }
        func mm(_ v: Float) -> String { String(format: "%.1f mm", v * 1000) }

        // 0. 파일
        if m.schema < 2 { err("schema", "template.json 스키마가 \(m.schema) 입니다(필요 2). 최신 tools/blender/export_coursona.py 로 다시 내보내세요.") }
        if !input.hasBustMesh { err("files.bustmesh", "bust.mesh 가 없습니다. export_coursona.py 는 항상 bust.mesh 를 함께 씁니다 — 스크립트를 다시 실행하세요.") }
        if !input.hasUSDZ {
            if synthetic { info("files.usdz", "합성 템플릿: Template.usdz 없음(정상).") }
            else { err("files.usdz", "Template.usdz 가 없습니다. export_coursona.py 를 --no-usdz 없이 실행하세요(Apply Modifiers OFF).") }
        }

        // 1. 패치·정점 수·해시
        if m.patchVertexCount != ARKitFaceTopology.vertexCount {
            err("patch.count", "얼굴 패치 정점 수가 \(m.patchVertexCount)개입니다. Apple ARFaceGeometry.obj 의 1220개를 순서 그대로(인덱스 0…1219) 가져오고 병합·정리·리메시를 하지 마세요.")
        }
        if m.vertexCount < 1220 { err("mesh.vertices", "전체 정점이 \(m.vertexCount)개로 패치보다 적습니다. 두피·귀·목·어깨를 패치 바깥에 이어 붙이세요.") }
        else if m.vertexCount < 10_000 || m.vertexCount > 14_000 {
            warn("mesh.vertices", "전체 정점이 \(m.vertexCount)개입니다. 계약 권장 범위는 10k–14k 입니다(두피·목·어깨 밀도를 조정하세요).")
        }
        if synthetic {
            info("patch.hash", "합성 템플릿: Apple 패치 해시 검사를 생략합니다.")
        } else {
            if m.patchFaceCount != ARKitFaceTopology.quadCount { err("patch.faces", "패치 사각형 수가 \(m.patchFaceCount)개입니다(Apple OBJ 1152). 패치 면을 나누거나 합치지 마세요(삼각분할 금지).") }
            if let q = m.patchQuadsSHA256?.lowercased() {
                if q != ARKitFaceTopology.patchQuadsSHA256 { err("patch.hash", "패치 사각형 해시가 Apple OBJ 와 다릅니다(\(q.prefix(12))… ≠ \(ARKitFaceTopology.patchQuadsSHA256.prefix(12))…). OBJ 가져오기에서 정점·면 순서를 보존하고(Keep Vert Order), 앞 1152개 면을 그대로 두세요.") }
            } else { err("patch.hash.missing", "template.json 에 patchQuadsSHA256 이 없습니다. 최신 export_coursona.py 로 다시 내보내세요.") }
            if let o = m.objSHA256?.lowercased(), o != ARKitFaceTopology.appleOBJSHA256 { warn("patch.obj", "source/ARFaceGeometry.obj 의 SHA-256 이 알려진 Apple 샘플과 다릅니다. Xcode 샘플 'Tracking and visualizing faces' 의 원본인지 확인하세요.") }
            if let t = m.patchTrianglesSHA256?.lowercased(), t != ARKitFaceTopology.patchTrianglesABCACDSHA256 { err("patch.tris", "패치 삼각형(a,b,c)+(a,c,d) 해시가 다릅니다. 스크립트가 사각형을 다른 순서로 쪼갰거나 OBJ 가 다릅니다.") }
        }
        if let t = input.template {
            if t.vertexCount != m.vertexCount { err("mesh.count", "template.json 의 정점 수(\(m.vertexCount))와 bust.mesh(\(t.vertexCount))가 다릅니다. 내보내기 스크립트를 다시 실행하세요.") }
            if t.triangleCount != m.triangleCount { warn("mesh.tris", "template.json 삼각형 수(\(m.triangleCount))와 bust.mesh(\(t.triangleCount))가 다릅니다.") }
            if !synthetic {
                let bytes = ARKitFaceTopology.patchTriangleBytes(indices: t.indices, patchCount: t.patchCount)
                let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                if sha != ARKitFaceTopology.patchTrianglesABCACDSHA256 { err("patch.mesh", "bust.mesh 의 패치 삼각형이 Apple OBJ 사각형의 (a,b,c)+(a,c,d) 분할과 다릅니다. Bust 의 앞 1152개 면이 OBJ 그대로인지(분할·순서) 확인하세요.") }
            }
            let h = ARKitFaceTopology.hexString(t.patchTriangleHash())
            if h != m.patchTriangleHash.lowercased() { err("patch.fnv", "bust.mesh 패치 삼각형 FNV(\(h))가 template.json(\(m.patchTriangleHash))과 다릅니다. 메시를 바꾼 뒤 스크립트를 다시 실행하세요.") }
            // OBJ 원본 위치와 비교
            if let obj = input.objPatchPositions, obj.count == 1220, t.patchCount == 1220 {
                var worst: Float = 0
                for i in 0..<1220 { worst = max(worst, simd_length(obj[i] - t.positions[i])) }
                if worst > 0.0002 { err("patch.position", "패치 정점 위치가 OBJ(스케일·이동 적용)와 최대 \(mm(worst)) 다릅니다. 패치 정점을 움직이지 마세요(스컬프트·스무딩 금지, 셰이프키는 Basis 가 아닌 키에만).") }
                else { info("patch.position", "패치 정점 = OBJ 변환값 (최대 차 \(mm(worst)))") }
            }
            // USDZ 교차 확인
            if let u = input.usdzPositions {
                // RealityKit 은 UV/법선 솔기에서 정점을 분할해 읽으므로 정점 수는 bust.mesh 이상(+솔기 정점)일 수 있다 → 최근접 정점 거리로 비교
                let render = t.makeRenderMesh()
                if u.count < t.vertexCount || u.count > render.vertexCount + t.vertexCount / 10 {
                    err("usdz.count", "Template.usdz 의 Bust 정점 수(\(u.count))가 bust.mesh(\(t.vertexCount), 솔기 분할 후 \(render.vertexCount))와 맞지 않습니다. Bust 에 모디파이어(Subdivision/Mirror/Triangulate)가 있으면 적용하거나 지우고, USD 내보내기에서 'Apply Modifiers' 를 끄세요.")
                } else {
                    let (worst, at) = nearestDistanceMax(from: u, to: t.positions)
                    if worst > 0.0005 { err("usdz.position", String(format: "Template.usdz 와 bust.mesh 의 정점이 최대 %@ 다릅니다(usdz 정점 (%.4f, %.4f, %.4f)). 좌표 변환(블렌더 x,z,−y → USD)·단위(m)·오브젝트 변환(위치 0, 회전 0, 스케일 1)을 확인하세요.", mm(worst), at.x, at.y, at.z)) }
                    else { info("usdz.position", "Template.usdz(\(u.count) 정점, 솔기 분할) = bust.mesh(\(t.vertexCount)) 최대 차 \(mm(worst))") }
                }
                if let names = input.usdzShapeNames {
                    let missing = ArkitShape.allCases.filter { !names.contains($0.rawValue) }
                    if !missing.isEmpty { err("usdz.shapes", "Template.usdz 의 Bust 에 셰이프키 \(missing.count)개가 없습니다(\(missing.prefix(6).map(\.rawValue).joined(separator: ", "))…). USD 내보내기에서 'Shape Keys' 를 켜세요.") }
                }
            }
            // UV 범위·겹침
            if t.effectiveCornerUVs.contains(where: { !$0.x.isFinite || !$0.y.isFinite || $0.x < -0.001 || $0.x > 1.001 || $0.y < -0.001 || $0.y > 1.001 }) {
                err("uv.range", "UV 가 0…1 을 벗어난 정점이 있습니다. UV 에디터에서 모든 아일랜드를 0–1 타일 안에 넣으세요.")
            }
            let overlap = uvOverlapRatio(t)
            if overlap > 0.01 { err("uv.overlap", String(format: "얼굴 패치 UV 와 다른 영역 UV 가 %.1f%% 겹칩니다. 두피·귀·목·어깨·안쪽 띠 아일랜드를 패치(아래 절반) 밖으로 옮기세요.", overlap * 100)) }
            else if overlap > 0.002 { warn("uv.overlap", String(format: "패치 UV 와 다른 영역이 %.2f%% 겹칩니다(가장자리 1–2 텍셀). 아일랜드 여백(margin)을 조금 늘리세요.", overlap * 100)) }
            // 스킨
            var badSum = 0, badIdx = 0
            let jointCount = t.skeleton?.jointNames.count ?? 6
            for s in t.skin {
                let sum = s.weights.x + s.weights.y + s.weights.z + s.weights.w
                if abs(sum - 1) > 0.02 { badSum += 1 }
                if Int(s.joints.max()) >= max(1, jointCount) { badIdx += 1 }
            }
            if badSum > 0 { warn("skin.sum", "정점 \(badSum)개의 스킨 가중치 합이 1 이 아닙니다. Weight Paint > Normalize All(Root/Neck/Head) 을 실행하세요.") }
            if badIdx > 0 { err("skin.index", "정점 \(badIdx)개가 존재하지 않는 뼈를 가리킵니다. Armature 에 Root/Spine/Neck/Head/Eye_L/Eye_R 만 두고 다시 내보내세요.") }
            if let sk = t.skeleton {
                let missing = BoneName.allCases.filter { sk.index(of: $0) == nil }
                if !missing.isEmpty { err("skeleton.mesh", "bust.mesh 조인트에 \(missing.map(\.rawValue).joined(separator: ", ")) 가 없습니다.") }
            } else if !synthetic { err("skeleton.missing", "bust.mesh 에 스켈레톤이 없습니다. Bust 의 부모를 Armature 로 두고(Armature 모디파이어) 다시 내보내세요.") }
            // 좌표계·치수 (랜드마크 기준)
            if let oL = m.landmark(.eyeLeftOuter), let iL = m.landmark(.eyeLeftInner), let iR = m.landmark(.eyeRightInner), let oR = m.landmark(.eyeRightOuter),
               [oL, iL, iR, oR].allSatisfy({ $0 < t.vertexCount }) {
                let cL = (t.positions[oL] + t.positions[iL]) / 2, cR = (t.positions[oR] + t.positions[iR]) / 2
                let spacing = simd_length(cL - cR)
                let eyeSpacing = simd_length(m.eyeCenterL - m.eyeCenterR)
                if abs(eyeSpacing - eyeSpacingContract) > eyeSpacingTol { err("coords.eyes", String(format: "눈알 중심 간격이 %.1f mm 입니다(계약 64 ± 3). OBJ 를 균일 스케일해 두 눈알 중심 간격을 0.064 m 로 맞추세요.", eyeSpacing * 1000)) }
                if abs(spacing - eyeSpacing) > 0.012 { warn("coords.eyeLandmarks", String(format: "눈꺼풀 랜드마크로 잰 간격(%.1f mm)이 눈알 중심 간격(%.1f mm)과 많이 다릅니다. eye_*_inner/outer 정점 id 를 확인하세요.", spacing * 1000, eyeSpacing * 1000)) }
                let ey = (m.eyeL[1] + m.eyeR[1]) / 2
                if abs(ey - eyeHeightContract) > eyeHeightTol { err("coords.eyeHeight", String(format: "눈알 중심 높이 y=%.3f m 입니다(계약 0.44 ± 0.01). 흉상을 Y 로 이동해 가슴 절단면이 y=0, 눈 중심이 0.44 가 되게 하세요.", ey)) }
                if cL.x < cR.x { err("coords.mirror", "왼눈(eye_left_*)이 −X 쪽에 있습니다. 피사체 기준 왼쪽이 +X 가 되도록 좌우를 확인하세요(Y-up, 얼굴 +Z).") }
                let front = t.positions[0..<t.patchCount].map(\.z).max() ?? 0
                if front < 0.02 { err("coords.facing", "얼굴 패치가 +Z 를 향하지 않습니다(최대 z=\(front)). 좌표 변환(블렌더 −Y 얼굴 → USD +Z)을 확인하세요.") }
                if let nose = m.landmark(.noseTip), nose < t.vertexCount, t.positions[nose].z < front - 0.005 { warn("coords.nose", "nose_tip 랜드마크가 패치의 가장 앞 점이 아닙니다. 정점 id 를 확인하세요.") }
            }
            // template.json 측정값 ↔ 메시
            if let chin = m.landmark(.chin), chin < t.vertexCount, let cy = m.chinY, abs(t.positions[chin].y - cy) > 0.002 {
                warn("measure.chin", String(format: "template.json chinY(%.3f)와 chin 랜드마크 높이(%.3f)가 다릅니다. 스크립트를 다시 실행하세요.", cy, t.positions[chin].y))
            }
            if let crown = m.crownY, let maxY = t.positions.map(\.y).max(), abs(maxY - crown) > 0.005 { warn("measure.crown", String(format: "template.json crownY(%.3f)와 메시 최고점(%.3f)이 다릅니다.", crown, maxY)) }
            if let mc = m.mouthCenter, mc.count == 3, let loop = m.patchLoops["mouth"], !loop.isEmpty, loop.allSatisfy({ $0 < t.vertexCount }) {
                let mean = loop.reduce(SIMD3<Float>.zero) { $0 + t.positions[$1] } / Float(loop.count)
                if abs(mean.y - mc[1]) > 0.002 { warn("measure.mouth", String(format: "입 중심 y: template.json %.4f, 입 루프 평균 %.4f. 스크립트를 다시 실행하세요.", mc[1], mean.y)) }
            }
            if let mc = m.mouthCenter, mc.count == 3, mc[1] < 0.36 || mc[1] > 0.40 { warn("measure.mouthRange", String(format: "입 중심 y=%.3f 가 예상 범위(0.36–0.40, 눈 간격 0.064 기준 ≈0.380) 밖입니다.", mc[1])) }
            let minY = t.positions.map(\.y).min() ?? 0
            if minY < -0.02 || minY > 0.03 { warn("coords.base", String(format: "가장 아래 정점 y=%.3f m 입니다. 가슴 절단면이 y=0 이 되게 하세요.", minY)) }
            // 눈알 중심 ↔ 눈 뼈
            for (bone, c) in [(BoneName.eyeL, m.eyeCenterL), (BoneName.eyeR, m.eyeCenterR)] {
                if let p = t.skeleton?.restPosition(of: bone), simd_length(p - c) > 0.0005 {
                    err("skeleton.eye", "\(bone.rawValue) 뼈 머리(\(p.array.map { String(format: "%.4f", $0) }))가 눈알 중심(\(c.array.map { String(format: "%.4f", $0) }))과 다릅니다. 뼈 머리를 눈알 중심에 두세요.")
                }
            }
            // 셰이프 크기
            func magnitude(_ s: ArkitShape) -> Float { t.maxDisplacement(s) }
            let mustMove = ArkitShape.lipSyncMinimum + ArkitShape.eyeBrowMinimum
            let empty = mustMove.filter { magnitude($0) < 0.0005 }
            if !empty.isEmpty { err("shapes.empty", "필수 셰이프가 비어 있습니다(최대 변위 < 0.5 mm): \(empty.map(\.rawValue).joined(separator: ", ")). 해당 셰이프키를 조각하거나 Mesh Data Transfer 로 옮기세요.") }
            let emptyAny = ArkitShape.allCases.filter { magnitude($0) < 0.0005 && !mustMove.contains($0) }
            if !emptyAny.isEmpty { warn("shapes.emptyOptional", "비어 있는(0.5 mm 미만) 셰이프: \(emptyAny.map(\.rawValue).joined(separator: ", ")). 앱은 0 으로 취급합니다.") }
            let huge = ArkitShape.allCases.filter { magnitude($0) * 1000 > shapeErrorMM }
            if !huge.isEmpty { err("shapes.range", "변위가 \(Int(shapeErrorMM)) mm 를 넘는 셰이프: \(huge.map { "\($0.rawValue)(\(Int(magnitude($0) * 1000)) mm)" }.joined(separator: ", ")). 값 1.0 = 최대 표정이어야 합니다.") }
            let big = ArkitShape.allCases.filter { let v = magnitude($0) * 1000; return v > shapeWarnMM && v <= shapeErrorMM }
            if !big.isEmpty { warn("shapes.large", "변위가 \(Int(shapeWarnMM)) mm 를 넘는 셰이프: \(big.map { "\($0.rawValue)(\(Int(magnitude($0) * 1000)) mm)" }.joined(separator: ", ")). 의도한 값인지 확인하세요(jawOpen 은 보통 30–40 mm).") }
            for s in ArkitShape.allCases where s.rawValue.hasSuffix("Left") {
                let a = magnitude(s), b = magnitude(s.mirrored)
                if a > 0.001, b > 0.001, abs(a - b) / max(a, b) > 0.5 { warn("shapes.symmetry", "\(s.rawValue)(\(Int(a * 1000)) mm) 와 \(s.mirrored.rawValue)(\(Int(b * 1000)) mm) 의 크기가 많이 다릅니다. 한쪽을 미러해 맞추세요.") }
            }
            let patchMoved = ArkitShape.allCases.filter { s in
                guard let d = t.shapeDeltas[s], d.count >= t.patchCount else { return false }
                var moved = false
                for i in t.patchCount..<d.count where simd_length(d[i]) > 0.0005 { if t.manifest.group(.shoulders).contains(i) { moved = true; break } }
                return moved
            }
            if !patchMoved.isEmpty { warn("shapes.shoulders", "어깨 정점을 움직이는 셰이프가 있습니다: \(patchMoved.map(\.rawValue).joined(separator: ", ")). 표정 셰이프는 어깨를 건드리지 않아야 합니다.") }
        }

        // 2. 셰이프키 52 이름
        let names = Set(m.shapeKeys)
        let missing = ArkitShape.allCases.filter { !names.contains($0.rawValue) }
        if !missing.isEmpty { err("shapes.missing", "셰이프키 \(missing.count)개가 없습니다: \(missing.map(\.rawValue).joined(separator: ", ")). Bust 오브젝트에 같은 이름(대소문자 그대로)의 셰이프키를 추가하세요(비어 있어도 됨).") }
        let extra = names.subtracting(ArkitShape.allCases.map(\.rawValue)).subtracting(["Basis"])
        if !extra.isEmpty { warn("shapes.extra", "ARKit 52 외의 셰이프키가 있습니다: \(extra.sorted().joined(separator: ", ")). 앱은 무시합니다.") }
        let miExpected = ["jawOpen", "jawLeft", "jawRight", "jawForward", "tongueOut"]
        let miMissing = miExpected.filter { !m.mouthInnerShapes.contains($0) }
        if !miMissing.isEmpty { err("mouthInner.shapes", "Mouth_Inner 에 셰이프키 \(miMissing.joined(separator: ", ")) 가 없습니다(2차 계약 #8: Bust 와 같은 이름 5개). 아래 치아·잇몸·혀가 jawOpen 을 따라 내려가야 합니다.") }

        // 3. 버텍스 그룹·랜드마크·대칭·루프
        for g in VertexGroupName.allCases {
            let ids = m.group(g)
            if ids.isEmpty { ((synthetic && (g == .lipInner || g == .lidInner)) ? warn : err)("groups.\(g.rawValue)", "버텍스 그룹 \(g.rawValue) 이 없거나 비어 있습니다. Bust 의 Vertex Groups 에 같은 이름으로 만들고 해당 정점을 할당하세요\(g == .neck ? "(Neck 은 Neck 뼈 스킨 가중치 > 0 인 정점)" : "").") }
            else if ids.contains(where: { $0 < 0 || $0 >= m.vertexCount }) { err("groups.range", "버텍스 그룹 \(g.rawValue) 에 범위 밖 정점 id 가 있습니다. 스크립트를 다시 실행하세요.") }
        }
        if m.group(.arkitFace).count != ARKitFaceTopology.vertexCount || m.group(.arkitFace).contains(where: { $0 >= ARKitFaceTopology.vertexCount }) {
            err("groups.ARKitFace", "ARKitFace 그룹은 정점 0…1219 정확히 1220개여야 합니다(현재 \(m.group(.arkitFace).count)개).")
        }
        if m.groupWeights[VertexGroupName.neck.rawValue] == nil, !m.group(.neck).isEmpty { warn("groups.neckWeights", "Neck 그룹의 가중치(groupWeights.Neck)가 template.json 에 없습니다. 2차 계약에서 Neck 영역 = Neck 뼈 스킨 가중치입니다 — 최신 스크립트로 다시 내보내세요.") }
        for l in LandmarkName.allCases {
            guard let id = m.landmark(l) else {
                if l.isRequired { err("landmarks.\(l.rawValue)", "랜드마크 \(l.rawValue) 가 없습니다. Bust 커스텀 속성 coursona_landmarks 에 정점 id 를 적으세요.") }
                else { info("landmarks.\(l.rawValue)", "선택 랜드마크 \(l.rawValue) 없음(앱이 입 루프/눈썹에서 추정).") }
                continue
            }
            if id < 0 || id >= m.vertexCount { err("landmarks.range", "랜드마크 \(l.rawValue) 의 정점 id \(id) 가 범위를 벗어났습니다.") }
            else if l.isRequired, l != .earTopLeft, l != .earTopRight, l != .shoulderLeft, l != .shoulderRight, id >= ARKitFaceTopology.vertexCount {
                warn("landmarks.patch", "랜드마크 \(l.rawValue)(정점 \(id))가 패치(0…1219) 밖입니다. 얼굴 랜드마크는 패치 정점이어야 피팅에 쓸 수 있습니다.")
            }
        }
        if m.symmetryMap.count != m.vertexCount { err("symmetry.size", "대칭 맵 길이(\(m.symmetryMap.count))가 정점 수(\(m.vertexCount))와 다릅니다.") }
        else {
            let unmatched = m.symmetryMap.filter { $0 < 0 }.count
            if unmatched > m.vertexCount / 20 { warn("symmetry.unmatched", "대칭 짝이 없는 정점이 \(unmatched)개(\(unmatched * 100 / max(1, m.vertexCount))%)입니다. 메시를 X 대칭(Symmetrize)으로 정리하세요.") }
        }
        if !synthetic {
            for (name, count) in [("eye_left", 24), ("eye_right", 24), ("mouth", 36), ("outer", 56)] {
                let loop = m.patchLoops[name] ?? []
                if loop.count != count { err("loops.\(name)", "patchLoops.\(name) 이 \(loop.count)개입니다(Apple OBJ 경계 \(count)개). 패치 구멍(눈·입)과 바깥 경계를 메우거나 바꾸지 마세요.") }
            }
        }

        // 4. 스켈레톤 (template.json)
        let bones = Set(m.boneRest.keys)
        let missingBones = BoneName.allCases.filter { !bones.contains($0.rawValue) }
        if !missingBones.isEmpty { err("skeleton.bones", "뼈가 없습니다: \(missingBones.map(\.rawValue).joined(separator: ", ")). Armature 를 Root > Spine > Neck > Head > {Eye_L, Eye_R} 로 만드세요.") }
        for (bone, y, tol) in [("Root", Float(0.0), Float(0.03)), ("Spine", 0.12, 0.03), ("Neck", 0.30, 0.03), ("Head", 0.36, 0.03)] {
            if let p = m.boneRest[bone], p.count == 3, abs(p[1] - y) > tol { warn("skeleton.\(bone)", String(format: "%@ 뼈 높이 y=%.3f (계약 ≈%.2f). 목·머리 회전 피벗이 어긋나면 클립이 다르게 보입니다.", bone, p[1], y)) }
        }
        if !m.boneParents.isEmpty {
            let expected = ["Spine": "Root", "Neck": "Spine", "Head": "Neck", "Eye_L": "Head", "Eye_R": "Head"]
            for (b, p) in expected where m.boneParents[b] != p { err("skeleton.parent", "\(b) 의 부모가 \(m.boneParents[b] ?? "없음") 입니다(계약 \(p)).") }
        }

        // 5. 라이브러리
        let libNames = Set(input.library.map(\.name)).union(m.libraryObjects)
        let libPattern = try! NSRegularExpression(pattern: "^(Hair|Glasses|Beard|Shoulders)_[a-z0-9_]+$")
        let bad = libNames.filter { libPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
        if !bad.isEmpty { err("library.names", "라이브러리 이름 규칙(Hair_<id>/Glasses_<id>/Beard_<id>/Shoulders_<id>, 소문자)에 맞지 않습니다: \(bad.sorted().joined(separator: ", "))") }
        let hairs = hairStyles.filter { libNames.contains("Hair_" + $0) }
        let missingHair = hairStyles.filter { !libNames.contains("Hair_" + $0) }
        if hairs.count < 10 { (synthetic ? warn : err)("library.hair", "머리카락 라이브러리가 \(hairs.count)종입니다(계약 10종 이상). 없는 것: \(missingHair.joined(separator: ", "))") }
        else if !missingHair.isEmpty { warn("library.hair", "계약 목록에서 빠진 머리카락: \(missingHair.joined(separator: ", "))") }
        for req in requiredLibrary where !libNames.contains(req) {
            if req.hasPrefix("Shoulders") { (synthetic ? warn : err)("library.missing", "라이브러리 \(req) 가 없습니다. Library_Shoulders 컬렉션에 Shoulders_<id> 오브젝트(Root/Neck 스킨, Bust 몸통 셸)를 만드세요.") }
            else { warn("library.missing", "라이브러리 \(req) 가 없습니다.") }
        }
        for e in input.library {
            switch e.kind {
            case .beard:
                if let bi = e.bustIndex { if bi.count != e.vertexCount { err("library.beardIndex", "\(e.name) 의 coursona_bust_index 길이(\(bi.count))가 정점 수(\(e.vertexCount))와 다릅니다.") }
                    else if bi.contains(where: { $0 < 0 || $0 >= m.vertexCount }) { err("library.beardIndex", "\(e.name) 의 coursona_bust_index 에 범위 밖 Bust 정점이 있습니다.") } }
                else { err("library.beardIndex", "\(e.name) 에 정점 속성 coursona_bust_index(INT, POINT) 가 없습니다(2차 계약 #5). 수염 셸 정점마다 원본 Bust 정점 id 를 넣으세요.") }
            case .shoulders:
                if !(e.skinGroups.contains("Root") && e.skinGroups.contains("Neck")) { warn("library.shouldersSkin", "\(e.name) 의 스킨 그룹이 \(e.skinGroups) 입니다(2차 계약 #6: Bust 의 Root/Neck 가중치 복사). 목둘레가 목을 따라가지 않습니다.") }
            case .hair:
                if e.textures["base"] == nil { warn("library.hairTex", "\(e.name) 에 베이스 텍스처가 연결돼 있지 않습니다(그레이스케일 + 알파, 틴트용).") }
            case .glasses:
                if e.noseBridge == nil { info("library.glasses", "\(e.name) 에 코 받침 위치(coursona_nose_bridge)가 없습니다.") }
            }
            for (_, file) in e.textures where !input.textures.contains(file) && !input.textures.isEmpty {
                err("library.texture", "\(e.name) 이 참조하는 텍스처 \(file) 이 Template/textures 에 없습니다. 이미지를 PNG 로 저장(File > External Data > Unpack)하고 다시 내보내세요.")
            }
        }

        // 6. 클립
        let clipByName = Dictionary(uniqueKeysWithValues: input.clips.map { ($0.name, $0) })
        for c in SampledClip.contract {
            guard let clip = clipByName[c.name] else { err("clips.missing", "클립 \(c.name) 이 없습니다. 액션 clip_\(c.name) 을 만들고(30 fps, \(c.seconds) s, \(c.loop ? "루프" : "1회")) 스크립트로 내보내세요."); continue }
            if abs(clip.fps - 30) > 0.01 { err("clips.fps", "클립 \(c.name) 의 fps 가 \(clip.fps) 입니다. 씬 프레임레이트를 30 으로 두세요.") }
            let expectedFrames = Int((c.seconds * 30).rounded()) + 1
            if clip.frames != expectedFrames { err("clips.length", "클립 \(c.name) 프레임 수가 \(clip.frames) 입니다(계약 0…\(expectedFrames - 1) 끝 포함 = \(expectedFrames)). 액션 프레임 범위를 0–\(expectedFrames - 1) 로 맞추세요.") }
            if clip.loop != c.loop { err("clips.loop", "클립 \(c.name) 의 loop 가 \(clip.loop) 입니다(계약 \(c.loop)). 액션의 Cyclic/use_cyclic 과 스크립트 CLIPS 표를 확인하세요.") }
            if c.loop, clip.loopSeamError() > 0.01 { err("clips.seam", String(format: "루프 클립 %@ 의 첫/끝 프레임이 다릅니다(최대 차 %.3f). 마지막 키프레임을 첫 키프레임과 같게 하세요.", c.name, clip.loopSeamError())) }
            let unknownShapes = clip.shapes.keys.filter { ArkitShape(rawValue: $0) == nil }
            if !unknownShapes.isEmpty { warn("clips.shapes", "클립 \(c.name) 에 ARKit 52 가 아닌 셰이프 트랙: \(unknownShapes.sorted().joined(separator: ", "))") }
            let unknownBones = clip.bones.keys.filter { BoneName(rawValue: $0) == nil }
            if !unknownBones.isEmpty { warn("clips.bones", "클립 \(c.name) 에 계약 밖 뼈 트랙: \(unknownBones.sorted().joined(separator: ", "))") }
            for (k, v) in clip.shapes where v.count != clip.frames { err("clips.frames", "클립 \(c.name) 셰이프 \(k) 트랙 길이(\(v.count))가 frames(\(clip.frames))와 다릅니다.") }
            for (k, v) in clip.bones where v.count != clip.frames { err("clips.frames", "클립 \(c.name) 뼈 \(k) 트랙 길이(\(v.count))가 frames(\(clip.frames))와 다릅니다.") }
            if c.name.hasPrefix("talk_"), clip.shapes.keys.contains(where: { ArkitShape(rawValue: $0)?.isMouthRegion == true }) {
                warn("clips.talkMouth", "클립 \(c.name) 에 입 셰이프 트랙이 있습니다. talk 클립은 입을 비워 두세요(앱이 비셈으로 채웁니다).")
            }
            if let anyShape = clip.shapes.values.first(where: { $0.contains { $0 < -0.001 || $0 > 1.001 } }) { _ = anyShape; err("clips.shapeRange", "클립 \(c.name) 의 셰이프 값이 0…1 을 벗어납니다. 셰이프키 slider_min/max 0–1 안에서 키를 찍으세요.") }
            if !input.previzNames.contains(c.name) { warn("previz.missing", "previz/\(c.name).mp4 가 없습니다. Previz_Camera(조준 (0,0.41,0.09), 위치 (0,0.41,1.29), 수평 FOV 39.6°, 1080p 30fps, 맨 흉상)로 렌더해 넣으세요.") }
        }
        if let pv = m.previz {
            let c = PrevizCameraSpec.contract
            if pv.aim.count == 3, pv.position.count == 3,
               zip(pv.aim, c.aim).contains(where: { abs($0 - $1) > 0.002 }) || zip(pv.position, c.position).contains(where: { abs($0 - $1) > 0.002 }) || abs(pv.horizontalFOVDegrees - c.horizontalFOVDegrees) > 0.05 {
                err("previz.camera", "프리비즈 카메라가 계약(조준 (0,0.41,0.09)·위치 (0,0.41,1.29)·수평 FOV 39.60°)과 다릅니다: 조준 \(pv.aim), 위치 \(pv.position), FOV \(pv.horizontalFOVDegrees). Previz_Camera 와 Previz_Aim 을 맞추세요.")
            }
            if pv.width != 1920 || pv.height != 1080 || abs(pv.fps - 30) > 0.01 { err("previz.format", "프리비즈 해상도/fps 가 \(pv.width)×\(pv.height) \(pv.fps) 입니다(계약 1920×1080 30 fps).") }
        } else if !synthetic { warn("previz.spec", "template.json 에 previz 카메라 정보가 없습니다. 최신 스크립트로 다시 내보내세요.") }
        return out
    }

    /// a 의 각 점에서 b 의 최근접 점까지 거리의 최댓값 (격자 해시).
    static func nearestDistanceMax(from a: [SIMD3<Float>], to b: [SIMD3<Float>]) -> (Float, SIMD3<Float>) {
        let cell: Float = 0.004
        var grid: [SIMD3<Int32>: [Int]] = [:]
        func key(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down))) }
        for (i, p) in b.enumerated() { grid[key(p), default: []].append(i) }
        var worst: Float = 0, at = SIMD3<Float>.zero
        for p in a {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return (1, p) }
            let k = key(p)
            var best = Float.greatestFiniteMagnitude
            for dx in -1...1 { for dy in -1...1 { for dz in -1...1 {
                for j in grid[SIMD3(k.x + Int32(dx), k.y + Int32(dy), k.z + Int32(dz))] ?? [] { best = min(best, simd_length_squared(p - b[j])) }
            } } }
            let d: Float = best == .greatestFiniteMagnitude ? 1 : best.squareRoot()
            if d > worst { worst = d; at = p }
        }
        return (worst, at)
    }

    /// 패치 UV 와 비패치 UV 의 겹침 비율 (1024² 점유 격자).
    static func uvOverlapRatio(_ t: BustTemplate) -> Float {
        let S = 1024
        var patch = [Bool](repeating: false, count: S * S), other = [Bool](repeating: false, count: S * S)
        func raster(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, into grid: inout [Bool]) {
            let pa = SIMD2(a.x * Float(S), (1 - a.y) * Float(S)), pb = SIMD2(b.x * Float(S), (1 - b.y) * Float(S)), pc = SIMD2(c.x * Float(S), (1 - c.y) * Float(S))
            let minX = max(0, Int(min(pa.x, pb.x, pc.x))), maxX = min(S - 1, Int(max(pa.x, pb.x, pc.x)))
            let minY = max(0, Int(min(pa.y, pb.y, pc.y))), maxY = min(S - 1, Int(max(pa.y, pb.y, pc.y)))
            guard minX <= maxX, minY <= maxY else { return }
            let area = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
            guard abs(area) > 1e-6 else { return }
            for y in minY...maxY { for x in minX...maxX {
                let px = Float(x) + 0.5, py = Float(y) + 0.5
                let w0 = ((pb.x - px) * (pc.y - py) - (pb.y - py) * (pc.x - px)) / area
                let w1 = ((pc.x - px) * (pa.y - py) - (pc.y - py) * (pa.x - px)) / area
                let w2 = 1 - w0 - w1
                if w0 >= 0, w1 >= 0, w2 >= 0 { grid[y * S + x] = true }
            } }
        }
        var i = 0
        let pc = t.patchCount
        let corner = t.effectiveCornerUVs
        while i + 2 < t.indices.count {
            let a = Int(t.indices[i]), b = Int(t.indices[i + 1]), c = Int(t.indices[i + 2])
            let isPatch = a < pc && b < pc && c < pc
            if isPatch { raster(corner[i], corner[i + 1], corner[i + 2], into: &patch) } else { raster(corner[i], corner[i + 1], corner[i + 2], into: &other) }
            i += 3
        }
        var both = 0, p = 0
        for k in 0..<(S * S) { if patch[k] { p += 1; if other[k] { both += 1 } } }
        return p > 0 ? Float(both) / Float(p) : 0
    }

    public static func hasErrors(_ issues: [ValidationIssue]) -> Bool { issues.contains { $0.severity == .error } }

    /// 보고서 텍스트.
    public static func report(_ issues: [ValidationIssue], title: String) -> String {
        var lines = ["# coursona-validate — \(title)"]
        let errors = issues.filter { $0.severity == .error }, warns = issues.filter { $0.severity == .warning }, infos = issues.filter { $0.severity == .info }
        lines.append(errors.isEmpty ? "✅ 오류 없음 (경고 \(warns.count))" : "❌ 오류 \(errors.count) · 경고 \(warns.count)")
        for i in errors + warns + infos { lines.append(i.description) }
        return lines.joined(separator: "\n")
    }
}
