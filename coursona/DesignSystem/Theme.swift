//
//  Theme.swift
//  coursona
//
//  C8 UI 디자인 토큰 (`Docs/UXPRD.md` §7 색상표). 초상(Chosang)·소반(Soban) 어느 쪽에도 이런 토큰 파일이
//  없었다 — 여기서 새로 만든다. 뷰포트가 항상 주인공이고 컨트롤은 얇은 유리 캡슐이라는 원칙(UXPRD §4)에
//  맞춰, 색은 최소한(배경·표면·등급 배지 3색·성공/경고/오류)만 정의한다.
//

import SwiftUI
import CoursonaCore

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// 기본(다크) 배경 — UXPRD §7.
    static let coursonaBackground = Color(hex: 0x0B0D12)
    /// 카드·패널 표면.
    static let coursonaSurface = Color(hex: 0x14171F)
    static let coursonaTierA = Color(hex: 0x007AFF)
    static let coursonaTierB = Color(hex: 0x32ADE6)
    static let coursonaTierC = Color(hex: 0x8E8E93)
    static let coursonaSuccess = Color(hex: 0x34C759)
    static let coursonaWarning = Color(hex: 0xFF9F0A)
    static let coursonaError = Color(hex: 0xFF453A)
}

extension CaptureTier {
    /// 등급 배지 색(UXPRD §7) — A=선명한 파랑(정밀), B=하늘색(바로 가능), C=중립 회색.
    var badgeColor: Color {
        switch self {
        case .a: .coursonaTierA
        case .b: .coursonaTierB
        case .c: .coursonaTierC
        }
    }

    /// 배지에 쓰는 한 글자.
    var badgeLabel: String { rawValue.uppercased() }

    /// UXPRD §4 원칙: B·C 를 "열등한" 등급으로 말하지 않는다 — "지금 바로" vs A 의 "더 정밀하게".
    var shortPitch: String {
        switch self {
        case .a: "더 정밀하게"
        case .b: "지금 바로"
        case .c: "가장 빠르게"
        }
    }
}

/// 등급 배지(A/B/C) — 화면 1·검수·라이브러리 공통.
struct TierBadge: View {
    let tier: CaptureTier
    var filled = true

    var body: some View {
        Text(tier.badgeLabel)
            .font(.caption.bold())
            .foregroundStyle(filled ? .white : tier.badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(filled ? tier.badgeColor : tier.badgeColor.opacity(0.15))
            }
            .overlay {
                if !filled { Capsule().strokeBorder(tier.badgeColor, lineWidth: 1) }
            }
    }
}

/// 상태 점(성공/경고/오류) + 문구 — "겹침 없음 ✓" 류의 결론만 보여주는 배지(UXPRD §4: 숫자는 기본으로 숨긴다).
struct StatusPill: View {
    enum Kind { case success, warning, error }
    let text: String
    let kind: Kind
    var systemImage: String? = nil

    private var color: Color {
        switch kind {
        case .success: .coursonaSuccess
        case .warning: .coursonaWarning
        case .error: .coursonaError
        }
    }

    private var icon: String {
        if let systemImage { return systemImage }
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(color.opacity(0.18)), in: .capsule)
    }
}
