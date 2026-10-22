# Fire

Flames that spread through Exanima. Wood, cloth and straw props and characters catch fire from anything burning, burn for a while, spread to what is near them, and burn out.

## Features

- **Props that burn.** Wood (crates, barrels, chairs, stools, tables, shelves, benches, planks, barricades), cloth (rugs, banners, cloth racks, cloth bolts), straw (sacks, wicker baskets and bottles) and logs placed in the game's levels can catch fire. Each soaks up heat from nearby flames and catches once it has taken enough: straw fastest, then cloth, wood and logs. A prop burns with the game's own fire for 20 to 90 seconds depending on its material, heats its neighbours, then goes out. A burnt-out prop does not catch again while you stay in that level. At most 24 props burn at once; past that the oldest fire goes out first.
- **People who burn.** A burning character takes health and balance damage for about 6 seconds, longer (up to 12) if more fire reaches them. Fire alone never knocks anyone down. A character on the ground rolls the flames out three times faster. You take three quarters of the damage others do; undead and corpses take half again as much. Fire jumps between people standing close together.
- **What starts a fire:**
  - A torch or candle you hold, brought near a prop.
  - A hit with a torch (sets the target alight 40% of the time) or a candle (10%).
  - A flaming weapon, which sets alight everyone it hits (started by another mod, see below).
  - Burning props and burning people.
  - The game's own braziers and hearths, for anyone who stands in them. They never set props alight, so crates beside a hearth stay safe.
- Blows caught on a shield or a blade never ignite.
- A short sizzle plays when something near you catches.

## Requirements

- Exanima (Steam).
- EMTK with the script-runtime startup patch (the Exanima Lua Runtime's README explains how to get it).
- Exanima Lua Runtime 0.28.0 or later.

Some parts depend on what your runtime supports. Each part that cannot work logs a note once and the rest of the mod carries on:

- Props burn only if your runtime can light the game's own fire on a prop. Without that, props do not catch.
- If your runtime can attach flames to a character, burning people show flames on their body. Otherwise the three burning characters nearest you glow with a flickering light.
- If your runtime reports what other characters hold, their torches heat props too.
- If your runtime lists the game's own fires, braziers and hearths set people alight.

### Optional companion mods

- **Injuries** (`com.necrosis.injuries`): Fire tells Injuries how much burn damage each character took, and Injuries turns it into burns on the skin and soot on clothes.
- **ExCamera**: Fire marks burning and scorched characters so ExCamera builds that read those marks can draw them. This repository also carries an optional ExCamera visual delta (`excamera/`) with volumetric flames and smoke, for ExCamera builds only.

## Install

1. Download the release ZIP (`Fire-<version>.zip`) from the GitHub Releases page.
2. Close Exanima.
3. Copy the ZIP's `mods` folder into your Exanima game folder.
4. Enable Fire in your EMTK profile.
5. Launch the game through EMTK.

## Usage and settings

Fire is always on and has no in-game menu. Tuning lives in `mods/com.necrosis.fire/scripts/config.lua`: how fast each material catches and how long it burns, burn length and damage on people, spread chances, torch and candle hit chances, and the most fires burning at once. Distances are in centimetres, times in seconds.

### For other mods

Other mods can start fires through the runtime's addon messages:

```lua
addons.send("com.necrosis.fire", "fire.ignite", {handle = row.handle, seconds = 6})   -- or record_id = ..., or target = "player"
addons.send("com.necrosis.fire", "fire.ignite", {cone = {origin = {x, y, z}, dir = {x, y, z}, length = 350, angle = 30},
                                                 health = 0.06, balance = 0.05, seconds = 6})   -- or sphere = {center = {x, y, z}, radius = 150}
addons.send("com.necrosis.fire", "fire.weapon", {seconds = 20})   -- the player's weapon burns; 0 ends it (0 to 600)
```

A cone or sphere sets alight everyone inside it except the player (add `player = true` to include them) and every flammable prop (add `props = false` to skip props). `health` and `balance` add an immediate scorch on top. `angle` is the half-angle in degrees. A level cone (`dir` with y = 0) also reaches `height` (default 200 cm) above and below.

## Saves and uninstalling

Fire stores nothing in your save. Every fire and burn ends when you leave the level or the session ends; damage already dealt stays like any other damage.

To uninstall, disable Fire in your EMTK profile, or close the game and delete `mods/com.necrosis.fire` from the Exanima folder.

## Building from source

Needs Python 3.9 or later.

```
python -X utf8 -B release.py
```

This builds the mod into `dist/mods/com.necrosis.fire/` and packages it as `dist/Fire-<version>.zip`, with a `.sha256` file beside it. The ZIP holds `mods/com.necrosis.fire/` exactly as EMTK loads it from the game folder. Any previous build folder is moved to `dist/previous/` first. `--zip-only` packages the folder already in `dist/` without rebuilding.

Pushing a tag `v<version>` matching the version in `manifest.toml` makes the GitHub workflow build and publish the release. A tag with a hyphen (for example `v0.2.0-rc1`) publishes a prerelease.

`scripts/flammables.lua`, the list of flammable models, is generated by `tools/make_flammables.py` from an installed copy of the game and checked in, so a normal build does not need the game.

`test_fire.py` runs the scripts against a stubbed runtime. It needs the Visual Studio C++ build tools and the Lua 5.4 source, given by the `EXANIMA_LUA_SRC` environment variable.
