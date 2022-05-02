#include "../inc/color.hlsl"
#include "../inc/samplers.hlsl"
#include "../inc/frame_constants.hlsl"
#include "../inc/pack_unpack.hlsl"
#include "../inc/brdf.hlsl"
#include "../inc/brdf_lut.hlsl"
#include "../inc/layered_brdf.hlsl"
#include "../inc/uv.hlsl"
#include "../inc/hash.hlsl"
#include "../inc/reservoir.hlsl"
#include "restir_settings.hlsl"

[[vk::binding(0)]] Texture2D<float4> irradiance_tex;
[[vk::binding(1)]] Texture2D<float4> hit_normal_tex;
[[vk::binding(2)]] Texture2D<float4> ray_tex;
[[vk::binding(3)]] Texture2D<float4> reservoir_input_tex;
[[vk::binding(4)]] Texture2D<float4> gbuffer_tex;
[[vk::binding(5)]] Texture2D<float4> half_view_normal_tex;
[[vk::binding(6)]] Texture2D<float> half_depth_tex;
[[vk::binding(7)]] Texture2D<float4> ssao_tex;
[[vk::binding(8)]] Texture2D<float4> candidate_input_tex;
[[vk::binding(9)]] RWTexture2D<float4> reservoir_output_tex;
[[vk::binding(10)]] cbuffer _ {
    float4 gbuffer_tex_size;
    float4 output_tex_size;
    uint spatial_reuse_pass_idx;
};

uint2 reservoir_payload_to_px(uint payload) {
    return uint2(payload & 0xffff, payload >> 16);
}

[numthreads(8, 8, 1)]
void main(uint2 px : SV_DispatchThreadID) {
    const uint2 hi_px_subpixels[4] = {
        uint2(0, 0),
        uint2(1, 1),
        uint2(1, 0),
        uint2(0, 1),
    };
    const uint2 hi_px = px * 2 + hi_px_subpixels[frame_constants.frame_index & 3];
    float depth = half_depth_tex[px];

    const uint seed = frame_constants.frame_index + spatial_reuse_pass_idx * 123;
    uint rng = hash3(uint3(px, seed));

    const float2 uv = get_uv(hi_px, gbuffer_tex_size);
    const ViewRayContext view_ray_context = ViewRayContext::from_uv_and_depth(uv, depth);

    const float3 center_normal_vs = half_view_normal_tex[px].rgb;
    const float3 center_normal_ws = direction_view_to_world(center_normal_vs);
    const float center_depth = half_depth_tex[px];
    const float center_ssao = ssao_tex[px * 2].r;

    Reservoir1spp reservoir = Reservoir1spp::create();
    float p_q_sel = 0;
    float3 dir_sel = 1;
    float M_sum = 0;

    float sample_radius_offset = uint_to_u01_float(hash1_mut(rng));

    Reservoir1spp center_r = Reservoir1spp::from_raw(reservoir_input_tex[px]);

    // TODO: drive this via variance, shrink when it's low. 80 is a bit of a blur...
    const float kernel_tightness = (1 - center_ssao);
    const float max_kernel_radius =
        spatial_reuse_pass_idx == 0
        ? lerp(96.0, 32.0, kernel_tightness)
        : lerp(32.0, 8.0, kernel_tightness);

    const float2 dist_to_edge_xy = min(float2(px), output_tex_size.xy - px);
    const float allow_edge_overstep = center_r.M < 10 ? 100.0 : 1.25;
    //const float allow_edge_overstep = 1.25;
    const float2 kernel_radius = min(max_kernel_radius, dist_to_edge_xy * allow_edge_overstep);
    //const float2 kernel_radius = max_kernel_radius;

    uint sample_count = DIFFUSE_GI_USE_RESTIR
        ? (spatial_reuse_pass_idx == 0 ? 8 : 5)
        : 1;

    const uint TARGET_M = 512;

    // Scrambling angles here would be nice, but results in bad cache thrashing.
    // Quantizing the offsets results in mild cache abuse, and fixes most of the artifacts
    // (flickering near edges, e.g. under sofa in the UE5 archviz apartment scene).
    const uint2 ang_offset_seed = spatial_reuse_pass_idx == 0
        ? (px >> 3)
        : (px >> 2);

    float ang_offset = uint_to_u01_float(hash3(
        uint3(ang_offset_seed, frame_constants.frame_index * 2 + spatial_reuse_pass_idx)
    )) * M_PI * 2;

    if (!RESTIR_USE_SPATIAL) {
        sample_count = 1;
    }

    for (uint sample_i = 0; sample_i < sample_count && M_sum < TARGET_M; ++sample_i) {
        //float ang = M_PI / 2;
        float ang = (sample_i + ang_offset) * GOLDEN_ANGLE;
        float2 radius = 0 == sample_i ? 0 : float(sample_i + sample_radius_offset) * (kernel_radius / sample_count);
        int2 rpx_offset = float2(cos(ang), sin(ang)) * radius;

        const bool is_center_sample = sample_i == 0;
        //const bool is_center_sample = all(rpx_offset == 0);

        const int2 rpx = px + rpx_offset;
        Reservoir1spp r = Reservoir1spp::from_raw(reservoir_input_tex[rpx]);

        // After the ReSTIR GI paper
        r.M = min(r.M, 500);

        const uint2 spx = reservoir_payload_to_px(r.payload);

        // TODO: to recover tiny highlights, consider raymarching first, and then using the screen-space
        // irradiance value instead of this.
        float4 prev_irrad = irradiance_tex[spx];
        float visibility = 1;
        float relevance = 1;

        const int2 sample_offset = int2(px) - int2(spx);
        const float sample_dist2 = dot(sample_offset, sample_offset);
        const float3 sample_normal_vs = half_view_normal_tex[spx].rgb;

        #if DIFFUSE_GI_BRDF_SAMPLING
            const float normal_cutoff = 0.9;
        #else
            const float normal_cutoff = 0.1;
        #endif

        // Note: Waaaaaay more loose than the ReSTIR papers. Reduces noise in
        // areas of high geometric complexity. The resulting bias tends to brighten edges,
        // and we clamp that effect later. The artifacts is less prounounced normal map detail.
        // TODO: detect this first, and sharpen the threshold. The poor normal counting below
        // is a shitty take at that.
        const float normal_similarity_dot = dot(sample_normal_vs, center_normal_vs);
        if (!is_center_sample && normal_similarity_dot < normal_cutoff) {
            continue;
        }

        relevance *= normal_similarity_dot;

        const float sample_ssao = ssao_tex[spx * 2 + hi_px_subpixels[frame_constants.frame_index & 3]].r;
        relevance *= 1 - abs(sample_ssao - center_ssao);

        const float2 sample_uv = get_uv(
            spx * 2 + hi_px_subpixels[frame_constants.frame_index & 3],
            gbuffer_tex_size);
        const float sample_depth = half_depth_tex[spx];
        
        if (sample_depth == 0.0) {
            continue;
        }

        const ViewRayContext sample_ray_ctx = ViewRayContext::from_uv_and_depth(sample_uv, sample_depth);

        const float4 sample_hit_ws_and_dist = ray_tex[spx];// + float4(get_eye_position(), 0.0);
        const float3 sample_hit_ws = sample_hit_ws_and_dist.xyz;
        const float3 prev_dir_to_sample_hit_unnorm_ws = sample_hit_ws - sample_ray_ctx.ray_hit_ws();
        //const float prev_dist = length(prev_dir_to_sample_hit_unnorm_ws);
        const float prev_dist = sample_hit_ws_and_dist.w;

        // Reject hits too close to the surface
        if (!is_center_sample && !(prev_dist > 1e-8)) {
            continue;
        }

        const float3 dir_to_sample_hit_unnorm = sample_hit_ws - view_ray_context.ray_hit_ws();
        const float dist_to_sample_hit = length(dir_to_sample_hit_unnorm);
        const float3 dir_to_sample_hit = normalize(dir_to_sample_hit_unnorm);

        // Reject hits below the normal plane
        if (!is_center_sample && dot(dir_to_sample_hit, center_normal_ws) < 1e-5) {
            continue;
        }

        // Reject neighbors with vastly different depths
        if (!is_center_sample) {
            // Clamp the normal_vs.z so that we don't get arbitrarily loose depth comparison at grazing angles.
            const float depth_diff = abs(max(0.3, center_normal_vs.z) * (center_depth / sample_depth - 1.0));

            const float depth_threshold =
                spatial_reuse_pass_idx == 0
                ? 0.15
                : 0.1;

            relevance *= 1 - smoothstep(0.0, depth_threshold, depth_diff);
        }

        {
            // Raymarch to check occlusion
            if (RESTIR_SPATIAL_USE_RAYMARCH && !is_center_sample) {
        		const float3 surface_offset_vs = sample_ray_ctx.ray_hit_vs() - view_ray_context.ray_hit_vs();

                // TODO: finish the derivations, don't perspective-project for every sample.

#if 1
                // Trace towards the hit point.

                const float3 raymarch_dir_unnorm_ws = sample_hit_ws - view_ray_context.ray_hit_ws();
                const float3 raymarch_end_ws =
                    view_ray_context.ray_hit_ws()
                    // TODO: what's a good max distance to raymarch? Probably need to project some stuff
                    + raymarch_dir_unnorm_ws * min(1.0, length(surface_offset_vs) / length(raymarch_dir_unnorm_ws));
#else
                // Trace in the same direction as the reused ray.
                // More precise shadowing sometimes, but corner darkening. TODO.

                const float3 raymarch_dir_unnorm_ws = prev_dir_to_sample_hit_unnorm_ws;
                const float3 raymarch_end_ws =
                    view_ray_context.ray_hit_ws()
                    + raymarch_dir_unnorm_ws * min(min(dist_to_sample_hit, 1.0), length(surface_offset_vs)) / length(prev_dist);
#endif

                const float2 raymarch_end_uv = cs_to_uv(position_world_to_clip(raymarch_end_ws).xy);
                const float2 raymarch_len_px = (raymarch_end_uv - uv) * output_tex_size.xy;

                const uint MIN_PX_PER_STEP = 2;
                const uint MAX_TAPS = 4;

                const int k_count = min(MAX_TAPS, int(floor(length(raymarch_len_px) / MIN_PX_PER_STEP)));

                // Depth values only have the front; assume a certain thickness.
                const float Z_LAYER_THICKNESS = 0.1;

                float t_step = 1.0 / k_count;
                float t = 0.5 * t_step;
                for (int k = 0; k < k_count; ++k) {
                    const float3 interp_pos_ws = lerp(view_ray_context.ray_hit_ws(), raymarch_end_ws, t);
                    const float3 interp_pos_cs = position_world_to_clip(interp_pos_ws);

                    // TODO: the point-sampled uv (cs) could end up with a quite different depth value.
                    // TODO: consider using full-res depth
                    const float depth_at_interp = half_depth_tex.SampleLevel(sampler_nnc, cs_to_uv(interp_pos_cs.xy), 0);

                    // TODO: get this const as low as possible to get micro-shadowing
                    if (depth_at_interp > interp_pos_cs.z * 1.003) {
                        const float depth_diff = inverse_depth_relative_diff(interp_pos_cs.z, depth_at_interp);

                        // TODO, BUG: if the hit surface is emissive, this ends up casting a shadow from it,
                        // without taking the emission into consideration.

                        visibility *= smoothstep(
                            Z_LAYER_THICKNESS * 0.5,
                            Z_LAYER_THICKNESS,
                            depth_diff);

                        if (depth_diff > Z_LAYER_THICKNESS) {
                            // Going behind an object; could be sketchy.
                            relevance *= 0.2;
                        }
                    }

                    t += t_step;
                }
    		}
        }

        const float4 sample_hit_normal_ws_dot = hit_normal_tex[spx];
        const float center_to_hit_vis = -dot(sample_hit_normal_ws_dot.xyz, dir_to_sample_hit);

        float p_q = 1;
        p_q *= max(0, sRGB_to_luminance(prev_irrad.rgb));

        // Actually looks more noisy with this the N dot L when using BRDF sampling.
        // With (hemi)spherical sampling, it's fine.
        #if !DIFFUSE_GI_BRDF_SAMPLING
            p_q *= max(0, dot(dir_to_sample_hit, center_normal_ws));
            //p_q *= step(0, dot(dir_to_sample_hit, center_normal_ws));
        #endif

        float jacobian = 1;

        // Distance falloff. Needed to avoid leaks.
        //jacobian *= max(0.0, prev_dist) / max(1e-4, dist_to_sample_hit);
        jacobian *= prev_dist / dist_to_sample_hit;
        jacobian *= jacobian;

        // N of hit dot -L. Needed to avoid leaks. Without it, light "hugs" corners.
        jacobian *= clamp(center_to_hit_vis / sample_hit_normal_ws_dot.w, 0, 1e4);

        #if DIFFUSE_GI_BRDF_SAMPLING
            // N dot L. Useful for normal maps, micro detail.
            // The min(const, _) should not be here, but it prevents fireflies and brightening of edges
            // when we don't use a harsh normal cutoff to exchange reservoirs with.
            //jacobian *= min(1.2, max(0.0, prev_irrad.a) / dot(dir_to_sample_hit, center_normal_ws));
            //jacobian *= max(0.0, prev_irrad.a) / dot(dir_to_sample_hit, center_normal_ws);
        #endif

        if (is_center_sample) {
            jacobian = 1;
        }

        // Clamp neighbors give us a hit point that's considerably easier to sample
        // from our own position than from the neighbor. This can cause some darkening,
        // but prevents fireflies.
        //
        // The darkening occurs in corners, where micro-bounce should be happening instead.

        if (RTDGI_RESTIR_USE_JACOBIAN_BASED_REJECTION) {
            #if 1
                // Doesn't over-darken corners as much
                jacobian = min(jacobian, RTDGI_RESTIR_JACOBIAN_BASED_REJECTION_VALUE);
            #else
                // Slightly less noise
                if (jacobian > RTDGI_RESTIR_JACOBIAN_BASED_REJECTION_VALUE) { continue; }
            #endif
        }

        if (!(p_q > 0)) {
            continue;
        }

        const float w = p_q * r.W * r.M * jacobian * relevance;
        if (reservoir.update(w * visibility, r.payload, rng)) {
            p_q_sel = p_q;
            dir_sel = dir_to_sample_hit;
        }

        M_sum += r.M * relevance;
    }

    reservoir.M = M_sum;
    reservoir.W =
        (1.0 / max(1e-8, p_q_sel))
        * (reservoir.w_sum / max(1.0, reservoir.M));
    reservoir.W = min(reservoir.W, RESTIR_RESERVOIR_W_CLAMP);

    reservoir_output_tex[px] = reservoir.as_raw();
}
