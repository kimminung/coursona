//
//  CapBuilder.swift
//  CoursonaFace
//
//  눈·입 구멍 닫기 (TechPRD §6.2·§6.4 F5·F6·F8, Tasks T-102·T-203·T-204·T-206).
//  초상은 눈알·입안을 분리 엔티티로 띄워서 피팅 뒤 어긋나거나 뚫렸다 — 코르소나는 그 대신
//  **같은 메시 안에서 구멍을 막는다**.
//
//  블렌더 흉상은 ARKit 패치 경계(`patchLoops.eye_left/eye_right/mouth`) → LidInner/LipInner 안쪽 띠
//  두 겹(`eye_band`/`mouth_band`)까지는 이미 만들어 두지만, 그 안쪽은 아직 열려 있다(눈알·치아 메시가
//  그 구멍 뒤에 있던 자리). 이 열린 테두리를 **위상(경계 변)으로 직접 찾아** — 어떤 정점이 "안쪽 2열"인지
//  블렌더 내부 순서를 추측하지 않고 — 중간 고리 1개 + 중심 1개로 닫는다.
//
//  v0(C1)는 템플릿 좌표 그대로 닫았다. v1(C2, F5·F6)은 **피팅된 좌표**(`BustEntity` 가 넘기는
//  `template.positions`)에 대해 **같은 함수를 그대로 다시 부른다** — 눈·입 구멍의 테두리를 위상으로
//  찾는 방식이라 "LidInner 몇 번째가 안쪽 고리인지" 추론(InnerBandIndexMap)이 처음부터 필요 없었다.
//  F8(셰이프 델타 재생성)은 새로 만든 중간 고리·중심 정점에, **그 캡이 붙은 테두리(기존 정점)의 평균
//  델타**를 준다 — 눈을 감으면 테두리가 움직이는 만큼 캡도 같이 움직여 뜯어지지 않는다.
//

import Foundation
import simd
import CoursonaCore

/// 캡 하나(눈 1개 또는 입)의 결과.
public struct CapClosure: Sendable, Equatable {
    /// 닫은 테두리(발견한 경계 고리)의 길이.
    public var ringSize: Int
    /// 새로 만든 삼각형 수(테두리→중간 고리 밴드 + 중간 고리→중심 팬).
    public var addedTriangles: Int
    /// 닫은 테두리를 이루는 **기존** 정점 id(재사용, 순서대로) — F8 평균 델타의 입력.
    public var loopVertexIDs: [Int]
    /// 이 캡이 새로 만든 정점 id(중간 고리 + 중심, 순서대로) — F8 평균 델타의 출력.
    public var addedVertexIDs: [Int]
    /// 이 캡의 삼각형이 최종 `indices` 배열에서 차지하는 구간(정점 id 3개 단위 — 바이트 아님).
    public var triangleIndexRange: Range<Int>
    public init(ringSize: Int, addedTriangles: Int, loopVertexIDs: [Int], addedVertexIDs: [Int], triangleIndexRange: Range<Int>) {
        self.ringSize = ringSize; self.addedTriangles = addedTriangles
        self.loopVertexIDs = loopVertexIDs; self.addedVertexIDs = addedVertexIDs; self.triangleIndexRange = triangleIndexRange
    }
}

public struct CapBuildResult: Sendable {
    public var template: BustTemplate
    public var eyeLeft: CapClosure?
    public var eyeRight: CapClosure?
    public var mouth: CapClosure?
    /// 새로 추가된 정점 id 전부(얼굴면 분류에 더해 준다 — `FaceSurfacePartitioner`).
    public var addedVertexIDs: Set<Int>
    public init(template: BustTemplate, eyeLeft: CapClosure?, eyeRight: CapClosure?, mouth: CapClosure?, addedVertexIDs: Set<Int>) {
        self.template = template; self.eyeLeft = eyeLeft; self.eyeRight = eyeRight; self.mouth = mouth; self.addedVertexIDs = addedVertexIDs
    }
    /// 세 캡을 전부 모은 목록(편의용).
    public var caps: [CapClosure] { [eyeLeft, eyeRight, mouth].compactMap { $0 } }
}

public enum CapBuilder {
    /// 경계 고리 중심이 시드(눈·입 중심)에서 이 거리보다 멀면 "이 구멍이 아니다" — 목/어깨 절단면과 혼동하지 않을 만큼 좁게.
    static let seedMatchRadius: Float = 0.02
    /// 중간 고리·중심을 테두리 반지름에서 안쪽으로 당기는 비율(완전 평면 방지, 살짝 돔 모양).
    static let domeInset: Float = 0.12
    /// 입 포켓: 안쪽(얼굴 바깥쪽 법선의 반대)으로 밀어 넣는 거리 + 위아래로 벌리는 거리.
    static let mouthPocketDepth: Float = 0.006
    static let mouthPocketSpread: Float = 0.0015

    /// 눈(좌·우)·입 구멍을 찾아 닫는다. 구멍이 없으면(합성 템플릿 등) 그 항목만 `nil`로 조용히 건너뛴다 — 전체가 막히지는 않는다.
    /// `template.positions` 가 피팅된 좌표면 그 좌표로 닫는다(F5·F6 v1) — 호출 쪽에서 좌표만 바꿔 넣으면 된다.
    public static func addingCaps(to template: BustTemplate) -> CapBuildResult {
        var positions = template.positions
        var normals = template.normals
        var uvs = template.uvs
        var corner = template.cornerUVs
        var indices = template.indices
        var addedIDs = Set<Int>()

        let loops = Geometry.boundaryLoops(indices: indices)

        func centroid(_ loop: [Int]) -> SIMD3<Float> {
            loop.reduce(SIMD3<Float>.zero) { $0 + positions[$1] } / Float(loop.count)
        }
        func nearestLoop(to seed: SIMD3<Float>, excluding used: Set<Int>) -> [Int]? {
            var best: ([Int], Float)? = nil
            for loop in loops where Set(loop).isDisjoint(with: used) {
                let d = simd_length(centroid(loop) - seed)
                if d < seedMatchRadius, (best == nil || d < best!.1) { best = (loop, d) }
            }
            return best?.0
        }

        func appendVertex(_ p: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>) -> Int {
            let id = positions.count
            positions.append(p); normals.append(normal); uvs.append(uv)
            addedIDs.insert(id)
            return id
        }
        func appendTriangle(_ a: Int, _ b: Int, _ c: Int, outward: SIMD3<Float>) {
            let pa = positions[a], pb = positions[b], pc = positions[c]
            let n = simd_cross(pb - pa, pc - pa)
            let (x, y, z) = simd_dot(n, outward) < 0 ? (a, c, b) : (a, b, c)
            indices.append(UInt32(x)); indices.append(UInt32(y)); indices.append(UInt32(z))
            if corner != nil { corner!.append(uvs[x]); corner!.append(uvs[y]); corner!.append(uvs[z]) }
        }

        /// 발견한 경계 고리를 "고리(재사용) → 중간 고리(신규) → 중심(신규)" 로 닫는다.
        func close(loop: [Int], pocket: Bool) -> CapClosure {
            let n = loop.count
            let triStart = indices.count
            let ringPos = loop.map { positions[$0] }
            let c = ringPos.reduce(.zero, +) / Float(n)
            var nFace = ringPos.reduce(SIMD3<Float>.zero) { $0 + simd_normalize($1 - c) }
            nFace = simd_length_squared(nFace) > 1e-10 ? simd_normalize(nFace) : SIMD3(0, 0, 1)
            let avgR = Swift.max(ringPos.reduce(Float(0)) { $0 + simd_length($1 - c) } / Float(n), 1e-5)
            let midUV = loop.map { uvs[$0] } // 안쪽은 텍스처가 중요하지 않다(C5 에서 다듬는다) — 바깥 고리 UV를 그대로 물려받는다.

            var midIDs: [Int] = []; midIDs.reserveCapacity(n)
            for i in 0..<n {
                let dir = simd_normalize(ringPos[i] - c)
                let mixed = Geometry.slerpUnit(dir, nFace, 0.5)
                var p = c + mixed * (avgR * (1 - domeInset))
                if pocket {
                    p -= nFace * mouthPocketDepth
                    p.y += (ringPos[i].y > c.y ? mouthPocketSpread : -mouthPocketSpread)
                }
                midIDs.append(appendVertex(p, normal: mixed, uv: midUV[i]))
            }
            var centerP = c - nFace * (avgR * domeInset)
            if pocket { centerP -= nFace * mouthPocketDepth }
            let centerID = appendVertex(centerP, normal: -nFace, uv: midUV[0])

            for i in 0..<n {
                let j = (i + 1) % n
                appendTriangle(loop[i], loop[j], midIDs[j], outward: nFace)
                appendTriangle(loop[i], midIDs[j], midIDs[i], outward: nFace)
            }
            for i in 0..<n {
                let j = (i + 1) % n
                appendTriangle(midIDs[i], midIDs[j], centerID, outward: nFace)
            }
            return CapClosure(ringSize: n, addedTriangles: n * 3, loopVertexIDs: loop, addedVertexIDs: midIDs + [centerID],
                              triangleIndexRange: triStart..<indices.count)
        }

        var usedVertices = Set<Int>()
        var eyeLeft: CapClosure? = nil, eyeRight: CapClosure? = nil, mouth: CapClosure? = nil
        if let loop = nearestLoop(to: template.manifest.eyeCenterL, excluding: usedVertices) {
            usedVertices.formUnion(loop); eyeLeft = close(loop: loop, pocket: false)
        }
        if let loop = nearestLoop(to: template.manifest.eyeCenterR, excluding: usedVertices) {
            usedVertices.formUnion(loop); eyeRight = close(loop: loop, pocket: false)
        }
        let mouthSeed: SIMD3<Float>? = template.manifest.mouthCenter.map { SIMD3($0[0], $0[1], $0[2]) }
            ?? template.manifest.patchLoops["mouth"].map { centroid($0) }
        if let seed = mouthSeed, let loop = nearestLoop(to: seed, excluding: usedVertices) {
            usedVertices.formUnion(loop); mouth = close(loop: loop, pocket: true)
        }

        var newTemplate = template
        newTemplate.positions = positions
        newTemplate.normals = normals
        newTemplate.uvs = uvs
        newTemplate.cornerUVs = corner
        newTemplate.indices = indices
        let caps = [eyeLeft, eyeRight, mouth].compactMap { $0 }
        let addedCount = positions.count - template.positions.count
        if addedCount > 0 {
            // F8: 새 정점에 "붙어 있는 테두리의 평균 델타" 를 준다 — 0 으로 두면 눈을 감아도 캡이 그대로 남아 뜯어진다.
            for (shape, arr) in newTemplate.shapeDeltas where arr.count == template.positions.count {
                var newArr = arr + [SIMD3<Float>](repeating: .zero, count: addedCount)
                for cap in caps {
                    guard !cap.loopVertexIDs.isEmpty else { continue }
                    let avg = cap.loopVertexIDs.reduce(SIMD3<Float>.zero) { $0 + arr[$1] } / Float(cap.loopVertexIDs.count)
                    for id in cap.addedVertexIDs { newArr[id] = avg }
                }
                newTemplate.shapeDeltas[shape] = newArr
            }
            if newTemplate.skin.count == template.positions.count {
                newTemplate.skin += [SkinInfluence](repeating: .none, count: addedCount)
            }
            if newTemplate.manifest.symmetryMap.count == template.positions.count {
                newTemplate.manifest.symmetryMap += [Int32](repeating: -1, count: addedCount)
            }
        }
        newTemplate.manifest.vertexCount = positions.count
        newTemplate.manifest.triangleCount = indices.count / 3
        return CapBuildResult(template: newTemplate, eyeLeft: eyeLeft, eyeRight: eyeRight, mouth: mouth, addedVertexIDs: addedIDs)
    }
}
