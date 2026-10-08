//
//  StormShaders.swift
//  meteocool
//
//  The AR storm view's shaders, compiled when the view opens, and the Swift
//  mirrors of their uniform structs.
//

import simd

/// Metal source for the AR storm view, compiled at run time with
/// `MTLDevice.makeLibrary(source:options:)`, with `STORM_FETCH` defined to 1
/// where the GPU can read its render target in a fragment shader (every
/// Apple GPU) and 0 where it cannot.
///
/// Source rather than a `.metal` file: since Xcode 26 the Metal compiler is
/// a separate download (`xcodebuild -downloadComponent MetalToolchain`), and a
/// build that needs it fails on every machine and CI image without it. This
/// way the app builds with nothing but Xcode, and the cost is a compile of a
/// few hundred lines when the AR view first opens.
///
/// The raymarch is core's (`src/layers/cellVolumeLayer.ts`,
/// `src/lib/volumeRaymarch.ts`) ported to Metal: the same transfer function,
/// lighting and cut, so a storm looks the same over the sky as on the 3D map.
/// Keep the constants in step with core's, and the uniform structs in step
/// with their Swift mirrors (`VolumeUniforms`, `CameraUniforms`,
/// `SkyUniforms`, `LineVertex`).
enum StormShaders {
    static let source = """
#include <metal_stdlib>
using namespace metal;

// Must match StormRenderer.swift.
struct VolumeUniforms {
    float4x4 inverseViewProjection; // clip space back to the world
    float4x4 worldToBox;            // world metres to the box's unit cube
    float4 camera;                  // xyz: camera position in the world
    float4 earth;                   // xyz: centre of the ground sphere, w: its radius
    float4 extentKm;                // xyz: what one unit of the cube is worth, per axis
    float4 planeNormal;             // the cut, in box coordinates; w > 0.5 when there is one
    float4 planePoint;
    float4 light;                   // xyz: towards the light, in box coordinates
    float4 shells;                  // xyz: the shell thresholds, in dBZ
    float4 boxMin;                  // xyz: the part of the unit cube that is marched: a tile
    float4 boxMax;                  //   without its apron, cut down to where it holds echo
    float2 viewport;                // pixels of the target being drawn into
    float2 slab;                    // box z range drawn in full; the rest is ghosted
    float dbzFloor;
    float dbzScale;
    float low;                      // where the echo starts to show; the peel raises it
    float steps;
    float dim;                      // how much opacity a storm keeps
    float behind;                   // 1 for a storm from an old scan
    float ghost;                    // how much of the ghosted part is drawn
    int mode;                       // 0 reflectivity, 1 shells
    float stepMetres;               // the march's step along a ray; `steps` caps the count
    float system;                   // which storm the box is a tile of, as a number (0: none)
    float2 padding;
};

struct CameraUniforms {
    float2 imageFromViewX;          // image uv = x * view.x + y * view.y + offset
    float2 imageFromViewY;
    float2 imageFromViewOffset;
};

struct SkyUniforms {
    float4x4 inverseViewProjection;
    float4 camera;
    float4 up;                      // world up
    float2 viewport;
    float horizonDip;               // sine of the horizon's depression
    float padding;
};

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;                      // 0..1, origin top left
};

// One oversized triangle rather than a quad: no seam down the diagonal.
vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 corner = float2((vid << 1) & 2, vid & 2);
    FullscreenOut out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

// MARK: - Camera image

fragment float4 camera_fragment(FullscreenOut in [[stage_in]],
                                constant CameraUniforms &u [[buffer(0)]],
                                texture2d<float> lumaTexture [[texture(0)]],
                                texture2d<float> chromaTexture [[texture(1)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = u.imageFromViewX * in.uv.x + u.imageFromViewY * in.uv.y + u.imageFromViewOffset;
    float y = lumaTexture.sample(s, uv).r;
    float2 cbcr = chromaTexture.sample(s, uv).rg;
    // BT.601 full range, as ARKit delivers it.
    const float4x4 ycbcrToRGB = float4x4(float4(+1.0000, +1.0000, +1.0000, +0.0000),
                                         float4(+0.0000, -0.3441, +1.7720, +0.0000),
                                         float4(+1.4020, -0.7141, +0.0000, +0.0000),
                                         float4(-0.7010, +0.5291, -0.8860, +1.0000));
    return ycbcrToRGB * float4(y, cbcr, 1.0);
}

// MARK: - Preview sky

/// A sky and a ground for the preview, which has no camera: enough to see
/// where the horizon is, so storms beyond it read as beyond it.
fragment float4 sky_fragment(FullscreenOut in [[stage_in]], constant SkyUniforms &u [[buffer(0)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, 1.0 - in.uv.y * 2.0);
    float4 far = u.inverseViewProjection * float4(ndc, 0.5, 1.0);
    float3 direction = normalize(far.xyz / far.w - u.camera.xyz);
    float elevation = dot(direction, u.up.xyz) + u.horizonDip;
    float3 zenith = float3(0.20, 0.30, 0.46);
    float3 horizon = float3(0.62, 0.66, 0.70);
    float3 ground = float3(0.16, 0.19, 0.15);
    float3 colour = elevation >= 0.0
        ? mix(horizon, zenith, pow(saturate(elevation), 0.45))
        : mix(ground * 1.35, ground, saturate(-elevation * 6.0));
    // The horizon itself, a hairline.
    float line = 1.0 - smoothstep(0.0, 0.0015, abs(elevation));
    colour = mix(colour, float3(0.92), line * 0.6);
    return float4(colour, 1.0);
}

// MARK: - Volume

static float2 sampleField(texture3d<float> volume, sampler s, float3 p, constant VolumeUniforms &u) {
    float2 raw = volume.sample(s, p).rg;
    return float2(raw.r * 255.0 / u.dbzScale + u.dbzFloor, raw.g);
}

/// The gradient of what is drawn, corrected for the box not being a cube in
/// the world: a step of 1/160 along x is 250 m, the same along z 500 m.
static float3 fieldNormal(texture3d<float> volume, sampler s, float3 p, float step, constant VolumeUniforms &u) {
    float3 d = float3(step, 0.0, 0.0);
    const float2 w = float2(0.02, 1.0);
    float dx = dot(sampleField(volume, s, p + d.xyz, u) - sampleField(volume, s, p - d.xyz, u), w) / u.extentKm.x;
    float dy = dot(sampleField(volume, s, p + d.zxy, u) - sampleField(volume, s, p - d.zxy, u), w) / u.extentKm.y;
    float dz = dot(sampleField(volume, s, p + d.yzx, u) - sampleField(volume, s, p - d.yzx, u), w) / u.extentKm.z;
    float3 g = float3(dx, dy, dz);
    return length(g) > 1e-6 ? normalize(-g) : float3(0.0, 0.0, 1.0);
}

/// Opacity per kilometre of fully dense storm (core's OPACITY_PER_KM).
constant float kOpacityPerKm = 0.62;
/// The ramp from transparent to as dense as it gets, in dBZ (core's PEEL_BAND).
constant float kPeelBand = 14.0;
/// How much of itself a storm from an older scan keeps (core's BEHIND_FADE).
constant float kBehindFade = 0.55;

/// One storm along one ray, premultiplied, or nothing (alpha 0).
///
/// `budget` is how opaque this storm may become before the march stops: all
/// of it when nothing is in front, less behind cloud already composited.
static float4 raymarch(FullscreenOut in, constant VolumeUniforms &u,
                       texture3d<float> volume, texture2d<float> ramp, float budget) {
    // Clamped, not wrapped: a ray leaving the box must find empty air, not the
    // far side of the storm folded back in.
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    constexpr sampler rampSampler(address::clamp_to_edge, filter::linear);

    float2 ndc = float2(in.position.x / u.viewport.x * 2.0 - 1.0, 1.0 - in.position.y / u.viewport.y * 2.0);
    float4 farPoint = u.inverseViewProjection * float4(ndc, 0.5, 1.0);
    float3 origin = u.camera.xyz;
    float3 direction = normalize(farPoint.xyz / farPoint.w - origin);

    // The same ray in the box: an affine map keeps the ray parameter, so t is
    // metres in both, and a step's length in kilometres is dt / 1000.
    float3 o = (u.worldToBox * float4(origin, 1.0)).xyz;
    float3 d = (u.worldToBox * float4(direction, 0.0)).xyz;

    // The marched part of the cube, not the whole of it: a tile's apron is
    // its neighbours' ground, sampled so the field blends across the seam but
    // theirs to draw, and the air above the storm's top holds nothing.
    float3 inverse = 1.0 / d;
    float3 a = (u.boxMin.xyz - o) * inverse;
    float3 b = (u.boxMax.xyz - o) * inverse;
    float3 lo = min(a, b), hi = max(a, b);
    // From the camera, not the near plane: the camera can be inside the box
    // when the storm is overhead.
    float near = max(max(max(lo.x, lo.y), lo.z), 0.0);
    float far = min(min(hi.x, hi.y), hi.z);
    if (far <= near) return float4(0.0);

    // The earth hides what is beyond the horizon.
    float3 toCentre = u.earth.xyz - origin;
    float along = dot(toCentre, direction);
    float miss = dot(toCentre, toCentre) - along * along;
    float r2 = u.earth.w * u.earth.w;
    if (miss < r2) {
        float tEarth = along - sqrt(r2 - miss);
        if (tEarth > 0.0) far = min(far, tEarth);
    }
    if (far <= near) return float4(0.0);

    // The cut, trimmed off the ray rather than tested per sample, so the
    // exposed face lands exactly on the plane instead of on whichever step
    // came first. Everything on the positive side of the plane is gone.
    bool cutFace = false;
    if (u.planeNormal.w > 0.5) {
        float facing = dot(d, u.planeNormal.xyz);
        float atPlane = dot(u.planePoint.xyz - o, u.planeNormal.xyz);
        if (abs(facing) < 1e-9) {
            if (atPlane < 0.0) return float4(0.0);
        } else {
            float t = atPlane / facing;
            if (facing > 0.0) far = min(far, t);
            else if (t > near) { near = t; cutFace = true; }
        }
        if (far <= near) return float4(0.0);
    }

    // Steps in proportion to the ray's length inside the box, every step about
    // `stepMetres` long, at most `steps`: a ray that clips a tile's corner, or
    // crosses one of many tiles of a storm, costs what its length does.
    float count = clamp(ceil((far - near) / u.stepMetres), 4.0, u.steps);
    float dt = (far - near) / count;
    float stepKm = dt / 1000.0;
    // The same step in the cube's units, for the gradient's finite difference;
    // never under half a voxel, or the difference is noise.
    float stepUnit = max(dt * length(d), 0.5 / 160.0);
    float4 accumulated = float4(0.0);
    // Start each ray a random fraction of a step in, so neighbouring rays do
    // not sample the same depths and a sharp boundary comes out as fine noise
    // rather than a staircase.
    float dither = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);

    for (float i = 0.0; i < u.steps; i += 1.0) {
        if (i >= count) break;
        float3 p = o + d * (near + dt * (i + dither));
        float2 field = sampleField(volume, s, p, u);
        bool ghosted = p.z < u.slab.x || p.z > u.slab.y;
        if (ghosted && u.ghost <= 0.0) continue;

        float3 colour;
        float alpha;
        float density;
        if (u.mode == 1) {
            // Shells: thin surfaces at three thresholds, the onion.
            float3 off = (float3(field.r) - u.shells.xyz) / 1.6;
            float3 bump = exp(-off * off);
            density = max(max(bump.x, bump.y), bump.z) * field.g * 3.0;
        } else {
            density = smoothstep(u.low, u.low + kPeelBand, field.r) * field.g;
        }
        if (density <= 0.002) continue;
        colour = ramp.sample(rampSampler, float2(saturate((field.r + 32.0) / 96.0), 0.5)).rgb;
        if (cutFace && i < 1.0) {
            // The sliced surface itself, drawn flat and solid, because this
            // face is what cutting a storm open is for: it shows what the
            // outside hides. Averaged over a second tap just behind it,
            // because one opaque sample facets along the voxel grid.
            float2 behindField = sampleField(volume, s, p + d * dt * 0.5, u);
            float smoothed = 0.5 * (density + smoothstep(u.low, u.low + kPeelBand, behindField.r) * behindField.g);
            alpha = saturate(smoothed * 2.1);
            colour *= 1.12;
        } else {
            float lambert = 0.42 + 0.58 * max(dot(fieldNormal(volume, s, p, stepUnit, u), u.light.xyz), 0.0);
            alpha = saturate(density * stepKm * kOpacityPerKm * (u.mode == 1 ? 4.0 : 1.0));
            colour *= lambert;
        }
        if (ghosted) {
            float grey = dot(colour, float3(0.299, 0.587, 0.114));
            colour = float3(grey);
            alpha *= u.ghost;
        }
        accumulated.rgb += (1.0 - accumulated.a) * colour * alpha;
        accumulated.a += (1.0 - accumulated.a) * alpha;
        if (accumulated.a > budget) break;
    }

    if (accumulated.a <= 0.0) return float4(0.0);
    if (u.behind > 0.5) {
        float grey = dot(accumulated.rgb, float3(0.299, 0.587, 0.114));
        accumulated = float4(float3(grey), accumulated.a) * kBehindFade;
    }
    // Premultiplied throughout.
    return accumulated * u.dim;
}

/// As opaque as a pixel gets before nothing behind it can show.
constant float kOpaque = 0.985;
/// Storms drawn at a pixel before everything behind them is skipped. Cloud
/// behind two clouds does not show through; marching it is wasted work.
constant float kMaxLayers = 2.0;
/// How opaque a storm has to be at a pixel to count as one of those layers:
/// a wisp in front hides nothing, so it does not use up a layer.
constant float kLayerAlpha = 0.2;

#if STORM_FETCH
/// Near to far, each storm reading what the nearer ones left at its pixel
/// (Apple GPUs read the target in place, so this costs no extra pass), and
/// composited under them by hand rather than by the blender.
///
/// Layers are storms, not boxes: one storm is as many tiles as it covers, and
/// a ray through three tiles of one storm crosses one cloud. So each pixel
/// keeps the count and which storm it counted last; a tile of that same
/// storm is never the layer too many.
struct StormPixel {
    float4 colour [[color(0)]];
    float2 layers [[color(1)]];     // x: storms counted, y: the last one's `system`
};

fragment StormPixel volume_fragment(FullscreenOut in [[stage_in]],
                                    constant VolumeUniforms &u [[buffer(0)]],
                                    texture3d<float> volume [[texture(0)]],
                                    texture2d<float> ramp [[texture(1)]],
                                    float4 front [[color(0)]],
                                    float2 frontLayers [[color(1)]]) {
    bool sameStorm = frontLayers.y == u.system;
    // Behind two other storms already, or behind cloud nothing gets through:
    // done before a single sample is taken.
    if ((frontLayers.x > kMaxLayers - 0.5 && !sameStorm) || front.a >= kOpaque) discard_fragment();
    float4 storm = raymarch(in, u, volume, ramp, (kOpaque - front.a) / max(1.0 - front.a, 1e-3));
    if (storm.a <= 0.0) discard_fragment();
    StormPixel out;
    out.colour = front + (1.0 - front.a) * storm;
    out.layers = storm.a >= kLayerAlpha && !sameStorm ? float2(frontLayers.x + 1.0, u.system) : frontLayers;
    return out;
}
#else
/// Far to near through the blender, for a GPU that cannot read its target.
fragment float4 volume_fragment(FullscreenOut in [[stage_in]],
                                constant VolumeUniforms &u [[buffer(0)]],
                                texture3d<float> volume [[texture(0)]],
                                texture2d<float> ramp [[texture(1)]]) {
    float4 storm = raymarch(in, u, volume, ramp, kOpaque);
    if (storm.a <= 0.0) discard_fragment();
    return storm;
}
#endif

// MARK: - Composite

/// The half-resolution storm pass, stretched over the full frame.
fragment float4 composite_fragment(FullscreenOut in [[stage_in]], texture2d<float> storms [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return storms.sample(s, in.uv);
}

// MARK: - Lines

struct LineVertex {
    float4 position;                // already in clip space
    float4 colour;                  // premultiplied
};

struct LineOut {
    float4 position [[position]];
    float4 colour;
};

vertex LineOut line_vertex(uint vid [[vertex_id]], const device LineVertex *vertices [[buffer(0)]]) {
    LineOut out;
    out.position = vertices[vid].position;
    out.colour = vertices[vid].colour;
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    return in.colour;
}
"""
}

/// Mirrors `VolumeUniforms` in `StormShaders.source`, field for field.
struct VolumeUniforms {
    var inverseViewProjection = matrix_identity_float4x4
    var worldToBox = matrix_identity_float4x4
    var camera = SIMD4<Float>()
    var earth = SIMD4<Float>()
    var extentKm = SIMD4<Float>()
    var planeNormal = SIMD4<Float>()
    var planePoint = SIMD4<Float>()
    var light = SIMD4<Float>()
    var shells = SIMD4<Float>()
    var boxMin = SIMD4<Float>(0, 0, 0, 0)
    var boxMax = SIMD4<Float>(1, 1, 1, 0)
    var viewport = SIMD2<Float>()
    var slab = SIMD2<Float>()
    var dbzFloor: Float = 0
    var dbzScale: Float = 1
    var low: Float = 20
    var steps: Float = 96
    var dim: Float = 1
    var behind: Float = 0
    var ghost: Float = 0
    var mode: Int32 = 0
    var stepMetres: Float = 40_000 / 96
    var system: Float = 0
    var padding = SIMD2<Float>()
}

/// Mirrors `CameraUniforms` in `StormShaders.source`.
struct CameraUniforms {
    var imageFromViewX: SIMD2<Float>
    var imageFromViewY: SIMD2<Float>
    var imageFromViewOffset: SIMD2<Float>
}

/// Mirrors `SkyUniforms` in `StormShaders.source`.
struct SkyUniforms {
    var inverseViewProjection: simd_float4x4
    var camera: SIMD4<Float>
    var up: SIMD4<Float>
    var viewport: SIMD2<Float>
    var horizonDip: Float
    var padding: Float
}

/// Mirrors `LineVertex` in `StormShaders.source`.
struct LineVertex {
    var position: SIMD4<Float>
    var colour: SIMD4<Float>
}
