# Fire 0.1.0 — Lua addon candidate (mod id com.necrosis.fire)

Flames that spread. Wood, cloth and straw props and characters catch fire from anything burning,
burn for a while with light and damage, spread to what is near them, and burn out.

- **What catches:** 753 placed models from the installed levels, by name (found through 118 name
  prefixes, one search a scan on runtime 0.28.0-r51): straw (sacks, baskets,
  beds, wicker), cloth (rugs, banners, awnings, cloth bolts), wood (crates, barrels, tables, chairs,
  shelves, carts, planks, barricades) and logs. `tools/make_flammables.py` writes the list.
- **What lights it:** a held torch or candle (held near a prop; a torch hit sets a foe alight 40% of
  the time, a candle 10%), a flaming weapon (every hit), burning props and people, and the game's own
  braziers and hearths (for people who stand in them). Blows caught on a shield or blade never ignite.
- **Props** soak up heat by distance and catch at a threshold: straw fastest, then cloth, wood, logs.
  They burn with the game's own fire (20 to 90 s), heat their neighbours, then go out; a burnt prop
  does not catch again in that level. At most 24 burn at once.
- **People** burn for 6 s (up to 12 with more fire): 0.024 health and 0.012 balance a second through
  the game's damage applier, never knocking them down by itself. On the ground they roll it out three
  times faster. The player takes three quarters; the dead (Undead, Corpse roles) take half again.
  Fire jumps between people standing close (15% a second).
- **Burn marks:** each burn tick tells the Injuries mod (`com.necrosis.injuries`) what it dealt
  (`injuries.burn`), and Injuries bakes reddening, blisters and char into the skin and soot onto
  clothes. Fire also sets the marks `fire.burning` and `fire.scorch` (`excamera/BURN-MARKS.md`).
- **No menu.** It is always on; tuning lives in `scripts/config.lua`.

## For other mods

```lua
addons.send("com.necrosis.fire", "fire.ignite", {handle = row.handle, seconds = 6})     -- or record_id, or target = "player"
addons.send("com.necrosis.fire", "fire.ignite", {cone = {origin = {x,y,z}, dir = {x,y,z}, length = 350, angle = 30},
                                                 health = 0.06, balance = 0.05, seconds = 6})   -- or sphere = {center, radius}
addons.send("com.necrosis.fire", "fire.weapon", {seconds = 20})                             -- 0 ends it
```

A cone or sphere sets alight everyone in it but the player (`player = true` includes them) and every
flammable prop (`props = false` skips them); `health`/`balance` are an immediate scorch on top. A
level `dir` (y = 0) takes `height` (200 cm) above and below.

## Needs

The Exanima Lua Runtime 0.28.0. Burning people works on it today. **Props burning, body flames, NPC
torches and the game's braziers need runtime additions** listed in `RUNTIME-REQUESTS.md`; until
then each part logs once and does without (burning people glow with a placed light instead of
flames).

## Build and check

```
python -X utf8 -B test_fire.py               # offline: the addon against a stubbed runtime
python -X utf8 -B tools/make_flammables.py   # re-read the installed levels' model names
python -X utf8 -B tools/make_dist.py         # dist/mods/com.necrosis.fire
```

**Status:** offline only. Nothing here has run in the game.
