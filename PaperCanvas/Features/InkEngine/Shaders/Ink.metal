#include <metal_stdlib>
using namespace metal;

struct InkVertexIn {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct InkVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

struct InkUniforms {
    float4x4 cameraMatrix;
};

vertex InkVertexOut ink_vertex(InkVertexIn vin [[stage_in]],
                               constant InkUniforms& uniforms [[buffer(1)]]) {
    InkVertexOut out;
    out.position = uniforms.cameraMatrix * float4(vin.position, 0.0, 1.0);
    out.uv = vin.uv;
    out.color = vin.color;
    return out;
}

fragment float4 ink_fragment(InkVertexOut vin [[stage_in]]) {
    float dist = length(vin.uv);
    // Pixel-space derivative — gives ~1 screen pixel of edge AA regardless of zoom or stamp size.
    float w = fwidth(dist);
    float alpha = 1.0 - smoothstep(1.0 - w * 1.5, 1.0, dist);
    if (alpha <= 0.001) {
        discard_fragment();
    }
    float a = vin.color.a * alpha;
    return float4(vin.color.rgb * a, a);
}
