import Foundation

enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FoldUniforms {
        float fold;
        float perspective;
        float darkening;
        float shadowStrength;
        float sheen;
        float curvature;
        float blurMix;
        float blurLOD;
        float vignette;
        float edgeSoftness;
        float cornerRadius;
        float aspect;
    };

    struct BlurUniforms {
        float2 texelStep;
        float  radius;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float  along;
        float  shade;
    };

    struct FSOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex FSOut fullscreenVertex(uint vid [[vertex_id]]) {
        float2 uv = float2((vid << 1) & 2, vid & 2);
        FSOut out;
        out.uv = uv;
        out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
        return out;
    }

    fragment float4 blurFragment(FSOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant BlurUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);

        const float weights[5] = { 0.2270270270, 0.1945945946, 0.1216216216,
                                   0.0540540541, 0.0162162162 };
        const float offsets[5] = { 0.0, 1.4615384615, 3.2307692308,
                                   5.0000000000, 6.7692307692 };

        float4 sum = src.sample(s, in.uv) * weights[0];
        for (int i = 1; i < 5; ++i) {
            float2 delta = u.texelStep * offsets[i] * u.radius;
            sum += src.sample(s, in.uv + delta) * weights[i];
            sum += src.sample(s, in.uv - delta) * weights[i];
        }
        return sum;
    }

    vertex VertexOut foldVertex(uint vid [[vertex_id]],
                                constant float2 *grid [[buffer(0)]],
                                constant FoldUniforms &u [[buffer(1)]],
                                constant float3x3 &panel [[buffer(2)]]) {
        // Content position, 0–1 with y measured up from the hinge.
        float2 content = (grid[vid] + 1.0) * 0.5;

        // `panel` (FoldRenderer.panelTransform) maps the desktop onto an
        // upright, keystoned panel in screen space, also 0–1 from the hinge.
        float3 q = panel * float3(content, 1.0);
        float2 screen = q.xy / q.z;

        // A slight inward bow at mid-height while the panel is moving.
        float bow = u.curvature * 0.06 * sin(M_PI_F * u.fold) * sin(M_PI_F * content.y);
        screen.x = 0.5 + (screen.x - 0.5) * (1.0 - bow);

        VertexOut out;
        // w = q.z so the rasterizer interpolates uv perspective-correctly.
        out.position = float4((screen * 2.0 - 1.0) * q.z, 0.0, q.z);
        out.uv = float2(content.x, 1.0 - content.y);
        out.along = content.y;
        out.shade = 1.0 - u.fold * 0.12 * content.y;
        return out;
    }

    fragment float4 foldFragment(VertexOut in [[stage_in]],
                                 texture2d<float> sharp  [[texture(0)]],
                                 texture2d<float> blurred [[texture(1)]],
                                 constant FoldUniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        constexpr sampler mipSampler(filter::linear, mip_filter::linear,
                                     address::clamp_to_edge);

        float along = clamp(in.along, 0.0, 1.0);
        float flatten = u.fold * u.fold;
        float levelRamp = mix(pow(along, 1.5), 1.0, flatten);
        float mixRamp = mix(smoothstep(0.0, 0.45, along), 1.0, flatten);
        float lod = u.blurLOD * levelRamp;
        float focus = clamp(u.blurMix * mixRamp, 0.0, 1.0);
        float3 color = mix(sharp.sample(s, in.uv).rgb,
                           blurred.sample(mipSampler, in.uv, level(lod)).rgb,
                           focus);

        color *= in.shade;
        color *= 1.0 - u.darkening * u.fold;

        // The panel stays lit like the reference fold: shadow and vignette only
        // shade it, they never swallow the desktop.
        float topFall = pow(in.along, 1.6) * u.shadowStrength * u.fold * 0.4;
        color *= 1.0 - topFall;

        float2 fromCentre = in.uv - 0.5;
        fromCentre.y -= 0.12;
        float corner = clamp(dot(fromCentre * float2(1.35, 1.75),
                                 fromCentre * float2(1.35, 1.75)) * 2.4, 0.0, 1.0);
        color *= 1.0 - clamp(corner * u.vignette * u.fold * 0.5, 0.0, 1.0);

        float sweep = in.uv.y - (1.0 - u.fold * 1.7);
        float band = exp(-(sweep * sweep) / 0.02);
        color += band * u.sheen * u.fold * 0.35;

        float radius = u.cornerRadius;
        float2 q = abs(in.uv - 0.5) - (0.5 - radius);
        float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float feather = u.edgeSoftness * mix(0.35, 1.0, levelRamp)
                      * clamp(u.fold * 2.2, 0.0, 1.0);
        float edgeAlpha = 1.0 - smoothstep(-max(feather, 0.0008), 0.0, dist);

        float alpha = smoothstep(1.0, 0.94, u.fold) * edgeAlpha;
        return float4(color * alpha, alpha);
    }

    fragment float4 compositeFragment(FSOut in [[stage_in]],
                                      texture2d<float> panel [[texture(0)]],
                                      constant float &lod [[buffer(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float4 crisp = panel.sample(s, in.uv, level(0.0));
        if (lod < 0.02) { return crisp; }

        float4 soft = panel.sample(s, in.uv, level(lod));
        float towardEdge = 1.0 - clamp(crisp.a, 0.0, 1.0);
        return mix(crisp, soft, towardEdge);
    }
    """
}
