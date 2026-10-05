//
//  UserShapeDeltasTests.swift
//  CoursonaKitTests
//
//  F7(C3, T-205): 눈 감기·입 벌림 컷이 있으면 `eyeBlinkLeft/Right`·`jawOpen` 패치 델타가 직접 치환되는지 확인한다.
//

import Testing
import simd
import CoursonaCore
import CoursonaFit
import CoursonaTexture

@Suite("F7 — 눈 감기·입 벌림 컷 직접 치환")
struct UserShapeDeltasTests {

    @Test("눈 감기·입 벌림 컷이 있으면 eyeBlink·jawOpen 패치 델타가 직접 치환된다(미소 기반 진폭 보정보다 더 정확)")
    func replacesPatchDeltasWhenOptionalShotsPresent() throws {
        let t = SyntheticTemplate.make()
        // "사용자" 턱은 템플릿 델타의 단순 배율이 아니라(그러면 미소 기반 스케일 보정이 유리해진다 — 스케일 하나로도 정답),
        // 거기에 옆으로 밀리는 변위가 더해진 **다른 모양**이다 — "템플릿 셰이프키가 실제 ARKit 과 다르다" 는 F7 의 전제 상황.
        // 스케일 보정은 템플릿 모양 하나만 늘리고 줄일 수 있어 이 옆 밀림을 설명 못 하고, F7 은 관측값을 그대로 읽어 정확하다.
        // 지그재그(부호가 정점마다 번갈아 뒤집히는) 흔들림을 더한다 — 균일한 평행이동이면 정렬(F) 단계의
        // 강체 변환이 그대로 상쇄해버려 두 방법의 차이가 드러나지 않는다(처음 시도에서 확인됨).
        var userT = t
        userT.shapeDeltas[.jawOpen] = t.shapeDeltas[.jawOpen]!.enumerated().map { i, d in
            let jitter: Float = (i % 2 == 0) ? 0.003 : -0.003
            return d * 1.5 + SIMD3<Float>(jitter, 0, 0)
        }

        var opt = SyntheticCaptureOptions(); opt.imageWidth = 640; opt.imageHeight = 480; opt.depthWidth = 640; opt.depthHeight = 480
        let withOptional = SyntheticCapture.makeBundle(template: userT, kinds: [.front, .left, .right, .up, .smile, .eyesClosed, .mouthOpen], options: opt)
        let withoutOptional = SyntheticCapture.makeBundle(template: userT, kinds: [.front, .left, .right, .up, .smile], options: opt)

        let idWith = try FaceFitter.fit(bundle: withOptional, template: t)
        let idWithout = try FaceFitter.fit(bundle: withoutOptional, template: t)

        // 직접 치환이 있으면 eyeBlinkLeft/Right 도 패치 델타로 들어온다(미소 기반 경로는 eyeBlink 를 전혀 다루지 않는다).
        #expect(idWith.patchDeltas[.eyeBlinkLeft]?.count == 1220)
        #expect(idWith.patchDeltas[.eyeBlinkRight]?.count == 1220)
        #expect(idWithout.patchDeltas[.eyeBlinkLeft] == nil)

        // jawOpen: 둘 다 결국 ×1.5 에 가깝게 복원하지만, 직접 치환(F7)이 진폭 스케일(미소 기반)보다 더 정확해야 한다.
        // patchDeltas/runtimeDeltas 는 패치(1220)만 비교한다 — truth 도 같은 길이로 자른다.
        let truth = Array(userT.shapeDeltas[.jawOpen]!.prefix(1220))
        let jawWith = idWith.patchDeltas[.jawOpen]!
        let jawWithout = idWithout.runtimeDeltas(template: t)[.jawOpen]!
        let errWith = Geometry.rms(jawWith, truth)
        let errWithout = Geometry.rms(Array(jawWithout[0..<1220]), truth)
        print("F7 직접 치환 RMS \(errWith * 1000) mm · 미소 기반 스케일 보정 RMS \(errWithout * 1000) mm")
        // 스케일 보정은 지그재그를 전혀 설명 못 해 훨씬 나쁘다(4배 이상) — F7 의 오차는 단일 컷 ARKit 캡처 자체의
        // 합성 노이즈(640×480 해상도, 다중 뷰 평균 없음) 바닥치로, 거의 다 사라지진 않지만 작다.
        #expect(errWith < errWithout / 2)
        #expect(errWith < 0.001)

        // 끄면(calibrateUserShapes = false) 선택 컷이 있어도 치환하지 않는다.
        var off = FitOptions(); off.calibrateUserShapes = false
        let idOff = try FaceFitter.fit(bundle: withOptional, template: t, options: off)
        #expect(idOff.patchDeltas[.eyeBlinkLeft] == nil)
    }

    @Test("UserShapeDeltas.patchDelta: 가중치가 임계보다 낮으면 nil")
    func returnsNilBelowMinWeight() throws {
        let t = SyntheticTemplate.make()
        let opt = SyntheticCaptureOptions()
        let bundle = SyntheticCapture.makeBundle(template: t, kinds: [.front, .eyesClosed], options: opt)
        let patch = try FacePatchSolver.solve(bundle: bundle, template: t)
        let d = UserShapeDeltas.patchDelta(for: .eyeBlinkLeft, shotKind: .eyesClosed, bundle: bundle, template: t,
                                           userPatch: patch.userPatch, alignments: patch.alignments, minWeight: 10) // 임계를 비정상적으로 높여 항상 떨어지게
        #expect(d == nil)
    }
}
