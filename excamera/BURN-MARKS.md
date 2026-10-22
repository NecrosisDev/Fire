# Burn marks: what Fire tells other mods

**The bake goes through Injuries (2026-10-22, the Wounds thread's shape):** each burn tick Fire sends
`addons.send("com.necrosis.injuries", "injuries.burn", {target = {handle = h} or "player", amount =
health dealt})`, and Injuries bakes reddening, blisters and char into the skin and soot onto clothes.
The marks below are kept for anything else that wants to show a burning or burnt character; the bake
sketch further down is only a starting shader for whoever owns that look. Nothing here has run.

## What Fire sets (runtime `characters.set_mark`, read by ExCamera through `character_mark_nodes`)

| Mark | Value | When |
|---|---|---|
| `fire.burning` | 1 while the character is alight, 0 when it goes out | for live flame look (embers, heat glow) |
| `fire.scorch` | 0..255, how burnt; grows 10 a second of burning (× strength), sent in steps of 8; never falls within a level | for the bake |

Targets are `"player"` or a record id (the runtime's mark targets), so NPCs sharing a record id share
the marks. At most 16 characters carry them at once (32 marks an addon). The runtime drops all marks
at a level change, the same lifetime as the burns.

Typical values: a torch hit ~40, a Fire Breath gout ~60, a long burn or several up to 255.

## The bake (ask)

The skin copy-bake already re-runs when a character's marks change (at most every 2 s). With
`fire.scorch` = s > 0, scorch the skin copy and the worn cloth/leather the same way:

- **Albedo:** patchy, not uniform. An fbm mask in UV space (seeded per character) whose threshold
  falls as s grows, so small burns are scattered patches and s = 255 covers most of the body. Inside
  the mask, charcoal; a thin band at its edge, raw reddened skin (or browned cloth).
- **Spec map:** lower gloss and strength inside the mask (dry char); leave metal untouched.
- **Normal map (optional):** a little crackle inside the mask.
- **Not on metal or plate** (the layer split wounds-05 already makes).

Starting point for the albedo pass (UV space; `burn` = s / 255, `burnSeed` per character):

```glsl
uniform float burn;
uniform float burnSeed;

float burnHash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7)) + burnSeed * 17.0) * 43758.5453); }
float burnNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
    return mix(mix(burnHash(i), burnHash(i + vec2(1, 0)), u.x), mix(burnHash(i + vec2(0, 1)), burnHash(i + vec2(1, 1)), u.x), u.y);
}
float burnFbm(vec2 p) { return 0.5 * burnNoise(p) + 0.25 * burnNoise(p * 2.1) + 0.125 * burnNoise(p * 4.3) + 0.125 * burnNoise(p * 8.7); }

vec3 burnAlbedo(vec3 albedo, vec2 uv) {
    if (burn <= 0.0) return albedo;
    float n = burnFbm(uv * 9.0);
    float edge = 1.0 - 0.75 * burn;                     // threshold falls as the burn grows
    float charred = smoothstep(edge, edge + 0.08, n);
    float raw = smoothstep(edge - 0.07, edge, n) * (1.0 - charred);
    albedo = mix(albedo, albedo * vec3(1.15, 0.55, 0.45), raw * 0.8);          // reddened edge
    return mix(albedo, vec3(0.05, 0.04, 0.035) * (0.7 + 0.6 * burnNoise(uv * 60.0)), charred);
}
```

`fire.burning` = 1 could also drive a faint flickering ember glow in the screen pass on charred
areas; optional, and the runtime's body flames (Fire RUNTIME-REQUESTS #3) carry the main look.
