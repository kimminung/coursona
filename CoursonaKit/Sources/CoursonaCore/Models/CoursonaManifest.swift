//
//  CoursonaManifest.swift
//  CoursonaCore
//
//  `.coursona` 패키지 manifest.json (schema 1, TechPRD §6.9).
//  패키지 = 폴더: manifest.json, identity.bin, albedo.png, mask.png, thumb.png, (선택) capture/ 번들.
//  입체감 v3(2026-10-07): 얼굴면 밖도 스플랫이 아니라 같은 텍스처(albedo.png)로 칠해지므로 splats.bin 은 더
//  안 쓴다(`CoursonaSplat` 모듈 자체를 제거 — `PersonaBuildPipeline.swift` 머리말 참고).
//

import Foundation

public struct CoursonaManifest: Codable, Sendable, Equatable {
    public var schema: Int = 1
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var createdOn: String            // 기기 모델
    public var templateID: String
    public var templateVersion: String
    public var vertexCount: Int
    /// 외형 라이브러리 선택
    public var hair: String?                // Hair_<id>
    public var glasses: String?
    public var beard: String?
    public var shoulders: String?
    /// 머리카락 틴트 (sRGB 0…1) 와 하이라이트 강도
    public var hairTint: [Float]?
    public var hairHighlight: Float?
    public var skinToneAdjust: Float = 0
    public var delightStrength: Float = 0.5
    public var albedoSize: Int = 2048
    public var quality: FitQuality?
    public var textureQuality: TextureQuality?
    public var appearance: AppearanceHintsRecord?
    public var includesCaptureBundle: Bool = false
    public var files: [String: String] = ["identity": "identity.bin", "albedo": "albedo.png", "mask": "mask.png", "thumb": "thumb.png"]
    /// C8 UI 2단계(T-701 일부) — 이 페르소나를 만든 등급. 갤러리 배지·업그레이드 병합 가능 여부에 쓴다.
    public var tier: CaptureTier? = nil

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), createdOn: String, templateID: String, templateVersion: String, vertexCount: Int) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.createdOn = createdOn
        self.templateID = templateID; self.templateVersion = templateVersion; self.vertexCount = vertexCount
    }
}

public struct TextureQuality: Codable, Sendable, Equatable {
    /// 관측 텍셀 비율 (0…1). 목표 > 0.7
    public var observedRatio: Float
    public var mirroredRatio: Float
    public var filledRatio: Float
    /// 접합선 색 단차 (0…255 스케일). 목표 < 3
    public var seamDelta: Float
    public var buildSeconds: Double
    public init(observedRatio: Float, mirroredRatio: Float, filledRatio: Float, seamDelta: Float, buildSeconds: Double) {
        self.observedRatio = observedRatio; self.mirroredRatio = mirroredRatio; self.filledRatio = filledRatio; self.seamDelta = seamDelta; self.buildSeconds = buildSeconds
    }
}

/// 외형 힌트의 저장 형태 (분석기는 CoursonaFit).
public struct AppearanceHintsRecord: Codable, Sendable, Equatable {
    public var hairLength: String = "medium"
    public var hairVolume: String = "medium"
    public var hasBangs = false
    public var isTied = false
    public var wearsGlasses = false
    public var beard: String = "none"
    public var shoulderGarment: String = "tee"
    public var source: String = "heuristic"
    public init() {}
}
