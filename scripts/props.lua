-- Flammable scenery near the player: which props are where, how much heat each has soaked up, which
-- burn, and the native fires that show it. The game marks no material on scenery, so `flammables`
-- (generated from the installed levels) names the wood, cloth and straw models.
--
-- A prop burns with the game's own fire, lit at its position and put out when it burns out; once burnt
-- out it does not catch again in this level. Without the runtime's world.light_fire nothing here burns
-- (there would be nothing to see), but the catalogue still feeds burning characters.
local config = require("config")
local list = require("flammables")

local props = {}

local CELL = 300            -- spatial grid cell (cm) on the ground plane; no reach is longer
local BATCH = 16            -- before runtime 0.28.0-r51, world.nearby took 16 exact names a call...
local CALLS = 4             -- ...and 4 calls a callback
local PREFIXES = 64         -- since r51 it takes 64 name prefixes; each call walks the whole scene tree
local RARE_EVERY = 4        -- the prefixes past the first 64 (rare models) are looked for every 4th scan
local FORGET = 30           -- a prop not seen for this long, and not burning, is dropped

local names, material_of = {}, {}
for i, row in ipairs(list.names) do
    names[i] = row[1]
    material_of[row[1]:lower()] = row[2]
end

local known = {}            -- key -> {key, name, material, position, seen, heat, ends, fire, spent}
local grid = {}             -- cell -> {key = true}
local cursor = 1
local prefix_mode = nil     -- nil until tried; false on a runtime without name prefixes
local common, rare = {}, {} -- the catalogue's prefixes: the 64 that find most placements, and the rest
local scans = 0
for i, prefix in ipairs(list.prefixes) do
    if i <= PREFIXES then
        common[#common + 1] = prefix
    elseif #rare < PREFIXES then
        rare[#rare + 1] = prefix
    end
end
local lit = {}              -- fire name -> key, for every fire this mod asked for
local lit_order = {}        -- fire names, oldest first
local to_light, to_put_out = {}, {}
local serial = 0
local shapes = {}           -- recent cone/sphere ignitions: {test, ends}
local warned = false

local function cell_of(x, z)
    return math.floor(x / CELL) .. ":" .. math.floor(z / CELL)
end

local function key_of(name, p)
    return string.format("%s@%d,%d,%d", name, math.floor(p[1] / 25), math.floor(p[2] / 25), math.floor(p[3] / 25))
end

local function drop_fire(name)
    lit[name] = nil
    for i, other in ipairs(lit_order) do
        if other == name then
            table.remove(lit_order, i)
            return
        end
    end
end

local function distance(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end
props.distance = distance

local function forget(entry)
    local cell = grid[entry.cell]
    if cell then
        cell[entry.key] = nil
        if next(cell) == nil then
            grid[entry.cell] = nil
        end
    end
    known[entry.key] = nil
end

-- Every prop within `reach` of `at`, from the grid, without walking the whole catalogue.
local function near(at, reach, fn)
    local x0, x1 = math.floor((at[1] - reach) / CELL), math.floor((at[1] + reach) / CELL)
    local z0, z1 = math.floor((at[3] - reach) / CELL), math.floor((at[3] + reach) / CELL)
    for cx = x0, x1 do
        for cz = z0, z1 do
            local cell = grid[cx .. ":" .. cz]
            if cell then
                for key in pairs(cell) do
                    local entry = known[key]
                    local d = entry and distance(entry.position, at)
                    if d and d <= reach then
                        fn(entry, d)
                    end
                end
            end
        end
    end
end

function props.can_burn()
    return world and world.light_fire ~= nil and api.has_capability("world.fire")
end

-- One world.nearby answer into the catalogue.
local function take(found, now)
    for _, object in ipairs(found.objects) do
        local material = material_of[(object.name or ""):lower()]
        if material and object.position then
            local key = key_of(object.name, object.position)
            local entry = known[key]
            if not entry then
                entry = { key = key, name = object.name, material = material, heat = 0,
                          position = { object.position[1], object.position[2], object.position[3] },
                          cell = cell_of(object.position[1], object.position[3]) }
                known[key] = entry
                grid[entry.cell] = grid[entry.cell] or {}
                grid[entry.cell][key] = true
                for _, shape in ipairs(shapes) do
                    if now < shape.ends and shape.test(entry.position) then
                        props.ignite(entry, now)
                        break
                    end
                end
            end
            entry.seen = now
        end
    end
end

-- Finds the catalogue's props around the player (a read-only callback): with name prefixes (runtime
-- 0.28.0-r51) one call finds nearly all of them, and a second every few scans the rare ones; before
-- that, the exact names 64 a callback in turn.
function props.scan(now)
    if not (world and world.nearby and api.has_capability("world.read")) then
        return
    end
    if prefix_mode ~= false then
        scans = scans + 1
        local lists = { common }
        if #rare > 0 and scans % RARE_EVERY == 0 then
            lists[2] = rare
        end
        for _, prefixes in ipairs(lists) do
            local ok, found = pcall(world.nearby, config.scan.radius, prefixes, { prefix = true })
            if not ok then
                if prefix_mode == nil then
                    prefix_mode = false   -- an older runtime refuses more than 16 names: exact names from now on
                end
                break
            end
            prefix_mode = true
            if not found then
                return
            end
            take(found, now)
        end
    end
    if prefix_mode == false then
        for _ = 1, CALLS do
            local batch = {}
            for i = 0, BATCH - 1 do
                batch[#batch + 1] = names[(cursor + i - 1) % #names + 1]
            end
            cursor = (cursor + BATCH - 1) % #names + 1
            local ok, found = pcall(world.nearby, config.scan.radius, batch)
            if not ok or not found then
                return
            end
            take(found, now)
        end
    end
    for key, entry in pairs(known) do
        if not entry.ends and now - (entry.seen or now) > FORGET then
            forget(entry)
        end
    end
end

function props.ignite(entry, now)
    if entry.ends or entry.spent then
        return false
    end
    if not props.can_burn() then
        if not warned then
            warned = true
            log.info("props cannot burn: this runtime has no world.light_fire (RUNTIME-REQUESTS.md)")
        end
        return false
    end
    local material = config.materials[entry.material]
    serial = serial + 1
    entry.ends = now + material.burn
    entry.fire = "p" .. serial
    lit[entry.fire] = entry.key
    lit_order[#lit_order + 1] = entry.fire
    to_light[#to_light + 1] = entry
    -- At the limit the oldest fire burns out early.
    if #lit_order > config.max_fires then
        local oldest = known[lit[lit_order[1]]]
        if oldest then
            oldest.ends = now
        end
    end
    return true
end

-- Heat from `sources` ({position, heat, reach}) over `dt`, then burning props heat their neighbours and
-- burn out. Returns the props that caught this step.
function props.step(now, dt, sources)
    local caught = {}
    local gained = {}
    local function warm(source)
        near(source.position, source.reach, function(entry, d)
            if not entry.ends and not entry.spent and entry ~= source.entry then
                gained[entry] = (gained[entry] or 0) + source.heat * (1 - d / source.reach)
            end
        end)
    end
    for _, source in ipairs(sources) do
        warm(source)
    end
    for _, entry in pairs(known) do
        if entry.ends then
            if now >= entry.ends then
                entry.ends, entry.spent, entry.heat = nil, true, 0
                to_put_out[#to_put_out + 1] = entry.fire
                drop_fire(entry.fire)
                entry.fire = nil
            else
                local material = config.materials[entry.material]
                warm({ position = entry.position, heat = material.heat, reach = material.reach, entry = entry })
            end
        end
    end
    for entry, heat in pairs(gained) do
        entry.heat = entry.heat + heat * dt
    end
    for _, entry in pairs(known) do
        if not entry.ends and not entry.spent then
            if not gained[entry] then
                entry.heat = math.max(0, entry.heat - config.cool * dt)
            end
            if entry.heat >= config.materials[entry.material].catch and props.ignite(entry, now) then
                caught[#caught + 1] = entry
            end
        end
    end
    return caught
end

-- Sets every flammable that `test(position)` accepts alight at once, and any found in the next few
-- seconds of scanning (the catalogue fills in over several calls).
function props.ignite_where(test, now)
    shapes[#shapes + 1] = { test = test, ends = now + 3 }
    local caught = {}
    for _, entry in pairs(known) do
        if test(entry.position) and props.ignite(entry, now) then
            caught[#caught + 1] = entry
        end
    end
    return caught
end

function props.burning()
    local out = {}
    for _, entry in pairs(known) do
        if entry.ends then
            out[#out + 1] = entry
        end
    end
    return out
end

function props.busy()
    return #to_light > 0 or #to_put_out > 0
end

-- The fire writes, in their own callback: lights first, then put-outs, 4 at most.
function props.flush()
    if not props.can_burn() then
        to_light, to_put_out = {}, {}
        return
    end
    local calls = 0
    while calls < 4 and #to_put_out > 0 do
        pcall(world.put_out_fire, table.remove(to_put_out, 1))
        calls = calls + 1
    end
    while calls < 4 and #to_light > 0 do
        local entry = table.remove(to_light, 1)
        if entry.fire then
            local ok, accepted = pcall(world.light_fire, entry.fire, {
                position = entry.position, size = config.materials[entry.material].size })
            if not (ok and accepted) then
                -- Refused (a fire is already there, or the runtime is at its limit): it does not burn.
                drop_fire(entry.fire)
                entry.ends, entry.fire, entry.heat = nil, nil, 0
            end
        end
        calls = calls + 1
    end
end

-- A level change or the menu: every fire this mod lit goes with the level (the runtime does not save
-- them), so only the bookkeeping is dropped.
function props.reset()
    known, grid, lit, lit_order, to_light, to_put_out, shapes = {}, {}, {}, {}, {}, {}, {}
    cursor, scans = 1, 0
end

function props.count()
    local n = 0
    for _ in pairs(known) do
        n = n + 1
    end
    return n
end

return props
