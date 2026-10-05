//
//  ARKitFaceTopology.swift
//  CoursonaCore
//
//  ARKit `ARFaceGeometry` 는 정점 1220 · 토폴로지가 모든 인스턴스에서 같다(문서 확인, 2026-10-03).
//  Apple 샘플 "Tracking and visualizing faces" 의 `ARFaceGeometry.obj` 는 **사각형 1152개**(v 인덱스 = vt 인덱스)다 — 2차 계약(Blender-요청.md §1)에서
//  패치 해시는 이 사각형 목록(OBJ 순서, int32 LE) 의 SHA-256 으로 정의한다. 삼각형은 (a,b,c)+(a,c,d) 로 쪼갠 것을 참고 상수로 둔다.
//  런타임 ARKit 의 삼각형 2304개는 대각선 선택이 다를 수 있으므로 🧪 T-007 에서 FNV 해시를 "기록" 만 한다(정점 순서가 같으면 피팅에는 충분).
//

import Foundation

public enum ARKitFaceTopology {
    public static let vertexCount = 1220
    /// Apple OBJ 의 사각형 수.
    public static let quadCount = 1152
    /// 삼각형 수 (ARKit 런타임 `triangleCount`, OBJ 사각형 × 2).
    public static let expectedTriangleCount = 2304

    /// Apple `ARFaceGeometry.obj` 파일 SHA-256 (Coursona_Blender/source/ARFaceGeometry.obj, 2026-10-03 측정).
    public static let appleOBJSHA256 = "97d906e49264713f94e64992c7568a93bfe9fd7000457f0d0a6c07ae50ec6e37"
    /// 패치 사각형 1152개(OBJ 순서, 꼭짓점 4개 × int32 LE) SHA-256 — **계약 해시**.
    public static let patchQuadsSHA256 = "a71869b9f260ce42d1065d29aacbdf427821c3b27a138e8f69fb7676bbec6334"
    /// 사각형을 (a,b,c)+(a,c,d) 로 쪼갠 삼각형 2304개(int32 LE) SHA-256 — bust.mesh 의 패치 삼각형 순서.
    public static let patchTrianglesABCACDSHA256 = "4a1e77efd9d65d2f58f8a91d76ef3661a1353bc3d3ac888572007e4fe447ff4d"
    /// 같은 삼각형 목록의 FNV-1a 64 (UInt32 LE) — `patchTriangleHash(indices:patchCount:)` 와 비교.
    public static let patchTrianglesABCACDFNV: UInt64 = 0xbf36df8487c55844

    /// 실기기에서 측정한 ARKit `triangleIndices`(Int16) 의 FNV-1a 64 — **iPhone 16 / iOS 27.0.1, 2026-10-03 측정**.
    /// 캡처 번들 `meta.arkitTriangleHash` 가 이 값과 다르면 OS 가 토폴로지를 바꿨다는 뜻이라 희소 피팅으로 폴백한다(§10 위험 표).
    public static let referenceTriangleHash: UInt64? = 0x67161fe4685cdd1e
    /// 위 해시의 16진 문자열 (번들 메타에 저장되는 형식).
    public static let referenceTriangleHashHex = "67161fe4685cdd1e"

    /// 패치 삼각형(세 정점이 모두 `patchCount` 미만)만 추려 UInt32 로 정규화한 뒤 FNV-1a 64.
    public static func patchTriangleHash(indices: [UInt32], patchCount: Int) -> UInt64 {
        var tris: [UInt32] = []
        tris.reserveCapacity(indices.count)
        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            if Int(a) < patchCount, Int(b) < patchCount, Int(c) < patchCount { tris.append(a); tris.append(b); tris.append(c) }
            i += 3
        }
        return Geometry.fnv1a(tris)
    }

    /// 패치 삼각형 목록(UInt32) 을 int32 LE 바이트로 — SHA-256 은 CoursonaValidate(CryptoKit) 가 계산한다.
    public static func patchTriangleBytes(indices: [UInt32], patchCount: Int) -> Data {
        var d = Data()
        var i = 0
        while i + 2 < indices.count {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            if Int(a) < patchCount, Int(b) < patchCount, Int(c) < patchCount {
                for v in [a, b, c] { var le = Int32(v).littleEndian; withUnsafeBytes(of: &le) { d.append(contentsOf: $0) } }
            }
            i += 3
        }
        return d
    }

    /// ARKit `triangleIndices: [Int16]` → FNV (실기기 측정 기록용).
    public static func hash(arkitTriangleIndices: [Int16]) -> UInt64 {
        Geometry.fnv1a(arkitTriangleIndices.map { UInt32(max(0, Int($0))) })
    }

    public static func hexString(_ h: UInt64) -> String { String(format: "%016llx", h) }
}
