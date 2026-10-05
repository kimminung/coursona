//
//  TexelRaster.swift
//  CoursonaTexture
//
//  T-401 UV 공간 래스터의 **압축 저장**: 텍셀(또는 부표본)마다 삼각형 id(Int32) + 무게중심 2개(UInt16 양자화) = 8 B.
//  4k × 4k 가 134 MB 로 들어가고, 위치·법선은 쓰는 자리에서 삼각형 정점으로 바로 계산한다(미리 풀어 두면 4k 에서 400 MB).
//  부표본(supersample n): 텍셀을 n×n 으로 쪼개 투영해 평균 — 텍셀 footprint 적분. 테스트(256²)에서 PSNR 을 끌어올리고 2k/4k 는 n=1.
//

import Foundation
import simd
import CoursonaCore

public struct TexelRaster: Sendable {
    public let size: Int
    public let supersample: Int
    /// 부표본 격자 한 변 (size × supersample)
    public var grid: Int { size * supersample }
    public var triID: [Int32]
    public var bary: [SIMD2<UInt16>]

    public init(render: BustTemplate.RenderMesh, size: Int, supersample: Int = 1) {
        self.size = size
        self.supersample = max(1, supersample)
        let g = size * self.supersample
        let (ids, b) = SoftwareRasterizer.rasterizeUV(uvs: render.uvs, indices: render.indices, size: g)
        triID = ids
        bary = b.map { TexelRaster.quantize($0) }
    }

    @inline(__always) public static func quantize(_ b: SIMD3<Float>) -> SIMD2<UInt16> {
        SIMD2(UInt16(min(65535, max(0, b.x * 65535 + 0.5))), UInt16(min(65535, max(0, b.y * 65535 + 0.5))))
    }
    @inline(__always) public static func barycentric(_ q: SIMD2<UInt16>) -> SIMD3<Float> {
        let x = Float(q.x) / 65535, y = Float(q.y) / 65535
        return SIMD3(x, y, max(0, 1 - x - y))
    }

    /// 부표본 k 의 보간 위치·법선·UV.
    @inline(__always) public func interpolate(_ k: Int, positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32])
        -> (pos: SIMD3<Float>, nrm: SIMD3<Float>, uv: SIMD2<Float>)? {
        let t = Int(triID[k])
        guard t >= 0 else { return nil }
        let ia = Int(indices[t * 3]), ib = Int(indices[t * 3 + 1]), ic = Int(indices[t * 3 + 2])
        let b = TexelRaster.barycentric(bary[k])
        let p = positions[ia] * b.x + positions[ib] * b.y + positions[ic] * b.z
        let n = simd_normalize(normals[ia] * b.x + normals[ib] * b.y + normals[ic] * b.z)
        let uv = uvs[ia] * b.x + uvs[ib] * b.y + uvs[ic] * b.z
        return (p, n, uv)
    }

    /// 텍셀(x, y) 가 메시 안인가 (부표본 하나라도 덮임).
    public func inside(x: Int, y: Int) -> Bool {
        let n = supersample
        for sy in 0..<n { for sx in 0..<n where triID[(y * n + sy) * grid + (x * n + sx)] >= 0 { return true } }
        return false
    }

    /// 텍셀(x, y) 의 대표 삼각형 (첫 덮인 부표본) — 채움·두피 판정용.
    public func representativeTriangle(x: Int, y: Int) -> Int32 {
        let n = supersample
        for sy in 0..<n { for sx in 0..<n { let t = triID[(y * n + sy) * grid + (x * n + sx)]; if t >= 0 { return t } } }
        return -1
    }
}
