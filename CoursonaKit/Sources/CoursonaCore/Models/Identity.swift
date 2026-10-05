//
//  Identity.swift
//  CoursonaCore
//
//  피팅 결과 = "내 얼굴로 바뀐 템플릿" (TechPRD §6.4-6). 정점 전체 + 스케일 + 눈알 + 패치 델타(바뀐 것만) + 품질 지표.
//  `identity.bin` 바이너리: 매직 "CHID", 버전 1, little-endian.
//

import Foundation
import simd

public struct FitQuality: Codable, Sendable, Equatable {
    /// 정합 후 사용자 메시 대비 패치 RMS (m). 목표 < 1.5 mm
    public var patchRMS: Float
    /// 컷별 패치 RMS
    public var patchRMSPerShot: [String: Float]
    /// 실루엣 잔차 중앙값 (m). M3 전에는 nil
    public var silhouetteResidualMedian: Float?
    /// RBF 정규화·조건
    public var rbfLambda: Double
    public var rbfPivotRatio: Double
    /// 쓴 컷 수
    public var shotsUsed: Int
    public var elapsedSeconds: Double

    // --- M3 (T-302 ~ T-308). 모두 옵셔널 — 옛 identity.bin/manifest 의 JSON 은 그대로 읽힌다. ---
    /// "dense"(ARKit 1220 밀집) / "sparse"(사진 + Vision 76 희소 폴백)
    public var method: String? = nil
    /// 실루엣 맞춤: 대응을 얻은 정점 수 · 포인트 클라우드 크기 · 잔차 p90 (m)
    public var silhouetteVertices: Int? = nil
    public var silhouettePoints: Int? = nil
    public var silhouetteResidualP90: Float? = nil
    /// 컷별 깊이 → ARKit 메시 오프셋 (m, 컷 이름 → 값). 실기기 TrueDepth 는 메시보다 ~25 mm 가깝게 나온다(M3)
    public var depthOffsetPerShot: [String: Float]? = nil
    /// jawOpen 진폭 보정 비율 (사용자 턱 벌림 / 템플릿 델타). nil = 미소 컷에 jawOpen 이 거의 없어 보정 안 함
    public var jawOpenScale: Float? = nil
    /// 눈알 추정 방식: "ring"(눈꺼풀 링 구 피팅) / "prior"(링 중심 + 사전 반지름) / "landmark" / "manifest" — 왼/오른쪽 "ring+prior" 식
    public var eyeFit: String? = nil
    /// 미소 컷 검증: 캡처 가중치로 변형한 패치 vs 미소 컷 ARKit 메시 RMS (m). 델타 보정이 맞는지의 직접 지표
    public var smileResidualRMS: Float? = nil
    /// 같은 비교를 **표정 없이**(중립 패치 vs 미소 메시) 한 값 — 델타가 도움이 되는지의 기준선. 이보다 크면 템플릿 셰이프키가 ARKit 과 다르다는 뜻
    public var smileNeutralRMS: Float? = nil
    /// 희소 피팅에 쓴 랜드마크 수
    public var landmarksUsed: Int? = nil
    /// 사람이 읽는 메모 (가정·경고)
    public var notes: String? = nil

    public init(patchRMS: Float, patchRMSPerShot: [String: Float], silhouetteResidualMedian: Float?, rbfLambda: Double, rbfPivotRatio: Double, shotsUsed: Int, elapsedSeconds: Double) {
        self.patchRMS = patchRMS; self.patchRMSPerShot = patchRMSPerShot; self.silhouetteResidualMedian = silhouetteResidualMedian
        self.rbfLambda = rbfLambda; self.rbfPivotRatio = rbfPivotRatio; self.shotsUsed = shotsUsed; self.elapsedSeconds = elapsedSeconds
    }

    /// 한 줄 요약 (앱 패널·CLI 공용, 한국어).
    public var summaryLine: String {
        var parts: [String] = []
        if method == "sparse" {
            parts.append("희소(사진) 피팅")
            if let n = landmarksUsed { parts.append("랜드마크 \(n)") }
        } else {
            parts.append("컷 \(shotsUsed)")
            parts.append(String(format: "패치 RMS %.2f mm", patchRMS * 1000))
        }
        if let s = silhouetteResidualMedian { parts.append(String(format: "실루엣 잔차 중앙값 %.1f mm", s * 1000)) }
        if let v = silhouetteVertices { parts.append("당긴 정점 \(v)") }
        if let j = jawOpenScale { parts.append(String(format: "jawOpen ×%.2f", j)) }
        if let e = eyeFit { parts.append("눈 \(e)") }
        if let r = smileResidualRMS {
            if let b = smileNeutralRMS { parts.append(String(format: "미소 잔차 %.2f mm (표정 없이 %.2f)", r * 1000, b * 1000)) }
            else { parts.append(String(format: "미소 잔차 %.2f mm", r * 1000)) }
        }
        parts.append(String(format: "%.1f s", elapsedSeconds))
        return parts.joined(separator: " · ")
    }
}

public struct Identity: Sendable, Equatable {
    public var templateID: String
    public var templateVersion: String
    public var positions: [SIMD3<Float>]
    /// 사용자 머리 스케일 (사용자 눈 간격 / 템플릿 눈 간격)
    public var scale: Float
    public var eyeCenterL: SIMD3<Float>
    public var eyeCenterR: SIMD3<Float>
    public var eyeRadius: Float
    /// 보정된 패치 델타 (셰이프 → 1220 × xyz). 없으면 템플릿 것을 `scale` 로 조정해 쓴다.
    public var patchDeltas: [ArkitShape: [SIMD3<Float>]]
    /// 셰이프별 진폭 비율 (T-305: `jawOpen` 등). 패치 밖 델타에 `scale × shapeScales[shape]` 를 곱한다. identity.bin v2.
    public var shapeScales: [ArkitShape: Float] = [:]
    public var quality: FitQuality?

    public init(templateID: String, templateVersion: String, positions: [SIMD3<Float>], scale: Float,
                eyeCenterL: SIMD3<Float>, eyeCenterR: SIMD3<Float>, eyeRadius: Float,
                patchDeltas: [ArkitShape: [SIMD3<Float>]] = [:], shapeScales: [ArkitShape: Float] = [:], quality: FitQuality? = nil) {
        self.templateID = templateID; self.templateVersion = templateVersion; self.positions = positions; self.scale = scale
        self.eyeCenterL = eyeCenterL; self.eyeCenterR = eyeCenterR; self.eyeRadius = eyeRadius
        self.patchDeltas = patchDeltas; self.shapeScales = shapeScales; self.quality = quality
    }

    /// 템플릿 그대로 (사용자 없음) — 미리보기·테스트용.
    public static func fromTemplate(_ t: BustTemplate) -> Identity {
        Identity(templateID: t.manifest.id, templateVersion: t.manifest.version, positions: t.positions, scale: 1,
                 eyeCenterL: SIMD3(t.manifest.eyeL[0], t.manifest.eyeL[1], t.manifest.eyeL[2]),
                 eyeCenterR: SIMD3(t.manifest.eyeR[0], t.manifest.eyeR[1], t.manifest.eyeR[2]),
                 eyeRadius: t.manifest.eyeRadius)
    }

    /// 런타임용 52 델타: 패치는 `patchDeltas`(있으면) 또는 템플릿 × shapeScales, 바깥은 템플릿 × scale × shapeScales.
    public func runtimeDeltas(template: BustTemplate) -> [ArkitShape: [SIMD3<Float>]] {
        var out: [ArkitShape: [SIMD3<Float>]] = [:]
        let pc = template.patchCount
        for (shape, d) in template.shapeDeltas {
            var arr = d
            let amp = shapeScales[shape] ?? 1
            if arr.count == positions.count {
                for i in 0..<min(pc, arr.count) { arr[i] *= amp }
                for i in pc..<arr.count { arr[i] *= scale * amp }
            }
            if let p = patchDeltas[shape], p.count == pc, arr.count >= pc {
                for i in 0..<pc { arr[i] = p[i] }
            }
            out[shape] = arr
        }
        return out
    }

    // MARK: identity.bin
    //
    // v1: 매직 · 버전 · 템플릿 id/버전 · 정점 · 스케일 · 눈 · 패치 델타 · 품질 JSON
    // v2 (M3): v1 뒤에 shapeScales (count · (name · Float)). 읽기는 v1·v2 모두.

    static let magic: UInt32 = 0x4449_4843 // "CHID" little-endian
    static let currentVersion: UInt32 = 2

    public func serialized() throws -> Data {
        var d = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { d.append(contentsOf: $0) } }
        func putString(_ s: String) { let u = Array(s.utf8); put(UInt32(u.count)); d.append(contentsOf: u) }
        put(Identity.magic); put(Identity.currentVersion)
        putString(templateID); putString(templateVersion)
        put(UInt32(positions.count))
        for p in positions { put(p.x); put(p.y); put(p.z) }
        put(scale)
        for v in [eyeCenterL, eyeCenterR] { put(v.x); put(v.y); put(v.z) }
        put(eyeRadius)
        put(UInt32(patchDeltas.count))
        for (shape, arr) in patchDeltas.sorted(by: { $0.key.index < $1.key.index }) {
            putString(shape.rawValue); put(UInt32(arr.count))
            for p in arr { put(p.x); put(p.y); put(p.z) }
        }
        if let q = quality {
            let json = try JSONEncoder().encode(q)
            put(UInt32(json.count)); d.append(json)
        } else { put(UInt32(0)) }
        // v2: 셰이프 진폭
        put(UInt32(shapeScales.count))
        for (shape, s) in shapeScales.sorted(by: { $0.key.index < $1.key.index }) { putString(shape.rawValue); put(s) }
        return d
    }

    public init(serialized data: Data) throws {
        var off = 0
        func take<T>(_: T.Type) throws -> T {
            let n = MemoryLayout<T>.size
            guard off + n <= data.count else { throw IdentityError.truncated }
            defer { off += n }
            return data.subdata(in: off..<(off + n)).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }
        func takeString() throws -> String {
            let n = Int(try take(UInt32.self))
            guard off + n <= data.count else { throw IdentityError.truncated }
            defer { off += n }
            return String(decoding: data.subdata(in: off..<(off + n)), as: UTF8.self)
        }
        func takeVec() throws -> SIMD3<Float> { SIMD3(try take(Float.self), try take(Float.self), try take(Float.self)) }
        guard try take(UInt32.self) == Identity.magic else { throw IdentityError.badMagic }
        let version = try take(UInt32.self)
        guard version >= 1, version <= Identity.currentVersion else { throw IdentityError.unsupportedVersion }
        templateID = try takeString(); templateVersion = try takeString()
        let n = Int(try take(UInt32.self))
        var pos: [SIMD3<Float>] = []; pos.reserveCapacity(n)
        for _ in 0..<n { pos.append(try takeVec()) }
        positions = pos
        scale = try take(Float.self)
        eyeCenterL = try takeVec(); eyeCenterR = try takeVec()
        eyeRadius = try take(Float.self)
        let dc = Int(try take(UInt32.self))
        var deltas: [ArkitShape: [SIMD3<Float>]] = [:]
        for _ in 0..<dc {
            let name = try takeString()
            let c = Int(try take(UInt32.self))
            var arr: [SIMD3<Float>] = []; arr.reserveCapacity(c)
            for _ in 0..<c { arr.append(try takeVec()) }
            if let s = ArkitShape(rawValue: name) { deltas[s] = arr }
        }
        patchDeltas = deltas
        let qn = Int(try take(UInt32.self))
        if qn > 0 {
            guard off + qn <= data.count else { throw IdentityError.truncated }
            quality = try JSONDecoder().decode(FitQuality.self, from: data.subdata(in: off..<(off + qn)))
            off += qn
        } else { quality = nil }
        var scales: [ArkitShape: Float] = [:]
        if version >= 2 {
            let sc = Int(try take(UInt32.self))
            for _ in 0..<sc {
                let name = try takeString()
                let v = try take(Float.self)
                if let s = ArkitShape(rawValue: name) { scales[s] = v }
            }
        }
        shapeScales = scales
    }
}

public enum IdentityError: Error, LocalizedError {
    case badMagic, unsupportedVersion, truncated
    public var errorDescription: String? {
        switch self {
        case .badMagic: "identity.bin 매직이 다릅니다"
        case .unsupportedVersion: "identity.bin 버전을 지원하지 않습니다"
        case .truncated: "identity.bin 이 잘렸습니다"
        }
    }
}
