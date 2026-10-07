//
//  PersonaBuildPipeline.swift
//  CoursonaStudio
//
//  C8 UI 2단계 — 캡처 번들 → 피팅 → 텍스처 → 패키지 저장을 하나로 엮는다.
//  지금까지 `CoursonaKit` 모듈은 전부 저수준이라(의도적으로, §6.1) 이 전체를 순서대로 부르는 코드가
//  `coursona-validate` CLI·테스트에만 있었다 — 화면(`BuildProgressView` 등)이 쓸 수 있는 앱 수준 API가
//  없었다는 뜻이다. 이 모듈이 그 자리를 채운다. SwiftUI/Observation 의존 없이 순수 async throws 함수로 둬서
//  (초상이 `AppModel`을 앱 타깃에 둔 것과 같은 경계), `@Observable` 진행 상태는 앱 타깃이 이 콜백을 받아 만든다.
//
//  입체감 v3(2026-10-07): 얼굴면 밖(두피·목·어깨)을 더는 가우시안 스플랫(`PhotoSplatBuilder`)으로 따로 만들지
//  않는다 — 실기기에서 "흉상 메시+스플랫 점구름+눈알" 세 겹이 따로 보인다는 문제가 확인됐다(사용자 스크린샷).
//  대신 `TextureBuilder` 를 `faceOnly` 없이(전체 옵션) 돌려 **얼굴면과 같은 사진 투영+채움 기술**로 두피·목·
//  어깨까지 한 장의 텍스처에 칠한다 — `BustEntity` 가 그 "나머지" 파트에 얼굴면과 같은 머티리얼(0)을 쓰므로
//  (`BustEntity.swift` 머리말 참고) 이걸로 "하나의 엔티티, 얼굴면 기술의 확장"이 완성된다. 이번엔(기존 "오래된
//  서브시스템은 지우지 말고 호출부만 바꾼다" 관례와 다르게) 쓸모가 완전히 없어졌다고 보고 `PhotoSplatBuilder`·
//  `PersonMatte`·`SplatGPUBridge`·`SplatFile`·`SplatBinder`(`CoursonaSplat` 모듈 전체)를 실제로 지웠다 — 되살릴
//  일이 있으면 git 이력에서 찾으면 된다.
import Foundation
import simd
import CoursonaCore
import CoursonaFit
import CoursonaTexture
import CoursonaIO

/// UXPRD 화면 4(빌드 진행)의 4단계. "얼굴면 완성"은 별도 단계가 아니라 `TextureBuilder` 내부에서 캡(눈·입)을
/// 닫는 과정에 자연히 포함된다(`CapBuilder.addingCaps`, T-204 구현 노트와 같은 이유) — 화면 문구는 텍스처 단계
/// 동안 "눈과 입 주변을 자연스럽게 다듬는 중"으로 보여주면 된다(UXPRD: "캡" 같은 내부 용어 금지).
/// `splat` 단계는 이제 별도로 할 일이 없다(텍스처 단계가 두피·목·어깨까지 이미 다 칠한다) — 화면 체크리스트
/// 4단계 구성을 그대로 두기 위해 즉시 0→1 로 보고만 한다.
public enum PersonaBuildStage: String, Sendable, CaseIterable {
    case fitting, texture, splat, package
}

public struct PersonaBuildProgress: Sendable {
    public var stage: PersonaBuildStage
    /// 그 단계 안에서의 진행률 0...1.
    public var fraction: Double
    public init(stage: PersonaBuildStage, fraction: Double) { self.stage = stage; self.fraction = fraction }
}

public enum PersonaBuildError: Error, LocalizedError {
    case noTemplate
    public var errorDescription: String? { "템플릿을 불러오지 못했습니다." }
}

public enum PersonaBuildPipeline {
    /// 캡처 번들 하나로 페르소나 하나를 끝까지 만들어 기본 폴더(`CoursonaPackageStore.defaultFolder`)에 저장하고
    /// 돌려준다. `FaceFitter.fit` 이 `bundle.meta.sparse` 로 밀집(A)/희소(B·C) 경로를 자동으로 가른다 —
    /// 이 함수는 등급을 신경 쓰지 않고 그냥 번들을 넘기면 된다(`tier` 는 매니페스트 기록용일 뿐).
    public static func run(bundle: CaptureBundle, template: BustTemplate, tier: CaptureTier, name: String,
                           fitOptions: FitOptions = FitOptions(), progress: (@Sendable (PersonaBuildProgress) -> Void)? = nil) async throws -> CoursonaPackage {
        progress?(PersonaBuildProgress(stage: .fitting, fraction: 0))
        let identity = try FaceFitter.fit(bundle: bundle, template: template, options: fitOptions)
        let alignments = FaceFitter.alignments(bundle: bundle, template: template)
        progress?(PersonaBuildProgress(stage: .fitting, fraction: 1))

        // faceOnly 없이(전체 옵션) 돌려 두피·목·어깨까지 같은 사진 투영+채움 기술로 한 장에 칠한다(머리말 참고).
        let tex = try TextureBuilder.build(bundle: bundle, template: template, identity: identity, alignments: alignments,
                                           options: TextureBuildOptions()) { _, frac in
            progress?(PersonaBuildProgress(stage: .texture, fraction: frac))
        }

        progress?(PersonaBuildProgress(stage: .splat, fraction: 0))
        progress?(PersonaBuildProgress(stage: .splat, fraction: 1))

        progress?(PersonaBuildProgress(stage: .package, fraction: 0))
        var manifest = CoursonaManifest(name: name, createdOn: bundle.meta.device, templateID: template.manifest.id,
                                        templateVersion: template.manifest.version, vertexCount: template.manifest.vertexCount)
        manifest.tier = tier
        manifest.textureQuality = tex.quality
        // 사진에서 잰 머리카락색 → Persona 헤어 에셋 틴트(T-704·D-303: 앱 틴트 = 목표색 ÷ 0.63). 0…1 sRGB.
        if let h = tex.hairColor { manifest.hairTint = [h.x, h.y, h.z] }
        manifest.includesCaptureBundle = true
        let pkg = CoursonaPackage(manifest: manifest, identity: identity, albedo: tex.albedo, mask: tex.mask, thumbnail: nil)
        let folder = CoursonaPackageStore.defaultFolder(for: manifest.id)
        try CoursonaPackageStore.write(pkg, to: folder, captureBundle: bundle)
        progress?(PersonaBuildProgress(stage: .package, fraction: 1))
        return pkg
    }
}
