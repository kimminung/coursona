//
//  SilhouetteFitter.swift
//  CoursonaFit
//
//  T-304 실루엣 맞춤 (TechPRD §6.4-4). 좌/우/위/정면 컷의 **깊이 → 포인트 클라우드(흉상 공간)** 로 패치 밖 두상·귀·턱 밑 정점을
//  법선 방향으로 당긴다. 패치(1220)는 ARKit 메시 그대로라 고정(경계 조건), 어깨는 건드리지 않고, 목은 아래로 갈수록 감쇠.
//
//  수식 (가우스-뉴턴 · 반복마다 대응 갱신):
//      E(δ) = Σ_{i∈대응} w_i (n_i·δ_i − τ_i)²  +  λ Σ_i ‖(L δ)_i‖²  +  ε ‖δ‖²
//      δ = 전파 결과 P⁰ 로부터의 총 변위, n_i = 현재 법선, τ_i = 현재 법선 성분 + 포인트까지의 부호 거리,
//      L = 정규화 그래프 라플라시안(δ_i − 이웃 평균; 고정 이웃은 0). 대칭 양정치 → 야코비 예조건 CG(ConjugateGradient).
//      풀고 나서 |δ_i| ≤ maxPull(12 mm) × 목 가중치로 자른다.
//  대응: 정점 법선 선에서 수직 거리 ≤ 3 mm 인 포인트들의 법선 거리 — 중앙값 주변(±4 mm) 가중 평균(바깥값 억제). 카메라가 그 면을 보는
//  경우만(n·(cam − v) > 0). **두피·목 정점은 비피부 포인트를 무시**한다 — 피부 기준색(그 컷에서 패치 정점이 찍힌 픽셀 평균)과 색도가
//  먼 포인트는 머리카락·옷으로 본다. 머리카락이 덮인 두피·깃에 가린 목은 대응이 없어 전파 결과(템플릿 형상)에 머문다. 목은 λ 4배(19차).
//

import Foundation
import simd
import CoursonaCore

public struct SilhouetteOptions: Sendable, Equatable {
    public var enabled = true
    /// 정점당 최대 당김 (m)
    public var maxPull: Float = 0.012
    /// 가우스-뉴턴 반복
    public var iterations = 5
    /// 라플라시안 정규화 λ (데이터 가중치 1 기준)
    public var laplacianLambda: Float = 0.1
    /// 접선 방향 고정 μ: 정점이 자기 법선 방향으로만 움직이게 한다. 점-평면 제약은 면 안에서 미끄러지는 운동을 막지 못해
    /// 주름 한 곳의 1 mm 당김이 이웃 전체의 3–4 mm 미끄러짐이 됐다(M3 디버그, 합성 턱 밑). 0 이면 끔.
    public var tangentialStiffness: Float = 1.0
    /// 전파 위치에 머무르려는 약한 사전항 ε
    public var positionStiffness: Float = 1e-3
    /// 법선 방향 탐색 반경 (m). 실기기: 템플릿 귀가 사용자 귀에서 ~10 mm 떨어져 15 mm 로는 거의 안 잡혔다 → 20 mm (법선 일치·수직 창이 오대응을 거른다)
    public var searchRadius: Float = 0.02
    /// 법선 선에서 허용 수직 거리 (m)
    public var perpendicularRadius: Float = 0.003
    /// 깊이 픽셀 간격 (1 = 전부)
    public var pixelStride = 2
    public var excludeHairOnScalp = true
    /// 목 정점도 **피부색 포인트에만** 대응(19차). 실기기에서 목은 셔츠 깃·늘어진 머리카락 깊이 포인트에 당겨져 세로 물결(±12 mm)이 생겼다 —
    /// 그 포인트들은 목 피부가 아니다. 제외하면 그 자리는 전파 결과(템플릿 목)에 머문다.
    public var excludeNonSkinOnNeck = true
    /// 목 정점의 라플라시안 λ 배율(19차). 목은 깊이 포인트가 성기고(깃·그늘) 정점 열마다 대응이 들쭉날쭉해 λ 0.1 로는 물결이 남는다.
    public var neckLaplacianScale: Float = 10
    /// 목 정점의 최대 당김 배율(19차). 턱 밑 수염은 IR 흡수로 TrueDepth 가 잡음이 커 색으로 못 거르는 세로 주름을 만든다 — 12 → 6 mm 로 묶는다.
    public var neckMaxPullScale: Float = 0.5
    /// 피부 기준색과의 색도 거리 허용 (rg 색도 평면)
    public var skinChromaTolerance: Float = 0.06
    public var minPointsPerVertex = 3
    public var cgIterations = 100
    public var cgTolerance: Double = 1e-4
    /// 포인트 법선(깊이 맵 이웃에서 추정)과 정점 법선의 최소 코사인. 다른 면(턱 밑 주름·콧구멍·목 턱)의 포인트를 거른다 —
    /// 합성 두상의 턱 밑 접힘에서 2–3 mm 를 잘못 당기던 원인(M3 디버그).
    public var normalAgreement: Float = 0.7
    /// 포인트 법선 추정 기준선 (표면에서의 길이, m)
    public var normalBaseline: Float = 0.004
    /// 컷마다 깊이를 ARKit 메시에 정합(상수 오프셋, `DepthRegistration`). 실기기 깊이는 메시보다 ~25 mm 가까웠다.
    public var registerDepthToMesh = true
    public init() {}
}

public struct SilhouetteResult: Sendable, Equatable {
    /// 마지막 대응의 |법선 거리| 중앙값·p90 (m)
    public var residualMedian: Float
    public var residualP90: Float
    public var matchedVertices: Int
    public var movableVertices: Int
    public var points: Int
    public var hairPoints: Int
    public var shotsUsed: [ShotKind]
    /// 컷별 깊이 오프셋 (m)
    public var depthOffsets: [ShotKind: Float]
    /// 대응 정점의 |δ| 중앙값·최대 (m)
    public var pullMedian: Float
    public var pullMax: Float
    public var cgIterationsTotal: Int
    public var elapsedSeconds: Double
}

public enum SilhouetteFitter {
    /// 포인트 클라우드 (흉상 공간) + 균일 격자.
    public struct Cloud: Sendable {
        public var points: [SIMD3<Float>] = []
        /// 포인트 법선 (깊이 이웃 외적, 카메라 쪽으로 향함, 템플릿 공간)
        public var normals: [SIMD3<Float>] = []
        /// 포인트를 찍은 컷의 카메라 위치 인덱스
        var camIndex: [Int32] = []
        var isSkin: [Bool] = []
        public var cameraPositions: [SIMD3<Float>] = []
        public var shots: [ShotKind] = []
        public var hairCount = 0
        /// 컷별 깊이 오프셋 (m, `DepthRegistration`) — 적용한 값
        public var depthOffsets: [ShotKind: Float] = [:]
        let cell: Float = 0.01
        var grid: [Int64: [Int32]] = [:]

        func key(_ ix: Int, _ iy: Int, _ iz: Int) -> Int64 {
            (Int64(ix) & 0x1F_FFFF) << 42 | (Int64(iy) & 0x1F_FFFF) << 21 | (Int64(iz) & 0x1F_FFFF)
        }
        func cellOf(_ v: Float) -> Int { Int((v / cell).rounded(.down)) }
        mutating func insert(_ p: SIMD3<Float>, normal: SIMD3<Float>, cam: Int32, skin: Bool) {
            let i = Int32(points.count)
            points.append(p); normals.append(normal); camIndex.append(cam); isSkin.append(skin)
            grid[key(cellOf(p.x), cellOf(p.y), cellOf(p.z)), default: []].append(i)
        }
        /// 가장 가까운 포인트까지의 거리 (반경 `maxRadius` 안에 없으면 nil) — 진단용.
        public func nearestDistance(to v: SIMD3<Float>, maxRadius r: Float) -> Float? {
            var best = Float.greatestFiniteMagnitude
            forEachCandidate(near: v, radius: r) { k in best = min(best, simd_length_squared(points[k] - v)) }
            return best < r * r ? best.squareRoot() : nil
        }
        /// 반경 r 안의 셀을 순회.
        func forEachCandidate(near v: SIMD3<Float>, radius r: Float, _ body: (Int) -> Void) {
            let lo = SIMD3<Int>(cellOf(v.x - r), cellOf(v.y - r), cellOf(v.z - r))
            let hi = SIMD3<Int>(cellOf(v.x + r), cellOf(v.y + r), cellOf(v.z + r))
            for ix in lo.x...hi.x { for iy in lo.y...hi.y { for iz in lo.z...hi.z {
                guard let list = grid[key(ix, iy, iz)] else { continue }
                for k in list { body(Int(k)) }
            } } }
        }
    }

    /// 깊이 컷(미소 제외) → 흉상 공간 포인트 클라우드. 머리 경계상자(어깨 제외 + 3 cm) 밖은 버린다.
    public static func buildCloud(bundle: CaptureBundle, template t: BustTemplate, alignments: [ShotKind: simd_float4x4],
                                  options o: SilhouetteOptions) -> Cloud {
        var cloud = Cloud()
        let shoulders = Set(t.manifest.group(.shoulders))
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for (i, p) in t.positions.enumerated() where !shoulders.contains(i) { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        lo -= SIMD3(repeating: 0.03); hi += SIMD3(repeating: 0.03)
        let pc = t.patchCount
        let stride = max(1, o.pixelStride)

        for shot in bundle.shots where shot.kind != .smile {
            guard var depth = shot.depth, let Kd = shot.depthIntrinsics, let F = alignments[shot.kind] else { continue }
            if o.registerDepthToMesh, let reg = DepthRegistration.estimate(shot: shot, template: t) {
                depth = DepthRegistration.corrected(depth, offset: reg.offset)
                cloud.depthOffsets[shot.kind] = reg.offset
            }
            let M = F * shot.faceTransform.inverse * shot.cameraTransform      // 카메라 → 템플릿
            let Minv = M.inverse
            let camPos = SIMD3(M.columns.3.x, M.columns.3.y, M.columns.3.z)
            let camIdx = Int32(cloud.cameraPositions.count)
            cloud.cameraPositions.append(camPos)
            cloud.shots.append(shot.kind)

            // 피부 기준색: 이 컷에서 패치 정점(ARKit 메시 → 템플릿 → 카메라 → 픽셀)이 찍힌 색의 색도·밝기 평균
            var chromaRef = SIMD2<Float>(0.4, 0.33), lumRef: Float = 0.5, haveSkinRef = false
            var Ki: Geometry.Intrinsics? = nil
            if let img = shot.image {
                let K = shot.meta.intrinsics.scaled(toWidth: img.width, height: img.height)
                Ki = K
                let raw = shot.meta.faceVertexArray
                var cs = SIMD2<Float>.zero, ls: Float = 0, n: Float = 0
                if raw.count == pc {
                    var i = 0
                    while i < pc {
                        let pt = Geometry.transformPoint(F, raw[i])
                        if let px = K.project(Geometry.transformPoint(Minv, pt)), let c = img.sample(px) {
                            let sum = max(1e-3, c.x + c.y + c.z)
                            cs += SIMD2(c.x / sum, c.y / sum); ls += sum / 3; n += 1
                        }
                        i += 7
                    }
                }
                if n >= 20 { chromaRef = cs / n; lumRef = ls / n; haveSkinRef = true }
            }

            for y in Swift.stride(from: 0, to: depth.height, by: stride) {
                for x in Swift.stride(from: 0, to: depth.width, by: stride) {
                    let d = depth[x, y]
                    guard depth.isValid(d), d < 2 else { continue }
                    let pCam = Kd.unproject(SIMD2(Float(x) + 0.5, Float(y) + 0.5), depth: d)
                    let p = Geometry.transformPoint(M, pCam)
                    guard p.x >= lo.x, p.y >= lo.y, p.z >= lo.z, p.x <= hi.x, p.y <= hi.y, p.z <= hi.z else { continue }
                    // 포인트 법선: 중심 차분 외적. 기준선은 **표면에서 약 4 mm**(TrueDepth 잡음 ~1 mm 라 1–2 px 기준선의 법선은 쓸 수 없다).
                    let footprint = d / max(1, Kd.fx)                      // m / px
                    let ns = min(8, max(stride, Int((o.normalBaseline / footprint).rounded())))
                    guard x >= ns, y >= ns, x + ns < depth.width, y + ns < depth.height else { continue }
                    let dxp = depth[x + ns, y], dxm = depth[x - ns, y], dyp = depth[x, y + ns], dym = depth[x, y - ns]
                    guard depth.isValid(dxp), depth.isValid(dxm), depth.isValid(dyp), depth.isValid(dym),
                          abs(dxp - d) < 0.02, abs(dxm - d) < 0.02, abs(dyp - d) < 0.02, abs(dym - d) < 0.02 else { continue }   // 깊이 불연속 = 가장자리
                    let ex = Kd.unproject(SIMD2(Float(x + ns) + 0.5, Float(y) + 0.5), depth: dxp) - Kd.unproject(SIMD2(Float(x - ns) + 0.5, Float(y) + 0.5), depth: dxm)
                    let ey = Kd.unproject(SIMD2(Float(x) + 0.5, Float(y + ns) + 0.5), depth: dyp) - Kd.unproject(SIMD2(Float(x) + 0.5, Float(y - ns) + 0.5), depth: dym)
                    var nCam = simd_cross(ex, ey)
                    guard simd_length_squared(nCam) > 1e-16 else { continue }
                    nCam = simd_normalize(nCam)
                    if simd_dot(nCam, -pCam) < 0 { nCam = -nCam }          // 카메라 쪽으로
                    let nT = simd_normalize(Geometry.transformDirection(M, nCam))
                    var skin = true
                    if haveSkinRef, let img = shot.image, let K = Ki, let px = K.project(pCam), let c = img.sample(px) {
                        let sum = max(1e-3, c.x + c.y + c.z)
                        let chroma = SIMD2(c.x / sum, c.y / sum)
                        let lum = sum / 3
                        skin = simd_length(chroma - chromaRef) < o.skinChromaTolerance && lum > 0.35 * lumRef && lum < 1.9 * lumRef
                    }
                    if !skin { cloud.hairCount += 1 }
                    cloud.insert(p, normal: nT, cam: camIdx, skin: skin)
                }
            }
        }
        return cloud
    }

    /// 대응 찾기: `vertices`(전역 id) 각각에 대해 법선 선 위 포인트들의 부호 거리 τ(m) 또는 nil.
    /// 수직 거리 ≤ perpendicularRadius 인 포인트의 법선 거리 — 중앙값 ±4 mm 안에서 가중 평균. 카메라가 그 면을 보는 포인트만.
    public static func matchTargets(cloud: Cloud, positions pos: [SIMD3<Float>], normals: [SIMD3<Float>], vertices: [Int],
                                    scalp: Set<Int>, neck: Set<Int> = [], options o: SilhouetteOptions) -> [Float?] {
        let n = vertices.count
        var out = [Float?](repeating: nil, count: n)
        let R = o.searchRadius, pr2 = o.perpendicularRadius * o.perpendicularRadius
        let sigma2 = 2 * (o.perpendicularRadius / 2) * (o.perpendicularRadius / 2)
        var alongs: [Float] = []
        var weights: [Float] = []
        for i in 0..<n {
            let g = vertices[i]
            let v = pos[g], nn = normals[g]
            let skinOnly = (scalp.contains(g) && o.excludeHairOnScalp) || (neck.contains(g) && o.excludeNonSkinOnNeck)
            alongs.removeAll(keepingCapacity: true); weights.removeAll(keepingCapacity: true)
            cloud.forEachCandidate(near: v, radius: R) { kk in
                let w = cloud.points[kk] - v
                let along = simd_dot(w, nn)
                guard abs(along) <= R else { return }
                let perp2 = simd_length_squared(w) - along * along
                guard perp2 <= pr2 else { return }
                // 같은 면인가 (법선 일치)
                guard simd_dot(nn, cloud.normals[kk]) >= o.normalAgreement else { return }
                if skinOnly, !cloud.isSkin[kk] { return }
                // 그 컷의 카메라가 이 면을 본다
                guard simd_dot(nn, cloud.cameraPositions[Int(cloud.camIndex[kk])] - v) > 0.1 else { return }
                alongs.append(along)
                weights.append(exp(-perp2 / sigma2))
            }
            guard alongs.count >= o.minPointsPerVertex else { continue }
            let sorted = alongs.sorted()
            let med = sorted[sorted.count / 2]
            var s: Float = 0, ws: Float = 0
            for (a, w) in zip(alongs, weights) where abs(a - med) < 0.004 { s += a * w; ws += w }
            if ws > 0 { out[i] = s / ws }
        }
        return out
    }

    /// 전파된 정점(`positions`, 패치는 이미 사용자 정점)을 포인트 클라우드에 맞춘다. 깊이 컷이 없으면 nil.
    public static func fit(positions: inout [SIMD3<Float>], template t: BustTemplate, bundle: CaptureBundle,
                           alignments: [ShotKind: simd_float4x4], options fo: FitOptions) -> SilhouetteResult? {
        let o = fo.silhouette
        let start = Date()
        let cloud = buildCloud(bundle: bundle, template: t, alignments: alignments, options: o)
        guard cloud.points.count >= 500 else { return nil }
        return fit(positions: &positions, template: t, cloud: cloud, options: fo, start: start)
    }

    static func fit(positions: inout [SIMD3<Float>], template t: BustTemplate, cloud: Cloud, options fo: FitOptions, start: Date) -> SilhouetteResult? {
        let o = fo.silhouette
        let V = t.vertexCount
        let pc = t.patchCount
        guard positions.count == V else { return nil }
        let shoulders = Set(t.manifest.group(.shoulders))
        let scalp = Set(t.manifest.group(.scalp))
        let neck = Set(t.manifest.group(.neck))

        // 움직일 정점 (패치·어깨 제외, 목은 가중치 > 0.02)
        var local = [Int32](repeating: -1, count: V)
        var globalOf: [Int] = []
        var neckW: [Float] = []
        for i in pc..<V where !shoulders.contains(i) {
            let w = neck.contains(i) ? HeadPropagator.neckWeight(y: t.positions[i].y, options: fo) : 1
            guard w > 0.02 else { continue }
            local[i] = Int32(globalOf.count)
            globalOf.append(i)
            neckW.append(w)
        }
        let n = globalOf.count
        guard n > 0 else { return nil }

        // 이웃 (삼각형 인접, 전역 id)
        var adj = [[Int32]](repeating: [], count: V)
        var k = 0
        let idx = t.indices
        while k + 2 < idx.count {
            let a = Int(idx[k]), b = Int(idx[k + 1]), c = Int(idx[k + 2])
            if local[a] >= 0 || local[b] >= 0 || local[c] >= 0 {
                for (p, q) in [(a, b), (b, c), (c, a)] {
                    if !adj[p].contains(Int32(q)) { adj[p].append(Int32(q)) }
                    if !adj[q].contains(Int32(p)) { adj[q].append(Int32(p)) }
                }
            }
            k += 3
        }
        // 지역 이웃 목록: (지역 인덱스 또는 -1 = 고정) · 차수
        var nbr: [[Int32]] = [], deg: [Float] = []
        nbr.reserveCapacity(n); deg.reserveCapacity(n)
        for g in globalOf {
            nbr.append(adj[g].map { local[Int($0)] })
            deg.append(Float(max(1, adj[g].count)))
        }

        let eps = o.positionStiffness, mu = o.tangentialStiffness
        // 정점별 라플라시안 가중 λ_i (목은 배율) — E 의 평활항 Σ_i λ_i‖(Lδ)_i‖² → A = Lᵀ Λ L (대칭 유지)
        let lamV: [Float] = globalOf.map { o.laplacianLambda * (neck.contains($0) ? o.neckLaplacianScale : 1) }
        let capV: [Float] = globalOf.enumerated().map { i, g in o.maxPull * neckW[i] * (neck.contains(g) ? o.neckMaxPullScale : 1) }
        // L δ (정규화: δ_i − 이웃 평균; 고정 이웃 0)
        func applyL(_ d: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var out = d
            for i in 0..<n {
                var s = SIMD3<Float>.zero
                for j in nbr[i] where j >= 0 { s += d[Int(j)] }
                out[i] = d[i] - s / deg[i]
            }
            return out
        }
        func applyLT(_ y: [SIMD3<Float>]) -> [SIMD3<Float>] {
            var out = y
            for i in 0..<n {
                var s = SIMD3<Float>.zero
                for j in nbr[i] where j >= 0 { s += y[Int(j)] / deg[Int(j)] }
                out[i] = y[i] - s
            }
            return out
        }
        // (Lᵀ Λ L) 의 대각: λ_i + Σ_{j∈이웃} λ_j / deg_j²
        var lapDiag = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = lamV[i]
            for j in nbr[i] where j >= 0 { let dj = deg[Int(j)]; s += lamV[Int(j)] / (dj * dj) }
            lapDiag[i] = s
        }

        let P0 = positions
        var delta = [SIMD3<Float>](repeating: .zero, count: n)
        var cgTotal = 0
        var lastResiduals: [Float] = []
        var lastMatched = 0

        for iter in 0...(max(1, o.iterations)) {
            let normals = Geometry.vertexNormals(positions: positions, indices: t.indices)
            let tau = matchTargets(cloud: cloud, positions: positions, normals: normals, vertices: globalOf, scalp: scalp, neck: neck, options: o)
            var residuals: [Float] = []
            residuals.reserveCapacity(n)
            for i in 0..<n { if let v = tau[i] { residuals.append(abs(v)) } }
            lastResiduals = residuals
            lastMatched = residuals.count
            if iter == o.iterations { break }   // 마지막 패스는 잔차 측정만
            guard residuals.count >= 10 else { break }

            // 선형계: A δ = b
            var dataW = [Float](repeating: 0, count: n)
            var nrm = [SIMD3<Float>](repeating: .zero, count: n)
            var b = [SIMD3<Float>](repeating: .zero, count: n)
            var diag = [SIMD3<Float>](repeating: .zero, count: n)
            for i in 0..<n {
                let g = globalOf[i]
                nrm[i] = normals[g]
                if let tv = tau[i] {
                    let w = neckW[i]
                    dataW[i] = w
                    let target = simd_dot(nrm[i], delta[i]) + tv
                    b[i] = nrm[i] * (w * target)
                }
                let nn = nrm[i]
                let n2 = SIMD3(nn.x * nn.x, nn.y * nn.y, nn.z * nn.z)
                // 대각: 데이터 w·n² + 접선 고정 μ·(1 − n²) + 라플라시안 + ε
                diag[i] = n2 * dataW[i] + (SIMD3(repeating: 1) - n2) * mu + SIMD3(repeating: lapDiag[i] + eps)
            }
            let sol = ConjugateGradient.solve(b: b, x0: delta, diagonal: diag, maxIterations: o.cgIterations, tolerance: o.cgTolerance) { x in
                var lx = applyL(x)
                for i in 0..<n { lx[i] *= lamV[i] }
                var out = applyLT(lx)
                for i in 0..<n {
                    let along = simd_dot(nrm[i], x[i])
                    let normalPart = nrm[i] * along
                    out[i] = out[i] + x[i] * eps + (x[i] - normalPart) * mu + normalPart * dataW[i]
                }
                return out
            }
            cgTotal += sol.iterations
            delta = sol.x
            for i in 0..<n {
                let cap = capV[i]
                let l = simd_length(delta[i])
                if l > cap { delta[i] *= cap / l }
                positions[globalOf[i]] = P0[globalOf[i]] + delta[i]
            }
        }

        let sortedRes = lastResiduals.sorted()
        var pulls: [Float] = []
        for i in 0..<n where simd_length_squared(delta[i]) > 0 { pulls.append(simd_length(delta[i])) }
        pulls.sort()
        return SilhouetteResult(residualMedian: sortedRes.isEmpty ? 0 : sortedRes[sortedRes.count / 2],
                                residualP90: sortedRes.isEmpty ? 0 : sortedRes[min(sortedRes.count - 1, sortedRes.count * 9 / 10)],
                                matchedVertices: lastMatched, movableVertices: n, points: cloud.points.count, hairPoints: cloud.hairCount,
                                shotsUsed: cloud.shots, depthOffsets: cloud.depthOffsets,
                                pullMedian: pulls.isEmpty ? 0 : pulls[pulls.count / 2], pullMax: pulls.last ?? 0,
                                cgIterationsTotal: cgTotal, elapsedSeconds: Date().timeIntervalSince(start))
    }
}
