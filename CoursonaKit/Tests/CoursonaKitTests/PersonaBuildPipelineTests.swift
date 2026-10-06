import Testing
import Foundation
@testable import CoursonaCore
@testable import CoursonaTexture
@testable import CoursonaStudio
@testable import CoursonaIO

/// C8 UI 2단계: `PersonaBuildPipeline` 이 합성 번들로 끝까지(피팅→텍스처→저장) 돌고,
/// 디스크에 쓴 패키지를 다시 읽으면 같은 내용(등급·정점 수)이 나오는지 확인한다.
/// 입체감 v3(2026-10-07): 얼굴면 밖도 더는 스플랫이 아니라 같은 텍스처로 칠해지므로(`PersonaBuildPipeline`
/// 머리말, `CoursonaSplat` 모듈 자체를 제거) 스플랫 왕복 대신 관측 비율이 얼굴 밖까지 포함해 올라갔는지 본다.
/// 진행 콜백이 여러 스레드에서 와도(텍스처 빌더 등 내부가 병렬일 수 있어) 안전하게 모으는 수집기.
private final class StageCollector: @unchecked Sendable {
    private var stages: Set<PersonaBuildStage> = []
    private let lock = NSLock()
    func insert(_ s: PersonaBuildStage) { lock.lock(); stages.insert(s); lock.unlock() }
    func contains(_ s: PersonaBuildStage) -> Bool { lock.lock(); defer { lock.unlock() }; return stages.contains(s) }
}

@Suite("페르소나 빌드 파이프라인 (C8, UI 2단계)")
struct PersonaBuildPipelineTests {
    @Test("합성 번들 → 패키지 저장 → 다시 읽기, 등급·정점이 왕복하고 스플랫 없이 전신이 텍스처로 칠해진다")
    func buildsAndRoundTrips() async throws {
        let template = SyntheticTemplate.make()
        let bundle = SyntheticCapture.makeBundle(template: template)
        let stagesSeen = StageCollector()
        let pkg = try await PersonaBuildPipeline.run(bundle: bundle, template: template, tier: .a, name: "테스트 페르소나") { p in
            stagesSeen.insert(p.stage)
        }
        defer { try? FileManager.default.removeItem(at: CoursonaPackageStore.defaultFolder(for: pkg.manifest.id)) }

        #expect(stagesSeen.contains(.fitting))
        #expect(stagesSeen.contains(.texture))
        #expect(stagesSeen.contains(.splat))
        #expect(stagesSeen.contains(.package))
        #expect(pkg.manifest.tier == .a)
        #expect(pkg.manifest.name == "테스트 페르소나")
        #expect(pkg.albedo != nil)
        #expect(pkg.mask != nil)
        // faceOnly 를 껐으니 두피·목·어깨까지 포함한 관측 비율이 faceOnly 시절(약 0.25 안팎)보다 뚜렷이 높아야 한다 —
        // "하나의 텍스처가 전신을 덮는다" 는 이번 변경의 핵심을 직접 확인.
        #expect(pkg.manifest.textureQuality?.observedRatio ?? 0 > 0.4)

        let folder = CoursonaPackageStore.defaultFolder(for: pkg.manifest.id)
        let reloaded = try CoursonaPackageStore.read(from: folder)
        #expect(reloaded.manifest.tier == .a)
        #expect(reloaded.identity.positions.count == pkg.identity.positions.count)
    }
}
