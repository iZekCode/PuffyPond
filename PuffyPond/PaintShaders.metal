#include <metal_stdlib>
using namespace metal;

// Wet paint simulated on the GPU.
// paint texture: rgb = pigment color, a = paint thickness (0…1).
// flow texture:  xy = velocity in texels/s (y points down the texture), z = wetness (0…1, up to 3 for
//                runny watercolor that keeps blooming outward), w = bristle relief.

struct PaintStamp {
    float4 segment;   // a.xy, b.xy in world units
    float4 color;     // rgb, kind (0 = paint, 1 = erase)
    float4 brush;     // radius, amount, dryness, seed
    float4 motion;    // brush velocity (texels/s) xy, erase rate, push
    float4 shape;     // nib angle, nib aspect (1 = round), bristles (0…1), watery (0…1)
    float4 extra;     // palette knife (0…1), unused…
};

struct PaintParams {
    float4 frame;     // left, top (world), world units per texel, dt
    float4 size;      // width, height, stamp count, clear
    float4 tune;      // dry rate, leveling, velocity damping, gravity
    float4 shade;     // normal strength, cavity darkening, bristle relief, paint body
    float4 canvas;    // weave thread pitch (texels), weave depth under thin paint
};

static float hash21(int2 p) {
    uint h = uint(p.x) * 374761393u + uint(p.y) * 668265263u;
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= h >> 16;
    return float(h & 0xFFFFu) / 65535.0 * 2.0 - 1.0;
}

/// Smooth value noise in -1…1.
static float noise(float2 p) {
    int2 i = int2(floor(p));
    float2 f = p - floor(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + int2(1, 0)), c = hash21(i + int2(0, 1)), d = hash21(i + int2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// One simulation step: advect paint along its velocity, level and blend wet paint,
/// let thick paint sag, dry, then apply this frame's brush dabs and starfish scrubs.
/// flow.w holds the bristle relief: the brush texture of the last stroke that passed, which is carried
/// along with the paint but never leveled, so strokes keep their texture instead of puffing up.
kernel void paintStep(texture2d<float, access::sample> paintIn [[texture(0)]],
                      texture2d<float, access::sample> flowIn [[texture(1)]],
                      texture2d<float, access::write> paintOut [[texture(2)]],
                      texture2d<float, access::write> flowOut [[texture(3)]],
                      constant PaintParams &P [[buffer(0)]],
                      constant PaintStamp *stamps [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uint(P.size.x) || gid.y >= uint(P.size.y)) return;
    if (P.size.w > 0.5) {
        paintOut.write(float4(1, 1, 1, 0), gid);
        flowOut.write(float4(0), gid);
        return;
    }
    constexpr sampler lin(coord::pixel, filter::linear, address::clamp_to_edge);
    const float dt = P.frame.w;
    const float2 pos = float2(gid) + 0.5;

    // Semi-Lagrangian advection: wet paint is carried along by its own flow. Resting paint is read
    // exactly (no resampling), otherwise bilinear filtering would slowly blur every texture away.
    float4 f0 = flowIn.sample(lin, pos);
    float2 shift = f0.xy * saturate(f0.z) * dt;
    float2 from = length(shift) > 0.05 ? pos - shift : pos;
    float4 p = paintIn.sample(lin, from);
    float4 f = flowIn.sample(lin, from);
    float wet = f.z;
    float relief = f.w;

    // Leveling: wet paint relaxes toward its painted neighbours, mixing colors where they meet.
    // Oil paint never creeps out onto bare canvas (strokes would swell); runny watercolor (wetness > 1.2)
    // does, blooming outward until it dries.
    float thickness = p.a;
    float3 color = p.rgb;
    float4 nb[4];
    float runny = 0;
    for (int k = 0; k < 4; k++) {
        float2 o = k == 0 ? float2(1, 0) : k == 1 ? float2(-1, 0) : k == 2 ? float2(0, 1) : float2(0, -1);
        nb[k] = paintIn.sample(lin, from + o);
        float nw = flowIn.sample(lin, from + o).z;
        if (nb[k].a > 0.02) runny = max(runny, nw);
    }
    bool blooming = runny > 1.2;
    float level = clamp(P.tune.y * max(wet, blooming ? runny : 0.0) * dt, 0.0, 0.25);
    if (level > 1e-4 && (p.a > 0.02 || blooming)) {
        float sumA = p.a;
        float3 sumC = p.rgb * p.a;
        for (int k = 0; k < 4; k++) {
            bool painted = nb[k].a > 0.02 || blooming;
            sumA += painted ? nb[k].a : p.a;
            sumC += painted ? nb[k].rgb * nb[k].a : p.rgb * p.a;
        }
        thickness = mix(p.a, sumA * 0.2, level);
        float3 premul = mix(p.rgb * p.a, sumC * 0.2, level);
        color = thickness > 1e-4 ? premul / thickness : p.rgb;
        if (blooming) wet = max(wet, runny * 0.9);   // the bloom carries on, a little weaker each texel
    }

    // Flow slows down (viscous paint) and stops, thick wet blobs sag downward, and everything dries.
    float2 velocity = f.xy * exp(-P.tune.z * dt);
    velocity.y += P.tune.w * max(thickness - 0.6, 0.0) * wet * dt;
    if (length(velocity) < 2.0) velocity = float2(0);
    wet *= exp(-P.tune.x * dt);
    if (wet < 0.02) { wet = 0; velocity = float2(0); }

    const float2 world = float2(P.frame.x + pos.x * P.frame.z, P.frame.y - pos.y * P.frame.z);
    const int count = int(P.size.z);
    for (int s = 0; s < count; s++) {
        PaintStamp st = stamps[s];
        float2 a = st.segment.xy, b = st.segment.zw;
        float radius = st.brush.x;
        float2 seg = b - a;
        float len2 = dot(seg, seg);
        float t = len2 > 1e-10 ? clamp(dot(world - a, seg) / len2, 0.0, 1.0) : 0.0;
        float2 offset = world - (a + seg * t);
        float dist = length(offset);
        if (dist > radius * 1.4) continue;
        // A flat nib is an ellipse (full width along its edge, thin across it) swept along the segment:
        // measure in nib space, where the ellipse is a circle, so the sweep has clean edges.
        float aspect = max(st.shape.y, 1.0);
        if (aspect > 1.0) {
            float2 nib = float2(cos(st.shape.x), sin(st.shape.x));
            float2 across = float2(-nib.y, nib.x);
            float2 pn = float2(dot(world - a, nib), dot(world - a, across) * aspect);
            float2 sn = float2(dot(seg, nib), dot(seg, across) * aspect);
            float tn = dot(sn, sn) > 1e-10 ? clamp(dot(pn, sn) / dot(sn, sn), 0.0, 1.0) : 0.0;
            dist = length(pn - sn * tn);
            if (dist > radius * 1.4) continue;
        }

        if (st.color.w > 0.5) {
            // Starfish scrub: smear thin and wipe away.
            float k = 1.0 - smoothstep(radius * 0.55, radius, dist);
            thickness *= 1.0 - k * st.motion.z;
            relief *= 1.0 - k * st.motion.z;
            if (thickness < 0.008) { thickness = 0.0; relief = 0.0; }
            wet = max(wet, 0.6 * k);
            continue;
        }

        float seed = st.brush.w;
        float2 seedOffset = float2(seed * 3.1, seed * 7.3);
        float ragged = noise(world * 9.0 + seedOffset) * 0.7 + noise(world * 23.0 + seedOffset) * 0.3;
        float x = dist / (radius * (1.0 + 0.22 * ragged));
        if (x >= 1.15) continue;

        const float bristles = st.shape.z, watery = st.shape.w, knife = st.extra.x;
        // Flat top (a brush lays a sheet, not a tube) with paint pushed up into a rim at the edges.
        // A knife leaves a crisper edge and a taller ridge; watercolor fades out softly.
        float edge = mix(mix(0.7, 0.88, knife), 0.35, watery);
        float profile = 1.0 - smoothstep(edge, 1.0, x);
        float rim = (x - 0.9) / 0.1;
        float rimLift = (0.45 + 0.7 * knife) * (1.0 - watery) * exp(-rim * rim);

        // Bristle grooves running along the stroke; a fast brush goes dry and streaky.
        float len = sqrt(len2);
        float2 dir = len > 1e-5 ? seg / len : float2(1, 0);
        float u = dot(world, float2(-dir.y, dir.x));
        float along = dot(world, dir);
        float groove = 0.5 * sin(u * 140.0 + seed) + 0.3 * sin(u * 61.0 + seed * 1.7)
                     + 0.45 * noise(float2(u * 260.0, along * 6.0 + seed));
        // A knife drags only a few fine streaks through its sheet.
        groove = mix(groove, 0.4 * noise(float2(u * 90.0, seed)), knife);
        float bristle = mix(1.0, 0.68 + 0.36 * groove, bristles);
        float dry = st.brush.z;
        float streak = max(0.0, bristle - dry * 0.5) / (1.0 - dry * 0.5);
        float deposit = st.brush.y * (profile + rimLift) * streak;

        // The brush drags whatever wet paint it passes through, and combs its own bristle marks into it.
        float push = saturate(1.1 - x);
        velocity = mix(velocity, st.motion.xy, push * st.motion.w);
        wet = max(wet, push);
        float comb = saturate(push * 2.0) * saturate(len * 400.0 + 0.15) * (1.0 - watery);
        relief = mix(relief, groove * 0.6 * max(bristles, knife) + rimLift, comb);

        if (deposit <= 1e-6) continue;
        // A brush lays a coat of paint, it doesn't build a mound: thickness tops out at a cap.
        // Watercolor is a thin glaze, so washes build up layer by layer.
        float cap = mix(0.55 + 0.1 * ragged, 0.12 + 0.03 * ragged, watery);
        float add = deposit * max(0.0, cap - thickness);
        // Wet-on-wet: new paint blends into what's there.
        float blend = thickness < 1e-3 ? 1.0 : min(1.0, add / (thickness * 0.5 + add) + 0.12 + 0.3 * watery);
        // Watercolor pigment gathers at the wash's edge and dries darker there.
        float pooled = 1.0 - 0.22 * watery * smoothstep(0.55, 0.95, x);
        float3 pigment = st.color.rgb * (0.96 + 0.04 * ragged) * pooled;
        // Watercolor is a transparent glaze: a pale tint that darkens whatever is below it, like
        // subtractive pigment (min, so a wash going over itself doesn't keep getting darker).
        float3 below = thickness < 1e-3 ? float3(1) : color;
        pigment = mix(pigment, min(below, mix(float3(1), pigment, 0.6)), watery);
        color = mix(color, pigment, blend);
        thickness += add;
        wet = max(wet, 1.0 + 2.0 * watery);
    }

    paintOut.write(float4(color, thickness), gid);
    flowOut.write(float4(velocity, wet, relief), gid);
}

/// The linen weave under the paint (0…1): warp and weft threads passing over and under each other.
static float weave(float2 p, float pitch) {
    float2 q = p / pitch;
    float2 cell = floor(q), f = q - cell;
    float warp = sin(M_PI_F * f.x), weft = sin(M_PI_F * f.y);
    bool warpOnTop = fmod(cell.x + cell.y, 2.0) < 0.5;
    float top = warpOnTop ? warp * (0.75 + 0.25 * weft) : weft * (0.75 + 0.25 * warp);
    return max(top, (warpOnTop ? weft : warp) * 0.55);
}

/// Surface height at a clamped texel: a low, flat paint body plus the bristle relief and a faint grain.
/// Thin paint follows the canvas weave underneath; a thick coat buries it.
static float surfaceHeight(texture2d<float, access::read> paint, texture2d<float, access::read> flow,
                           int2 c, int2 size, float4 shade, float4 canvas) {
    c = clamp(c, int2(0), size - 1);
    float a = paint.read(uint2(c)).a;
    float covered = saturate(a * 20.0);
    float relief = flow.read(uint2(c)).w;
    float thin = covered * (1.0 - smoothstep(0.05, 0.4, a));
    return a * shade.w + relief * shade.z * covered + 0.006 * noise(float2(c) * 0.9) * covered
         + weave(float2(c), canvas.x) * canvas.y * thin;
}

/// Turns the simulation into what the material samples: color + coverage, a per-pixel normal map
/// (so every ridge and bristle groove catches the light) and roughness (wet = glossy).
kernel void paintShade(texture2d<float, access::read> paint [[texture(0)]],
                       texture2d<float, access::read> flow [[texture(1)]],
                       texture2d<float, access::write> albedo [[texture(2)]],
                       texture2d<float, access::write> normalMap [[texture(3)]],
                       texture2d<float, access::write> roughness [[texture(4)]],
                       constant PaintParams &P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    const int2 size = int2(P.size.xy);
    if (int(gid.x) >= size.x || int(gid.y) >= size.y) return;
    float4 p = paint.read(gid);
    #define h(o) surfaceHeight(paint, flow, int2(gid) + (o), size, P.shade, P.canvas)
    float hc = h(int2(0));
    float hl = h(int2(-1, 0)), hr = h(int2(1, 0)), hu = h(int2(0, -1)), hd = h(int2(0, 1));
    float strength = P.shade.x;
    float3 n = normalize(float3((hl - hr) * strength, (hd - hu) * strength, 1.0));

    // Cavities (grooves, the dip inside a rim) read darker, like real impasto.
    float around = (h(int2(-3, 0)) + h(int2(3, 0)) + h(int2(0, -3)) + h(int2(0, 3))) * 0.25;
    float cavity = 1.0 - saturate((around - hc) * P.shade.y);
    float coverage = smoothstep(0.004, 0.05, p.a);
#undef h

    float wet = saturate(flow.read(gid).z);
    // Pigment colors are sRGB values; the material samples this texture as linear.
    float3 linearColor = pow(saturate(p.rgb * cavity), 2.2);
    albedo.write(float4(linearColor, coverage), gid);
    normalMap.write(float4(n * 0.5 + 0.5, 1), gid);
    roughness.write(float4(float3(mix(0.55, 0.12, wet)), 1), gid);
}
