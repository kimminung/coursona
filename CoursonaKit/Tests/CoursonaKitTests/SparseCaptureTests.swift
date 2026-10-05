import Testing
import Foundation
import simd
@testable import CoursonaCore
@testable import CoursonaFit
@testable import CoursonaIO

/// T-205 희소 캡처(사진 폴백)의 결정적 기하·포맷 회귀.
@Suite("희소 캡처 (T-205)")
struct SparseCaptureTests {
    @Test("가정 FOV → 핀홀 intrinsics (60°, 1920×1080 → f ≈ 1662.8, 주점 중앙)")
    func intrinsicsFromFOV() {
        let K = SparseFaceGeometry.intrinsics(horizontalFOVDegrees: 60, width: 1920, height: 1080)
        #expect(abs(K.fx - 1662.77) < 0.1)
        #expect(K.fx == K.fy)
        #expect(K.cx == 960 && K.cy == 540)
        // 왕복: 가장자리 픽셀의 광선 각도가 FOV/2
        let edge = K.unproject(SIMD2(1920, 540), depth: 1)
        #expect(abs(atan2(edge.x, -edge.z) * 180 / .pi - 30) < 0.01)
    }

    /// 눈 윤곽 두 덩어리를 이미지 좌표로 만든다 (피사체 왼쪽 눈 = 이미지 오른쪽).
    static func syntheticKeyPoints(noseOffsetX: Float = 0) -> [LandmarkName: SIMD2<Float>] {
        func ring(_ c: SIMD2<Float>, rx: Float = 20, ry: Float = 8) -> [SIMD2<Float>] { (0..<8).map { i in let a = Float(i) / 8 * 2 * .pi; return c + SIMD2(rx * cos(a), ry * sin(a)) } }
        let right = ring(SIMD2(900, 500))   // 이미지 왼쪽 = 피사체 오른쪽
        let left = ring(SIMD2(1020, 500))   // 이미지 오른쪽 = 피사체 왼쪽
        let crest = [SIMD2<Float>(960, 520), SIMD2(960, 560), SIMD2(960 + noseOffsetX, 600)]
        let lips = [SIMD2<Float>(920, 680), SIMD2(960, 690), SIMD2(1000, 680)]
        let contour = [SIMD2<Float>(820, 500), SIMD2(960, 780), SIMD2(1100, 500)]
        // Vision 명명과 무관하게 x 로 좌우를 정하는지: 일부러 eyeA 에 피사체 오른쪽 눈을 넣는다
        return SparseFaceGeometry.keyPoints(eyeA: right, eyeB: left, nose: [], noseCrest: crest, lipsOuter: lips, contour: contour)
    }

    @Test("핵심점: 좌/우는 이미지 x 로 결정, 눈꼬리·코끝·입꼬리·턱")
    func keyPoints() {
        let k = Self.syntheticKeyPoints()
        #expect(k[.eyeLeftOuter]?.x == 1040 && k[.eyeLeftInner]?.x == 1000)
        #expect(k[.eyeRightOuter]?.x == 880 && k[.eyeRightInner]?.x == 920)
        #expect(k[.noseTip] == SIMD2(960, 600))
        #expect(k[.mouthLeft]?.x == 1000 && k[.mouthRight]?.x == 920)
        #expect(k[.chin]?.y == 780)
        let eyes = SparseFaceGeometry.eyeCenters(k)
        #expect(eyes?.left == SIMD2(1020, 500) && eyes?.right == SIMD2(900, 500))
    }

    @Test("yaw 부호는 코끝 치우침으로: 이미지 오른쪽 = 피사체 왼쪽 = +. pitch 는 Vision 부호 반전")
    func poseSign() {
        let center = Self.syntheticKeyPoints()
        #expect(SparseFaceGeometry.yawSign(center) == 0)
        let turnedLeft = Self.syntheticKeyPoints(noseOffsetX: +30)
        #expect(SparseFaceGeometry.yawSign(turnedLeft) == 1)
        let turnedRight = Self.syntheticKeyPoints(noseOffsetX: -30)
        #expect(SparseFaceGeometry.yawSign(turnedRight) == -1)
        // Vision 이 −28° 를 줘도 랜드마크가 왼쪽이면 +28
        let p = SparseFaceGeometry.pose(visionYaw: -28, visionPitch: 10, visionRoll: 3, keyPoints: turnedLeft)
        #expect(p.x == 28 && p.y == -10 && p.z == 3)
    }

    @Test("얼굴 변환 추정: 정면 눈 간격 120 px, f 1662.8 → 깊이 ≈ 0.873 m, 얼굴 +Z 가 카메라 쪽, yaw/pitch 왕복")
    func faceTransform() {
        let K = SparseFaceGeometry.intrinsics(horizontalFOVDegrees: 60, width: 1920, height: 1080)
        let k = Self.syntheticKeyPoints()
        let eyes = SparseFaceGeometry.eyeCenters(k)!
        let T = SparseFaceGeometry.estimateFaceTransform(eyeLeft: eyes.left, eyeRight: eyes.right, poseDegrees: .zero, intrinsics: K)
        let expectedZ = K.fx * SparseFaceGeometry.assumedInterpupillary / 120
        #expect(abs(expectedZ - 0.873) < 0.001)
        // 눈 중점 = 원점 + R·eyeMidpointInFace → 카메라 앞 expectedZ
        let eyeMid = Geometry.transformPoint(T, SparseFaceGeometry.eyeMidpointInFace)
        #expect(abs(-eyeMid.z - expectedZ) < 1e-3)
        // 눈 중점 픽셀 (960, 500) 은 주점(960, 540) 보다 40 px 위 → 카메라 좌표 y = +40/f·z ≈ +0.021 m, x = 0
        #expect(abs(eyeMid.x) < 1e-3 && abs(eyeMid.y - 40 / K.fy * expectedZ) < 1e-3)
        #expect(T.columns.2.z > 0.999)                               // 얼굴 +Z = 카메라 +Z (카메라를 본다)
        #expect(T.columns.0.x > 0.999)                               // 얼굴 +X(피사체 왼쪽) = 카메라 +X
        // 재투영: 눈 중점이 (960, 500) 으로 돌아온다
        let px = K.project(eyeMid)!
        #expect(abs(px.x - 960) < 0.5 && abs(px.y - 500) < 0.5)
        // yaw 30 · pitch 15 넣고 FaceCaptureSession 과 같은 식으로 읽으면 같은 값
        let T2 = SparseFaceGeometry.estimateFaceTransform(eyeLeft: eyes.left, eyeRight: eyes.right, poseDegrees: SIMD3(30, 15, 0), intrinsics: K)
        let yp = SparseFaceGeometry.yawPitch(of: T2)
        #expect(abs(yp.yaw - 30) < 0.01 && abs(yp.pitch - 15) < 0.01)
    }

    @Test("희소 컷 meta.json 왕복 + 옛 번들(필드 없음) 호환 + 희소 번들은 SparseFitter 로 (M3 T-306)")
    func metaRoundTripAndFitterRejects() throws {
        // syntheticKeyPoints() 는 1920×1080 용(픽셀이 900~1100대) 이라 intrinsics 도 그 크기로 맞춘다 — 640×480 과 섞으면
        // 주점이 멀어져 랜드마크가 다 카메라 주변부(접선에 가까운 각도)가 되고, SparseFitter 의 광선-법선 가중치가 다 걸러버린다.
        let K = SparseFaceGeometry.intrinsics(horizontalFOVDegrees: 60, width: 1920, height: 1080)
        let k = Self.syntheticKeyPoints()
        let pts = (0..<76).map { SIMD2<Float>(Float($0), Float($0) * 2) }
        // faceTransform 은 identity 가 아니라 실제 맥 캡처처럼(PhotoCaptureSession) 눈 중점·포즈에서 추정한다 —
        // identity 면 "카메라가 정면을 본다" 가 아니라 템플릿·카메라 좌표축이 그냥 같다는 뜻이라, SparseFitter 의
        // 광선-법선 가중치(T-306 다시점)가 말이 안 되는 방향을 보고 랜드마크를 버린다.
        let eyes = SparseFaceGeometry.eyeCenters(k)!
        let faceT = SparseFaceGeometry.estimateFaceTransform(eyeLeft: eyes.left, eyeRight: eyes.right, poseDegrees: .zero, intrinsics: K)
        let meta = CaptureShotMeta(kind: .front, imageFile: "shot-front.jpg", depthFile: nil, imageWidth: 1920, imageHeight: 1080, depthWidth: nil, depthHeight: nil,
                                   intrinsics: K, cameraTransform: matrix_identity_float4x4, faceTransform: faceT,
                                   faceVertices: [], blendShapes: ArkitWeights(), light: LightEstimate(), averagedFrames: 8, timestamp: 1,
                                   landmarks2D: pts, keyPoints2D: k, faceBox: CGRect(x: 10, y: 20, width: 300, height: 320), poseEstimate: SIMD3(1, 2, 3), intrinsicsEstimated: true)
        #expect(meta.isSparse)
        let data = try JSONEncoder().encode(meta)
        let back = try JSONDecoder().decode(CaptureShotMeta.self, from: data)
        #expect(back == meta)
        #expect(back.landmarkArray.count == 76 && back.landmarkArray[5] == SIMD2(5, 10))
        #expect(back.keyPoint(.noseTip) == SIMD2(960, 600))
        #expect(back.faceBox == [10, 20, 300, 320] && back.poseEstimate == [1, 2, 3] && back.intrinsicsEstimated == true)

        // 옛 meta.json (희소 필드 없음) 도 그대로 읽힌다
        let old = try JSONDecoder().decode(CaptureShotMeta.self, from: JSONEncoder().encode(
            CaptureShotMeta(kind: .left, imageFile: "a.jpg", depthFile: nil, imageWidth: 1, imageHeight: 1, depthWidth: nil, depthHeight: nil, intrinsics: K,
                            cameraTransform: matrix_identity_float4x4, faceTransform: matrix_identity_float4x4, faceVertices: [.zero], blendShapes: ArkitWeights(), light: LightEstimate(), averagedFrames: 1, timestamp: 0)))
        #expect(old.landmarks2D == nil && !old.isSparse && old.landmarkArray.isEmpty)

        // 번들 저장 → 읽기 (이미지 포함) 왕복
        let img = RGBAImage(width: 1920, height: 1080, fill: SIMD4(200, 150, 120, 255))
        let bundle = CaptureBundle(meta: CaptureBundleMeta(device: "test", sparse: true, arkitTriangleHash: nil, arkitVertexCount: 0, shots: [meta]), shots: [CaptureShot(meta: meta, image: img, depth: nil)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sparse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try CaptureBundleStore.write(bundle, to: dir)
        let read = try CaptureBundleStore.read(from: dir)
        #expect(read.meta.sparse && read.shots.count == 1 && read.shots[0].meta.landmarkArray.count == 76 && read.shots[0].image?.width == 1920 && read.shots[0].depth == nil)

        // M0–M2 에는 sparse 번들을 거부했지만, M3 부터 `FaceFitter.fit` 이 `SparseFitter`(T-306) 로 보낸다 — 8 핵심점이면 돈다
        let t = SyntheticTemplate.make()
        let id = try FaceFitter.fit(bundle: read, template: t)
        #expect(id.quality?.method == "sparse" && id.positions.count == t.vertexCount && id.scale == 1)
        // 밀집 솔버에 직접 넣으면 여전히 한국어 사유로 거부한다
        #expect(throws: FitError.self) { try FacePatchSolver.solve(bundle: read, template: t) }
        do { _ = try FacePatchSolver.solve(bundle: read, template: t) } catch let e as FitError {
            #expect(e.errorDescription?.contains("희소") == true)
        }
    }

    @Test("T-204 썸네일: 저장 시 자동 생성 · 메타에 기록 · 이미지 없이도 읽힌다 · 폴더 목록")
    func thumbnailsAndListing() throws {
        let K = SparseFaceGeometry.intrinsics(horizontalFOVDegrees: 60, width: 640, height: 480)
        var img = RGBAImage(width: 640, height: 480, fill: SIMD4(10, 20, 30, 255))
        for y in 0..<240 { for x in 0..<320 { img[x, y] = SIMD4(240, 30, 20, 255) } }   // 왼쪽 위만 붉게
        let meta = CaptureShotMeta(kind: .front, imageFile: "shot-front.jpg", depthFile: nil, imageWidth: 640, imageHeight: 480, depthWidth: nil, depthHeight: nil,
                                   intrinsics: K, cameraTransform: matrix_identity_float4x4, faceTransform: matrix_identity_float4x4,
                                   faceVertices: [], blendShapes: ArkitWeights(), light: LightEstimate(), averagedFrames: 1, timestamp: 1,
                                   landmarks2D: [SIMD2(1, 2)], keyPoints2D: [:], faceBox: .zero, poseEstimate: .zero, intrinsicsEstimated: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleMeta = CaptureBundleMeta(device: "test", sparse: true, arkitTriangleHash: nil, arkitVertexCount: 0, shots: [meta])
        let folder = root.appendingPathComponent(bundleMeta.id.uuidString)
        try CaptureBundleStore.write(CaptureBundle(meta: bundleMeta, shots: [CaptureShot(meta: meta, image: img, depth: nil)]), to: folder)

        // 썸네일 파일이 생기고 메타가 가리킨다
        let saved = try CaptureBundleStore.read(from: folder)
        let m = try #require(saved.shots.first?.meta)
        #expect(m.thumbFile == "thumb-front.jpg")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("thumb-front.jpg").path))
        let thumb = try #require(saved.shots.first?.thumbnail)
        #expect(max(thumb.width, thumb.height) == CaptureBundleStore.thumbnailMaxDimension)
        #expect(thumb.width == 256 && thumb.height == 192)
        // 축소해도 왼쪽 위는 붉고 오른쪽 아래는 어둡다 (JPEG 손실 허용)
        #expect(thumb[20, 20].x > 180 && thumb[20, 20].y < 90)
        #expect(thumb[230, 170].x < 90)

        // 원본 없이 썸네일만 읽기 (목록 화면)
        let light = try CaptureBundleStore.read(from: folder, loadImages: false)
        #expect(light.shots[0].image == nil && light.shots[0].thumbnail != nil)

        // 폴더 목록 (최신순)
        let list = CaptureBundleStore.list(in: root)
        #expect(list.count == 1 && list[0].id == bundleMeta.id && list[0].sparse)

        // `.coursonacapture` 왕복에도 썸네일이 실린다
        let zip = root.appendingPathComponent("x.coursonacapture")
        try CaptureBundleStore.archive(CaptureBundle(meta: bundleMeta, shots: [CaptureShot(meta: meta, image: img, depth: nil)]), to: zip)
        let back = try CaptureBundleStore.readArchive(zip)
        #expect(back.shots[0].thumbnail?.width == 256 && back.shots[0].meta.thumbFile == "thumb-front.jpg")
    }
}
