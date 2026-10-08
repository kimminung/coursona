//
//  InspectionView.swift
//  coursona
//
//  화면 5(UXPRD) — 검수. 뷰포트가 화면의 주인공(UXPRD §4)이고 컨트롤은 그 아래 얇은 바 — 포즈 세그먼트·
//  움직임/마이크 토글·품질 카드(접힘/펼침). 입체감 v3부터 머리부터 어깨까지 하나의 텍스처 메시로 항상 보이므로
//  (`BustEntity.swift` 머리말) 따로 켜고 끄는 토글이 없다. 초상(Chosang) `TemplatePreviewView.swift` 의
//  `RealityView` 패턴(엔티티는 `@Observable` 홀더에, SwiftUI 뷰 값 타입 수명 밖에 둔다)을 재사용한다 — 홀더는 거울 화면과
//  같이 쓰는 `PersonaStageHolder`(`PersonaStage.swift`).
//  자기교차("겹침") 배지는 숫자(RMS 등)를 기본 화면에 안 보여주고 "겹침 없음 ✓" 결론만 보여준다(UXPRD §4) —
//  자세히 보려면 품질 카드를 펼친다.
//

import SwiftUI
import RealityKit
import CoursonaCore
import CoursonaFace
import CoursonaRig
import CoursonaIO
import CoursonaDrive

private enum PosePreset: String, CaseIterable, Identifiable {
    case neutral = "무표정", smile = "미소", eyesClosed = "눈 감기", mouthOpen = "입 벌림", gaze = "시선"
    var id: String { rawValue }

    var weights: ArkitWeights {
        var w = ArkitWeights()
        switch self {
        case .neutral: break
        case .smile: w[.mouthSmileLeft] = 1; w[.mouthSmileRight] = 1
        case .eyesClosed: w[.eyeBlinkLeft] = 1; w[.eyeBlinkRight] = 1
        case .mouthOpen: w[.jawOpen] = 0.6
        case .gaze: w[.eyeLookOutLeft] = 0.7; w[.eyeLookInRight] = 0.7
        }
        return w
    }

    var gaze: SIMD2<Float> { self == .gaze ? SIMD2(0.7, 0) : .zero }
}

struct InspectionView: View {
    let package: CoursonaPackage
    let template: BustTemplate

    @State private var holder = PersonaStageHolder()
    @State private var pose: PosePreset = .neutral
    @State private var showQualityDetail = false
    /// 지금 포즈에서 **보이는** 캡 중 뒤집힌 삼각형 수(`BustEntity.flippedCapTriangles`) — 배지용. 포즈를 바꾸면 다시 센다.
    @State private var flippedTriangleCount: Int?
    /// 52 셰이프 각각 1.0 에서 뒤집히는 캡 삼각형의 합(숨겨진 캡 포함, Identity 런타임 델타 기준) — 빌드 품질 참고치, 품질 카드에만.
    @State private var flippedTriangleTotal: Int?
    /// 드래그로 흉상을 좌우로 돌려 디테일을 점검한다(초상 `TemplatePreviewView.swift` 의 `dragYaw` 와 같은 패턴).
    @State private var dragYaw: Float = 0
    @State private var dragStartYaw: Float = 0
    /// 입체감 v2 — Soban식 자동 움직임(숨·고개·깜빡임·시선)과 입모양 입력(마이크 / 한글 텍스트).
    @State private var motionOn = true
    /// 유령 룩(D-308) — 디자인 PRD 의 기본 룩. 텍스처가 올라간 뒤 `.task` 에서 켠다(셰이더가 없으면 자동으로 꺼진다).
    @State private var ghostLookOn = false
    @State private var micOn = false
    @State private var speechText = ""

    /// `dragYaw`(라디안)를 도 단위 슬라이더에 묶는다. 슬라이더로 바꾼 값은 다음 드래그의 시작점이 된다.
    private var yawDegrees: Binding<Double> {
        Binding(get: { Double(dragYaw) * 180 / .pi },
                set: { dragYaw = Float($0) * .pi / 180; dragStartYaw = dragYaw })
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RealityView { content in
                    holder.setup(content: content, template: template, identity: package.identity)
                    holder.apply(pose: pose.weights, gaze: pose.gaze, yaw: dragYaw, motion: motionOn)
                } update: { _ in
                    holder.apply(pose: pose.weights, gaze: pose.gaze, yaw: dragYaw, motion: motionOn)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .gesture(DragGesture().onChanged { v in dragYaw = dragStartYaw + Float(v.translation.width) * 0.01 }
                    .onEnded { _ in dragStartYaw = dragYaw })

                if let count = flippedTriangleCount {
                    StatusPill(text: count == 0 ? "겹침 없음 ✓" : "겹침 의심 \(count)곳",
                              kind: count == 0 ? .success : .warning)
                        .padding(12)
                }
                TierBadge(tier: package.manifest.tier ?? .b)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            VStack(spacing: 14) {
                Picker("포즈", selection: $pose) {
                    ForEach(PosePreset.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)

                // 드래그와 같은 yaw 를 숫자로 — 각도별 점검(5° 단위)·접근성 조작용. 드래그는 이 값을 이어서 돌린다.
                HStack(spacing: 8) {
                    Text("회전").font(.caption).foregroundStyle(.secondary)
                    Slider(value: yawDegrees, in: -90...90, step: 5)
                        .accessibilityLabel("회전 각도")
                    Text("\(Int((dragYaw * 180 / .pi).rounded()))°")
                        .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                }

                Toggle("움직임(숨·고개·깜빡임·시선)", isOn: $motionOn)

                Toggle("유령 룩(반투명·가장자리 소멸·하단 페이드)", isOn: $ghostLookOn)
                    .onChange(of: ghostLookOn) { _, on in
                        if !holder.setGhostLook(on) && on { ghostLookOn = false }
                    }

                Toggle("마이크로 입모양", isOn: $micOn)
                    .onChange(of: micOn) { _, on in holder.setMic(on) }

                HStack(spacing: 8) {
                    TextField("말해보기 — 한글 문장을 입력", text: $speechText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { holder.speak(speechText) }
                    Button("말하기") { holder.speak(speechText) }
                        .buttonStyle(.glass)
                        .disabled(speechText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                qualityCard
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .background(Color.coursonaBackground)
        .navigationTitle(package.manifest.name)
        .toolbar {
            // UXPRD 화면 5 액션 바: 저장 / 거울로 보기(화면 6, 라이브 구동).
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MirrorView(package: package, template: template)
                } label: {
                    Label("거울로 보기", systemImage: "face.smiling")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    SaveShareView(package: package)
                } label: {
                    Label("저장·보내기", systemImage: "square.and.arrow.up")
                }
            }
        }
        .onChange(of: pose) { _, _ in refreshFlippedCount() }
        .task {
            flippedTriangleTotal = computeFlippedTriangleTotal()
            // `RealityView` 의 콘텐츠 클로저(`holder.setup`, `holder.bust` 를 채운다)가 이 `.task` 보다 늦게
            // 실행될 수 있다 — 그러면 `applyTexture` 가 `bust == nil` 로 조용히 아무것도 안 하고 끝나고,
            // 재시도가 없어 사진 텍스처가 영영 안 올라가고 기본(살구색) 머티리얼만 남는다(실기기에서 재현:
            // 매번 똑같은 민무늬 얼굴). `bust` 가 생길 때까지 잠깐 기다렸다가 적용한다.
            await holder.waitForBust()
            await holder.applyTexture(package.albedo)
            // 디자인 PRD 기본 룩 — 셰이더가 없으면 false 가 돌아와 토글도 꺼진 채로 남는다.
            ghostLookOn = holder.setGhostLook(true)
            // Persona 재현 에셋(Tasks.md D 절): coursona_assets.json 이 있으면 Template.usdz 의 헤어·셔츠·눈·입을,
            // 없으면(옛 템플릿) EyesMouth.usdz 경로 — 텍스처 다음에(캡이 투명해지며 그 자리를 채운다).
            await holder.attachPersonaAssets(package: package, presence: false)   // 턴테이블 검수: 옆·뒤도 봐야 하므로 정적 존재 마스크는 끈다
            // 눈·입 에셋이 붙으면 그 캡은 투명이라 "겹침" 에서 빠진다 — 붙은 뒤에 센다.
            refreshFlippedCount()
        }
        .onDisappear { holder.setMic(false) }
    }

    private var qualityCard: some View {
        DisclosureGroup(isExpanded: $showQualityDetail) {
            if let q = package.manifest.textureQuality {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "관측 비율 %.0f%% · 채움 %.0f%% · 접합 단차 %.1f/255", q.observedRatio * 100, q.filledRatio * 100, q.seamDelta))
                    Text(String(format: "빌드 시간 %.1f초", q.buildSeconds))
                    if let count = flippedTriangleCount { Text("이 포즈에서 보이는 캡 중 뒤집힌 삼각형 \(count)개") }
                    if let total = flippedTriangleTotal { Text("셰이프별 최대치 합계 \(total)개 (숨겨진 눈·입 캡 포함, 빌드 참고치)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            } else {
                Text("품질 정보 없음").font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            HStack {
                TierBadge(tier: package.manifest.tier ?? .b)
                Text(summarySentence).font(.subheadline)
                Spacer()
            }
        }
    }

    private var summarySentence: String {
        guard let q = package.manifest.textureQuality else { return "품질 정보 없음" }
        if q.observedRatio > 0.65 { return "실제로 찍은 모습이 대부분 그대로 반영됐어요" }
        return "일부는 추정해서 채웠어요"
    }

    /// 배지: 지금 포즈 프리셋에서 실제로 보이는 캡의 뒤집힘만 센다(2026-10-08 — 이전엔 52 셰이프 합계를 포즈와 무관하게 보여줘
    /// 템플릿 자체 수치(≈250)가 "겹침 의심 249곳" 으로 늘 떠 있었고, 눈·입 에셋에 가려 보이지도 않는 캡까지 세고 있었다).
    private func refreshFlippedCount() {
        guard let bust = holder.bust else { return }
        flippedTriangleCount = bust.flippedCapTriangles(weights: pose.weights)
    }

    /// 품질 카드 참고치: 셰이프별 1.0 뒤집힘 합계 — 템플릿 델타가 아니라 이 페르소나의 런타임 델타(Identity 보정 반영)로.
    private func computeFlippedTriangleTotal() -> Int {
        var fitted = template
        if package.identity.positions.count == template.vertexCount { fitted.positions = package.identity.positions }
        fitted.shapeDeltas = package.identity.runtimeDeltas(template: template)
        let capped = CapBuilder.addingCaps(to: fitted)
        return SelfIntersectionCheck.check(capped).reduce(0) { $0 + $1.flippedTriangles }
    }
}

#Preview {
    Text("InspectionView 는 실제 CoursonaPackage 가 있어야 미리보기가 됩니다 — BuildProgressView 를 통해 확인하세요.")
        .padding()
}
