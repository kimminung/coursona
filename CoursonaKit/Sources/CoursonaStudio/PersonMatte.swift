//
//  PersonMatte.swift
//  CoursonaStudio
//
//  "누끼"(인물 컷아웃) — 촬영 사진 한 장의 **인물 마스크**. 2026-10-07 재도입: 지난번엔 스플랫(`PhotoSplatBuilder`,
//  이제 삭제됨) 전용으로 만들었다가 스플랫을 걷어내며 같이 지웠는데, 사용자가 실기기에서 "두피·목처럼 메시가 실제
//  사람 머리보다 넓게 삐져나온 자리에 배경 색이 울퉁불퉁하게 섞여 들어온다"를 지적 — 원인은 `TextureBuilder.sample`
//  이 **깊이 데이터가 있는 컷에서만** "그 픽셀에 깊이가 없으면 배경" 식으로 걸러내고, 깊이가 없는 컷에서는 아무
//  배경 거름망이 없었던 것(코드 확인: `sample()`의 깊이 분기 `if let d = c.depth, let Kd = c.Kd { ... }` 밖에서는
//  색만 그대로 받는다). 그 틈을 깊이와 무관하게 항상 동작하는 이 마스크로 막는다 — 깊이가 있는 컷에서도 "가까운
//  배경(벽 등)이 깊이 허용치 안에 들어와 통과하는" 드문 경우까지 2중으로 막아 준다.
//
//  Vision `GeneratePersonInstanceMaskRequest`(실패 시 `GenerateForegroundInstanceMaskRequest`) — 전체 매트 픽셀
//  버퍼를 OS 26 에서도 꺼낼 수 있는 `generateScaledMask(for:scaledToImageFrom:)` 를 쓴다(`PersonCoverage.swift` 가
//  꺼리던 `GeneratePersonSegmentationRequest` 의 OS 27+ 전용 `pixelBuffer` 접근자가 필요 없다).
//
//  좌표: 마스크 픽셀 버퍼는 입력 이미지와 같은 방향(행 0 = 위) — `alpha(atImagePoint:)` 는 이미지 픽셀 좌표,
//  좌상단 원점을 받는다. `TextureBuilder.sample` 이 `c.K.project(pc)` 로 얻는 픽셀(`Geometry.Intrinsics.project`,
//  "x 오른쪽, y 아래" = 좌상단 원점)과 좌표계가 그대로 맞는다 — 뒤집을 필요 없음.
//

import Foundation
import CoreGraphics
import CoreVideo
import Vision
import CoursonaCore
import CoursonaIO

public struct PersonMatte: Sendable {
    public var width: Int
    public var height: Int
    /// 0...255, 행 우선(행 0 = 위).
    public var alpha: [UInt8]
    /// 이 마스크가 만들어진 원본 이미지 크기 — 샘플 좌표 스케일용.
    public var imageWidth: Int
    public var imageHeight: Int

    public init(width: Int, height: Int, alpha: [UInt8], imageWidth: Int, imageHeight: Int) {
        self.width = width; self.height = height; self.alpha = alpha; self.imageWidth = imageWidth; self.imageHeight = imageHeight
    }

    /// 이미지 픽셀 좌표(좌상단 원점) → 0...1 인물 알파(최근접). 범위 밖은 0.
    public func alpha(atImagePoint p: SIMD2<Float>) -> Float {
        guard width > 0, height > 0, imageWidth > 0, imageHeight > 0 else { return 0 }
        let x = Int(p.x * Float(width) / Float(imageWidth)), y = Int(p.y * Float(height) / Float(imageHeight))
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return Float(alpha[y * width + x]) / 255
    }

    /// `TextureBuilder.build(personAlpha:)`/`PhotoSplatBuilder` 에 그대로 넘길 클로저.
    public var sampler: @Sendable (SIMD2<Float>) -> Float { { self.alpha(atImagePoint: $0) } }

    /// 사진 한 장에서 마스크를 만든다. 사람을 못 찾으면(또는 Vision 실패) nil — 호출자는 마스크 없이 진행한다.
    public static func make(from image: RGBAImage) async -> PersonMatte? {
        guard let cg = ImageCodec.cgImage(image) else { return nil }
        let handler = ImageRequestHandler(cg)
        var observation: InstanceMaskObservation? = nil
        if let o = try? await handler.perform(GeneratePersonInstanceMaskRequest()), !o.allInstances.isEmpty {
            observation = o
        } else if let o = try? await handler.perform(GenerateForegroundInstanceMaskRequest()), !o.allInstances.isEmpty {
            observation = o
        }
        guard let observation, let buffer = try? observation.generateScaledMask(for: observation.allInstances, scaledToImageFrom: handler) else { return nil }
        return fromPixelBuffer(buffer, imageWidth: image.width, imageHeight: image.height)
    }

    /// Vision 마스크 버퍼(OneComponent8 또는 OneComponent32Float — 버전에 따라 다르다)를 UInt8 알파로.
    static func fromPixelBuffer(_ pb: CVPixelBuffer, imageWidth: Int, imageHeight: Int) -> PersonMatte? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_OneComponent32Float:
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let row = (p + y * bpr).withMemoryRebound(to: Float.self, capacity: w) { $0 }
                for x in 0..<w { out[y * w + x] = UInt8(max(0, min(255, (row[x] * 255).rounded()))) }
            }
        case kCVPixelFormatType_OneComponent16Half:
            let p = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let row = (p + y * bpr).withMemoryRebound(to: Float16.self, capacity: w) { $0 }
                for x in 0..<w { out[y * w + x] = UInt8(max(0, min(255, (Float(row[x]) * 255).rounded()))) }
            }
        default:
            // OneComponent8 (및 알 수 없는 1바이트 포맷) — 첫 바이트를 그대로.
            let p = base.assumingMemoryBound(to: UInt8.self)
            let bpp = max(1, bpr / max(1, w))
            for y in 0..<h { for x in 0..<w { out[y * w + x] = p[y * bpr + x * bpp] } }
        }
        return PersonMatte(width: w, height: h, alpha: out, imageWidth: imageWidth, imageHeight: imageHeight)
    }
}
