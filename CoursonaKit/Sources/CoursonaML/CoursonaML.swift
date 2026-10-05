//
//  CoursonaML.swift
//  CoursonaML
//
//  Apple 제공 온디바이스 모델 래퍼 — 신규(TechPRD §6.10). B·C 등급(일반 카메라·사진 1장)의 의사 깊이 추정.
//  C3 에서 채운다. 지금은 모듈 경계만 선언한다(T-002).
//
//  계획된 타입(C3):
//    MonoDepthEstimator   Depth Anything V2 small(Core ML, Apple 배포, Apache-2.0) 래퍼.
//                         지연 로드·CPU 폴백, 얼굴 박스 영역만 추론(T-305).
//
//  SHARP(apple/ml-sharp)는 라이선스가 연구·비상업 전용이라 이 모듈에 넣지 않는다 — 제품 경로에서 완전히
//  분리된 Mac 전용 스파이크 타깃(`coursona-spike`, 제품 번들 제외)에서만 비교용으로 쓴다(TechPRD §6.6 스파이크, Q9).
//

import Foundation
import CoursonaCore

public enum CoursonaMLPlaceholder {
    public static let monoDepthModelName = "DepthAnythingV2SmallF16"
}
