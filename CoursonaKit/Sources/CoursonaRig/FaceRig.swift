//
//  FaceRig.swift
//  CoursonaRig
//
//  소반 8차 `FaceRig/FaceRig.swift` 이식 (T-503). 매 프레임 ARKit 공간의 목표 가중치를 만든다:
//  externalWeights(라이브) > 비셈 큐(HangulViseme) > 음량 순환 합성, + 자동 깜빡임·시선. 출력은 두 곳으로 간다:
//   • 레거시 USDZ 엔티티: 하위 `BlendShapeWeightsComponent` (이름 어댑터 적용)
//   • `BustBinding` 컴포넌트가 가리키는 `BustEntity`: `update(weights:)` (LowLevelMesh 경로)
//  레이어 합성(클립 ⊕ 라이브 ⊕ 비셈 ⊕ 깜빡임)은 `ExpressionMixer` (M5 T-505 에서 확정) — 여기서는 기본 규칙만.
//

import RealityKit
import Foundation
import simd
import CoursonaCore

public struct FaceRigComponent: Component {
    // 외부 입력 ------------------------------------------------------------------------
    /// 0…1 음량 (RMS 정규화)
    public var audioLevel: Float = 0
    public var visemeQueue: [VisemeStep] = []
    public var smile: Float = 0
    public var browUp: Float = 0
    public var autoBlink = true
    public var autoGaze = true
    /// 라이브 표정(ARKit 52). nil 이면 합성.
    public var externalWeights: ArkitWeights?
    public var externalIncludesBlink = false
    /// 클립(상황) 가중치 — 기본 레이어
    public var clipWeights: ArkitWeights?

    // 튜닝 -----------------------------------------------------------------------------
    public var speechGate: Float = 0.04
    public var jawGain: Float = 1.6
    public var syllablesPerSecond: Float = 6.0
    public var blinkInterval: ClosedRange<Float> = 2.2...5.5
    public var blinkDuration: Float = 0.14

    // 내부 상태 -------------------------------------------------------------------------
    var current: [String: Float] = [:]
    var blinkTimer: Float = Float.random(in: 1...3)
    var blinkPhase: Float = -1
    var doubleBlink = false
    var syllableTimer: Float = 0
    var autoViseme: Viseme = .A
    var queueTimer: Float = 0
    var gazeTimer: Float = 1
    var gazeTarget: SIMD2<Float> = .zero
    var gaze: SIMD2<Float> = .zero
    var isSetUp = false
    var shapeNames: Set<String> = []
    var previousViseme: Viseme = .rest
    var previousAmount: Float = 0
    /// 마지막으로 계산한 ARKit 목표 (디버그·스냅샷)
    public internal(set) var lastWeights = ArkitWeights()

    public init() {}

    public mutating func speak(text: String, secondsPerSyllable: Float = 0.16) {
        visemeQueue.append(contentsOf: HangulViseme.visemes(for: text, secondsPerSyllable: secondsPerSyllable))
    }
}

/// BustEntity 를 ECS 에서 찾기 위한 바인딩.
public struct BustBinding: Component {
    public weak var bust: BustEntity?
    public init(bust: BustEntity) { self.bust = bust }
}

/// 레이어 합성 규칙 (TechPRD §6.7). M5 에서 확정·테스트.
public enum ExpressionMixer {
    /// 가중치 = 클립 ⊕ 라이브(입·눈썹·눈 영역 100% 치환) ⊕ 비셈(입 가산, 클립 입 0.3 감쇠) ⊕ 깜빡임(max).
    public static func mix(clip: ArkitWeights?, live: ArkitWeights?, viseme: ArkitWeights?, blink: Float) -> ArkitWeights {
        var out = clip ?? .zero
        if let live {
            for s in ArkitShape.allCases where s.isMouthRegion || s.isBrowRegion || s.isEyeRegion { out[s] = live[s] }
        }
        if let viseme, !viseme.isEmpty {
            for s in ArkitShape.allCases where s.isMouthRegion { out[s] = min(1, out[s] * 0.3 + viseme[s]) }
        }
        if blink > 0 {
            out[.eyeBlinkLeft] = max(out[.eyeBlinkLeft], blink)
            out[.eyeBlinkRight] = max(out[.eyeBlinkRight], blink)
        }
        return out
    }
}

public struct FaceRigSystem: System {
    static let query = EntityQuery(where: .has(FaceRigComponent.self))

    public init(scene: RealityKit.Scene) {}

    /// 등록 (App init 에서 1회).
    @MainActor public static func register() {
        FaceRigComponent.registerComponent()
        BustBinding.registerComponent()
        FaceRigSystem.registerSystem()
    }

    public func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var rig = entity.components[FaceRigComponent.self] else { continue }
            let bust = entity.components[BustBinding.self]?.bust
            if !rig.isSetUp {
                FaceRigSystem.prepareBlendShapes(in: entity)
                rig.isSetUp = true
            }
            if rig.shapeNames.isEmpty, bust == nil { rig.shapeNames = FaceRigSystem.collectShapeNames(in: entity) }

            var live: ArkitWeights? = rig.externalWeights
            var synth = ArkitWeights()
            var legacyVisemes: [String: Float] = [:]

            // 시선
            if rig.autoGaze {
                rig.gazeTimer -= dt
                if rig.gazeTimer <= 0 {
                    rig.gazeTimer = Float.random(in: 0.8...2.8)
                    rig.gazeTarget = SIMD2(Float.random(in: -0.12...0.12), Float.random(in: -0.06...0.06))
                }
                rig.gaze += (rig.gazeTarget - rig.gaze) * min(1, dt * 18)
                if live == nil {
                    let gx = rig.gaze.x / 0.12, gy = rig.gaze.y / 0.06
                    if gx > 0 { synth[.eyeLookOutLeft] = gx; synth[.eyeLookInRight] = gx } else { synth[.eyeLookInLeft] = -gx; synth[.eyeLookOutRight] = -gx }
                    if gy > 0 { synth[.eyeLookUpLeft] = gy; synth[.eyeLookUpRight] = gy } else { synth[.eyeLookDownLeft] = -gy; synth[.eyeLookDownRight] = -gy }
                }
            }
            // 깜빡임
            var blink: Float = 0
            if rig.autoBlink && !(live != nil && rig.externalIncludesBlink) {
                rig.blinkTimer -= dt
                if rig.blinkTimer <= 0 && rig.blinkPhase < 0 {
                    rig.blinkPhase = 0
                    rig.doubleBlink = Float.random(in: 0...1) < 0.15
                }
                if rig.blinkPhase >= 0 {
                    rig.blinkPhase += dt / rig.blinkDuration
                    let p = rig.blinkPhase
                    blink = p < 0.4 ? p / 0.4 : max(0, 1 - (p - 0.4) / 0.6)
                    if p >= 1 {
                        rig.blinkPhase = -1
                        rig.blinkTimer = rig.doubleBlink ? 0.12 : Float.random(in: rig.blinkInterval)
                        rig.doubleBlink = false
                    }
                }
            }
            // 말하기 합성 (라이브 없을 때)
            var viseme = ArkitWeights()
            let level = max(0, rig.audioLevel - rig.speechGate) / max(0.001, 1 - rig.speechGate)
            let open = min(1, level * rig.jawGain)
            if live == nil {
                if !rig.visemeQueue.isEmpty {
                    rig.queueTimer += dt
                    let head = rig.visemeQueue[0]
                    let t = min(1, rig.queueTimer / max(0.01, head.duration))
                    let env = sin(Float.pi * t)
                    let amount = env * max(0.5, min(1, 0.5 + open)) * 0.95
                    let fadeIn = min(1, rig.queueTimer / 0.05)
                    var cur = ArkitVisemePreset.weights(for: head.viseme, amount: amount)
                    cur.scale(fadeIn)
                    if fadeIn < 1, rig.previousAmount > 0 { cur.add(ArkitVisemePreset.weights(for: rig.previousViseme, amount: rig.previousAmount), scale: 1 - fadeIn) }
                    let remaining = head.duration - rig.queueTimer
                    if remaining < 0.04, rig.visemeQueue.count > 1 {
                        let next = rig.visemeQueue[1]
                        cur.add(ArkitVisemePreset.weights(for: next.viseme, amount: 0.5 * amount), scale: (0.04 - remaining) / 0.04)
                    }
                    viseme.add(cur)
                    for (k, v) in head.viseme.legacyWeights { legacyVisemes[k, default: 0] += v * amount }
                    if rig.queueTimer >= head.duration {
                        rig.previousViseme = head.viseme; rig.previousAmount = amount
                        rig.queueTimer = 0; rig.visemeQueue.removeFirst()
                    }
                } else if open > 0.01 {
                    rig.syllableTimer += dt
                    if rig.syllableTimer > 1 / rig.syllablesPerSecond {
                        rig.syllableTimer = 0
                        let pool: [Viseme] = [.A, .A, .E, .O, .I, .U, .A, .E]
                        var next = pool.randomElement()!
                        if next == rig.autoViseme { next = .A }
                        rig.previousViseme = rig.autoViseme; rig.previousAmount = open * 0.85
                        rig.autoViseme = next
                    }
                    let fadeIn = min(1, rig.syllableTimer / 0.05)
                    var cur = ArkitVisemePreset.weights(for: rig.autoViseme, amount: open * 0.85)
                    cur.scale(fadeIn)
                    if fadeIn < 1 { cur.add(ArkitVisemePreset.weights(for: rig.previousViseme, amount: rig.previousAmount), scale: 1 - fadeIn) }
                    viseme.add(cur)
                    viseme.add(.jawOpen, open * 0.25)
                    for (k, v) in rig.autoViseme.legacyWeights { legacyVisemes[k, default: 0] += v * open * 0.85 }
                } else {
                    rig.previousAmount = max(0, rig.previousAmount - dt * 6)
                }
            }
            // 표정 오버라이드
            if rig.smile > 0 { synth.add(.mouthSmileLeft, rig.smile); synth.add(.mouthSmileRight, rig.smile) }
            if rig.browUp > 0 { synth.add(.browInnerUp, rig.browUp); synth.add(.browOuterUpLeft, rig.browUp * 0.7); synth.add(.browOuterUpRight, rig.browUp * 0.7) }
            if live == nil, !synth.isEmpty {
                // 합성 레이어를 "라이브처럼" 넣되 영역 치환이 아니라 가산
                var base = rig.clipWeights ?? .zero
                base.add(synth)
                live = nil
                let mixed = ExpressionMixer.mix(clip: base, live: nil, viseme: viseme, blink: blink)
                rig.lastWeights = mixed
            } else {
                rig.lastWeights = ExpressionMixer.mix(clip: rig.clipWeights, live: live, viseme: viseme, blink: blink)
            }

            if let bust {
                bust.update(weights: rig.lastWeights)
                // T-604: 시선은 (라이브든 합성이든) 최종 가중치의 eyeLook 8방향에서 바로 뽑아 눈 캡 UV 로 보낸다 —
                // `rig.gaze`(아래 레거시 경로의 각도 상태)와 달리 라이브 입력일 때도 그대로 맞는다.
                bust.applyGaze(FaceRigSystem.gazeFromWeights(rig.lastWeights))
            } else {
                var target = ShapeNameAdapter.resolve(rig.lastWeights, legacyVisemes: legacyVisemes, names: rig.shapeNames)
                target = target.mapValues { min(1, $0) }
                var next: [String: Float] = [:]
                for name in Set(rig.current.keys).union(target.keys) {
                    let goal = target[name] ?? 0, cur = rig.current[name] ?? 0
                    let isBlink = name.hasPrefix("Blink") || name.hasPrefix("eyeBlink")
                    let speed: Float = isBlink ? 60 : (goal > cur ? 22 : 14)
                    let v = cur + (goal - cur) * min(1, dt * speed)
                    if v > 0.0005 || goal > 0 { next[name] = v }
                }
                rig.current = next
                FaceRigSystem.apply(next, to: entity)
                if rig.autoGaze { FaceRigSystem.applyGaze(rig.gaze, to: entity) }
            }
            entity.components.set(rig)
        }
    }

    @MainActor
    static func prepareBlendShapes(in root: Entity) {
        root.forEachDescendant { e in
            guard let model = e.components[ModelComponent.self], e.components[BlendShapeWeightsComponent.self] == nil else { return }
            let comp = BlendShapeWeightsComponent(weightsMapping: BlendShapeWeightsMapping(meshResource: model.mesh))
            if comp.weightSet.contains(where: { !$0.weightNames.isEmpty }) { e.components.set(comp) }
        }
    }

    @MainActor public static var lastNamingDescription = "셰이프키 없음"

    @MainActor
    public static func collectShapeNames(in root: Entity) -> Set<String> {
        var names = Set<String>()
        root.forEachDescendant { e in
            guard let comp = e.components[BlendShapeWeightsComponent.self] else { return }
            for data in comp.weightSet { for full in data.weightNames {
                let short = full.split(separator: "/").last.map(String.init) ?? full
                names.insert(String(short.reversed().drop(while: { $0.isNumber }).reversed()))
            } }
        }
        if !names.isEmpty { lastNamingDescription = ShapeNameAdapter.usesArkitNames(names) ? "ARKit 52 직통 (\(names.count)개)" : "레거시 \(names.count)개 → ARKit 어댑터" }
        return names
    }

    @MainActor
    static func apply(_ values: [String: Float], to root: Entity) {
        root.forEachDescendant { e in
            guard var comp = e.components[BlendShapeWeightsComponent.self] else { return }
            for i in comp.weightSet.indices {
                var data = comp.weightSet[i]
                for (j, full) in data.weightNames.enumerated() {
                    let name = full.split(separator: "/").last.map(String.init) ?? full
                    // USD 가 중복 이름에 붙인 접미 숫자(jawOpen2 = Mouth_Inner 의 jawOpen) 제거
                    let base = String(name.reversed().drop(while: { $0.isNumber }).reversed())
                    data.weights[j] = values[name] ?? values[base] ?? 0
                }
                comp.weightSet[i] = data
            }
            e.components.set(comp)
        }
    }

    @MainActor
    static func applyGaze(_ g: SIMD2<Float>, to root: Entity) {
        root.forEachDescendant { e in
            let isEye: (Entity?) -> Bool = { $0.map { $0.name.hasSuffix("_Eye_L") || $0.name.hasSuffix("_Eye_R") || $0.name == "Eye_L" || $0.name == "Eye_R" } ?? false }
            guard isEye(e), !isEye(e.parent) else { return }
            e.orientation = simd_quatf(angle: g.x, axis: [0, 1, 0]) * simd_quatf(angle: -g.y, axis: [1, 0, 0])
        }
    }

    /// T-604: 최종(라이브든 합성이든) eyeLook 8방향 가중치 → 대략 -1...1 시선 벡터(오른쪽·아래가 양수).
    /// `BustEntity.applyGaze` 가 쓰는 단위 — 위 `applyGaze(_:to:)`(레거시 각도, `rig.gaze` 전용)와는 다르다.
    static func gazeFromWeights(_ w: ArkitWeights) -> SIMD2<Float> {
        let x = ((w[.eyeLookOutLeft] + w[.eyeLookInRight]) - (w[.eyeLookInLeft] + w[.eyeLookOutRight])) / 2
        let y = ((w[.eyeLookDownLeft] + w[.eyeLookDownRight]) - (w[.eyeLookUpLeft] + w[.eyeLookUpRight])) / 2
        return SIMD2(x, y)
    }
}

extension Entity {
    @MainActor
    public func forEachDescendant(_ body: (Entity) -> Void) {
        body(self)
        for child in children { child.forEachDescendant(body) }
    }
}
