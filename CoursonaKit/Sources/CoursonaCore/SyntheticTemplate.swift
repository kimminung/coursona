//
//  SyntheticTemplate.swift
//  CoursonaCore
//
//  블렌더 산출물이 없을 때 쓰는 **절차적 흉상 템플릿**. 계약(Blender-요청.md)과 같은 구조를 갖는다:
//  정점 0…1219 = 얼굴 패치(20 열 × 61 행 격자, ARKit 1220 과 수만 같고 토폴로지는 다르다 — 실제 템플릿이 오면 교체),
//  그 뒤로 두상·귀·목·어깨(80 열 lat-long), 52 셰이프키(절차적 델타), 스켈레톤 6 뼈, 버텍스 그룹, 랜드마크, 대칭 맵, UV.
//  용도: Fixtures(합성 캡처 번들), 셀프 피팅 테스트, 시뮬레이터 미리보기, 검증기 자체 테스트.
//

import Foundation
import simd

public enum SyntheticTemplate {
    public static let id = "synthetic-bust"
    public static let version = "0.1"

    // 격자 치수
    public static let patchCols = 20
    public static let patchRows = 61          // 20 × 61 = 1220
    static let backCols = 60                  // 전체 80 열
    static var cols: Int { patchCols + backCols }
    static let crownPhis: [Float] = [85, 80, 75, 70, 65, 60, 55, 50]
    static let belowPhis: [Float] = [-55, -60, -65]
    static let neckYs: [Float] = [0.30, 0.28, 0.26, 0.24, 0.22]
    static let shoulderYs: [Float] = [0.20, 0.17, 0.14, 0.10, 0.06, 0.02, 0.0]

    // 두상 타원체
    static let headCenterY: Float = 0.43
    static let ax: Float = 0.075, by: Float = 0.136, cz: Float = 0.095

    /// 행 종류
    enum RowKind { case crown(Float), patch(Float), below(Float), neck(Float), shoulder(Float) }

    static var rows: [RowKind] {
        var r: [RowKind] = []
        r += crownPhis.map { .crown($0) }
        r += (0..<patchRows).map { .patch(45 - 95 * Float($0) / Float(patchRows - 1)) }
        r += belowPhis.map { .below($0) }
        r += neckYs.map { .neck($0) }
        r += shoulderYs.map { .shoulder($0) }
        return r
    }

    /// 열 → 방위각(도). 0 = 정면(+Z), + = 피사체 왼쪽(+X).
    static func theta(col g: Int) -> Float {
        if g < patchCols { return -55 + 110 * Float(g) / Float(patchCols - 1) }
        let k = g - patchCols
        return 55 + 250 * Float(k + 1) / Float(backCols + 1)
    }

    /// 행 → (y, rx, rz)
    static func profile(_ row: RowKind) -> (y: Float, rx: Float, rz: Float, phi: Float?) {
        switch row {
        case .crown(let p), .patch(let p), .below(let p):
            let rad = p * .pi / 180
            return (headCenterY + by * sin(rad), ax * cos(rad), cz * cos(rad), p)
        case .neck(let y):
            // 목: 턱 아래(0.30, r≈0.045)에서 0.22 까지 살짝 굵어짐
            let t = (0.30 - y) / 0.08
            return (y, 0.045 + 0.012 * t, 0.045 + 0.010 * t, nil)
        case .shoulder(let y):
            // 어깨: 0.20 에서 0 까지 가로 0.06 → 0.22, 앞뒤 0.055 → 0.10
            let t = min(1, max(0, (0.20 - y) / 0.14))
            let s = t * t * (3 - 2 * t)
            return (y, 0.06 + 0.16 * s, 0.055 + 0.045 * s, nil)
        }
    }

    static func gauss(_ th: Float, _ ph: Float, _ th0: Float, _ ph0: Float, _ sth: Float, _ sph: Float) -> Float {
        let dt = (th - th0) / sth, dp = (ph - ph0) / sph
        return exp(-(dt * dt + dp * dp))
    }
    static func smooth(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }

    /// 템플릿 생성 (결정적).
    public static func make() -> BustTemplate {
        let rowList = rows
        let C = cols
        let R = rowList.count
        // 정점 id 배정: 패치 먼저
        var idOf = [[Int]](repeating: [Int](repeating: -1, count: C), count: R)
        var next = 0
        for ri in 0..<R { if case .patch = rowList[ri] { for g in 0..<patchCols { idOf[ri][g] = next; next += 1 } } }
        precondition(next == ARKitFaceTopology.vertexCount)
        for ri in 0..<R { for g in 0..<C where idOf[ri][g] < 0 { idOf[ri][g] = next; next += 1 } }
        let poleID = next; next += 1
        let V = next

        var pos = [SIMD3<Float>](repeating: .zero, count: V)
        var uv = [SIMD2<Float>](repeating: .zero, count: V)
        var thetaOf = [Float](repeating: 0, count: V), phiOf = [Float](repeating: .nan, count: V)
        var rowOf = [Int](repeating: -1, count: V)
        var patchRowCol = [(Int, Int)?](repeating: nil, count: V)

        for ri in 0..<R {
            let prof = profile(rowList[ri])
            for g in 0..<C {
                let th = theta(col: g)
                let rad = th * .pi / 180
                var p = SIMD3<Float>(prof.rx * sin(rad), prof.y, prof.rz * cos(rad))
                // 코: 패치 중앙 아래쪽 융기
                if let ph = prof.phi {
                    let bump = 0.02 * gauss(th, ph, 0, -8, 12, 9)
                    if bump > 1e-5 {
                        let n = simd_normalize(SIMD3(p.x / (ax * ax), (p.y - headCenterY) / (by * by), p.z / (cz * cz)))
                        p += n * bump
                    }
                    // 콧대
                    p.z += 0.006 * gauss(th, ph, 0, 0, 5, 10)
                }
                let id = idOf[ri][g]
                pos[id] = p
                thetaOf[id] = th; phiOf[id] = prof.phi ?? .nan; rowOf[id] = ri
                if case .patch = rowList[ri], g < patchCols {
                    let r = ri - crownPhis.count
                    patchRowCol[id] = (r, g)
                    uv[id] = SIMD2(Float(g) / Float(patchCols - 1), 0.5 - 0.5 * Float(r) / Float(patchRows - 1))
                } else {
                    var u = (th + 55) / 360
                    u -= u.rounded(.down)
                    let v = 0.5 + 0.5 * (1 - Float(ri) / Float(R - 1))
                    uv[id] = SIMD2(u, v)
                }
            }
        }
        pos[poleID] = SIMD3(0, headCenterY + by, 0)
        uv[poleID] = SIMD2(0.5, 1)
        thetaOf[poleID] = 0; phiOf[poleID] = 90; rowOf[poleID] = -1

        // 삼각형
        var idx: [UInt32] = []
        idx.reserveCapacity(R * C * 6)
        for g in 0..<C {
            let a = idOf[0][g], b = idOf[0][(g + 1) % C]
            idx += [UInt32(poleID), UInt32(a), UInt32(b)]
        }
        for ri in 0..<(R - 1) {
            for g in 0..<C {
                let g1 = (g + 1) % C
                let A = idOf[ri][g], B = idOf[ri][g1], Cc = idOf[ri + 1][g], D = idOf[ri + 1][g1]
                idx += [UInt32(A), UInt32(Cc), UInt32(B), UInt32(B), UInt32(Cc), UInt32(D)]
            }
        }

        // 버텍스 그룹
        var groups: [String: [Int]] = [:]
        groups[VertexGroupName.arkitFace.rawValue] = Array(0..<ARKitFaceTopology.vertexCount)
        var scalp: [Int] = [poleID], earL: [Int] = [], earR: [Int] = [], neck: [Int] = [], shoulders: [Int] = []
        for id in 0..<V where id != poleID {
            let ri = rowOf[id]
            let th = thetaOf[id], ph = phiOf[id]
            switch rowList[ri] {
            case .crown: scalp.append(id)
            case .patch, .below:
                let isBack = th > 55 && th < 305
                if isBack, ph > -20 { scalp.append(id) }
                if ph <= -55 { neck.append(id) }
                if isBack, abs(th - 90) < 12, ph > -15, ph < 10 { earL.append(id) }
                if isBack, abs(th - 270) < 12, ph > -15, ph < 10 { earR.append(id) }
            case .neck: neck.append(id)
            case .shoulder: shoulders.append(id)
            }
        }
        groups[VertexGroupName.scalp.rawValue] = scalp
        groups[VertexGroupName.earL.rawValue] = earL
        groups[VertexGroupName.earR.rawValue] = earR
        groups[VertexGroupName.neck.rawValue] = neck
        groups[VertexGroupName.shoulders.rawValue] = shoulders
        groups[VertexGroupName.lipInner.rawValue] = []
        groups[VertexGroupName.lidInner.rawValue] = []

        // 랜드마크
        func patchID(_ r: Int, _ c: Int) -> Int { r * patchCols + c }
        func nearest(theta th: Float, phi ph: Float) -> Int {
            if ph <= -80 {   // 어깨 끝: 어깨 행에서 x 극값
                var best = 0, bx: Float = -1
                for id in 0..<V where rowOf[id] >= 0 { if case .shoulder = rowList[rowOf[id]] { let x = th < 180 ? pos[id].x : -pos[id].x; if x > bx { bx = x; best = id } } }
                return best
            }
            var best = 0, bd = Float.greatestFiniteMagnitude
            for id in 0..<V where phiOf[id].isFinite {
                var dth = abs(thetaOf[id] - th); dth = min(dth, 360 - dth)
                let d = dth * dth + (phiOf[id] - ph) * (phiOf[id] - ph)
                if d < bd { bd = d; best = id }
            }
            return best
        }
        var landmarks: [String: Int] = [:]
        landmarks[LandmarkName.eyeLeftOuter.rawValue] = patchID(26, 16)
        landmarks[LandmarkName.eyeLeftInner.rawValue] = patchID(26, 12)
        landmarks[LandmarkName.eyeRightInner.rawValue] = patchID(26, 7)
        landmarks[LandmarkName.eyeRightOuter.rawValue] = patchID(26, 3)
        landmarks[LandmarkName.noseTip.rawValue] = patchID(34, 10)
        landmarks[LandmarkName.mouthLeft.rawValue] = patchID(49, 14)
        landmarks[LandmarkName.mouthRight.rawValue] = patchID(49, 5)
        landmarks[LandmarkName.lipUpperMid.rawValue] = patchID(47, 10)
        landmarks[LandmarkName.lipLowerMid.rawValue] = patchID(51, 10)
        landmarks[LandmarkName.chin.rawValue] = patchID(60, 10)
        landmarks[LandmarkName.browInnerLeft.rawValue] = patchID(21, 12)
        landmarks[LandmarkName.browInnerRight.rawValue] = patchID(21, 7)
        landmarks[LandmarkName.earTopLeft.rawValue] = nearest(theta: 90, phi: 10)
        landmarks[LandmarkName.earTopRight.rawValue] = nearest(theta: 270, phi: 10)
        landmarks[LandmarkName.shoulderLeft.rawValue] = nearest(theta: 90, phi: -89)
        landmarks[LandmarkName.shoulderRight.rawValue] = nearest(theta: 270, phi: -89)

        // 패치 루프 (계약 `patchLoops`): 눈꺼풀 고리(행 25…27 × 열 3…7 / 12…16 의 테두리, 순서대로) · 입 고리. 눈알 링 피팅(T-302) 테스트용.
        func rectLoop(rows r0: Int, _ r1: Int, cols c0: Int, _ c1: Int) -> [Int] {
            var loop: [Int] = []
            for c in c0...c1 { loop.append(patchID(r0, c)) }
            for r in (r0 + 1)..<r1 { loop.append(patchID(r, c1)) }
            for c in stride(from: c1, through: c0, by: -1) { loop.append(patchID(r1, c)) }
            for r in stride(from: r1 - 1, to: r0, by: -1) { loop.append(patchID(r, c0)) }
            return loop
        }
        let patchLoops: [String: [Int]] = [
            "eye_right": rectLoop(rows: 25, 27, cols: 3, 7),
            "eye_left": rectLoop(rows: 25, 27, cols: 12, 16),
            "mouth": rectLoop(rows: 46, 52, cols: 5, 14),
        ]

        // 대칭 맵
        var sym = [Int32](repeating: -1, count: V)
        for ri in 0..<R {
            for g in 0..<C {
                let gm = g < patchCols ? (patchCols - 1 - g) : (99 - g)
                sym[idOf[ri][g]] = Int32(idOf[ri][gm])
            }
        }
        sym[poleID] = Int32(poleID)

        // 셰이프 델타
        let deltas = makeShapeDeltas(positions: pos, theta: thetaOf, phi: phiOf, rows: rowOf, rowList: rowList)

        // 스켈레톤·스킨
        let jointNames = BoneName.allCases.map(\.rawValue)
        let parents = [-1, 0, 1, 2, 3, 3]
        let eyeZ = cz * cos(4.2 * Float.pi / 180) * cos(25.3 * Float.pi / 180) - 0.010
        let restPos: [SIMD3<Float>] = [[0, 0, 0], [0, 0.12, 0], [0, 0.30, 0], [0, 0.36, 0], [0.032, 0.44, eyeZ], [-0.032, 0.44, eyeZ]]
        let rest = restPos.map { p -> simd_float4x4 in var m = matrix_identity_float4x4; m.columns.3 = SIMD4(p, 1); return m }
        let skeleton = TemplateSkeleton(jointNames: jointNames, parentIndices: parents, restWorld: rest)
        let jNeck = UInt16(2), jHead = UInt16(3), jRoot = UInt16(0)
        var skin = [SkinInfluence](repeating: .none, count: V)
        for id in 0..<V {
            if id == poleID { skin[id] = SkinInfluence(joints: SIMD4(jHead, 0, 0, 0), weights: SIMD4(1, 0, 0, 0)); continue }
            switch rowList[rowOf[id]] {
            case .crown, .patch: skin[id] = SkinInfluence(joints: SIMD4(jHead, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
            case .below(let ph):
                let wh = smooth((ph + 65) / 10 * 0.5 + 0.5)
                skin[id] = SkinInfluence(joints: SIMD4(jHead, jNeck, 0, 0), weights: SIMD4(wh, 1 - wh, 0, 0))
            case .neck(let y):
                let wh = smooth((y - 0.22) / 0.08) * 0.6
                skin[id] = SkinInfluence(joints: SIMD4(jHead, jNeck, 0, 0), weights: SIMD4(wh, 1 - wh, 0, 0))
            case .shoulder: skin[id] = SkinInfluence(joints: SIMD4(jRoot, 0, 0, 0), weights: SIMD4(1, 0, 0, 0))
            }
        }

        let patchHash = ARKitFaceTopology.patchTriangleHash(indices: idx, patchCount: ARKitFaceTopology.vertexCount)
        // 코너 UV: 패치 삼각형은 패치 UV, 그 외(혼합 포함)는 lat-long UV. u 랩(열 79→0)을 건너는 삼각형은 작은 u 에 +1 → 전체 상반부 u 를 1/1.31 로 축소
        var latlong = [SIMD2<Float>](repeating: .zero, count: V)
        for id in 0..<V {
            let th = thetaOf[id]
            let u = (th + 55) / 360
            let v: Float = id == poleID ? 1 : 0.5 + 0.5 * (1 - Float(rowOf[id]) / Float(R - 1))
            latlong[id] = SIMD2(u, v)
        }
        var cornerUV = [SIMD2<Float>](repeating: .zero, count: idx.count)
        var t3 = 0
        while t3 + 2 < idx.count {
            let a = Int(idx[t3]), b = Int(idx[t3 + 1]), c = Int(idx[t3 + 2])
            if a < ARKitFaceTopology.vertexCount, b < ARKitFaceTopology.vertexCount, c < ARKitFaceTopology.vertexCount {
                cornerUV[t3] = uv[a]; cornerUV[t3 + 1] = uv[b]; cornerUV[t3 + 2] = uv[c]
            } else {
                var us = [latlong[a], latlong[b], latlong[c]]
                let umax = us.map(\.x).max() ?? 0
                for k in 0..<3 where umax - us[k].x > 0.5 { us[k].x += 1 }   // 랩 보정 (극점 u=0 은 이웃을 따라감)
                if a == poleID || b == poleID || c == poleID {
                    let others = [a, b, c].enumerated().filter { $0.element != poleID }.map { us[$0.offset].x }
                    for k in 0..<3 where [a, b, c][k] == poleID { us[k].x = (others.first ?? 0 + (others.last ?? 0)) / 2 }
                }
                for k in 0..<3 { cornerUV[t3 + k] = SIMD2(us[k].x / 1.31, us[k].y) }
            }
            t3 += 3
        }

        var manifest = TemplateManifest(id: id, version: version, vertexCount: V, triangleCount: idx.count / 3,
                                        patchTriangleHash: ARKitFaceTopology.hexString(patchHash),
                                        landmarks: landmarks, groups: groups, shapeKeys: ArkitShape.allCases.map(\.rawValue))
        manifest.generator = "CoursonaCore.SyntheticTemplate"
        manifest.schema = 2
        manifest.patchFaceCount = 0   // 합성 패치는 사각형이 아닌 삼각형 격자 (Apple 해시 검사 생략 대상)
        manifest.symmetryMap = sym
        manifest.patchLoops = patchLoops
        manifest.eyeSpacing = 0.064
        manifest.mouthCenter = [0, headCenterY + by * sin(-32.5 * Float.pi / 180), 0.08]
        manifest.chinY = pos[patchID(60, 10)].y
        manifest.crownY = headCenterY + by
        manifest.jawPivot = [0, 0.414, -0.006]; manifest.jawOpenDegrees = 22; manifest.jawOpenTranslate = [0, -0.013, 0]
        manifest.boneParents = ["Spine": "Root", "Neck": "Spine", "Head": "Neck", "Eye_L": "Head", "Eye_R": "Head"]
        manifest.mouthInnerShapes = ["jawOpen", "jawLeft", "jawRight", "jawForward", "tongueOut"]
        manifest.previz = .contract
        manifest.groupWeights[VertexGroupName.neck.rawValue] = neck.map { id -> Float in
            if case .neck(let y) = rowList[rowOf[id]] { return 1 - smooth((y - 0.22) / 0.08) * 0.6 }
            return 0.5
        }
        for s in ArkitShape.allCases { manifest.shapeMaxDisplacementMM[s.rawValue] = (deltas[s] ?? []).reduce(0) { max($0, simd_length($1)) } * 1000 }
        manifest.eyeL = [0.032, 0.44, eyeZ]; manifest.eyeR = [-0.032, 0.44, eyeZ]; manifest.eyeRadius = 0.012
        manifest.uvRegions = ["face": [0, 0, 1, 0.5], "scalpNeck": [0, 0.5, 1, 0.85], "shoulders": [0, 0.85, 1, 1]]
        manifest.boneRest = Dictionary(uniqueKeysWithValues: zip(jointNames, restPos.map(\.array)))
        manifest.clips = []
        var template = BustTemplate(manifest: manifest, positions: pos, uvs: uv, indices: idx, shapeDeltas: deltas, skin: skin, skeleton: skeleton)
        template.cornerUVs = cornerUV
        return template
    }

    /// 52 셰이프 델타 (각도 공간의 가우스 범프). 두상 정점에만 (목·어깨 0).
    static func makeShapeDeltas(positions: [SIMD3<Float>], theta: [Float], phi: [Float], rows: [Int], rowList: [RowKind]) -> [ArkitShape: [SIMD3<Float>]] {
        let V = positions.count
        var out: [ArkitShape: [SIMD3<Float>]] = [:]
        func field(_ shape: ArkitShape, _ f: (Float, Float, SIMD3<Float>) -> SIMD3<Float>) {
            var arr = [SIMD3<Float>](repeating: .zero, count: V)
            for i in 0..<V where phi[i].isFinite && phi[i] < 89 {
                var th = theta[i]; if th > 180 { th -= 360 }
                guard abs(th) < 70 else { continue }
                arr[i] = f(th, phi[i], positions[i])
            }
            out[shape] = arr
        }
        let mouthPhi: Float = -32.5, eyePhi: Float = 4.2, browPhi: Float = 12
        func side(_ s: ArkitShape) -> Float { s.rawValue.hasSuffix("Left") ? 1 : -1 }
        func outward(_ p: SIMD3<Float>) -> SIMD3<Float> { simd_normalize(SIMD3(p.x / (ax * ax), (p.y - headCenterY) / (by * by), p.z / (cz * cz))) }

        for s in ArkitShape.allCases {
            switch s {
            case .jawOpen:
                field(s) { th, ph, _ in SIMD3(0, -0.018 * smooth((-30 - ph) / 15) * smooth((50 - abs(th)) / 10), -0.004 * smooth((-30 - ph) / 15)) }
            case .jawForward:
                field(s) { th, ph, _ in SIMD3(0, 0, 0.006 * smooth((-35 - ph) / 10) * smooth((50 - abs(th)) / 10)) }
            case .jawLeft, .jawRight:
                field(s) { th, ph, _ in SIMD3(side(s) * 0.006 * smooth((-35 - ph) / 10) * smooth((50 - abs(th)) / 10), 0, 0) }
            case .mouthSmileLeft, .mouthSmileRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 23, mouthPhi, 10, 8); return SIMD3(side(s) * 0.004 * g, 0.006 * g, -0.002 * g) }
            case .mouthFrownLeft, .mouthFrownRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 23, mouthPhi, 10, 8); return SIMD3(0, -0.005 * g, 0) }
            case .mouthStretchLeft, .mouthStretchRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 20, mouthPhi, 12, 8); return SIMD3(side(s) * 0.006 * g, 0, 0) }
            case .mouthDimpleLeft, .mouthDimpleRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 26, mouthPhi, 7, 7); return SIMD3(0, 0, -0.003 * g) }
            case .mouthPressLeft, .mouthPressRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 10, mouthPhi, 10, 5); return SIMD3(0, 0, -0.002 * g) }
            case .mouthLowerDownLeft, .mouthLowerDownRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 10, mouthPhi - 4, 10, 4); return SIMD3(0, -0.005 * g, 0) }
            case .mouthUpperUpLeft, .mouthUpperUpRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 10, mouthPhi + 4, 10, 4); return SIMD3(0, 0.004 * g, 0) }
            case .mouthPucker:
                field(s) { th, ph, p in let g = gauss(th, ph, 0, mouthPhi, 16, 8); return SIMD3(-p.x * 0.3 * g, 0, 0.006 * g) }
            case .mouthFunnel:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi, 16, 8); return SIMD3(0, (ph > mouthPhi ? 0.003 : -0.003) * g, 0.005 * g) }
            case .mouthClose:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi - 3, 16, 4); return SIMD3(0, 0.003 * g, 0) }
            case .mouthLeft, .mouthRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi, 16, 8); return SIMD3((s == .mouthLeft ? 1 : -1) * 0.006 * g, 0, 0) }
            case .mouthRollLower:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi - 3, 14, 3); return SIMD3(0, 0.002 * g, -0.003 * g) }
            case .mouthRollUpper:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi + 3, 14, 3); return SIMD3(0, -0.002 * g, -0.003 * g) }
            case .mouthShrugLower:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi - 5, 14, 5); return SIMD3(0, 0.004 * g, 0.002 * g) }
            case .mouthShrugUpper:
                field(s) { th, ph, _ in let g = gauss(th, ph, 0, mouthPhi + 5, 14, 5); return SIMD3(0, 0.004 * g, 0.002 * g) }
            case .eyeBlinkLeft, .eyeBlinkRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi + 3, 9, 5) * smooth((ph - eyePhi) / 2 + 0.5); return SIMD3(0, -0.006 * g, -0.001 * g) }
            case .eyeWideLeft, .eyeWideRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi + 4, 9, 4); return SIMD3(0, 0.003 * g, 0) }
            case .eyeSquintLeft, .eyeSquintRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi - 4, 9, 4); return SIMD3(0, 0.003 * g, 0) }
            case .eyeLookUpLeft, .eyeLookUpRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi + 3, 9, 4); return SIMD3(0, 0.002 * g, 0) }
            case .eyeLookDownLeft, .eyeLookDownRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi + 3, 9, 4); return SIMD3(0, -0.002 * g, 0) }
            case .eyeLookInLeft, .eyeLookInRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi, 9, 4); return SIMD3(-side(s) * 0.001 * g, 0, 0) }
            case .eyeLookOutLeft, .eyeLookOutRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 25, eyePhi, 9, 4); return SIMD3(side(s) * 0.001 * g, 0, 0) }
            case .browInnerUp:
                field(s) { th, ph, _ in let g = max(gauss(th, ph, 12, browPhi, 9, 6), gauss(th, ph, -12, browPhi, 9, 6)); return SIMD3(0, 0.006 * g, 0) }
            case .browDownLeft, .browDownRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 18, browPhi, 12, 6); return SIMD3(0, -0.005 * g, 0) }
            case .browOuterUpLeft, .browOuterUpRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 32, browPhi, 9, 6); return SIMD3(0, 0.005 * g, 0) }
            case .cheekPuff:
                field(s) { th, ph, p in let g = max(gauss(th, ph, 28, -15, 10, 9), gauss(th, ph, -28, -15, 10, 9)); return outward(p) * (0.008 * g) }
            case .cheekSquintLeft, .cheekSquintRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 28, -8, 10, 6); return SIMD3(0, 0.003 * g, 0) }
            case .noseSneerLeft, .noseSneerRight:
                field(s) { th, ph, _ in let g = gauss(th, ph, side(s) * 6, -5, 5, 5); return SIMD3(0, 0.003 * g, 0) }
            case .tongueOut:
                out[s] = [SIMD3<Float>](repeating: .zero, count: V)
            }
        }
        return out
    }

    /// "사용자" 형상 변형: 템플릿 토폴로지 그대로, 전체 스케일 + 코 융기 + 턱 길이 + 광대. 셀프 피팅의 정답 역할.
    public struct Perturbation: Sendable, Equatable {
        public var scale: Float = 1
        public var noseBump: Float = 0        // m
        public var chinExtend: Float = 0      // m
        public var cheekWidth: Float = 0      // m
        public var asymmetry: Float = 0       // 왼쪽 뺨만 추가로 (m)
        public init(scale: Float = 1, noseBump: Float = 0, chinExtend: Float = 0, cheekWidth: Float = 0, asymmetry: Float = 0) {
            self.scale = scale; self.noseBump = noseBump; self.chinExtend = chinExtend; self.cheekWidth = cheekWidth; self.asymmetry = asymmetry
        }
        public static let identity = Perturbation()
        public static let sample = Perturbation(scale: 1.05, noseBump: 0.005, chinExtend: 0.006, cheekWidth: 0.004, asymmetry: 0.002)
    }

    /// 템플릿 정점을 섭동한다 (두상만; 어깨는 scale 만). 눈 간격 기준점(0, 0.44, 0) 을 중심으로 스케일.
    public static func perturbed(_ t: BustTemplate, _ p: Perturbation) -> [SIMD3<Float>] {
        let center = SIMD3<Float>(0, 0.44, 0)
        var out = t.positions
        let shoulders = Set(t.manifest.group(.shoulders))
        for i in out.indices {
            var v = out[i]
            v = center + (v - center) * p.scale
            if !shoulders.contains(i) {
                let rel = v - center
                let th = atan2(rel.x, rel.z) * 180 / .pi
                let ph = asin(max(-1, min(1, (v.y - headCenterY * p.scale - center.y * (1 - p.scale)) / (by * p.scale)))) * 180 / .pi
                if p.noseBump != 0 { v.z += p.noseBump * gauss(th, ph, 0, -8, 12, 9) }
                if p.chinExtend != 0 { v.y -= p.chinExtend * smooth((-35 - ph) / 12) * smooth((45 - abs(th)) / 10) }
                if p.cheekWidth != 0 {
                    let g = max(gauss(th, ph, 32, -10, 14, 12), gauss(th, ph, -32, -10, 14, 12))
                    v.x += (th > 0 ? 1 : -1) * p.cheekWidth * g
                }
                if p.asymmetry != 0 { v.x += p.asymmetry * gauss(th, ph, 32, -10, 14, 12) }
            }
            out[i] = v
        }
        return out
    }
}

/// 합성 알베도 (UV → sRGB 0…1). 피부톤 + 입술·눈썹·주근깨 — 텍스처 PSNR 테스트의 정답.
public enum SyntheticAlbedo {
    public static func color(u: Float, v: Float) -> SIMD3<Float> {
        var c = SIMD3<Float>(0.86, 0.68, 0.58)
        // 완만한 색 변화(관측 비율·접합 테스트가 의미 있도록)
        c += SIMD3(0.06, 0.03, 0.0) * sin(u * 6.283 * 2) * 0.5
        c -= SIMD3(0.0, 0.02, 0.04) * v
        if v < 0.5 {   // 얼굴 패치 영역
            let r = (0.5 - v) / 0.5 * Float(SyntheticTemplate.patchRows - 1)   // 패치 행 좌표
            let col = u * Float(SyntheticTemplate.patchCols - 1)
            // 입술 (행 47…51, 열 5…14)
            if r > 46.5, r < 51.5, col > 5, col < 14 { c = SIMD3(0.70, 0.36, 0.38) }
            // 눈썹 (행 20…22)
            if r > 19.5, r < 22.5, (col > 2.5 && col < 8) || (col > 11 && col < 16.5) { c = SIMD3(0.28, 0.20, 0.16) }
            // 눈 (행 25.5…26.5)
            if r > 25.3, r < 26.7, (col > 3 && col < 7) || (col > 12 && col < 16) { c = SIMD3(0.95, 0.95, 0.95) }
            // 주근깨
            let f = sin(u * 97.0) * sin(v * 131.0)
            if f > 0.97 { c *= 0.8 }
        } else if v > 0.85 {
            c = SIMD3(0.25, 0.35, 0.55)   // 어깨 옷
        } else {
            // 두피·목: 머리카락 색
            let hair = SIMD3<Float>(0.18, 0.12, 0.09)
            let t = min(1, max(0, (v - 0.55) / 0.2))
            c = c * (1 - t) + hair * t
        }
        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    /// 격자 이미지로 굽기 (테스트·시뮬레이터 머티리얼용).
    public static func image(size: Int) -> RGBAImage {
        var img = RGBAImage(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                // 이미지 좌표 y 아래 → UV v 위 (USD 규약: v=0 이 이미지 아래)
                let c = color(u: (Float(x) + 0.5) / Float(size), v: 1 - (Float(y) + 0.5) / Float(size))
                img[x, y] = SIMD4(UInt8(c.x * 255), UInt8(c.y * 255), UInt8(c.z * 255), 255)
            }
        }
        return img
    }

    /// **대역 제한** 합성 알베도 (M4 T-408 충실도 측정용): 같은 피부톤·입술·눈썹이지만 경계는 smoothstep(폭 `edge`, UV 단위)이고 주근깨가 없다.
    /// `color(u:v:)` 의 1텍셀 주근깨·계단 경계는 어떤 투영기도 256² 에서 재현할 수 없어(에일리어싱) 파이프라인 오차와 섞인다.
    public static func smooth(u: Float, v: Float, edge: Float = 0.012) -> SIMD3<Float> {
        func step(_ x: Float) -> Float { let t = min(1, max(0, x)); return t * t * (3 - 2 * t) }
        /// 사각형 [a0,a1]×[b0,b1] 안쪽 1, 경계에서 부드럽게 0
        func box(_ a: Float, _ a0: Float, _ a1: Float, _ b: Float, _ b0: Float, _ b1: Float) -> Float {
            step((a - a0) / edge) * step((a1 - a) / edge) * step((b - b0) / edge) * step((b1 - b) / edge)
        }
        var c = SIMD3<Float>(0.86, 0.68, 0.58)
        c += SIMD3(0.06, 0.03, 0.0) * sin(u * 6.283 * 2) * 0.5
        c -= SIMD3(0.0, 0.02, 0.04) * v
        if v < 0.5 + edge {
            let rows = Float(SyntheticTemplate.patchRows - 1), cols = Float(SyntheticTemplate.patchCols - 1)
            // 패치 행 r = (0.5 − v)/0.5 · rows, 열 col = u · cols → UV 로 환산한 사각형
            func vOf(_ r: Float) -> Float { 0.5 - r / rows * 0.5 }
            func uOf(_ col: Float) -> Float { col / cols }
            let lips = box(v, vOf(51.5), vOf(46.5), u, uOf(5), uOf(14))
            c = c * (1 - lips) + SIMD3(0.70, 0.36, 0.38) * lips
            let browL = box(v, vOf(22.5), vOf(19.5), u, uOf(2.5), uOf(8)), browR = box(v, vOf(22.5), vOf(19.5), u, uOf(11), uOf(16.5))
            let brow = max(browL, browR)
            c = c * (1 - brow) + SIMD3(0.28, 0.20, 0.16) * brow
            let eyeL = box(v, vOf(26.7), vOf(25.3), u, uOf(3), uOf(7)), eyeR = box(v, vOf(26.7), vOf(25.3), u, uOf(12), uOf(16))
            let eye = max(eyeL, eyeR)
            c = c * (1 - eye) + SIMD3(0.95, 0.95, 0.95) * eye
        }
        if v > 0.5 {
            let hair = SIMD3<Float>(0.18, 0.12, 0.09)
            let t = min(1, max(0, (v - 0.55) / 0.2))
            c = c * (1 - t) + hair * t
            let cloth = step((v - 0.85) / edge)
            c = c * (1 - cloth) + SIMD3(0.25, 0.35, 0.55) * cloth
        }
        return simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
