-- Tuning for fire. Distances in scene cm, times in seconds, damage in the game's native units (a full
-- health or balance pool is about 1).
return {
    tick = 0.5,                 -- burning characters and heat: one step every tick
    scan = { hot = 0.25, warm = 0.5, radius = 2500 },  -- flammables near the player: hot while anything burns, warm while only a held flame is out

    -- How each material takes fire. `catch` is the heat it must soak up (a source gives its `heat` per
    -- second at the source, falling to 0 at its `reach`); `burn` how long it burns; `size` the native
    -- fire's size (0.25..2; the game's own medium fire is 1).
    materials = {
        straw = { catch = 0.8, burn = 20, heat = 1.8, reach = 260, size = 0.7 },
        cloth = { catch = 1.2, burn = 25, heat = 1.4, reach = 220, size = 0.6 },
        wood  = { catch = 4.5, burn = 60, heat = 1.0, reach = 170, size = 0.9 },
        logs  = { catch = 6.0, burn = 90, heat = 1.2, reach = 170, size = 1.1 },
    },
    cool = 0.4,                 -- heat a prop sheds each second while nothing heats it
    max_fires = 24,             -- fires this mod keeps lit at once; the oldest burns out first

    person = {
        seconds = 6,            -- a fresh burn
        max_seconds = 12,       -- more fire on a burning character lengthens it up to this
        health = 0.024,         -- per second
        balance = 0.012,        -- per second
        down = 3,               -- knocked down, a character rolls the flames out this many times faster
        player = 0.75,          -- the player takes this share
        undead = 1.5,           -- the dead (the game's Undead and Corpse roles) burn worse
        spread_reach = 70,      -- a burning character sets others this close alight
        spread_chance = 0.15,   -- per second
        catch_reach = 80,       -- standing this close to a fire
        catch_chance = 0.35,    -- per second
        heat = 1.2,             -- a burning character heats flammables like a cloth fire...
        reach = 90,             -- ...this far
        max = 12,
    },

    -- Held flames. Torch and candle-holder object ids are the game's own records (objdb Torch A01,
    -- CandleHold 1..5). Held torches are taken to be lit; the game keeps no unlit carried torch
    -- that the runtime reports (RUNTIME-REQUESTS.md asks for the flag).
    torch = { records = { 0x1F }, hit_chance = 0.4, hit_seconds = 4, heat = 1.6, reach = 90 },
    candle = { records = { 0x80, 0xEE, 0xEF, 0xF0, 0x3FE }, hit_chance = 0.1, hit_seconds = 3, heat = 0.7, reach = 60 },
    weapon = { hit_seconds = 5, heat = 2.5, reach = 110 },   -- a flaming weapon (fire.weapon)

    -- Native fires (braziers, hearths, fires this mod lit) set alight a character who stands in them;
    -- they never heat props, or every crate beside a hearth would catch at level load.
    native_reach = 60,

    injuries = "com.necrosis.injuries",   -- told each burn tick's damage ("injuries.burn"): it bakes the burn

    -- Marks other mods may read: scorch grows `rate` a second of burning (x strength), up to 255,
    -- and is sent whenever it has grown by `step`.
    marks = { burning = "fire.burning", scorch = "fire.scorch", rate = 10, step = 8 },

    -- Until the runtime can put flames on a character, the nearest burning ones glow.
    light = { color = { 1.6, 0.75, 0.3 }, range = 500, intensity = 1.6, up = 20, glow = 9 },
    sounds = { ignite = { "firesizzlea01", "firesizzlea02", "firesizzlea03", "firesizzlea04" }, volume = 0.2, hear = 1500 },
}
