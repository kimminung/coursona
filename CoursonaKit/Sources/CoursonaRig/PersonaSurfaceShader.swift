//
//  PersonaSurfaceShader.swift
//  CoursonaRig
//
//  D-310/D-304: `CustomMaterial` 표면 셰이더 `coursonaPersonaSurface`(앱 타깃 `Shaders/PersonaSurface.metal`) 래퍼.
//  RealityKit 셰이더는 `<RealityKit/RealityKit.h>` 를 포함해야 해서 런타임 소스 컴파일(`makeLibrary(source:)`, SDK 헤더가
//  없다)이 아니라 **Xcode 가 앱 타깃에서 컴파일한 기본 라이브러리**(`device.makeDefaultLibrary()`)에서 함수를 찾는다.
//  패키지 테스트·CLI 처럼 그 라이브러리가 없으면 `shared == nil` 이고 호출자는 PBR 폴백을 쓴다.
//
//  셰이더 입력 규약(`CustomMaterial.custom.value`): x = 프레넬 강도, y·z = 하단 페이드 시작·끝(uv1.y = height01 구간),
//  w = 기본 불투명도. uv1 = (presence, height01) 은 `BustEntity.bakePresenceUV1` 이 bust 공간에서 굽는다.
//

import Foundation
import RealityKit
import Metal

public final class PersonaSurfaceShader: @unchecked Sendable {
    public static let functionName = "coursonaPersonaSurface"
    public static let shared: PersonaSurfaceShader? = PersonaSurfaceShader()

    public let library: MTLLibrary

    public init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        var found: MTLLibrary?
        if let lib = device.makeDefaultLibrary(), lib.makeFunction(name: Self.functionName) != nil { found = lib }
        if found == nil, let lib = try? device.makeDefaultLibrary(bundle: .main), lib.makeFunction(name: Self.functionName) != nil { found = lib }
        guard let found else { return nil }
        library = found
    }

    public var surfaceShader: CustomMaterial.SurfaceShader { .init(named: Self.functionName, in: library) }

    /// 흉상(LowLevelMesh, uv1 없음) 유령 룩 함수 — 높이를 모델 좌표 y 로 잰다. 라이브러리에 없으면 nil(옛 metallib).
    public static let bustFunctionName = "coursonaPersonaBust"
    public var bustSurfaceShader: CustomMaterial.SurfaceShader? {
        library.makeFunction(name: Self.bustFunctionName) == nil ? nil : .init(named: Self.bustFunctionName, in: library)
    }

    /// `pbr`(틴트·텍스처·거칠기·컬링)을 복사한 커스텀 머티리얼. 실패하면 nil(호출자가 PBR 그대로 쓴다).
    @MainActor
    public func makeMaterial(from pbr: PhysicallyBasedMaterial, fresnel: Float, fade: SIMD2<Float>, baseOpacity: Float, opacityThreshold: Float?) -> CustomMaterial? {
        guard var cm = try? CustomMaterial(from: pbr, surfaceShader: surfaceShader) else { return nil }
        cm.custom = .init(value: SIMD4(fresnel, fade.x, fade.y, baseOpacity))
        cm.opacityThreshold = opacityThreshold
        cm.blending = .transparent(opacity: .init(floatLiteral: 1))
        cm.faceCulling = pbr.faceCulling
        return cm
    }

    /// 흉상 피부용(D-308 ③ 근사): 프레넬 가장자리 소멸 + 모델 y `fadeY.x…fadeY.y` 구간 하단 페이드 + 기본 불투명도.
    @MainActor
    public func makeBustMaterial(from pbr: PhysicallyBasedMaterial, fresnel: Float, fadeY: SIMD2<Float>, baseOpacity: Float) -> CustomMaterial? {
        guard let shader = bustSurfaceShader, var cm = try? CustomMaterial(from: pbr, surfaceShader: shader) else { return nil }
        cm.custom = .init(value: SIMD4(fresnel, fadeY.x, fadeY.y, baseOpacity))
        cm.blending = .transparent(opacity: .init(floatLiteral: 1))
        cm.faceCulling = pbr.faceCulling
        return cm
    }
}
