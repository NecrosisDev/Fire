# ExCamera delta fire-01: volumetric fire and smoke

For the ExCamera owner (E:\ExCamera), via the coordinator. `git apply -p1 fire-01.patch` in E:\ExCamera
(checked with `git apply --check` against E as of 2026-10-22 12:20 UTC, view_effects.inl sha256
09975807…). `apply_fire.py <tree> fire_shader.glsl` re-applies it onto a newer copy, with `fire.inl`
copied to `src/mod/` first.

## What it draws

Flames as a volume, not sprites: a teardrop of rising noise, deep red at the edge to near white at the
hot core (brighter than 1, so the game's bloom picks it up), and a smoke plume above fires that widens,
drifts and thins as it rises, lit orange from below and dark grey higher up. It is depth-tested
against the scene, so flames stop where they meet a wall, the floor or a body. The noise runs in a frame
fixed to the world, so nothing swims as the camera turns.

Sources (fire.inl, all read-only):
- **Fires:** ScriptRuntime's `fire_nodes` export (version 1; requested as Fire RUNTIME-REQUESTS #10):
  braziers, hearths, prop fires, attached flames. Size 1 (the game's medium fire) gives a 20 cm base
  radius and 70 cm of flame, with smoke up to 3.2 times that.
- **Burning people:** the `fire.burning` mark (Fire sets it; marks export version 1): a 30 cm, 165 cm
  column from about the knees.
- **Flaming weapon:** the `fire.blade` mark on the player: flames 6 cm wide along the primary weapon's
  blade (`bladeLine`).

## How it fits

- A new pass in `drawViewEffectsOwned`, right after the wound marks and before the finishing pass, the
  same way: the finishing image read and rewritten in place over a screen box (the wound pass's FBO,
  quad and texture barrier), the depth copy on unit 1, the held-detail 3D noise on its own unit (bound
  and restored through the existing `noiseTouched`). No blend state, no new GL queries, no new targets.
- `ViewRequest.fires` joins `finish()`, so the finishing pass runs while a fire is in view.
- Program `programFire` and failure bit `viewFireFailed` (16384); `CueResources::fireProgram` is
  retired with the others.
- **Cost and auto quality:** at most 12 volumes, nearest first, within 40 m. Each pixel in the box
  marches every volume its ray crosses, between the volume's bounding sphere and the scene depth.
  Steps fall from 18 to 6 as the eased frame period goes from 18 to 25 ms (the level-detail rule,
  climbing back 2% a frame), far or small volumes take fewer (4 at least), and smoke stops below a
  quarter scale. Three 3D-texture fetches per step at most.
- Status json: `fire_volumes`, `fire_quality`, `fire_faults`.
- Always on, no row (Hunter's default-on rule; auto quality is the only knob).

## Checked

Offline only: the shader compiles and links on this PC's driver (GTX 1070, GL 4.6, glslcheck with the
real prelude), and ExCamera builds clean with the delta (`build.py`, the only warning is the existing
C4324 in hook_profile.h). Not run in the game: the look, the cost, which reading of the sector origin
the view matrix takes for fire nodes, and that a fire node's origin is the base of its flames are all
unverified. The native fire sprites still draw; this adds the volume around them.
