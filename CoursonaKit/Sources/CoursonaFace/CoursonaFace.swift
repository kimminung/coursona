//
//  CoursonaFace.swift
//  CoursonaFace
//
//  얼굴면 완성 모듈 — 초상에는 없던 신규 모듈(TechPRD §6.4 F2·F5·F6·F8·F9).
//  분리된 눈알·입안 엔티티를 쓰지 않고, 같은 흉상 메시 안에서 눈·입 구멍을 닫는다.
//
//  구현 상태:
//    CapBuilder(F6, v0)      ✅ C1 — 눈·입 구멍을 경계(위상)로 찾아 중간 고리+중심으로 닫는다(템플릿 좌표).
//    EyeOpeningSolver(F2)    ⏳ C2 — 가상 눈알 중심·반지름(시선 UV 이동의 원점).
//    InnerBandBuilder(F5)    ⏳ C2 — 피팅된 좌표로 LidInner·LipInner·캡을 다시 닫는다(CapBuilder v1).
//    UserShapeDeltas(F7)     ⏳ C2 — 눈 감기·입 벌림 컷으로 패치 델타 치환.
//    RegionDeltaBuilder(F8)  ⏳ C2 — 띠·캡 셰이프 델타를 피팅된 눈알 중심 기준으로 재계산.
//    SelfIntersectionCheck(F9) ⏳ C2 — 자기교차 4종 검사.
//

import Foundation
import CoursonaCore
