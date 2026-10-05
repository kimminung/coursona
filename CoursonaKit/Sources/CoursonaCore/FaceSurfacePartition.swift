//
//  FaceSurfacePartition.swift
//  CoursonaCore
//
//  얼굴면/나머지 분리 (TechPRD §6.2, Tasks T-101). 얼굴면 = 세 꼭짓점이 모두
//  ARKitFace ∪ LidInner ∪ LipInner(+ CapBuilder 가 만든 새 정점)에 속하는 삼각형, 또는(C6, T-604)
//  `capIndexRanges` 로 명시한 캡 삼각형(정점 그룹 판정과 무관하게 무조건 포함).
//  `CoursonaRig.BustEntity` 가 이 결과로 `LowLevelMesh.Part` 를 만든다(얼굴면 먼저, 나머지 다음 —
//  얼굴면 블록 안에서 눈·입 캡은 `capRanges` 로 따로 떼어내 전용 머티리얼을 줄 수 있다).
//

import Foundation
import simd

public struct FaceSurfacePartition: Sendable {
    /// 얼굴면 삼각형이 앞쪽에 오도록 재배열한 인덱스(원본과 같은 길이).
    public var indices: [UInt32]
    /// `indices` 와 같은 순서로 재배열한 코너 UV(있으면).
    public var cornerUVs: [SIMD2<Float>]?
    public var faceTriangleCount: Int
    public var restTriangleCount: Int
    /// 얼굴면 인덱스 구간: `indices[0 ..< faceIndexCount]`.
    public var faceIndexCount: Int { faceTriangleCount * 3 }
    public var restIndexCount: Int { restTriangleCount * 3 }
    /// C6(T-604): `capIndexRanges` 로 넘긴 순서 그대로, 그 캡 삼각형이 `indices[0..<faceIndexCount]` 안에서
    /// 차지하는 새 구간(플랫 인덱스 단위). `CapBuilder` 가 캡을 항상 원본 `template.indices` 맨 뒤에 순서대로
    /// 덧붙이므로(눈 왼쪽 → 눈 오른쪽 → 입) 얼굴면 블록 안에서도 항상 꼬리 쪽에 그 순서로 몰린다.
    public var capRanges: [Range<Int>] = []
}

public enum FaceSurfacePartitioner {
    /// - Parameters:
    ///   - template: 분류 대상 템플릿(= CapBuilder 가 캡을 더한 뒤의 템플릿을 넣는다).
    ///   - additionalFaceVertexIDs: ARKitFace∪LidInner∪LipInner 외에 얼굴면으로 셀 정점(캡 전용 신규 정점 등).
    ///   - capIndexRanges: 원본 `template.indices` 기준 캡별 삼각형 구간(`CapClosure.triangleIndexRange`) — 주면
    ///     `FaceSurfacePartition.capRanges` 로 재배열 뒤의 새 구간을 같은 순서로 돌려준다(없으면 빈 배열).
    public static func partition(template: BustTemplate, additionalFaceVertexIDs: Set<Int> = [], capIndexRanges: [Range<Int>] = []) -> FaceSurfacePartition {
        var faceSet = additionalFaceVertexIDs
        faceSet.formUnion(template.manifest.group(.arkitFace))
        faceSet.formUnion(template.manifest.group(.lidInner))
        faceSet.formUnion(template.manifest.group(.lipInner))
        // 캡 삼각형은 정점 그룹 판정과 무관하게 항상 얼굴면이다 — 띠(밴드) 삼각형은 기존 정점(LidInner/LipInner
        // 테두리) + 새 정점이 섞여 있어서, 기존 정점이 실제로 그 그룹에 들어있는지에 기대는 간접 판정은 깨지기
        // 쉽다(합성 템플릿처럼 그룹이 아예 없으면 특히). `capIndexRanges` 를 직접·무조건 신뢰하는 쪽이 더 안전하다.
        var capTriSet = Set<Int>()
        for r in capIndexRanges { capTriSet.formUnion(stride(from: r.lowerBound / 3, to: r.upperBound / 3, by: 1)) }

        let idx = template.indices
        let corner = template.cornerUVs
        var faceTris: [Int] = [], restTris: [Int] = []
        var t = 0, i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            if capTriSet.contains(t) || (faceSet.contains(a) && faceSet.contains(b) && faceSet.contains(c)) { faceTris.append(t) } else { restTris.append(t) }
            i += 3; t += 1
        }

        var newIndices: [UInt32] = []; newIndices.reserveCapacity(idx.count)
        var newCorner: [SIMD2<Float>]? = corner != nil ? [] : nil
        if let c = corner { newCorner?.reserveCapacity(c.count) }
        for triList in [faceTris, restTris] {
            for tri in triList {
                let base = tri * 3
                newIndices.append(idx[base]); newIndices.append(idx[base + 1]); newIndices.append(idx[base + 2])
                if let c = corner { newCorner?.append(c[base]); newCorner?.append(c[base + 1]); newCorner?.append(c[base + 2]) }
            }
        }
        // 캡별 삼각형 구간을 새 인덱스 배열 기준으로 다시 찾는다. `faceTris` 는 t 증가 순이고 캡 삼각형은
        // 위에서 전부 무조건 포함시켰으므로, 원본 구간 [triStart, triEnd) 전체가 연속으로 들어있다 — 시작
        // 위치만 찾으면 끝까지 그대로 이어진다.
        var capRanges: [Range<Int>] = []
        for r in capIndexRanges {
            let triStart = r.lowerBound / 3, triEnd = r.upperBound / 3
            guard let pos = faceTris.firstIndex(where: { $0 >= triStart }) else { capRanges.append(0..<0); continue }
            let count = triEnd - triStart
            capRanges.append((pos * 3) ..< ((pos + count) * 3))
        }
        return FaceSurfacePartition(indices: newIndices, cornerUVs: newCorner, faceTriangleCount: faceTris.count, restTriangleCount: restTris.count, capRanges: capRanges)
    }
}
