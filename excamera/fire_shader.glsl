// Fire and smoke (fire.inl), their own pass before the finishing pass: drawn only inside the box that
// holds every volume. Each volume is marched front to back between the camera ray's entry into its
// bounding sphere and the scene's depth, so flames end where they meet a wall, the floor or a body.
// Flames emit (a black-body ramp from deep red at the edge to near white at the hot core) and smoke
// absorbs and scatters a little of the flames' light. The noise is a frame fixed to the world, rising
// over time, so the fire does not swim as the camera turns.
uniform vec4 fireA[12];   // base centre, view space (cm); w: radius at the base (cm)
uniform vec4 fireB[12];   // base to the flame's top (cm); w: kind (0 fire, 1 a burning body, 2 a blade)
uniform vec4 fireC[12];   // intensity 0..1, seed, smoke 0..1, unused
uniform float fireCount;
uniform vec4 fireRect;    // screen box (uv min xy, max zw); outside it nothing to do
uniform vec4 fireLook;    // x seconds, y march steps, z 1 with smoke, w unused
uniform vec4 fireRight;   // world +x in view space (xyz)
uniform sampler3D fireNoise; // tiling smooth noise, 16 units a tile, four channels

float fireFbm(vec3 p) {
    vec4 a = texture3D(fireNoise, p * 0.0625);
    vec4 b = texture3D(fireNoise, p * 0.137 + 0.31);
    return a.r * 0.5 + b.g * 0.3 + a.b * 0.2;
}

// Deep red, orange, yellow, then white-hot: linear light, brighter than 1 at the core for the bloom.
vec3 fireRamp(float t) {
    t = clamp(t, 0.0, 1.4);
    return vec3(1.6, 0.42, 0.08) * smoothstep(0.02, 0.4, t) + vec3(0.0, 0.62, 0.16) * smoothstep(0.35, 0.8, t) +
           vec3(0.0, 0.18, 0.55) * smoothstep(0.8, 1.3, t);
}

void main() {
    vec4 scene = texture2D(sceneTex, uv);
    if (uv.x < fireRect.x || uv.y < fireRect.y || uv.x > fireRect.z || uv.y > fireRect.w) {
        gl_FragColor = scene;
        return;
    }
    float raw = texture2D(depthTex, uv).r;
    vec3 surface = viewPosition(uv, raw);
    vec3 ray = normalize(vec3((uv * 2.0 - 1.0 + projection.zw) / projection.xy, -1.0));
    float sceneT = raw >= skyDepth ? 1e6 : length(surface);
    vec3 light = vec3(0.0);
    float through = 1.0;   // how much of what lies behind still shows
    float jitter = noise();
    float time = fireLook.x;
    for (int i = 0; i < 12; ++i) {
        if (float(i) >= fireCount || through < 0.02) break;
        vec4 A = fireA[i], B = fireB[i], C = fireC[i];
        float height = length(B.xyz);
        if (height < 1.0) continue;
        vec3 axis = B.xyz / height;
        float kind = B.w, radius = A.w;
        float plume = kind < 0.5 && fireLook.z > 0.5 ? 3.2 : 1.0 + 0.6 * C.z * fireLook.z; // smoke rises above the flames
        float top = height * plume;
        // Bounding sphere of flames and plume.
        vec3 centre = A.xyz + axis * top * 0.5;
        float bound = top * 0.5 + radius * (1.0 + 0.9 * (plume - 1.0));
        float b = dot(ray, centre);
        float disc = b * b - dot(centre, centre) + bound * bound;
        if (disc <= 0.0) continue;
        float s = sqrt(disc);
        float t0 = max(b - s, 0.0), t1 = min(b + s, sceneT);
        if (t1 <= t0) continue;
        // Fewer steps for a far, small volume; the step count never drops below 4.
        float steps = clamp(fireLook.y * clamp(bound * 4.0 / max(t0, 1.0), 0.35, 1.0), 4.0, fireLook.y);
        float dt = (t1 - t0) / steps;
        vec3 side = normalize(fireRight.xyz - axis * dot(fireRight.xyz, axis));
        vec3 depthAxis = cross(axis, side);
        float scale = 1.0 / max(radius * 0.55, 2.0);   // noise features about half the base radius across
        for (int k = 0; k < 24; ++k) {
            if (float(k) >= steps || through < 0.02) break;
            vec3 p = ray * (t0 + (float(k) + jitter) * dt) - A.xyz;
            float h = dot(p, axis) / height;          // 0 at the base, 1 at the flame's top
            vec3 across = p - axis * (h * height);
            float r = length(across) / radius;          // 0 on the axis, 1 at the base's edge
            vec3 q = vec3(dot(across, side), h * height, dot(across, depthAxis)) * scale + C.y;
            // Flames: a teardrop narrowing to the top, licked by noise rising faster than the smoke.
            float lick = fireFbm(q - vec3(0.0, time * 2.6, 0.0));
            float width = pow(clamp(1.0 - h, 0.0, 1.0), kind > 1.5 ? 0.25 : 0.6) * (0.75 + 0.5 * lick);
            float flame = h > -0.05 && h < 1.1 ? smoothstep(0.0, 0.35, width - r) * (1.0 - smoothstep(0.7, 1.08, h + 0.3 * lick)) : 0.0;
            float density = flame * (0.6 + 0.8 * lick);
            if (density > 0.001) {
                float heat = density * (1.15 - h * 0.6) * (1.0 - r * 0.45);
                light += through * fireRamp(heat * 1.25) * density * C.x * dt * 0.045;
                through *= exp(-density * dt * 0.012);
            }
            // Smoke: above the flames, widening as it rises, drifting and thinning out.
            if (fireLook.z > 0.5 && C.z > 0.0 && h > 0.55) {
                float rise = h - 0.55;
                float wide = r / (0.55 + 0.45 * rise);
                float puff = fireFbm(q * 0.55 - vec3(0.4 * sin(time * 0.3 + C.y), time * 1.1, 0.0));
                float smoke = smoothstep(0.35, 0.75, puff + 0.45 - wide) * smoothstep(0.0, 0.5, rise) *
                              (1.0 - smoothstep(plume * 0.55, plume * 0.95, h)) * C.z;
                if (smoke > 0.001) {
                    // Lit from below by the flames, dark grey higher up.
                    vec3 tint = mix(vec3(0.5, 0.2, 0.06) * C.x, vec3(0.05, 0.048, 0.045), smoothstep(0.0, 0.8, rise));
                    float absorb = smoke * dt * 0.012;
                    light += through * tint * absorb;
                    through *= exp(-absorb * 1.6);
                }
            }
        }
    }
    vec3 base = encoded > 0.5 ? pow(scene.rgb, vec3(2.2)) : scene.rgb;
    vec3 c = base * through + light;
    gl_FragColor = vec4(encoded > 0.5 ? pow(c, vec3(1.0 / 2.2)) : c, scene.a);
}
