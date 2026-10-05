//
//  DepthCoverage.swift
//  CoursonaCapture
//
//  T-301(C3): A 등급 저장 전 "5/5 깊이 검증" — 필수 5컷(정면·좌·우·위·미소) 전부 깊이가 있어야
//  `SilhouetteFitter`(F4)가 두상·귀·목을 제대로 당길 수 있다. TrueDepth 깊이는 색 프레임과 주기가 달라
//  평균에 쓴 프레임 중 한 번도 못 걸릴 수 있다(`FaceCaptureSession` 참고) — "찍었다" 와 "깊이가 있다" 는 다르다.
//  선택 컷(눈 감기·입 벌림)은 검사하지 않는다 — F7(`UserShapeDeltas`)은 ARKit 메시 정점만 쓰고 깊이를 보지 않는다.
//

import CoursonaCore

public struct DepthCoverageReport: Sendable, Equatable {
    public var missing: [ShotKind]
    public var isComplete: Bool { missing.isEmpty }
    /// 사용자에게 보여줄 문장. 다 있으면 nil.
    public var message: String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.title).joined(separator: "·")
        return "\(names) 컷에 깊이 정보가 없습니다 — 얼굴을 30–60cm 거리에 두고 다시 찍어 주세요"
    }
}

public enum DepthCoverage {
    /// 필수 컷(선택 2컷 제외) 중 깊이가 없는 것을 찾는다. 그 kind 가 번들에 아예 없으면(아직 안 찍음) 포함하지 않는다 —
    /// "찍었는데 깊이가 없다" 만 신경 쓴다. 아직 안 찍은 컷은 `CaptureGuide` 가 따로 안내한다.
    public static func check(_ bundle: CaptureBundle) -> DepthCoverageReport {
        let missing = bundle.shots
            .filter { !$0.kind.isOptional && $0.depth == nil }
            .map(\.kind)
        return DepthCoverageReport(missing: missing)
    }
}
