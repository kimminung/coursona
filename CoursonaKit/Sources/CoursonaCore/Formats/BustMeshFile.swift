//
//  BustMeshFile.swift
//  CoursonaCore
//
//  `bust.mesh` — 블렌더 내보내기 스크립트가 USDZ 와 함께 쓰는 **폴백 바이너리**(Blender-요청.md §6, T-004 실패 대비).
//  스펙은 `Formats.md` 와 동일. little-endian, 정렬 없음.
//
//  header : magic "CBM1"(4) · version u32(1|2) · vertexCount u32 · triangleCount u32 · shapeCount u32 · jointCount u32 · flags u32(bit0 = normals, bit1 = 코너 UV)
//  positions : f32 × 3 × V
//  normals   : f32 × 3 × V (flags bit0)
//  uvs       : f32 × 2 × V (정점당 첫 루프 — 호환용)
//  cornerUVs : f32 × 2 × 3 × T (flags bit1, v2) — 삼각형 코너 순서. 솔기에서 UV 가 갈라지므로 렌더·텍스처는 이것을 쓴다(로더가 정점 분할)
//  indices   : u32 × 3 × T
//  shapes    : shapeCount × { nameLen u32, name utf8, f32 × 3 × V }     (중립 대비 델타)
//  skin      : V × { u16 × 4 joints, f32 × 4 weights }
//  joints    : jointCount × { nameLen u32, name utf8, parent i32, restWorld f32 × 16 (열 우선) }
//

import Foundation
import simd

public enum BustMeshFile {
    static let magic: [UInt8] = Array("CBM1".utf8)

    public static func write(_ t: BustTemplate) -> Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        func putString(_ s: String) { let u = Array(s.utf8); put(UInt32(u.count)); d.append(contentsOf: u) }
        d.append(contentsOf: magic)
        let hasCorner = (t.cornerUVs?.count ?? 0) == t.indices.count
        put(UInt32(2)); put(UInt32(t.positions.count)); put(UInt32(t.indices.count / 3)); put(UInt32(t.shapeDeltas.count))
        put(UInt32(t.skeleton?.jointNames.count ?? 0)); put(UInt32(1 | (hasCorner ? 2 : 0)))
        for p in t.positions { put(p.x); put(p.y); put(p.z) }
        for n in t.normals { put(n.x); put(n.y); put(n.z) }
        for uv in t.uvs { put(uv.x); put(uv.y) }
        if hasCorner, let c = t.cornerUVs { for uv in c { put(uv.x); put(uv.y) } }
        for i in t.indices { put(i) }
        for (shape, arr) in t.shapeDeltas.sorted(by: { $0.key.index < $1.key.index }) {
            putString(shape.rawValue)
            for p in arr { put(p.x); put(p.y); put(p.z) }
        }
        for s in t.skin {
            put(s.joints.x); put(s.joints.y); put(s.joints.z); put(s.joints.w)
            put(s.weights.x); put(s.weights.y); put(s.weights.z); put(s.weights.w)
        }
        if let sk = t.skeleton {
            for j in sk.jointNames.indices {
                putString(sk.jointNames[j]); put(Int32(sk.parentIndices[j]))
                let m = sk.restWorld[j]
                for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] { put(c.x); put(c.y); put(c.z); put(c.w) }
            }
        }
        return d
    }

    /// manifest 는 template.json 에서 따로 읽어 넘긴다.
    public static func read(_ data: Data, manifest: TemplateManifest) throws -> BustTemplate {
        var off = 0
        func take<T>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            guard off + n <= data.count else { throw BustMeshError.truncated }
            defer { off += n }
            return data.subdata(in: off..<(off + n)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        func takeString() throws -> String {
            let n = Int(try take(UInt32.self))
            guard off + n <= data.count else { throw BustMeshError.truncated }
            defer { off += n }
            return String(decoding: data.subdata(in: off..<(off + n)), as: UTF8.self)
        }
        guard data.count >= 4, Array(data.prefix(4)) == magic else { throw BustMeshError.badMagic }
        off = 4
        let version = try take(UInt32.self)
        guard version == 1 || version == 2 else { throw BustMeshError.unsupportedVersion }
        let V = Int(try take(UInt32.self)), T = Int(try take(UInt32.self)), S = Int(try take(UInt32.self)), J = Int(try take(UInt32.self))
        let flags = try take(UInt32.self)
        guard V > 0, V < 5_000_000, T < 10_000_000 else { throw BustMeshError.badCounts }
        var pos = [SIMD3<Float>](); pos.reserveCapacity(V)
        for _ in 0..<V { pos.append(SIMD3(try take(Float.self), try take(Float.self), try take(Float.self))) }
        var normals: [SIMD3<Float>]? = nil
        if flags & 1 != 0 {
            var n = [SIMD3<Float>](); n.reserveCapacity(V)
            for _ in 0..<V { n.append(SIMD3(try take(Float.self), try take(Float.self), try take(Float.self))) }
            normals = n
        }
        var uvs = [SIMD2<Float>](); uvs.reserveCapacity(V)
        for _ in 0..<V { uvs.append(SIMD2(try take(Float.self), try take(Float.self))) }
        var corner: [SIMD2<Float>]? = nil
        if flags & 2 != 0 {
            var c = [SIMD2<Float>](); c.reserveCapacity(T * 3)
            for _ in 0..<(T * 3) { c.append(SIMD2(try take(Float.self), try take(Float.self))) }
            corner = c
        }
        var idx = [UInt32](); idx.reserveCapacity(T * 3)
        for _ in 0..<(T * 3) { idx.append(try take(UInt32.self)) }
        var shapes: [ArkitShape: [SIMD3<Float>]] = [:]
        for _ in 0..<S {
            let name = try takeString()
            var arr = [SIMD3<Float>](); arr.reserveCapacity(V)
            for _ in 0..<V { arr.append(SIMD3(try take(Float.self), try take(Float.self), try take(Float.self))) }
            if let s = ArkitShape(rawValue: name) { shapes[s] = arr }
        }
        var skin = [SkinInfluence](); skin.reserveCapacity(V)
        for _ in 0..<V {
            let j = SIMD4<UInt16>(try take(UInt16.self), try take(UInt16.self), try take(UInt16.self), try take(UInt16.self))
            let w = SIMD4<Float>(try take(Float.self), try take(Float.self), try take(Float.self), try take(Float.self))
            skin.append(SkinInfluence(joints: j, weights: w))
        }
        var skeleton: TemplateSkeleton? = nil
        if J > 0 {
            var names: [String] = [], parents: [Int] = [], rest: [simd_float4x4] = []
            for _ in 0..<J {
                names.append(try takeString()); parents.append(Int(try take(Int32.self)))
                var cols: [SIMD4<Float>] = []
                for _ in 0..<4 { cols.append(SIMD4(try take(Float.self), try take(Float.self), try take(Float.self), try take(Float.self))) }
                rest.append(simd_float4x4(columns: (cols[0], cols[1], cols[2], cols[3])))
            }
            skeleton = TemplateSkeleton(jointNames: names, parentIndices: parents, restWorld: rest)
        }
        var t = BustTemplate(manifest: manifest, positions: pos, normals: normals, uvs: uvs, indices: idx, shapeDeltas: shapes, skin: skin, skeleton: skeleton)
        t.cornerUVs = corner
        return t
    }
}

public enum BustMeshError: Error, LocalizedError {
    case badMagic, unsupportedVersion, truncated, badCounts
    public var errorDescription: String? {
        switch self {
        case .badMagic: "bust.mesh 매직(CBM1)이 아닙니다"
        case .unsupportedVersion: "bust.mesh 버전을 지원하지 않습니다"
        case .truncated: "bust.mesh 가 잘렸습니다"
        case .badCounts: "bust.mesh 정점/삼각형 수가 비정상입니다"
        }
    }
}
