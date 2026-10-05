//
//  FaceSurfacePartition.swift
//  CoursonaCore
//
//  얼굴면/나머지 분리 (TechPRD §6.2, Tasks T-101). 얼굴면 = 세 꼭짓점이 모두
//  ARKitFace ∪ LidInner ∪ LipInner(+ CapBuilder 가 만든 새 정점)에 속하는 삼각형.
//  `CoursonaRig.BustEntity` 가 이 결과로 `LowLevelMesh.Part` 2개(얼굴면 먼저, 나머지 다음)를 만든다.
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
}

public enum FaceSurfacePartitioner {
    /// - Parameters:
    ///   - template: 분류 대상 템플릿(= CapBuilder 가 캡을 더한 뒤의 템플릿을 넣는다).
    ///   - additionalFaceVertexIDs: ARKitFace∪LidInner∪LipInner 외에 얼굴면으로 셀 정점(캡 전용 신규 정점 등).
    public static func partition(template: BustTemplate, additionalFaceVertexIDs: Set<Int> = []) -> FaceSurfacePartition {
        var faceSet = additionalFaceVertexIDs
        faceSet.formUnion(template.manifest.group(.arkitFace))
        faceSet.formUnion(template.manifest.group(.lidInner))
        faceSet.formUnion(template.manifest.group(.lipInner))

        let idx = template.indices
        let corner = template.cornerUVs
        var faceTris: [Int] = [], restTris: [Int] = []
        var t = 0, i = 0
        while i + 2 < idx.count {
            let a = Int(idx[i]), b = Int(idx[i + 1]), c = Int(idx[i + 2])
            if faceSet.contains(a) && faceSet.contains(b) && faceSet.contains(c) { faceTris.append(t) } else { restTris.append(t) }
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
        return FaceSurfacePartition(indices: newIndices, cornerUVs: newCorner, faceTriangleCount: faceTris.count, restTriangleCount: restTris.count)
    }
}
