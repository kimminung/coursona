//
//  PersonMatte.swift
//  CoursonaStudio
//
//  입체감 v2(2026-10-06): 전면 컷의 **인물 마스크**. 레퍼런스 앱 Soban(`PersonaBuilder.build`)과 같은 Vision 요청
//  (`GeneratePersonInstanceMaskRequest`, 실패 시 `GenerateForegroundInstanceMaskRequest`)으로 사람 영역만 남긴다.
//  `PhotoSplatBuilder` 가 이 마스크로 ① 메시가 덮지만 사진 속 사람이 아닌 픽셀(배경 벽·옷 밖) 샘플을 버리고 —
//  실기기 회전 점검에서 본 "회색 마네킹색"·"가슴의 검은 점" 의 원인 — ② 메시 밖인데 사람인 픽셀(삐져나온 머리카락·
//  넓은 어깨)을 외삽해 살린다.
//
//  왜 `GeneratePersonSegmentationRequest`(이미 `PhotoCaptureSession` 게이트가 쓰는 것)가 아닌가: 그쪽 전체 매트
//  (`pixelBuffer`)는 OS 27+ 접근자라 배포 타깃(OS 26)에서 못 꺼낸다(`PersonCoverage.swift` 머리말). 인스턴스 마스크의
//  `generateScaledMask(for:scaledToImageFrom:)` 는 OS 26 에서도 전체 해상도 마스크 픽셀 버퍼를 준다.
//
//  좌표: 마스크 픽셀 버퍼는 입력 이미지와 같은 방향(행 0 = 위). `alpha(atImagePoint:)` 는 **이미지 픽셀 좌표, 좌상단
//  원점**을 받아 0...1 을 돌려준다 — `PhotoSplatBuilder` 가 `image.sample(imgPx)` 에 넣는 그 좌표 그대로다
//  (Vision `pixel(at:)`/`NormalizedPoint` 경로의 좌하단 원점 함정과 무관).
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

    /// `PhotoSplatBuilder.build(personAlpha:)` 에 그대로 넘길 클로저.
    public var sampler: @Sendable (SIMD2<Float>) -> Float { { self.alpha(atImagePoint: $0) } }

    /// 전면 컷에서 마스크를 만든다. 사람을 못 찾으면(또는 Vision 실패) nil — 호출자는 마스크 없이 진행한다.
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
