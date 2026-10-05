import Testing
import simd
@testable import CoursonaCore
@testable import CoursonaSplat

/// C5 T-504: `[SplatRecord]` → `GaussianSplatComponent` 브리지. `GaussianSplatComponent` 는 macOS 전용이고
/// (`#if os(macOS)`, iOS SDK 에 타입 자체가 없다 — 실제 빌드로 확인) `@available(macOS 27, *)` 다(이 프로젝트
/// 배포 타깃 OS 26 보다 높다). 이 스위트는 그 조건을 만족하는 기기(이 개발 Mac 은 macOS 27.0.1)에서만 돈다.
@Suite("스플랫 GPU 브리지 (C5, T-504)")
struct SplatGPUBridgeTests {
    @Test("isSupported 는 플랫폼·OS 가리지 않고 항상 불러도 안전하다")
    func isSupportedNeverCrashes() {
        _ = SplatGPUBridge.isSupported()
    }

#if os(macOS)
    static func sampleRecords(_ n: Int = 10) -> [SplatRecord] {
        (0..<n).map { i in
            SplatRecord(position: SIMD3(Float(i) * 0.001, 0.4, 0.08), scale: SIMD3(0.002, 0.002, 0.0007),
                       rotation: simd_quatf(angle: 0, axis: [0, 0, 1]), color: SIMD3(0.6, 0.4, 0.3), opacity: 0.9,
                       triangle: Int32(i), baryU: 0.3, baryV: 0.3, normalOffset: 0.0015)
        }
    }

    @Test("빈 레코드는 nil")
    func emptyRecordsReturnNil() async {
        guard #available(macOS 27.0, *) else { return }
        let component = await MainActor.run { SplatGPUBridge.makeComponent(records: []) }
        #expect(component == nil)
    }

    @Test("GPU 가 지원하면 레코드로 실제 컴포넌트가 나온다")
    func makesComponentWhenSupported() async {
        guard #available(macOS 27.0, *) else { return }
        guard SplatGPUBridge.isSupported() else { return } // 이 기기가 Apple7 미만이면 폴백이 맞는 동작이라 통과 처리
        let component = await MainActor.run { SplatGPUBridge.makeComponent(records: Self.sampleRecords()) }
        #expect(component != nil)
    }

    @Test("수천 개 레코드도 에러 없이 처리한다")
    func handlesManyRecords() async {
        guard #available(macOS 27.0, *) else { return }
        guard SplatGPUBridge.isSupported() else { return }
        let component = await MainActor.run { SplatGPUBridge.makeComponent(records: Self.sampleRecords(5000)) }
        #expect(component != nil)
    }
#endif
}
