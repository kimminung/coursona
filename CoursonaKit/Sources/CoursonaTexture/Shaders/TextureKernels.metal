//
//  TextureKernels.metal
//  ChosangTexture
//
//  M4 T-401/T-402/T-406 GPU 커널. `TextureBuilder` 의 CPU 참조 구현(`sample`, `TextureFill.bilateral`)과 **같은 수식**이어야 한다 —
//  256² 패리티 테스트가 지킨다. 런타임에 소스를 컴파일한다(SwiftPM 리소스 `.copy("Shaders")`, `MetalTextureBackend`).
//
//  accumulateTexels: 텍셀(부표본 n×n) → 컷마다 가시성(투영·cos·자기 가림·캡처 깊이)·가중치·색(탈조명·뺨 보정·접합 게인·페더) 누적.
//  bilateralPass: 분리 근사 양방향 필터 한 방향.
//

#include <metal_stdlib>
using namespace metal;

struct Intrinsics { float fx, fy, cx, cy; int width, height; int pad0, pad1; };

struct ShotUniforms {
    float4x4 worldToCamera;
    float4 cameraPosition;
    float4 light;            // xyz = 광원 쪽 단위벡터, w = 주변광 비율 f (> 0 이면 탈조명)
    Intrinsics K, Kd, Ko;
    int hasDepth; int isSmile; float depthTolerance; float occlusionTolerance;
};

struct BuildUniforms {
    int size; int supersample; int grid; int lowRes;
    int shotCount; int seamGrid; float delight; int excludeMouth;
    float4 mouthUV;          // xy, z = 1 이면 유효
    float4 cheekGain;
    int bandY0; int bandRows; int pad2; int pad3;
};

// Geometry.Intrinsics.project — 카메라는 −Z 를 본다. 뒤면 false.
static inline bool project(Intrinsics K, float3 pc, thread float2 &px) {
    if (pc.z >= -1e-6f) return false;
    float z = -pc.z;
    px = float2(K.fx * pc.x / z + K.cx, -K.fy * pc.y / z + K.cy);
    return true;
}

// DepthMap.sample — 유효하지 않은 이웃 제외 쌍선형, 픽셀 중심 (x+0.5)
static inline bool sampleDepth(texture2d<float, access::read> tex, float2 p, thread float &out) {
    float2 q = p - 0.5f;
    int x0 = int(floor(q.x)), y0 = int(floor(q.y));
    int w = tex.get_width(), h = tex.get_height();
    if (x0 < 0 || y0 < 0 || x0 + 1 >= w || y0 + 1 >= h) return false;
    float fx = q.x - float(x0), fy = q.y - float(y0);
    float wts[4] = { (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
    int dx[4] = { 0, 1, 0, 1 }, dy[4] = { 0, 0, 1, 1 };
    float sum = 0, wsum = 0;
    for (int k = 0; k < 4; k++) {
        float d = tex.read(uint2(x0 + dx[k], y0 + dy[k])).x;
        if (isfinite(d) && d > 0.01f && d < 10.0f) { sum += d * wts[k]; wsum += wts[k]; }
    }
    if (wsum <= 0.25f) return false;
    out = sum / wsum;
    return true;
}

// RGBAImage.sample — 쌍선형, 픽셀 중심 (x+0.5)
static inline bool sampleColor(texture2d<float, access::read> tex, float2 p, thread float3 &out) {
    float2 q = p - 0.5f;
    int x0 = int(floor(q.x)), y0 = int(floor(q.y));
    int w = tex.get_width(), h = tex.get_height();
    if (x0 < 0 || y0 < 0 || x0 + 1 >= w || y0 + 1 >= h) return false;
    float fx = q.x - float(x0), fy = q.y - float(y0);
    float3 c00 = tex.read(uint2(x0, y0)).xyz, c10 = tex.read(uint2(x0 + 1, y0)).xyz;
    float3 c01 = tex.read(uint2(x0, y0 + 1)).xyz, c11 = tex.read(uint2(x0 + 1, y0 + 1)).xyz;
    float3 top = c00 * (1 - fx) + c10 * fx, bot = c01 * (1 - fx) + c11 * fx;
    out = top * (1 - fy) + bot * fy;
    return true;
}

static inline float bilinearGrid(device const float* grid, int L, float u, float v) {
    float fx = clamp(u * float(L) - 0.5f, 0.0f, float(L) - 1), fy = clamp((1 - v) * float(L) - 0.5f, 0.0f, float(L) - 1);
    int x0 = int(fx), y0 = int(fy), x1 = min(L - 1, x0 + 1), y1 = min(L - 1, y0 + 1);
    float tx = fx - float(x0), ty = fy - float(y0);
    float top = grid[y0 * L + x0] * (1 - tx) + grid[y0 * L + x1] * tx;
    float bot = grid[y1 * L + x0] * (1 - tx) + grid[y1 * L + x1] * tx;
    return top * (1 - ty) + bot * ty;
}

static inline float3 bilinearGain(device const float4* grid, int G, float u, float v) {
    float fx = clamp(u * float(G) - 0.5f, 0.0f, float(G) - 1), fy = clamp((1 - v) * float(G) - 0.5f, 0.0f, float(G) - 1);
    int x0 = int(fx), y0 = int(fy), x1 = min(G - 1, x0 + 1), y1 = min(G - 1, y0 + 1);
    float tx = fx - float(x0), ty = fy - float(y0);
    float3 top = grid[y0 * G + x0].xyz * (1 - tx) + grid[y0 * G + x1].xyz * tx;
    float3 bot = grid[y1 * G + x0].xyz * (1 - tx) + grid[y1 * G + x1].xyz * tx;
    return top * (1 - ty) + bot * ty;
}

kernel void accumulateTexels(device const int* triID [[buffer(0)]],
                             device const ushort2* bary [[buffer(1)]],
                             device const packed_float3* positions [[buffer(2)]],
                             device const packed_float3* normals [[buffer(3)]],
                             device const float2* uvs [[buffer(4)]],
                             device const uint* indices [[buffer(5)]],
                             device const float4* gains [[buffer(6)]],
                             device const float* feather [[buffer(7)]],
                             constant BuildUniforms& U [[buffer(8)]],
                             constant ShotUniforms* shots [[buffer(9)]],
                             device float4* out [[buffer(10)]],
                             array<texture2d<float, access::read>, 8> images [[texture(0)]],
                             array<texture2d<float, access::read>, 8> depths [[texture(8)]],
                             array<texture2d<float, access::read>, 8> occl [[texture(16)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int S = U.size;
    int x = int(gid.x), yLocal = int(gid.y);
    if (x >= S || yLocal >= U.bandRows) return;
    int y = U.bandY0 + yLocal;
    if (y >= S) return;
    int n = U.supersample, G = U.grid, L = U.lowRes, SG = U.seamGrid;
    int cells = SG * SG, Lc = L * L;
    float3 acc = 0; float wsum = 0;
    for (int sy = 0; sy < n; sy++) {
        for (int sx = 0; sx < n; sx++) {
            int k = (y * n + sy) * G + (x * n + sx);
            int t = triID[k];
            if (t < 0) continue;
            uint ia = indices[t * 3], ib = indices[t * 3 + 1], ic = indices[t * 3 + 2];
            float bx = float(bary[k].x) / 65535.0f, by = float(bary[k].y) / 65535.0f;
            float3 b = float3(bx, by, max(0.0f, 1 - bx - by));
            float3 pos = float3(positions[ia]) * b.x + float3(positions[ib]) * b.y + float3(positions[ic]) * b.z;
            float3 nrm = normalize(float3(normals[ia]) * b.x + float3(normals[ib]) * b.y + float3(normals[ic]) * b.z);
            float2 uv = uvs[ia] * b.x + uvs[ib] * b.y + uvs[ic] * b.z;
            for (int s = 0; s < U.shotCount; s++) {
                constant ShotUniforms& c = shots[s];
                if (c.isSmile && U.excludeMouth && U.mouthUV.z > 0.5f && length(uv - U.mouthUV.xy) < 0.12f) continue;
                float4 pc4 = c.worldToCamera * float4(pos, 1);
                float3 pc = pc4.xyz / pc4.w;
                float2 px;
                if (!project(c.K, pc, px)) continue;
                if (px.x < 1 || px.y < 1 || px.x >= float(c.K.width - 1) || px.y >= float(c.K.height - 1)) continue;
                float3 viewDir = normalize(c.cameraPosition.xyz - pos);
                float cosv = dot(nrm, viewDir);
                if (cosv <= 0.3f) continue;
                float zc = -pc.z;
                float2 po; float zr;
                if (project(c.Ko, pc, po) && sampleDepth(occl[s], po, zr) && zc > zr + c.occlusionTolerance) continue;
                float wd = 1;
                if (c.hasDepth) {
                    float2 pd; float captured;
                    // 깊이 맵이 있는데 깊이가 없는 픽셀 = 배경 → 버린다 (CPU 와 동일)
                    if (!(project(c.Kd, pc, pd) && sampleDepth(depths[s], pd, captured))) continue;
                    float dz = fabs(captured - zc);
                    if (dz >= 2 * c.depthTolerance) continue;
                    wd = exp(-(dz * dz) / (c.depthTolerance * c.depthTolerance));
                }
                float3 col;
                if (!sampleColor(images[s], px, col)) continue;
                float ex = min(px.x, float(c.K.width) - px.x) / float(c.K.width), ey = min(px.y, float(c.K.height) - px.y) / float(c.K.height);
                float edge = min(1.0f, min(ex, ey) / 0.08f);
                float w = cosv * cosv * cosv * edge * wd;
                float shade = 1;
                if (c.light.w > 0) shade = c.light.w + (1 - c.light.w) * max(0.0f, dot(nrm, c.light.xyz));
                float fe = bilinearGrid(feather + s * Lc, L, uv.x, uv.y);
                if (fe <= 0) continue;
                float inv = 1 / max(0.25f, shade);
                float f = 1 + (inv - 1) * U.delight;
                float3 g = bilinearGain(gains + s * cells, SG, uv.x, uv.y);
                float3 cc = min(float3(1), col * f * U.cheekGain.xyz) * g;
                float ww = w * fe;
                acc += cc * ww; wsum += ww;
            }
        }
    }
    int idx = yLocal * S + x;
    out[idx] = wsum > 0 ? float4(min(float3(1), acc / wsum), wsum) : float4(0);
}

struct BilateralUniforms { int size; int horizontal; int radius; float sigmaSpace; float sigmaColor; int pad0, pad1, pad2; };

kernel void bilateralPass(device const float4* src [[buffer(0)]],
                          device float4* dst [[buffer(1)]],
                          device const uchar* apply [[buffer(2)]],
                          constant BilateralUniforms& U [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
    int S = U.size;
    int x = int(gid.x), y = int(gid.y);
    if (x >= S || y >= S) return;
    int i = y * S + x;
    float4 c0 = src[i];
    if (!apply[i]) { dst[i] = c0; return; }
    float inv2c = 1 / (2 * U.sigmaColor * U.sigmaColor);
    float3 acc = c0.xyz; float ws = 1;
    for (int d = 1; d <= U.radius; d++) {
        float sw = exp(-float(d * d) / (2 * U.sigmaSpace * U.sigmaSpace));
        for (int sgn = -1; sgn <= 1; sgn += 2) {
            int xx = U.horizontal ? x + d * sgn : x, yy = U.horizontal ? y : y + d * sgn;
            if (xx < 0 || yy < 0 || xx >= S || yy >= S) continue;
            int j = yy * S + xx;
            if (!apply[j]) continue;
            float3 c = src[j].xyz;
            float3 dd = c - c0.xyz;
            float w = sw * exp(-dot(dd, dd) * inv2c);
            acc += c * w; ws += w;
        }
    }
    dst[i] = float4(acc / ws, c0.w);
}
