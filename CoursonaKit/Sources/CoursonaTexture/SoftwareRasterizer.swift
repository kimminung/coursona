//
//  SoftwareRasterizer.swift
//  CoursonaTexture
//
//  CPU 삼각형 래스터라이저(참조 구현). 용도: ① 합성 캡처 번들 렌더(가상 카메라 RGB·깊이), ② UV 공간 래스터(텍셀 → 삼각형·무게중심),
//  ③ M4 Metal 커널의 정답 비교. 원근 보정 무게중심, z-버퍼, 후면 컬링 없음(깊이로 해결).
//

import Foundation
import simd
import CoursonaCore

public struct RenderCamera: Sendable {
    public var intrinsics: Geometry.Intrinsics
    /// 카메라 → 월드 (카메라는 −Z 를 본다)
    public var transform: simd_float4x4
    public init(intrinsics: Geometry.Intrinsics, transform: simd_float4x4) { self.intrinsics = intrinsics; self.transform = transform }
    public var worldToCamera: simd_float4x4 { transform.inverse }
    public var position: SIMD3<Float> { SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z) }
}

public struct RasterOutput: Sendable {
    public var width: Int, height: Int
    public var color: RGBAImage
    public var depth: DepthMap
    /// 픽셀별 삼각형 id (-1 = 배경)
    public var triangleID: [Int32]
    public var barycentric: [SIMD3<Float>]
}

public enum SoftwareRasterizer {
    /// 월드 공간 메시를 카메라로 렌더. `shade(uv, worldNormal, worldPos)` → sRGB 0…1.
    public static func render(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>], indices: [UInt32],
                              camera: RenderCamera, width: Int, height: Int,
                              shade: (SIMD2<Float>, SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>) -> RasterOutput {
        let w2c = camera.worldToCamera
        let K = camera.intrinsics.scaled(toWidth: width, height: height)
        let n = positions.count
        var screen = [SIMD3<Float>](repeating: .zero, count: n)   // x, y, invDepth
        var valid = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let pc = Geometry.transformPoint(w2c, positions[i])
            if let px = K.project(pc) { screen[i] = SIMD3(px.x, px.y, 1 / -pc.z); valid[i] = true }
        }
        var depthBuf = [Float](repeating: .infinity, count: width * height)
        var triID = [Int32](repeating: -1, count: width * height)
        var bary = [SIMD3<Float>](repeating: .zero, count: width * height)

        var t = 0
        var tri = 0
        while t + 2 < indices.count {
            defer { t += 3; tri += 1 }
            let ia = Int(indices[t]), ib = Int(indices[t + 1]), ic = Int(indices[t + 2])
            guard valid[ia], valid[ib], valid[ic] else { continue }
            let a = screen[ia], b = screen[ib], c = screen[ic]
            let minX = max(0, Int(min(a.x, b.x, c.x).rounded(.down))), maxX = min(width - 1, Int(max(a.x, b.x, c.x).rounded(.up)))
            let minY = max(0, Int(min(a.y, b.y, c.y).rounded(.down))), maxY = min(height - 1, Int(max(a.y, b.y, c.y).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-9 else { continue }
            let invArea = 1 / area
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let px = Float(x) + 0.5
                    var w0 = ((b.x - px) * (c.y - py) - (b.y - py) * (c.x - px)) * invArea
                    var w1 = ((c.x - px) * (a.y - py) - (c.y - py) * (a.x - px)) * invArea
                    var w2 = 1 - w0 - w1
                    guard w0 >= -1e-5, w1 >= -1e-5, w2 >= -1e-5 else { continue }
                    // 원근 보정: 1/z 선형
                    let invZ = w0 * a.z + w1 * b.z + w2 * c.z
                    let z = 1 / invZ
                    let idx = y * width + x
                    guard z < depthBuf[idx] else { continue }
                    w0 = w0 * a.z * z; w1 = w1 * b.z * z; w2 = w2 * c.z * z
                    depthBuf[idx] = z
                    triID[idx] = Int32(tri)
                    bary[idx] = SIMD3(w0, w1, w2)
                }
            }
        }
        // 셰이딩
        var color = RGBAImage(width: width, height: height, fill: SIMD4(20, 22, 26, 255))
        var depthVals = [Float](repeating: 0, count: width * height)
        for idx in 0..<(width * height) where triID[idx] >= 0 {
            let t3 = Int(triID[idx]) * 3
            let ia = Int(indices[t3]), ib = Int(indices[t3 + 1]), ic = Int(indices[t3 + 2])
            let b = bary[idx]
            let uv = uvs[ia] * b.x + uvs[ib] * b.y + uvs[ic] * b.z
            let nrm = simd_normalize(normals[ia] * b.x + normals[ib] * b.y + normals[ic] * b.z)
            let pos = positions[ia] * b.x + positions[ib] * b.y + positions[ic] * b.z
            let c = simd_clamp(shade(uv, nrm, pos), SIMD3(repeating: 0), SIMD3(repeating: 1))
            color[idx % width, idx / width] = SIMD4(UInt8(c.x * 255 + 0.5), UInt8(c.y * 255 + 0.5), UInt8(c.z * 255 + 0.5), 255)
            depthVals[idx] = depthBuf[idx]
        }
        return RasterOutput(width: width, height: height, color: color, depth: DepthMap(width: width, height: height, values: depthVals), triangleID: triID, barycentric: bary)
    }

    /// UV 공간 래스터: 텍셀 → (삼각형 id, 무게중심). v=0 이 이미지 **아래**(USD) 이므로 텍셀 행 y 는 1−v.
    public static func rasterizeUV(uvs: [SIMD2<Float>], indices: [UInt32], size: Int) -> (triangleID: [Int32], barycentric: [SIMD3<Float>]) {
        var triID = [Int32](repeating: -1, count: size * size)
        var bary = [SIMD3<Float>](repeating: .zero, count: size * size)
        let S = Float(size)
        var t = 0, tri = 0
        while t + 2 < indices.count {
            defer { t += 3; tri += 1 }
            let a = uvs[Int(indices[t])], b = uvs[Int(indices[t + 1])], c = uvs[Int(indices[t + 2])]
            let pa = SIMD2(a.x * S, (1 - a.y) * S), pb = SIMD2(b.x * S, (1 - b.y) * S), pcc = SIMD2(c.x * S, (1 - c.y) * S)
            let minX = max(0, Int(min(pa.x, pb.x, pcc.x).rounded(.down))), maxX = min(size - 1, Int(max(pa.x, pb.x, pcc.x).rounded(.up)))
            let minY = max(0, Int(min(pa.y, pb.y, pcc.y).rounded(.down))), maxY = min(size - 1, Int(max(pa.y, pb.y, pcc.y).rounded(.up)))
            guard minX <= maxX, minY <= maxY else { continue }
            let area = (pb.x - pa.x) * (pcc.y - pa.y) - (pb.y - pa.y) * (pcc.x - pa.x)
            guard abs(area) > 1e-9 else { continue }
            let inv = 1 / area
            // 1 텍셀 확장(접합선 틈 방지): 가장자리 허용 오차
            let eps: Float = -0.75 / max(1, abs(area).squareRoot())
            for y in minY...maxY {
                let py = Float(y) + 0.5
                for x in minX...maxX {
                    let px = Float(x) + 0.5
                    let w0 = ((pb.x - px) * (pcc.y - py) - (pb.y - py) * (pcc.x - px)) * inv
                    let w1 = ((pcc.x - px) * (pa.y - py) - (pcc.y - py) * (pa.x - px)) * inv
                    let w2 = 1 - w0 - w1
                    let inside = w0 >= 0 && w1 >= 0 && w2 >= 0
                    let idx = y * size + x
                    if inside || (triID[idx] < 0 && w0 >= eps && w1 >= eps && w2 >= eps) {
                        if inside || triID[idx] < 0 {
                            triID[idx] = Int32(tri)
                            bary[idx] = simd_clamp(SIMD3(w0, w1, w2), SIMD3(repeating: 0), SIMD3(repeating: 1))
                        }
                    }
                }
            }
        }
        return (triID, bary)
    }
}
