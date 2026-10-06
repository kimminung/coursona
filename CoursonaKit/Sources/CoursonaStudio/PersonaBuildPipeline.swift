//
//  PersonaBuildPipeline.swift
//  CoursonaStudio
//
//  C8 UI 2단계 — 캡처 번들 → 피팅 → 텍스처(+스플랫 색) → 스플랫 바인딩 → 패키지 저장을 하나로 엮는다.
//  지금까지 `CoursonaKit` 모듈은 전부 저수준이라(의도적으로, §6.1) 이 전체를 순서대로 부르는 코드가
//  `coursona-validate` CLI·테스트에만 있었다 — 화면(`BuildProgressView` 등)이 쓸 수 있는 앱 수준 API가
//  없었다는 뜻이다. 이 모듈이 그 자리를 채운다. SwiftUI/Observation 의존 없이 순수 async throws 함수로 둬서
//  (초상이 `AppModel`을 앱 타깃에 둔 것과 같은 경계), `@Observable` 진행 상태는 앱 타깃이 이 콜백을 받아 만든다.
//

import Foundation
import simd
import CoursonaCore
import CoursonaFit
import CoursonaTexture
import CoursonaSplat
import CoursonaIO

/// UXPRD 화면 4(빌드 진행)의 4단계. "얼굴면 완성"은 별도 단계가 아니라 `TextureBuilder`/`SplatBinder` 내부에서
/// 캡(눈·입)을 닫는 과정에 자연히 포함된다(`CapBuilder.addingCaps`, T-204 구현 노트와 같은 이유) — 화면 문구는
/// 텍스처 단계 동안 "눈과 입 주변을 자연스럽게 다듬는 중"으로 보여주면 된다(UXPRD: "캡" 같은 내부 용어 금지).
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

        let tex = try TextureBuilder.build(bundle: bundle, template: template, identity: identity, alignments: alignments,
                                           options: .faceOnlyPreset()) { _, frac in
            progress?(PersonaBuildProgress(stage: .texture, fraction: frac))
        }

        progress?(PersonaBuildProgress(stage: .splat, fraction: 0))
        // C9: 얼굴면 밖(두피·목·어깨)은 더 이상 메시 삼각형 외접원 기반(`SplatBinder`, 둔각 삼각형에서 폭주하던
        // 그 버그)이 아니라 촬영 사진에서 직접 뽑는다(`PhotoSplatBuilder`) — 전면 컷을 쓰고, 정렬이 없으면
        // (드문 경우) 정렬 가능한 다른 중립 컷으로 대신하고, 그것도 없으면 빈 스플랫(고스트 폴백)으로 둔다.
        let photoShot = [bundle.shot(.front)].compactMap { $0 }.first { alignments[$0.kind] != nil }
            ?? bundle.neutralShots.first { alignments[$0.kind] != nil }
        let splatResult: SplatBuildResult
        if let shot = photoShot, let F = alignments[shot.kind] {
            // 입체감 v2: 인물 마스크(Vision)로 배경·옷 밖 픽셀을 거르고, 메시 밖 머리카락·어깨까지 살린다. 마스크를 못 만들면
            // (사람을 못 찾음·Vision 실패) nil 로 넘겨 v1 처럼 메시 실루엣만으로 간다.
            var matte: PersonMatte? = nil
            if let img = shot.image { matte = await PersonMatte.make(from: img) }
            splatResult = PhotoSplatBuilder.build(shot: shot, faceToTemplate: F, template: template, identity: identity,
                                                  light: tex.lights[shot.kind], personAlpha: matte?.sampler, skinColor: tex.skinColor)
        } else {
            splatResult = SplatBuildResult(records: [], faceTriangleCount: 0, nonFaceTriangleCount: 0)
        }
        progress?(PersonaBuildProgress(stage: .splat, fraction: 1))

        progress?(PersonaBuildProgress(stage: .package, fraction: 0))
        var manifest = CoursonaManifest(name: name, createdOn: bundle.meta.device, templateID: template.manifest.id,
                                        templateVersion: template.manifest.version, vertexCount: template.manifest.vertexCount)
        manifest.tier = tier
        manifest.textureQuality = tex.quality
        // `CoursonaPackageStore.write` 가 splatCount·includesCaptureBundle 을 자기 지역 복사본에만 채워 디스크로
        // 내보낸다(호출자의 `pkg.manifest` 는 그대로 둠) — 돌려줄 값은 여기서 미리 맞춰 둔다.
        manifest.splatCount = splatResult.records.isEmpty ? nil : splatResult.records.count
        manifest.includesCaptureBundle = true
        let pkg = CoursonaPackage(manifest: manifest, identity: identity, albedo: tex.albedo, mask: tex.mask, thumbnail: nil, splats: splatResult.records)
        let folder = CoursonaPackageStore.defaultFolder(for: manifest.id)
        try CoursonaPackageStore.write(pkg, to: folder, captureBundle: bundle)
        progress?(PersonaBuildProgress(stage: .package, fraction: 1))
        return pkg
    }
}
