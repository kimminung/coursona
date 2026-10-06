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
    /// 얼굴 상자(이미지 좌표, 픽셀, **좌상단 원점** — 호출부의 `box` 규약) 안을 `grid`×`grid` 로 고르게 샘플링해
    /// `sample`(이 좌상단 원점 이미지 좌표 점 → 0...1 마스크 값)의 **평균**을 돌려준다. 호출부가 이미지→정규화
    /// 좌표 변환을 맡는다 — `NormalizedPoint(imagePoint:in:)` 는 전달한 좌표를 그대로(flip 없이) 정규화하는데
    /// Vision 의 `pixel(at:)`/`ImageProcessingRequest.regionOfInterest` 규약은 **좌하단 원점**이므로, 호출부는
    /// 이 클로저 안에서 Y 를 뒤집고서 `NormalizedPoint` 를 만들어야 한다(안 그러면 세로축이 뒤집힌 위치를 샘플링한다 —
    /// `PhotoCaptureSession.analyze` 참고, RunCodeSnippet 으로 실측 확인한 회귀).
    /// 값을 0.5 로 먼저 자르고 그 비율을 세지 않고 **원값을 평균**하는 이유: 조명이 한쪽으로 치우치면 그림자 진 쪽
    /// 마스크 신뢰도가 0.5 언저리에서 흔들리는데, 이진 판정 후 비율을 내면 그 흔들림이 그대로 증폭돼(픽셀 하나하나가
    /// "사람 0" 또는 "사람 1"로 뒤집히며) 체감상 게이트가 조명 방향에 과민하게 반응한다 — 원값 평균은 그 노이즈를
    /// 자연스럽게 눌러 준다.
    /// 상자가 비어 있으면 1(통과)로 본다 — 상자를 못 구하면 이 게이트가 막을 이유가 없다.
    public static func ratio(faceBoxImageCoords box: CGRect, grid: Int = 5, sample: (CGPoint) -> Float) -> Float {
        guard box.width > 0, box.height > 0 else { return 1 }
        var sum: Float = 0, total = 0
        for i in 0..<grid {
            for j in 0..<grid {
                let fx = (Double(i) + 0.5) / Double(grid), fy = (Double(j) + 0.5) / Double(grid)
                let imagePoint = CGPoint(x: box.minX + box.width * fx, y: box.minY + box.height * fy)
                total += 1
                sum += sample(imagePoint)
            }
        }
        return total > 0 ? sum / Float(total) : 1
    }
}
