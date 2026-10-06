//
//  SplatGPUBridge.swift
//  CoursonaSplat
//
//  C5(T-504): `[SplatRecord]` → `GaussianSplatComponent`(RealityKit). 문서(Apple, 2026-10-06 `DocumentationSearch`
//  로 직접 확인)의 "Creating a Splat Entity" 예제와 같은 레이아웃 — 인터리브 14 float(위치3·스케일3·회전4(r,x,y,z
//  순서!)·불투명도1·구면조화 0차=색3), `LowLevelBuffer` 하나에 전부 담고 `GaussianSplatResource.BufferDescriptor`
//  5개로 각 속성의 자리(스트라이드·오프셋)를 알려준다. `splats.bin`(`SplatFile`) 의 바이트 배치와는 **다르다** —
//  그건 우리 자체 보관 포맷이고, 이건 RealityKit 이 요구하는 GPU 레이아웃이라 `[SplatRecord]` 에서 매번 새로 짠다.
//
//  🧪 **가용성 — 두 번 고쳐 쓴 메모**:
//  1) `GaussianSplatComponent`/`GaussianSplatResource` 는 OS 27(iOS 27·macOS 27·visionOS 27) 전용이라 이 프로젝트
//     배포 타깃(OS 26)보다 높다 — `#available` 로 가른다. GPU 지원(Apple7)과는 별개의 조건.
//  2) 처음엔 "iOS 빌드에서 이 타입이 아예 없다(cannot find in scope)" 고 보고 `#if os(macOS)` 로만 감쌌는데, 그건
//     **시뮬레이터 SDK**(iphonesimulator 27.0) 를 보고 내린 결론이었다 — 레퍼런스 앱 Soban(`SplatMesh.swift`)이
//     `#if !targetEnvironment(simulator)` + `#available(visionOS 27, iOS 27, macOS 27, *)` 로 **iOS 실기기에서
//     네이티브 스플랫을 쓰고 있음**을 확인(2026-10-06). 그래서 게이트를 "시뮬레이터가 아니면" 으로 바꿨다 — 아이폰에서도
//     얼굴면 밖이 고스트가 아니라 사진 스플랫으로 보인다. 시뮬레이터만 `isSupported() == false`(고스트 폴백).
//

import Foundation
import Metal
import simd
import CoursonaCore

#if !targetEnvironment(simulator)
import RealityKit

public enum SplatGPUBridge {
    /// 가우시안 스플랫 렌더에 필요한 GPU 지원 여부 — `@available` 없이 아무 데서나 불러도 된다(OS 27 미만이면 false).
    public static func isSupported(device: MTLDevice? = MTLCreateSystemDefaultDevice()) -> Bool {
        guard #available(visionOS 27, iOS 27, macOS 27, *) else { return false }
        return device?.supportsFamily(.apple7) ?? false
    }

    /// `records` 로 `GaussianSplatComponent` 를 만든다. 지원 안 하거나 레코드가 없거나 버퍼 생성이 실패하면
    /// nil — 호출 쪽이 고스트 파트 폴백으로 넘어가면 된다(UI 문구는 "스플랫: 폴백", §6.6).
    @available(visionOS 27, iOS 27, macOS 27, *)
    @MainActor
    public static func makeComponent(records: [SplatRecord], device: MTLDevice? = MTLCreateSystemDefaultDevice()) -> GaussianSplatComponent? {
        guard isSupported(device: device), !records.isEmpty else { return nil }
        let floatSize = MemoryLayout<Float>.size
        let floatsPerSplat = 14 // 위치3 · 스케일3 · 회전4 · 불투명도1 · 색(SH0)3
        let stride = floatsPerSplat * floatSize
        let totalBytes = records.count * stride
        let rounded = (totalBytes + 15) & ~0xF // GaussianSplatComponent 예제와 같은 16 B 정렬
        do {
            let buffer = try LowLevelBuffer(descriptor: .init(capacity: rounded, sizeMultiple: 16))
            buffer.withUnsafeMutableBytes { raw in
                let ptr = raw.bindMemory(to: Float.self)
                for (i, r) in records.enumerated() {
                    let base = i * floatsPerSplat
                    ptr[base] = r.position.x; ptr[base + 1] = r.position.y; ptr[base + 2] = r.position.z
                    ptr[base + 3] = r.scale.x; ptr[base + 4] = r.scale.y; ptr[base + 5] = r.scale.z
                    // 회전은 (r, x, y, z) 순서 — Apple 문서 표에 명시된 순서, 우리 SplatFile(x,y,z,r)과는 다르다.
                    ptr[base + 6] = r.rotation.real; ptr[base + 7] = r.rotation.imag.x
                    ptr[base + 8] = r.rotation.imag.y; ptr[base + 9] = r.rotation.imag.z
                    ptr[base + 10] = r.opacity
                    ptr[base + 11] = r.color.x; ptr[base + 12] = r.color.y; ptr[base + 13] = r.color.z
                }
            }
            let position = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: stride, offset: 0)
            let scale = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: stride, offset: floatSize * 3)
            let rotation = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float4, stride: stride, offset: floatSize * 6)
            let opacity = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float, stride: stride, offset: floatSize * 10)
            let sh = GaussianSplatResource.BufferDescriptor(buffer: buffer, format: .float3, stride: stride, offset: floatSize * 11)
            let bufferResource = try GaussianSplatResource.BufferResource(
                count: records.count, position: position, scale: scale, rotation: rotation, opacity: opacity, sphericalHarmonics: (sh, .zero))
            return GaussianSplatComponent(GaussianSplatResource(bufferResource))
        } catch {
            return nil
        }
    }
}
#else
/// 시뮬레이터 SDK 에는 `GaussianSplatComponent` 자체가 없다(위 머리말 참고) — 항상 지원 안 함(고스트 폴백).
/// `makeComponent` 는 반환 타입을 선언할 방법이 없어 시뮬레이터 빌드엔 없다 — 호출부가 `isSupported()` 로 먼저
/// 물어보면 어차피 false 라 부를 일이 없다.
public enum SplatGPUBridge {
    public static func isSupported(device: MTLDevice? = MTLCreateSystemDefaultDevice()) -> Bool { false }
}
#endif
