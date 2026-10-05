//
//  CoursonaSplat.swift
//  CoursonaSplat
//
//  얼굴면 밖 입체감(가우시안 스플랫) 모듈 — 신규(TechPRD §6.6). 학습 없음, 바인딩 + 초기화만.
//  C5 에서 채운다. 지금은 모듈 경계만 선언한다(T-002).
//
//  계획된 타입(C5):
//    SplatBinder        얼굴면 밖 삼각형에 스플랫(≤60k) 바인딩
//    SplatInitializer   색·불투명도 초기화(관측 텍셀 또는 영역별 기본색)
//    SplatFile          splats.bin(magic CSP1) 직렬화
//    GPUSplatBridge     GaussianSplatResource.BufferResource 브리지, 시뮬레이터 고스트 폴백
//

import Foundation
import CoursonaCore

public enum CoursonaSplatPlaceholder {
    public static let maxSplatCount = 60_000
}
