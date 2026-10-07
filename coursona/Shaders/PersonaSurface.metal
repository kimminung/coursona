//
//  PersonaSurface.metal
//  coursona
//
//  Persona 재현 에셋(헤어·셔츠) 표면 셰이더 — Tasks.md D-310(presence·프레넬) · D-304(셔츠 하단 페이드) · D-303(헤어 실루엣 마스크).
//  Swift 쪽 래퍼: CoursonaRig/PersonaSurfaceShader.swift. 앱 타깃에서 컴파일돼 기본 Metal 라이브러리에 들어간다
//  (RealityKit.h 는 런타임 소스 컴파일로는 못 찾는다).
//
//  입력 규약
//    uv0                 렌더 UV(텍스처). RealityKit 이 USD 의 V 를 뒤집어 읽으므로 샘플할 때 1 − v.
//    uv1                 (presence, height01) — 앱이 bust 공간 정점으로 구움(AssetContract §5, BustEntity.bakePresenceUV1).
//    custom_parameter    x = 프레넬 강도, y·z = 하단 페이드 시작·끝(height01), w = 기본 불투명도.
//    opacity_threshold   > 0 이면 base 텍스처 알파를 실루엣 마스크로(헤어, 0.45).
//    base_color          텍스처 × 틴트 (텍스처 없는 역할은 Swift 가 1×1 흰색을 넣는다).
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

constexpr sampler coursonaSampler(address::repeat, filter::linear, mip_filter::linear);

[[visible]]
void coursonaPersonaSurface(realitykit::surface_parameters params)
{
    auto geo = params.geometry();
    auto tex = params.textures();
    auto mc = params.material_constants();
    float4 cp = params.uniforms().custom_parameter();

    // 색: 텍스처 × 틴트
    float2 uv = geo.uv0();
    uv.y = 1.0 - uv.y;
    half4 base = tex.base_color().sample(coursonaSampler, uv);
    half3 color = base.rgb * half3(mc.base_color_tint());

    // 불투명도: 기본 × presence × 하단 페이드 × (1 − 프레넬 × edge)
    float2 data = geo.uv1();
    float presence = saturate(data.x);
    float fade = (cp.z > cp.y) ? smoothstep(cp.y, cp.z, data.y) : 1.0;
    float3 n = normalize(geo.normal());
    float3 v = normalize(geo.view_direction());
    float edge = pow(1.0 - abs(dot(n, v)), 2.0);
    float opacity = cp.w * presence * fade * (1.0 - cp.x * edge);
    // 양면(헤어 카드, faceCulling none): 뒷면은 기하 법선이 시선 반대라 조명이 꺼져 검게 나왔다(실측 2026-10-07, 머리 뒤쪽 카드가
    // 새까맣게 보임). 탄젠트 공간 법선을 뒤집어 뒷면도 앞면처럼 빛을 받게 한다.
    if (dot(n, v) < 0.0) {
        params.surface().set_normal(float3(0.0, 0.0, -1.0));
    }

    // 실루엣 마스크(헤어): 알파 ≤ threshold 는 프래그먼트 자체를 버린다 — 깊이도 안 쓰이게. opacity 를 0 으로만 두면 카드 사각형 전체가
    // 깊이를 써서 뒤의 반투명 흉상(유령 룩)이 가려져 검게 뚫려 보였다(실측 2026-10-07, 3/4 뷰 먼 쪽 볼).
    float threshold = mc.opacity_threshold();
    if (threshold > 0.0 && float(base.a) <= threshold) {
        discard_fragment();
    }

    params.surface().set_base_color(color);
    params.surface().set_opacity(half(saturate(opacity)));
    params.surface().set_roughness(half(mc.roughness_scale()));
    params.surface().set_metallic(half(mc.metallic_scale()));
}

//  흉상(Bust, `BustEntity` 의 LowLevelMesh) 유령 룩 — Tasks.md D-308 ③ 의 "오프스크린 렌더 → 가장자리 블러 → 불투명도 0.85 →
//  하단 페이드" 를 표면 셰이더 한 번으로 근사한다. LowLevelMesh 에는 uv1 이 없으니 높이는 **모델 좌표 y** 로 잰다.
//    custom_parameter    x = 프레넬 강도, y·z = 하단 페이드 시작·끝(모델 좌표 y, m), w = 기본 불투명도(0.85).
//    base_color          사진 알베도(없으면 틴트만).
[[visible]]
void coursonaPersonaBust(realitykit::surface_parameters params)
{
    auto geo = params.geometry();
    auto tex = params.textures();
    auto mc = params.material_constants();
    float4 cp = params.uniforms().custom_parameter();

    float2 uv = geo.uv0();
    uv.y = 1.0 - uv.y;
    // 흉상 색은 사진 알베도 그대로 — 틴트는 곱하지 않는다(실측 2026-10-07: 초기 피부 PBR 의 살구색 틴트(0.86,0.68,0.58)가
    // 텍스처를 올린 뒤에도 남아 있어, 틴트를 곱하면 PBR 보다 어둡고 주황빛으로 나왔다).
    half4 base = tex.base_color().sample(coursonaSampler, uv);
    half3 color = base.rgb;

    float y = geo.model_position().y;
    float fade = (cp.z > cp.y) ? smoothstep(cp.y, cp.z, y) : 1.0;
    float3 n = normalize(geo.normal());
    float3 v = normalize(geo.view_direction());
    float edge = pow(1.0 - abs(dot(n, v)), 2.0);
    float opacity = cp.w * fade * (1.0 - cp.x * edge);

    params.surface().set_base_color(color);
    params.surface().set_opacity(half(saturate(opacity)));
    params.surface().set_roughness(half(mc.roughness_scale()));
    params.surface().set_metallic(half(mc.metallic_scale()));
}
