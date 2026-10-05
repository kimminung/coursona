//
//  PersonCoverage.swift
//  CoursonaCapture
//
//  T-302(C3): B 등급 "인물 매트" 게이트. `GeneratePersonSegmentationRequest`(Vision)의 결과 전체(픽셀 버퍼)를
//  꺼내려면 이 배포 타깃(OS 26)보다 높은 `pixelBuffer` 접근자가 필요해(🧪 OS 27+) 전체 알베도 매트 저장은 아직 안 한다.
//  대신 `pixel(at:)`(OS 26 에서 이미 쓸 수 있음)로 얼굴 상자 안을 그리드 샘플링해 "이 상자가 실제로 사람으로
//  분류되는가" 를 게이트 신호로만 쓴다 — 전경·배경을 분리해 저장하는 기능은 아니다.
//
//  순수 로직(`ratio`)은 Vision 관찰 값을 클로저로 받아 합성 값으로 테스트한다. 실제 호출부(`PhotoCaptureSession`)만
//  `GeneratePersonSegmentationRequest` 를 쓴다.
//

import Foundation
import CoreGraphics

public enum PersonCoverage {
    /// 얼굴 상자(이미지 좌표, 픽셀) 안을 `grid`×`grid` 로 고르게 샘플링해 `sample`(**이미지 좌표** 점 → 0...1 마스크 값)이
    /// 0.5 를 넘는 비율을 돌려준다. 호출부가 이미지→정규화 좌표 변환(Vision 의 `NormalizedPoint(imagePoint:in:)`)을
    /// 맡는다 — 여기서 직접 `x/width` 로 정규화하면 Vision 의 좌하단 원점 규약과 안 맞는다(실측으로 확인).
    /// 상자가 비어 있으면 1(통과)로 본다 — 상자를 못 구하면 이 게이트가 막을 이유가 없다.
    public static func ratio(faceBoxImageCoords box: CGRect, grid: Int = 5, sample: (CGPoint) -> Float) -> Float {
        guard box.width > 0, box.height > 0 else { return 1 }
        var hits = 0, total = 0
        for i in 0..<grid {
            for j in 0..<grid {
                let fx = (Double(i) + 0.5) / Double(grid), fy = (Double(j) + 0.5) / Double(grid)
                let imagePoint = CGPoint(x: box.minX + box.width * fx, y: box.minY + box.height * fy)
                total += 1
                if sample(imagePoint) > 0.5 { hits += 1 }
            }
        }
        return total > 0 ? Float(hits) / Float(total) : 1
    }
}
