//
//  SplatFile.swift
//  CoursonaSplat
//
//  `splats.bin` 직렬화 (TechPRD §6.6, Formats.md 참고). little-endian, 정렬 없음(BustMeshFile 과 같은 규칙).
//
//  header  : magic "CSP1"(4) · version u32(1) · count u32 · stride u32(렌더용 "데이터" 한 개의 바이트 수) · bindingFlag u32(1 = 바인딩 블록 있음)
//  data    : count × stride 바이트 — 인터리브 14 float(위치3·스케일3·회전쿼터니언4·색3·불투명도1 = 56 B) + 16 B 정렬 패딩(8 B, f32 2개) = 64 B.
//            `GaussianSplatResource`(RealityKit) 가 실제로 기대하는 레이아웃은 T-504 에서 확정 — 그때까지는 이 파일 자체 레이아웃.
//  binding : bindingFlag 가 있으면 count × { tri u32 · u f32 · v f32 · offset f32 } = 16 B — 삼각형이 바뀌면(변형) 다시 구울 때 쓴다(v1.1).
//

import Foundation
import simd

public enum SplatFileError: Error, LocalizedError {
    case badMagic
    case truncated
    public var errorDescription: String? {
        switch self {
        case .badMagic: "splats.bin 매직이 아니다(CSP1 아님)"
        case .truncated: "splats.bin 이 잘렸다(길이 부족)"
        }
    }
}

public enum SplatFile {
    static let magic: [UInt8] = Array("CSP1".utf8)
    /// 렌더용 데이터 한 개의 바이트 수(14 float + 2 float 패딩 = 16 float = 64 B, 16 B 정렬).
    public static let dataStride = 64

    public static func write(_ records: [SplatRecord], includeBinding: Bool = true) -> Data {
        var d = Data(); d.reserveCapacity(16 + records.count * (dataStride + (includeBinding ? 16 : 0)))
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: magic)
        put(UInt32(1)); put(UInt32(records.count)); put(UInt32(dataStride)); put(UInt32(includeBinding ? 1 : 0))
        for r in records {
            put(r.position.x); put(r.position.y); put(r.position.z)
            put(r.scale.x); put(r.scale.y); put(r.scale.z)
            put(r.rotation.imag.x); put(r.rotation.imag.y); put(r.rotation.imag.z); put(r.rotation.real)
            put(r.color.x); put(r.color.y); put(r.color.z)
            put(r.opacity)
            put(Float(0)); put(Float(0)) // 패딩(16 B 정렬)
        }
        if includeBinding {
            for r in records { put(UInt32(bitPattern: r.triangle)); put(r.baryU); put(r.baryV); put(r.normalOffset) }
        }
        return d
    }

    public static func read(_ data: Data) throws -> [SplatRecord] {
        var off = 0
        func take<T>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            guard off + n <= data.count else { throw SplatFileError.truncated }
            let v = data.subdata(in: (data.startIndex + off)..<(data.startIndex + off + n)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            off += n
            return v
        }
        guard data.count >= 4, data.subdata(in: data.startIndex..<(data.startIndex + 4)) == Data(magic) else { throw SplatFileError.badMagic }
        off = 4
        _ = try take(UInt32.self) // version
        let count = Int(try take(UInt32.self))
        let stride = Int(try take(UInt32.self))
        let hasBinding = try take(UInt32.self) != 0
        var out: [SplatRecord] = []; out.reserveCapacity(count)
        for _ in 0..<count {
            let start = off
            let px = try take(Float.self), py = try take(Float.self), pz = try take(Float.self)
            let sx = try take(Float.self), sy = try take(Float.self), sz = try take(Float.self)
            let qx = try take(Float.self), qy = try take(Float.self), qz = try take(Float.self), qw = try take(Float.self)
            let cx = try take(Float.self), cy = try take(Float.self), cz = try take(Float.self)
            let opacity = try take(Float.self)
            off = start + stride // dataStride 가 늘어나도(미래 버전) 다음 레코드 시작점을 안전하게 찾는다.
            out.append(SplatRecord(position: SIMD3(px, py, pz), scale: SIMD3(sx, sy, sz), rotation: simd_quatf(ix: qx, iy: qy, iz: qz, r: qw),
                                   color: SIMD3(cx, cy, cz), opacity: opacity, triangle: -1, baryU: 0, baryV: 0, normalOffset: 0))
        }
        if hasBinding {
            for i in 0..<count {
                let tri = Int32(bitPattern: try take(UInt32.self))
                let u = try take(Float.self), v = try take(Float.self), offset = try take(Float.self)
                out[i].triangle = tri; out[i].baryU = u; out[i].baryV = v; out[i].normalOffset = offset
            }
        }
        return out
    }
}
