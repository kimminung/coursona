//
//  Geometry.swift
//  CoursonaCore
//
//  카메라·좌표계·법선 유틸. 좌표계 규약(Blender-요청.md §0): m, Y-up, 얼굴 +Z, 피사체 왼쪽 = +X.
//

import Foundation
import simd

public enum Geometry {
    /// 삼각형 면적 가중 정점 법선.
    public static func vertexNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var n = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            let fn = simd_cross(positions[b] - positions[a], positions[c] - positions[a])
            n[a] += fn; n[b] += fn; n[c] += fn
            i += 3
        }
        return n.map { simd_length_squared($0) > 1e-20 ? simd_normalize($0) : SIMD3(0, 0, 1) }
    }

    /// 핀홀 카메라 intrinsics (fx, fy, cx, cy; 픽셀 단위, 저장 이미지 해상도 기준).
    public struct Intrinsics: Codable, Sendable, Equatable {
        public var fx: Float, fy: Float, cx: Float, cy: Float
        public var width: Int, height: Int
        public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
            self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy; self.width = width; self.height = height
        }
        /// ARKit `camera.intrinsics`(3×3, 열 우선) + `imageResolution` 에서.
        public init(matrix m: simd_float3x3, width: Int, height: Int) {
            self.init(fx: m.columns.0.x, fy: m.columns.1.y, cx: m.columns.2.x, cy: m.columns.2.y, width: width, height: height)
        }
        public var matrix: simd_float3x3 {
            simd_float3x3(columns: (SIMD3(fx, 0, 0), SIMD3(0, fy, 0), SIMD3(cx, cy, 1)))
        }
        /// 다른 해상도로 리샘플 (fx·cx 등 비례).
        public func scaled(toWidth w: Int, height h: Int) -> Intrinsics {
            let sx = Float(w) / Float(width), sy = Float(h) / Float(height)
            return Intrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
        }
        /// 카메라 좌표(카메라가 −Z 를 본다, ARKit/RealityKit 규약) → 픽셀 (x 오른쪽, y 아래). 뒤에 있으면 nil.
        public func project(_ pc: SIMD3<Float>) -> SIMD2<Float>? {
            guard pc.z < -1e-6 else { return nil }
            let z = -pc.z
            return SIMD2(fx * pc.x / z + cx, -fy * pc.y / z + cy)
        }
        /// 픽셀 + 깊이(m, 카메라 앞 거리) → 카메라 좌표.
        public func unproject(_ px: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
            SIMD3((px.x - cx) / fx * depth, -(px.y - cy) / fy * depth, -depth)
        }
    }

    // MARK: 가로 센서 → 세로(포트레이트) 저장 방향
    //
    // iPhone 전면 카메라는 **가로 센서 버퍼**(W×H, 예 1440×1080)를 준다. 저장·표시는 세로 업라이트라서
    // `CIImage.oriented(.right)`(EXIF 6, 시계방향 90°)로 돌린다. 그 픽셀 매핑은
    //     (x', y') = (H − y, x)          — 연속 좌표, H = 가로 이미지의 높이
    // 이고, 같은 회전을 **intrinsics 와 카메라 변환 양쪽에** 일관되게 적용해야 재투영이 맞는다.
    // 함정(T-203 실기기): intrinsics 는 시계방향인데 카메라를 반시계로 돌리면 투영점이 주점 기준
    // 점대칭으로 뒤집힌다(화면에서 얼굴 위 → 점은 아래). 그래서 둘을 여기 한 쌍으로 둔다.

    /// 가로 intrinsics → 세로(시계방향 90°) intrinsics. `fx'=fy, fy'=fx, cx'=H−cy, cy'=cx`, 크기도 뒤바뀐다.
    public static func portraitRotated(_ K: Intrinsics) -> Intrinsics {
        Intrinsics(fx: K.fy, fy: K.fx, cx: Float(K.height) - K.cy, cy: K.cx, width: K.height, height: K.width)
    }

    /// 같은 회전을 카메라에 적용하는 행렬. `portraitCameraTransform = camera.transform * portraitCameraRotation`.
    public static let portraitCameraRotation = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 0, 1]))

    /// 얼굴 앵커 → **카메라 좌표** 변환에서 자세 각도(도).
    /// yaw + = 피사체가 자기 왼쪽으로 고개를 돌림, pitch + = 턱을 듦. 얼굴 +Z(정면)를 카메라 축에 투영해 잰다.
    ///
    /// **세로로 든 기기**에서는 `camera.transform * portraitCameraRotation` 의 역행렬로 얼굴을 옮긴 뒤 부른다.
    /// `ARCamera.transform` 의 x 축은 기기 긴 축(전면 카메라 → 홈버튼)이라 세로에서는 월드 아래를 향하고,
    /// 그대로 쓰면 좌우 회전이 pitch 로 새어 나간다(iPhone 16 실측: 왼쪽 30° 자세가 yaw −0.8° / pitch −33.8° 로 읽혔다).
    /// 캡처 번들의 `cameraTransform` 은 **이미 회전이 적용된 값**이므로 다시 읽을 때는 그대로 넘긴다.
    public static func faceYawPitch(faceInCamera m: simd_float4x4) -> (yaw: Float, pitch: Float) {
        let fwd = m.columns.2
        let yaw = atan2(fwd.x, fwd.z) * 180 / .pi
        let pitch = atan2(fwd.y, (fwd.x * fwd.x + fwd.z * fwd.z).squareRoot()) * 180 / .pi
        return (yaw, pitch)
    }

    /// 세로 FOV(라디안)·크기에서 intrinsics.
    public static func intrinsics(verticalFOV: Float, width: Int, height: Int) -> Intrinsics {
        let fy = Float(height) / 2 / tan(verticalFOV / 2)
        return Intrinsics(fx: fy, fy: fy, cx: Float(width) / 2, cy: Float(height) / 2, width: width, height: height)
    }

    /// 카메라가 `from` 에서 `target` 을 바라보는 변환 (카메라 → 월드, −Z 가 전방, +Y 위).
    public static func lookAt(from eye: SIMD3<Float>, to target: SIMD3<Float>, up: SIMD3<Float> = [0, 1, 0]) -> simd_float4x4 {
        let f = simd_normalize(target - eye)          // 전방
        let r = simd_normalize(simd_cross(f, up))     // 오른쪽
        let u = simd_cross(r, f)
        return simd_float4x4(columns: (SIMD4(r, 0), SIMD4(u, 0), SIMD4(-f, 0), SIMD4(eye, 1)))
    }

    public static func transformPoint(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z) / v.w
    }
    public static func transformDirection(_ m: simd_float4x4, _ d: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4(d, 0)
        return SIMD3(v.x, v.y, v.z)
    }

    /// RMS (m)
    public static func rms(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .nan }
        var s: Float = 0
        for i in a.indices { s += simd_length_squared(a[i] - b[i]) }
        return (s / Float(a.count)).squareRoot()
    }

    /// 경계 고리 찾기(CoursonaFace.CapBuilder, T-101/102): 정확히 한 삼각형에만 속한 변(경계 변)을 모아
    /// 닫힌 고리로 묶는다. 메시에 열린 구멍이 있으면(흉상 목 아래 절단면, 눈·입 소켓 등) 그 테두리가 고리 하나로 나온다.
    /// 도는 방향(시계/반시계)은 임의 — 호출 쪽에서 바깥 방향을 법선으로 정한다. 형태가 어긋난(분기하는) 경계는 건너뛴다.
    public static func boundaryLoops(indices: [UInt32]) -> [[Int]] {
        func edgeKey(_ a: Int, _ b: Int) -> UInt64 {
            let lo = UInt64(min(a, b)), hi = UInt64(max(a, b))
            return (lo << 32) | hi
        }
        var edgeCount: [UInt64: Int] = [:]
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            for (p, q) in [(a, b), (b, c), (c, a)] { edgeCount[edgeKey(p, q), default: 0] += 1 }
            i += 3
        }
        var adjacency: [Int: [Int]] = [:]
        i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            for (p, q) in [(a, b), (b, c), (c, a)] where edgeCount[edgeKey(p, q)] == 1 {
                adjacency[p, default: []].append(q)
                adjacency[q, default: []].append(p)
            }
            i += 3
        }
        var visited = Set<Int>()
        var loops: [[Int]] = []
        for start in adjacency.keys.sorted() where !visited.contains(start) {
            guard let firstNeighbors = adjacency[start], firstNeighbors.count == 2 else { visited.insert(start); continue }
            var loop = [start]
            visited.insert(start)
            var prev = start, current = firstNeighbors[0]
            var ok = true
            while current != start {
                loop.append(current); visited.insert(current)
                guard let neighbors = adjacency[current], neighbors.count == 2 else { ok = false; break }
                let next = neighbors[0] == prev ? neighbors[1] : neighbors[0]
                prev = current; current = next
                if loop.count > indices.count { ok = false; break } // 분기 보호
            }
            if ok, loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    /// 단위 벡터 구면 선형 보간(캡 팬 돔 모양에 쓴다). 거의 같은 방향이면 `a` 를 그대로.
    public static func slerpUnit(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let d = Swift.min(Swift.max(simd_dot(a, b), -1), 1)
        let theta = acos(d)
        if theta < 1e-4 { return simd_normalize(a) }
        let s = sin(theta)
        let wa = sin((1 - t) * theta) / s, wb = sin(t * theta) / s
        return simd_normalize(a * wa + b * wb)
    }

    /// FNV-1a 64 해시 (삼각형 인덱스·정점 순서 검증용).
    public static func fnv1a(_ bytes: UnsafeRawBufferPointer) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
    public static func fnv1a<T>(_ values: [T]) -> UInt64 {
        values.withUnsafeBytes { fnv1a($0) }
    }
}

/// `simd_float4x4` Codable 래퍼 (열 우선 16개).
public struct Matrix4Codable: Codable, Sendable, Equatable {
    public var m: simd_float4x4
    public init(_ m: simd_float4x4) { self.m = m }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let a = try c.decode([Float].self)
        guard a.count == 16 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "matrix needs 16 floats") }
        m = simd_float4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]), SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let cs = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
        try c.encode(cs.flatMap { [$0.x, $0.y, $0.z, $0.w] })
    }
}

extension SIMD3 where Scalar == Float {
    public var array: [Float] { [x, y, z] }
}

/// 사원수 (x, y, z, w) 직렬화 — clip.json 의 `quat xyzw`.
public struct QuatCodable: Codable, Sendable, Equatable {
    public var q: simd_quatf
    public init(_ q: simd_quatf) { self.q = q }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let a = try c.decode([Float].self)
        guard a.count == 4 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "quat needs 4 floats") }
        q = simd_quatf(ix: a[0], iy: a[1], iz: a[2], r: a[3])
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode([q.imag.x, q.imag.y, q.imag.z, q.real])
    }
}
