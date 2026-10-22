# Runtime requests from Fire (and Energy School)

**Landed (2026-10-22, runtime 0.28.0-r44/r47/r48):** #1 `world.light_fire`/`put_out_fire`, #2 `world.fires`,
#3 `effects.attach_fire` (characters and, in the source, `"weapon:right"`/`"weapon:left"`; API.md's row still
says weapons are not supported), #6 as `held`/`held_lit` on character rows and `weapon_lit` on hits (no
`weapon_record`: an instanced torch's `weapon_id` is not its record), #8 Energy casts, #9 `levels.read`,
#10 `fire_nodes`. Still open: #4 the fire jet, #5 `facing`, #7 `world.nearby` prefixes, and
`weapon_record` on hits.

Static reading of Exanima.exe 0.9.5.2g (addresses are RVAs; sources: KNOWLEDGEBASE.md "What lights a
fire", "Fire does not hurt by itself", "Particle emitters through CFD20", and API.md 0.21/0.22 and
`gear.use`). Nothing here has run in game. Fire and Energy School already call each of these behind
presence checks, so each part switches on when a runtime provides it; until then they log once and
do without.

| # | Call | Who needs it | Without it |
|---|---|---|---|
| 1 | `world.light_fire` / `world.put_out_fire` (capability `world.fire`) | props burning at all | props never burn (logged once); people still do |
| 2 | `world.fires(radius)` | braziers and hearths set people alight | only fires this mod lit do |
| 3 | `effects.attach_fire` / `effects.remove_fire` (capability `effects.fire`) | flames on burning people and the flaming blade | a placed glow light stands in (3 at most) |
| 4 | `effects.spawn_fire_jet` (capability `effects.fire`) | Fire Breath's visible gout | a short orange flash light stands in |
| 5 | `facing` on character rows | Fire Breath aims where you face | aims at the nearest foe fighting you |
| 6 | held-item record and lit flag (hits, inventory, NPC rows) | NPC torches; candles; unlit torches | only hits whose `weapon_id` is the torch record itself count |
| 7 | `world.nearby` prefix match, or more names a call | one scan instead of 12 | the 753-name catalogue is read 64 names a callback |
| 8 | Energy casts the game does not know go to `power.cast` | Fire Breath and Flaming Weapon can be cast at all | the game plays its fail sound |
| 9 | `levels.read(member, package)` | Energy School builds its page from the installed one (ships no game data) | the Energy page stays as installed: the powers cannot be learnt |
| 10 | native export `fire_nodes` | ExCamera's volumetric flames and smoke on every fire (excamera/fire-01.patch) | ExCamera draws flames only on burning people and the flaming blade (marks) |

## 1. `world.light_fire(name, {position, size})`, `world.put_out_fire(name)`

- **Game:** every fire comes from one builder, `F2A70(position, size, scene)`: size picks the small,
  medium or large variant (`F1C40`/`F20C0`/`F2510`), flames, particles `FirePrt01/02`, light and
  sound; the controller is tagged `+158` = `0x3DD0E002`. The runtime already calls it for
  `gear.use`'s `event:ignite_target()` (a medium fire at a placed object, as a job after the click), and
  already removes fires with `5BED0` mode 1 for `:extinguish()` (0.22).
- **Ask:** from timer callbacks, a staged `world.light_fire(name, {position = {x, y, z}, size = s})`:
  scene cm in the space `world.nearby` and `characters.snapshot` use, size 0.25..2, built on the game
  thread with the `ignite_target` path, refused (false) when a fire already stands within 50 cm or
  the addon has 24 lit. `name` (1..31 bytes) is the addon's handle on it; reusing a live name is
  refused. `world.put_out_fire(name)` removes it with the 0.22 extinction path.
  **These fires must not be saved:** `F2ED0` rebuilds every `0x3DD0E002` body at load, so a mod fire
  saved while burning would burn forever after a reload. The tag is the save key: `F2A70` writes it
  to the fire controller (`*(fire + 0x160) + 0x158` = `0x3DD0E002`), and the level serializer
  `1CD320` saves only nodes whose controller tag is registered. So zero that word right after the
  build (static reading of `1000f2a70.c`; what else reads the tag besides `1C9820`'s load-time test
  and the save path was not traced). At a level change the fires go with the scene and the names
  are forgotten.
- **Fire:** lights one per burning prop (size by material: straw 0.7, cloth 0.6, wood 0.9, logs 1.1)
  and puts it out when the prop has burnt (20 to 90 s).

## 2. `world.fires(radius_cm)`

- **Game:** fire bodies are scene nodes whose controller `+158` is `0x3DD0E002` (the test `1C9820`
  uses); `gear.use` already finds "any fire effect in the player's sector" within 300 cm
  (`target.heat`).
- **Ask:** with `world.read`, a list of the fire bodies in the player's sector within `radius_cm` (at
  most 5000) of the player: `{position = {x, y, z}, size, mod = true|false}`, scene cm, nearest first,
  at most 64. `mod` is true for fires an addon lit with request 1. Static wall torch flames count if
  they are fire bodies.
- **Fire:** a character who stands within 60 cm of one catches fire (35% a second). Native fires
  never heat props (a crate beside a hearth would otherwise catch at load).

## 3. `effects.attach_fire(name, target, {size})`, `effects.remove_fire(name)`

- **Game:** `149740` links a fire to a node's child with `A1730`; `CFD20(scene, spec, material)`
  builds an unsaved particle node that a mod can parent (`50170`) and remove (`50A60(node, 1)`).
  The fire variants' own builders (`F15A0`/`F1760`/`F1920`) give the flame look and light.
- **How the builder hands back a fire (static, `1000f2a70.c`):** `F2A70(&position, size, scene)`
  returns the fire node unattached: for small sizes it builds it from the fire preset at `.data 2B5A70`
  (`F1920`), stores the position at node `+94..+9C`, tags the controller (`+160`) `+158` and makes a
  light node (class `2FCF40`, `51880`) that it parents to the fire with `50170(fire, light)`; larger
  sizes go to `F2510`/`F20C0`/`F1C40`. The caller attaches and registers it, as `149740` does
  (`50170` under the target node, or `A1730` to link it to a child). So an attached flame is: build
  with a local offset as the position, clear the tag (request 1), `50170(part or weapon node, fire)`,
  propagate the pose (`EXP_propagate_node_pose`), `5A420(scene, &fire, 0)`; remove with
  `50A60(fire, 1)`. Each fire also carries the preset's looping sound (`FireS02`) and light (strength 8,
  range 1500, `.data 2B5A70 +74/+78`), which suits a burning body; for a blade, size 0.25 and
  dimming the light node `+220` would keep it from lighting the room like a hearth.
- **Ask:** a fire look (the game's small fire, built as above) that follows
  `target` until removed or the level ends: `target` is `"player"`, a row with a `handle`
  (`characters.read` row or `character.hit` event) or `"weapon:right"`/`"weapon:left"` (the player's
  held weapon body: the same node `character_hits` reports as `weapon`); `size` 0.1..1 scales it.
  Not saved; never a damage source of its own. 16 per addon.
- **Fire:** one per burning character (`size` 0.5 × strength); **Energy School:** the blade of a
  Flaming Weapon (`size` 0.35).

## 4. `effects.spawn_fire_jet{from, length, spread, life}`

- **Game:** the `CFD20` emitter spec (KNOWLEDGEBASE "Particle emitters"): emission count `+C`, life
  `+10`, size `+14`, a colour ramp at `+60` with flag 0x200 (kept by pointer, so the runtime owns it).
  Borrow `_FirePrt01` (its colour is set by every fire build) or `_PrtlPrt01` with an orange ramp.
- **Ask:** like `effects.spawn_arc`: a short directional jet of fire particles from the player's head
  (`from = "head"`) or casting hand (`"hand"`), along the body's facing, `length` cm (100..600),
  `spread` degrees (5..60), removed after `life` ticks (1..200). Visual only. 2 per pulse per addon.
- **Energy School:** Fire Breath, `{from = "head", length = 350, spread = 30, life = 40}`.

## 5. `facing` on `characters.snapshot` rows

- **Ask:** each row's horizontal facing as a unit vector `{x, 0, z}` in the snapshot's space (the
  runtime already uses the body's facing for `lights.set`'s `follow.forward`).
- **Energy School:** Fire Breath's cone follows it.

## 6. What a hand holds, and whether it burns

- **Ask:** on `character.hit`, `weapon_record` (the objdb record of the weapon, so an instanced or
  level-local torch still reads as Torch A01, record 0x1F) and `weapon_lit` when it is a torch or
  candle holder; on `inventory.snapshot().weapons` rows, `record_id` and `lit`; on
  `characters.snapshot` rows, `held = {right = record, left = record}`.
- **Fire:** a torch (0x1F) or candle holder (0x80, 0xEE, 0xEF, 0xF0, 0x3FE) that hits sets its victim
  alight sometimes (40% / 10%); NPCs carrying one heat props they pass. Today only hits whose
  `weapon_id` equals the record count, and held torches are taken to be lit.

## 7. `world.nearby` by name prefix

- **Ask:** `world.nearby(radius, {prefixes}, {prefix = true})` (a name matches when it starts with
  one of them), or up to 64 names a call.
- **Fire:** the catalogue is 753 placed model names (`scripts/flammables.lua`, generated from the
  installed levels). With prefixes ("crate", "barrel wdo", "sack", "chair", ...) one call covers it;
  today it is read 16 names a call, 4 calls a callback, only while something burns or a flame is
  held.

## 8. Energy powers the game does not cast go to `power.cast`

- **Game:** `1D8340` dispatches Energy (school byte 4) to `28F9E0`, whose cast table `2F1030` has 2
  rows: `0x401` Shock (0.10) and `0x2040B` (0.30); any other Energy id fails with `ThaumFail01`.
- **Ask:** take a cast whose school is Energy and whose `id & 0x0E0FFFFF` is in neither row, exactly
  as Light (0x5NN) and Body (0x3NN) casts are taken today (`power_bridge.h` line 58), with `school =
  "energy"`. Leave 0x401 and 0x2040B to the game. Extending `powers.teach` to these ids is not needed:
  the player learns them on the Energy page like Shock.
- **Energy School:** Fire Breath `0x402` and Flaming Weapon `0x403`.

## 9. `levels.read(member, package)`

- **Why:** the project rule is never to ship game files. The Energy page (`pwr_energy.pwr`, Shock
  only) and its icon sheet (`thmnrgico1.rfi`, one 512 px cell) ship with the game, so Energy School
  must add its two nodes and cells to the installed ones at load. It ships only its own nodes
  (`scripts/page.lua`) and a sheet with its own cells (`assets/energy-cells.rfi`); `scripts/merge.lua`
  does the merge on a worker and `levels.serve` serves the result. The offline test checks the merge
  byte for byte against the same merge done with the ExaniMate library (2950-byte tree, 1,249,180-byte
  sheet; 0.6 s of CPU in stock Lua).
- **Ask:** with `levels.serve`, from callbacks: the bytes of an uncompressed (type 0) `member` of the
  installed `package` (such as `"Resource.rpk"`), as the game's own archive holds them, ignoring any
  addon's serve and EMTK's replacements; nil and a reason when it is missing or compressed; 4 MiB at
  most. Reading only, the same members `levels.serve` can replace.
- **Open question for you:** when the game first reads `pwr_energy.pwr` and `thmnrgico1.rfi`. Energy
  School serves them from its first `menu` or `session` callback; if the game reads them earlier (at
  startup) and keeps them, the serve has to be in place before that, and `levels.read` would be needed
  while loading.

## 10. Native export `fire_nodes` (for ExCamera's fire pass)

- **Why:** ExCamera's fire pass (`excamera/fire-01.patch`) draws volumetric flames and smoke at every
  fire. Burning people and the flaming blade come from marks it already reads; fires themselves
  (braziers, hearths, prop fires from request 1, flames from request 3) need a list, and the runtime
  already tracks fire bodies (the 0.21 identity registry, request 2).
- **Ask:** two exports beside `character_mark_nodes`, same rules (any thread, no lock, no game memory
  read or allocation in the call, refreshed at each pulse, so a node may be one pulse stale):
  - `uint32_t fire_nodes_version()` returning 1;
  - `int fire_nodes(uintptr_t* nodes, float* sizes, int capacity)`: each live fire body in the player's
    sector (controller tag `0x3DD0E002`, or a fire an addon lit or attached even after its tag was
    cleared), its scene node and its size (controller `+0x12C`, which `F2A70` writes with the size),
    nearest the player first; returns how many it wrote (at most `capacity`, 64).
- **ExCamera:** reads each node's sampled transform (`+0xA0`, translation) and its sector's origin, as
  it does for held items; nothing else.
