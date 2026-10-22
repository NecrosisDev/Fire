-- Fire: flames that spread. Wood, cloth and straw props and characters catch fire from anything
-- burning (a lit torch or candle, a flaming weapon, a burning prop or person, a brazier or hearth),
-- burn for a while with light and damage, spread to what is near them, and burn out.
--
-- Other mods start fires through messages (see README):
--   addons.send("com.necrosis.fire", "fire.ignite", {handle = row.handle, seconds = 6})
--   addons.send("com.necrosis.fire", "fire.ignite", {cone = {origin, dir, length, angle}, health = 0.05})
--   addons.send("com.necrosis.fire", "fire.weapon", {seconds = 20})   -- the player's weapon burns
--
-- Writes of different kinds never share a callback (the runtime runs one kind per callback): the tick
-- only reads, and damage, fires, body flames, glow lights and sounds each go out in their own.
local config = require("config")
local props = require("props")
local people = require("people")

local function set_of(list)
    local out = {}
    for _, id in ipairs(list) do
        out[id] = true
    end
    return out
end
local TORCHES, CANDLES = set_of(config.torch.records), set_of(config.candle.records)

local tick_timer, scan_timer
local last_tick, scan_skip = nil, 0
local weapon_until = 0
local orders = {}           -- ignitions asked for by messages and hits, applied at the next tick
local sound_due = false
local held_flame = nil      -- what the player holds burning: config.torch, config.candle or nil
local held_ids = {}         -- the player's held item ids, from the last inventory read

local function distance(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function flame_of(record)
    if TORCHES[record] then
        return config.torch
    elseif CANDLES[record] then
        return config.candle
    end
    return nil
end

-- The player's held torch or candle, from the inventory (weapon slots of the active set).
local function read_held()
    held_flame, held_ids = nil, {}
    if not (inventory and inventory.snapshot and api.has_capability("inventory.read")) then
        return
    end
    local ok, view = pcall(inventory.snapshot)
    if not ok or not view or not view.weapons then
        return
    end
    for _, slot in ipairs(view.weapons) do
        local id = slot.record_id or slot.item_id
        if id and id ~= 0 then
            held_ids[slot.item_id] = true
            local flame = slot.lit ~= false and flame_of(id)
            if flame and (not held_flame or flame.heat > held_flame.heat) then
                held_flame = flame
            end
        end
    end
end

local function weapon_burning(now)
    return now < weapon_until
end

-- Shapes from messages. Directions need not be unit length; angle is the half-angle in degrees.
-- A cone with a level direction (dir[2] == 0) also takes `height` (cm above and below, 200).
local function cone_test(cone)
    local o, d = cone.origin, cone.dir
    local n = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
    if n == 0 then
        return function() return false end
    end
    local ux, uy, uz = d[1] / n, d[2] / n, d[3] / n
    local spread = math.tan(math.rad(math.max(1, math.min(cone.angle or 30, 80))))
    local length = cone.length or 300
    if uy == 0 then
        -- A level cone: measured on the ground plane, taking in everything within `height` above or
        -- below it (props stand on the floor, below a body's centre).
        local height = cone.height or 200
        return function(p)
            local vx, vz = p[1] - o[1], p[3] - o[3]
            local along = vx * ux + vz * uz
            if along < 0 or along > length or math.abs(p[2] - o[2]) > height then
                return false
            end
            local lx, lz = vx - along * ux, vz - along * uz
            return math.sqrt(lx * lx + lz * lz) <= along * spread + 40
        end
    end
    return function(p)
        local vx, vy, vz = p[1] - o[1], p[2] - o[2], p[3] - o[3]
        local along = vx * ux + vy * uy + vz * uz
        if along < 0 or along > length then
            return false
        end
        local lx, ly, lz = vx - along * ux, vy - along * uy, vz - along * uz
        -- 40 cm of slack: a body or crate is not a point.
        return math.sqrt(lx * lx + ly * ly + lz * lz) <= along * spread + 40
    end
end

local function sphere_test(sphere)
    local c, r = sphere.center, sphere.radius or 150
    return function(p)
        return distance(c, p) <= r
    end
end

local function valid_point(p)
    return type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and type(p[3]) == "number"
end

if addons and addons.on then
    addons.on("fire.ignite", function(value, from)
        if type(value) ~= "table" then
            log.warn("fire.ignite from " .. tostring(from) .. " needs a table")
            return
        end
        local order = { seconds = tonumber(value.seconds), strength = tonumber(value.strength),
                        health = tonumber(value.health) or 0, balance = tonumber(value.balance) or 0,
                        player = value.player == true, props = value.props ~= false }
        if type(value.cone) == "table" and valid_point(value.cone.origin) and valid_point(value.cone.dir) then
            order.test = cone_test(value.cone)
        elseif type(value.sphere) == "table" and valid_point(value.sphere.center) then
            order.test = sphere_test(value.sphere)
        elseif value.target == "player" then
            order.is_player = true
        elseif math.type(value.handle) == "integer" then
            order.handle = value.handle
        elseif math.type(value.record_id) == "integer" then
            order.record_id = value.record_id
        else
            log.warn("fire.ignite from " .. tostring(from) .. " needs handle, record_id, target = \"player\", cone or sphere")
            return
        end
        orders[#orders + 1] = order
    end)
    addons.on("fire.weapon", function(value, from)
        local seconds = type(value) == "table" and tonumber(value.seconds)
        if not seconds or seconds < 0 or seconds > 600 then
            log.warn("fire.weapon from " .. tostring(from) .. " needs {seconds = 0..600}")
            return
        end
        weapon_until = seconds > 0 and timers.now() + seconds or 0
    end)
end

-- Hits: a flaming weapon always sets its victim alight; a torch or candle sometimes does. A blow
-- caught on a shield or blade does not.
if api.has_capability("events.combat") then
    events.on("character.hit", function(event)
        if event.source ~= "weapon" or event.blocked or event.parried or not event.handle then
            return
        end
        local by_player = event.attacker and event.attacker.is_player
        local victim = { handle = event.handle, record_id = event.record_id, is_player = event.is_player }
        if by_player and weapon_burning(timers.now()) then
            orders[#orders + 1] = { victim = victim, seconds = config.weapon.hit_seconds }
            return
        end
        local flame = flame_of(event.weapon_record or event.weapon_id)
        if flame and event.weapon_lit ~= false and math.random() < flame.hit_chance then
            orders[#orders + 1] = { victim = victim, seconds = flame.hit_seconds }
        end
    end)
end

local function read_characters()
    if not api.has_capability("characters.read") then
        return {}, nil
    end
    local ok, view = pcall(characters.snapshot)
    if not ok or not view then
        return {}, nil
    end
    local me
    for _, row in ipairs(view.characters) do
        if row.is_player then
            me = row
        end
    end
    return view.characters, me
end

-- Ignitions waiting for this tick's character rows.
local function apply_orders(now, rows, me)
    local caught = {}
    local list = orders
    orders = {}
    for _, order in ipairs(list) do
        local function hit(row)
            local fresh = people.ignite(row, order.seconds, order.strength)
            if (order.health or 0) > 0 or (order.balance or 0) > 0 then
                people.scorch(row, order.health or 0, order.balance or 0)
            end
            if fresh then
                caught[#caught + 1] = row
            end
        end
        if order.victim then
            for _, row in ipairs(rows) do
                if row.handle == order.victim.handle then
                    hit(row)
                end
            end
        elseif order.test then
            for _, row in ipairs(rows) do
                if row.position and not row.dead and (order.player or not row.is_player) and order.test(row.position) then
                    hit(row)
                end
            end
            if order.props then
                for _, entry in ipairs(props.ignite_where(order.test, now)) do
                    caught[#caught + 1] = entry
                end
            end
        else
            for _, row in ipairs(rows) do
                if (order.is_player and row.is_player) or (order.handle and row.handle == order.handle)
                    or (order.record_id and row.record_id == order.record_id) then
                    hit(row)
                end
            end
        end
    end
    return caught
end

local function heard(things, here)
    if not here then
        return false
    end
    for _, thing in ipairs(things) do
        if thing.position and distance(thing.position, here) <= config.sounds.hear then
            return true
        end
    end
    return false
end

local function flush_damage()
    if people.flush_damage() then
        timers.after(0, flush_damage)
    end
end

local function flush_props()
    props.flush()
    if props.busy() then
        timers.after(0, flush_props)
    end
end

local function play_sound()
    if sound_due and ui and ui.sound and api.has_capability("ui.sound") then
        local list = config.sounds.ignite
        pcall(ui.sound, list[math.random(#list)], config.sounds.volume)
    end
    sound_due = false
end

local level_id = nil

local function tick()
    -- A level change inside a session: the old level's fires and burns are gone.
    local level = world and world.level and api.has_capability("world.read") and world.level()
    if level and level.id ~= level_id then
        if level_id ~= nil then
            props.reset()
            people.reset()
            orders = {}
        end
        level_id = level.id
    end
    local now = timers.now()
    local dt = last_tick and math.min(now - last_tick, 1) or config.tick
    last_tick = now
    local rows, me = read_characters()
    local here = me and me.position
    read_held()

    -- What gives off heat for props: held flames, burning people (burning props add their own).
    local sources = {}
    if here then
        local flame = held_flame
        if weapon_burning(now) and (not flame or config.weapon.heat > flame.heat) then
            flame = config.weapon
        end
        if flame then
            sources[#sources + 1] = { position = here, heat = flame.heat, reach = flame.reach }
        end
    end
    -- NPCs' held torches, where the runtime reports what they hold (requested).
    for _, row in ipairs(rows) do
        if row.held and row.position and not row.is_player and not row.dead then
            local flame = flame_of(row.held.right) or flame_of(row.held.left)
            if flame then
                sources[#sources + 1] = { position = row.position, heat = flame.heat, reach = flame.reach }
            end
        end
    end
    people.sources(sources)

    local caught = apply_orders(now, rows, me)
    for _, entry in ipairs(props.step(now, dt, sources)) do
        caught[#caught + 1] = entry
    end

    -- What sets people alight: burning props, and the game's own fires where the runtime lists them.
    local fires = {}
    for _, entry in ipairs(props.burning()) do
        fires[#fires + 1] = { position = entry.position }
    end
    if world and world.fires and api.has_capability("world.read") then
        local ok, native = pcall(world.fires, config.scan.radius)
        if ok and native then
            for _, fire in ipairs(native) do
                if fire.position and not fire.mod then
                    fires[#fires + 1] = { position = fire.position, reach = config.native_reach }
                end
            end
        end
    end
    for _, row in ipairs(people.step(now, dt, rows, fires)) do
        caught[#caught + 1] = row
    end

    if people.need_roles() and api.has_capability("characters.read") then
        local ok, view = pcall(characters.snapshot, { details = true })
        if ok and view then
            people.learn_roles(view.characters)
        end
    end

    if people.owes() then
        timers.after(0, flush_damage)
    end
    if props.busy() then
        timers.after(0, flush_props)
    end
    if people.has_fx() then
        timers.after(0, people.flush_fx)
    end
    timers.after(0, function() people.flush_glow(here) end)
    if heard(caught, here) then
        sound_due = true
        timers.after(0, play_sound)
    end
end

-- Flammables are looked up only while something burns ("hot") or the player holds a flame ("warm").
local function scan()
    local now = timers.now()
    local hot = people.count() > 0 or #props.burning() > 0 or #orders > 0
    local warm = held_flame ~= nil or weapon_burning(now)
    if not hot then
        if not warm then
            return
        end
        scan_skip = (scan_skip + 1) % math.max(1, math.floor(config.scan.warm / config.scan.hot + 0.5))
        if scan_skip ~= 0 then
            return
        end
    end
    props.scan(now)
end

local function stop()
    if tick_timer then
        timers.cancel(tick_timer)
        tick_timer = nil
    end
    if scan_timer then
        timers.cancel(scan_timer)
        scan_timer = nil
    end
end

-- Fires this mod lit and every burn belong to the level: any phase change starts over.
events.on("runtime.phase", function(event)
    stop()
    props.reset()
    people.reset()
    orders, weapon_until, last_tick, held_flame, level_id = {}, 0, nil, nil, nil
    if event.phase == "session" then
        tick_timer = timers.every(config.tick, tick)
        scan_timer = timers.every(config.scan.hot, scan)
    end
end)
