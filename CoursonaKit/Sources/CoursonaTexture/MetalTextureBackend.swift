//
//  MetalTextureBackend.swift
//  CoursonaTexture
//
//  `Shaders/TextureKernels.metal` 의 Swift 래퍼. 커널 소스를 리소스에서 읽어 런타임에 컴파일한다(한 번, 캐시) —
//  SwiftPM 의 .metal 자동 컴파일은 `swift build`/시뮬레이터에서 들쭉날쭉해서 소스 복사(`.copy("Shaders")`)가 가장 안전했다.
//  장치가 없거나(일부 CI) 컴파일이 실패하면 `shared == nil` 이고 TextureBuilder 는 CPU 로 간다. 수식은 CPU 와 같다(256² 패리티 테스트).
//

import Foundation
import simd
import CoursonaCore
#if canImport(Metal)
import Metal

public final class MetalTextureBackend: @unchecked Sendable {
    public static let shared: MetalTextureBackend? = try? MetalTextureBackend()

    public let device: MTLDevice
    let queue: MTLCommandQueue
    let accumulatePipeline: MTLComputePipelineState
    let bilateralPipeline: MTLComputePipelineState
    public let name: String

    public enum BackendError: Error, LocalizedError {
        case noDevice, noSource, buffer(String)
        public var errorDescription: String? {
            switch self {
            case .noDevice: "Metal 장치 없음"
            case .noSource: "TextureKernels.metal 리소스를 찾을 수 없음"
            case .buffer(let s): "Metal 버퍼 생성 실패: \(s)"
            }
        }
    }

    public init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw BackendError.noDevice }
        device = d; queue = q; name = d.name
        guard let url = Bundle.module.url(forResource: "TextureKernels", withExtension: "metal", subdirectory: "Shaders")
                ?? Bundle.module.url(forResource: "TextureKernels", withExtension: "metal") else { throw BackendError.noSource }
        let source = try String(contentsOf: url, encoding: .utf8)
        let opts = MTLCompileOptions()
        opts.mathMode = .safe   // CPU 참조와의 패리티 (fast-math 끔)
        let lib = try d.makeLibrary(source: source, options: opts)
        guard let fa = lib.makeFunction(name: "accumulateTexels"), let fb = lib.makeFunction(name: "bilateralPass") else { throw BackendError.noSource }
        accumulatePipeline = try d.makeComputePipelineState(function: fa)
        bilateralPipeline = try d.makeComputePipelineState(function: fb)
    }

    // MARK: 유니폼 (Metal 구조체와 레이아웃 일치)

    struct Intrinsics { var fx: Float, fy: Float, cx: Float, cy: Float; var width: Int32, height: Int32, pad0: Int32 = 0, pad1: Int32 = 0
        init(_ k: Geometry.Intrinsics) { fx = k.fx; fy = k.fy; cx = k.cx; cy = k.cy; width = Int32(k.width); height = Int32(k.height) }
        init() { fx = 1; fy = 1; cx = 0; cy = 0; width = 1; height = 1 }
    }
    struct ShotUniforms {
        var worldToCamera: simd_float4x4
        var cameraPosition: SIMD4<Float>
        var light: SIMD4<Float>
        var K: Intrinsics, Kd: Intrinsics, Ko: Intrinsics
        var hasDepth: Int32, isSmile: Int32, depthTolerance: Float, occlusionTolerance: Float
    }
    struct BuildUniforms {
        var size: Int32, supersample: Int32, grid: Int32, lowRes: Int32
        var shotCount: Int32, seamGrid: Int32, delight: Float, excludeMouth: Int32
        var mouthUV: SIMD4<Float>
        var cheekGain: SIMD4<Float>
        var bandY0: Int32, bandRows: Int32, pad2: Int32 = 0, pad3: Int32 = 0
    }
    struct BilateralUniforms { var size: Int32, horizontal: Int32, radius: Int32; var sigmaSpace: Float, sigmaColor: Float; var pad0: Int32 = 0, pad1: Int32 = 0, pad2: Int32 = 0 }

    func makeBuffer<T>(_ array: [T], _ label: String) throws -> MTLBuffer {
        let bytes = max(1, array.count * MemoryLayout<T>.stride)
        guard let b = array.withUnsafeBytes({ raw in raw.baseAddress.map { device.makeBuffer(bytes: $0, length: bytes, options: .storageModeShared) } ?? device.makeBuffer(length: bytes, options: .storageModeShared) }) else { throw BackendError.buffer(label) }
        b.label = label
        return b
    }

    func texture(rgba img: RGBAImage) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
        desc.usage = .shaderRead; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw BackendError.buffer("image") }
        img.bytes.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 4) }
        return tex
    }

    func texture(depth d: DepthMap?) throws -> MTLTexture {
        let w = d?.width ?? 1, h = d?.height ?? 1
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { throw BackendError.buffer("depth") }
        let vals = d?.values ?? [0]
        vals.withUnsafeBytes { tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        return tex
    }

    // MARK: 3단계 누적

    public func accumulate(raster: TexelRaster, render: BustTemplate.RenderMesh, positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                           shots: [ShotContext], gains: SeamGains, feather: [[Float]], mouthUV: SIMD2<Float>?, cheekGain: SIMD3<Float>,
                           options o: TextureBuildOptions, albedo: inout [SIMD3<Float>], state: inout [UInt8], progress: (Double) -> Void) throws {
        let S = raster.size
        let L = o.lowResSize
        let ns = min(8, shots.count)
        func packed(_ a: [SIMD3<Float>]) -> [Float] { var f = [Float](); f.reserveCapacity(a.count * 3); for v in a { f.append(v.x); f.append(v.y); f.append(v.z) }; return f }
        let bTri = try makeBuffer(raster.triID, "triID")
        let bBary = try makeBuffer(raster.bary, "bary")
        let bPos = try makeBuffer(packed(positions), "positions")
        let bNrm = try makeBuffer(packed(normals), "normals")
        let bUV = try makeBuffer(render.uvs, "uvs")
        let bIdx = try makeBuffer(render.indices, "indices")
        var gainArr: [SIMD4<Float>] = []
        for s in 0..<ns { gainArr += gains.gains[s].map { SIMD4($0, 1) } }
        let bGain = try makeBuffer(gainArr, "gains")
        let bFeather = try makeBuffer(Array(feather.prefix(ns).joined()), "feather")
        var shotU: [ShotUniforms] = []
        var images: [MTLTexture] = [], depths: [MTLTexture] = [], occls: [MTLTexture] = []
        for c in shots.prefix(ns) {
            let light = (c.light.map { $0.contrast >= TextureLighting.minContrast ? SIMD4($0.towardLight, $0.ambientFraction) : SIMD4(0, 0, 0, 0) }) ?? SIMD4(0, 0, 0, 0)
            shotU.append(ShotUniforms(worldToCamera: c.worldToCamera, cameraPosition: SIMD4(c.cameraPosition, 1), light: light,
                                      K: Intrinsics(c.K), Kd: c.Kd.map(Intrinsics.init) ?? Intrinsics(), Ko: Intrinsics(c.Ko),
                                      hasDepth: c.depth != nil ? 1 : 0, isSmile: c.isSmile ? 1 : 0, depthTolerance: o.depthTolerance, occlusionTolerance: o.occlusionTolerance))
            images.append(try texture(rgba: c.image)); depths.append(try texture(depth: c.depth)); occls.append(try texture(depth: c.occlusion))
        }
        let bShots = try makeBuffer(shotU, "shots")
        let bandRows = max(16, min(S, (1 << 20) / S))
        guard let bOut = device.makeBuffer(length: bandRows * S * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else { throw BackendError.buffer("out") }
        var y0 = 0
        while y0 < S {
            let rows = min(bandRows, S - y0)
            var U = BuildUniforms(size: Int32(S), supersample: Int32(raster.supersample), grid: Int32(raster.grid), lowRes: Int32(L),
                                  shotCount: Int32(ns), seamGrid: Int32(gains.grid), delight: o.delight, excludeMouth: o.excludeMouthInSmile ? 1 : 0,
                                  mouthUV: mouthUV.map { SIMD4($0.x, $0.y, 1, 0) } ?? SIMD4(0, 0, 0, 0), cheekGain: SIMD4(cheekGain, 1),
                                  bandY0: Int32(y0), bandRows: Int32(rows))
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw BackendError.buffer("command") }
            enc.setComputePipelineState(accumulatePipeline)
            enc.setBuffer(bTri, offset: 0, index: 0); enc.setBuffer(bBary, offset: 0, index: 1)
            enc.setBuffer(bPos, offset: 0, index: 2); enc.setBuffer(bNrm, offset: 0, index: 3)
            enc.setBuffer(bUV, offset: 0, index: 4); enc.setBuffer(bIdx, offset: 0, index: 5)
            enc.setBuffer(bGain, offset: 0, index: 6); enc.setBuffer(bFeather, offset: 0, index: 7)
            enc.setBytes(&U, length: MemoryLayout<BuildUniforms>.stride, index: 8)
            enc.setBuffer(bShots, offset: 0, index: 9); enc.setBuffer(bOut, offset: 0, index: 10)
            for s in 0..<8 {
                let k = min(s, ns - 1)
                enc.setTexture(images[k], index: s); enc.setTexture(depths[k], index: 8 + s); enc.setTexture(occls[k], index: 16 + s)
            }
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let grid = MTLSize(width: S, height: rows, depth: 1)
            enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            if let err = cb.error { throw err }
            let p = bOut.contents().assumingMemoryBound(to: SIMD4<Float>.self)
            for i in 0..<(rows * S) {
                let v = p[i]
                let idx = (y0 * S) + i
                if v.w > 0 { albedo[idx] = SIMD3(v.x, v.y, v.z); state[idx] = TextureFill.TexelState.observed.rawValue }
            }
            y0 += rows
            progress(Double(y0) / Double(S))
        }
    }

    // MARK: 양방향 필터

    public func bilateral(albedo: inout [SIMD3<Float>], apply: [Bool], size S: Int, sigmaSpace: Float, sigmaColor: Float) throws {
        let src4 = albedo.map { SIMD4($0, 0) }
        let bA = try makeBuffer(src4, "src"), bB = try makeBuffer(src4, "dst")
        let bApply = try makeBuffer(apply.map { $0 ? UInt8(1) : UInt8(0) }, "apply")
        let r = max(1, Int((2 * sigmaSpace).rounded()))
        for pass in 0..<2 {
            var U = BilateralUniforms(size: Int32(S), horizontal: pass == 0 ? 1 : 0, radius: Int32(r), sigmaSpace: sigmaSpace, sigmaColor: sigmaColor)
            guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { throw BackendError.buffer("command") }
            enc.setComputePipelineState(bilateralPipeline)
            enc.setBuffer(pass == 0 ? bA : bB, offset: 0, index: 0)
            enc.setBuffer(pass == 0 ? bB : bA, offset: 0, index: 1)
            enc.setBuffer(bApply, offset: 0, index: 2)
            enc.setBytes(&U, length: MemoryLayout<BilateralUniforms>.stride, index: 3)
            enc.dispatchThreads(MTLSize(width: S, height: S, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            if let err = cb.error { throw err }
        }
        let p = bA.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        for i in 0..<(S * S) where apply[i] { albedo[i] = SIMD3(p[i].x, p[i].y, p[i].z) }
    }
}
#endif
