-- Runs scripts/main.lua against a stub of the runtime (API.md 0.28.0 plus the calls requested in
-- RUNTIME-REQUESTS.md). Checks the addon's own logic only, not the runtime or the game.
-- Usage: lua harness.lua <mod folder>
local root = assert(arg[1], "mod folder")

local function new(opts)
    opts = opts or {}
    local s = { logs = {}, now = 100, timers = {}, afters = {}, handlers = {}, topics = {},
                rows = {}, props = {}, held = {}, fires_lit = {}, fires_out = {}, lights = {}, sounds = {},
                damage = {}, player_damage = {}, fx = {}, calls_in_callback = 0, max_calls = 0,
                level = 1, random = opts.random or 0 }
    local caps = { ["events.lifecycle"] = true, timers = true, ["world.read"] = true, ["characters.read"] = true,
                   ["inventory.read"] = true, ["events.combat"] = true, ["characters.damage"] = true,
                   ["player.damage"] = true, ["world.lights"] = true, ["ui.sound"] = true,
                   ["characters.marks"] = true, ["world.fire"] = not opts.no_fire, ["effects.fire"] = not opts.no_fx }
    local mathx = {}
    for k, v in pairs(math) do mathx[k] = v end
    mathx.random = function(n) if n then return 1 end return s.random end
    local env = { math = mathx, string = string, table = table, ipairs = ipairs, pairs = pairs, next = next,
                  tonumber = tonumber, tostring = tostring, type = type, error = error, assert = assert,
                  pcall = pcall, select = select }
    env.log = { info = function(m) s.logs[#s.logs + 1] = "info: " .. m end,
                warn = function(m) s.logs[#s.logs + 1] = "warn: " .. m end }
    env.api = { has_capability = function(name) return caps[name] == true end }
    env.events = { on = function(name, fn) s.handlers[name] = fn end }
    s.injuries = {}
    env.addons = { on = function(topic, fn) s.topics[topic] = fn return true end,
                   send = function(target, topic, value)
                       assert(target == "com.necrosis.injuries" and topic == "injuries.burn" and value.amount > 0)
                       local key = value.target == "player" and "player" or value.target.handle
                       s.injuries[key] = (s.injuries[key] or 0) + value.amount
                       return true end }
    env.timers = {
        every = function(sec, fn) s.timers[#s.timers + 1] = { sec = sec, fn = fn, due = s.now + sec } return #s.timers end,
        after = function(sec, fn) s.afters[#s.afters + 1] = fn return 1000 + #s.afters end,
        cancel = function(id) if s.timers[id] then s.timers[id].fn = nil end return true end,
        now = function() return s.now end,
    }
    local function staged() s.calls_in_callback = s.calls_in_callback + 1
        if s.calls_in_callback > s.max_calls then s.max_calls = s.calls_in_callback end
        assert(s.calls_in_callback <= 4, "more than 4 staged calls in one callback") end
    env.characters = { snapshot = function(o)
        local out = {}
        for _, r in ipairs(s.rows) do
            local row = { handle = r.handle, record_id = r.record_id, is_player = r.is_player, dead = r.dead, down = r.down,
                          held = r.held, held_lit = r.held_lit,
                          position = { r.position[1], r.position[2], r.position[3] }, roles = o and o.details and r.roles or nil }
            if not r.is_player then
                row.damage = function(self, spec) staged()
                    assert(spec.health >= 0 and spec.health <= 1 and spec.balance >= 0 and spec.balance <= 1)
                    s.damage[r.handle] = (s.damage[r.handle] or 0) + spec.health return true end
            end
            out[#out + 1] = row
        end
        return { characters = out }
    end }
    s.marks = {}
    env.characters.set_mark = function(target, name, value)
        assert((target == "player" or math.type(target) == "integer") and name:match("^fire%.") and math.type(value) == "integer"
               and value >= 0 and value <= 255)
        s.marks[tostring(target) .. ":" .. name] = value ~= 0 and value or nil
        return true
    end
    env.player = { damage = function(b, h, fall) staged() s.player_damage[#s.player_damage + 1] = h return true end }
    env.inventory = { snapshot = function() return { weapons = { { item_id = s.held[1] or 0 }, { item_id = s.held[2] or 0 } } } end }
    env.world = {
        level = function() return { id = s.level, loaded = true } end,
        nearby = function(radius, names, how)
            s.nearby_calls = (s.nearby_calls or 0) + 1
            local prefix = opts.prefixes and how and how.prefix
            if prefix then assert(#names <= 64) else assert(#names <= 16, "more than 16 names") end
            local wanted = {}
            for _, n in ipairs(names) do wanted[n:lower()] = true end
            local function matches(model)
                model = model:lower()
                if not prefix then return wanted[model] end
                for n in pairs(wanted) do if model:sub(1, #n) == n then return true end end
                return false
            end
            local me
            for _, r in ipairs(s.rows) do if r.is_player then me = r.position end end
            local out = {}
            for _, p in ipairs(s.props) do
                local dx, dz = p.position[1] - me[1], p.position[3] - me[3]
                if matches(p.name) and math.sqrt(dx * dx + dz * dz) <= radius then
                    out[#out + 1] = { name = p.name, position = p.position }
                end
            end
            return { objects = out }
        end,
    }
    if not opts.no_fire then
        env.world.light_fire = function(name, spec) staged() s.fires_lit[name] = spec.position return true end
        env.world.put_out_fire = function(name) staged() s.fires_out[name] = true return true end
    end
    if opts.native_fire then
        env.world.fires = function() return { { position = opts.native_fire } } end
    end
    env.lights = { place = function(name, spec) s.lights[name] = spec return true end,
                   remove = function(name) s.lights[name] = nil return true end }
    env.ui = { sound = function(name) s.sounds[#s.sounds + 1] = name return true end }
    if not opts.no_fx then
        env.effects = { attach_fire = function(name, target) s.fx[name] = target return true end,
                        remove_fire = function(name) s.fx[name] = nil return true end }
    end
    local loaded = {}
    env.require = function(name)
        if loaded[name] == nil then
            loaded[name] = assert(loadfile(root .. "/scripts/" .. name .. ".lua", "t", env))()
        end
        return loaded[name]
    end
    assert(loadfile(root .. "/scripts/main.lua", "t", env))()
    s.session = function() s.handlers["runtime.phase"]({ phase = "session" }) end
    -- Advance the clock in tick-sized steps, running due timers and every callback they schedule.
    s.run = function(seconds)
        local stop = s.now + seconds
        while s.now < stop - 1e-9 do
            s.now = s.now + 0.25
            for _, t in ipairs(s.timers) do
                if t.fn and s.now >= t.due - 1e-9 then
                    t.due = t.due + t.sec
                    s.calls_in_callback = 0
                    t.fn()
                end
            end
            local guard = 0
            while #s.afters > 0 do
                local a = s.afters s.afters = {}
                for _, fn in ipairs(a) do s.calls_in_callback = 0 fn() end
                guard = guard + 1 assert(guard < 50, "after loop")
            end
        end
    end
    s.send = function(topic, value) s.topics[topic](value, "test") end
    s.hit = function(e) s.handlers["character.hit"](e) end
    s.player = { handle = 1, record_id = 0, is_player = true, position = { 0, 0, 0 } }
    s.rows = { s.player }
    return s
end

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local passed = 0
local function case(name, fn) fn() passed = passed + 1 print("ok  " .. name) end

case("a held torch beside a sack sets it alight, it burns out and does not catch again", function()
    local s = new() s.held = { 0x1F }
    s.props = { { name = "sack a", position = { 50, 0, 0 } } }
    s.session() s.run(6)
    assert(count(s.fires_lit) == 1, "lit " .. count(s.fires_lit))
    s.held = {} s.run(22)
    assert(count(s.fires_out) == 1, "put out")
    s.held = { 0x1F } s.run(10)
    assert(count(s.fires_lit) == 1, "a burnt-out sack stays out")
end)

case("fire spreads from a burning sack to a crate beside it, never to one across the room", function()
    local s = new() s.held = { 0x1F }
    s.props = { { name = "sack a", position = { 50, 0, 0 } }, { name = "cratesmall a", position = { 150, 0, 0 } },
                { name = "chair a", position = { 900, 0, 0 } } }
    s.session() s.run(3) s.held = {} s.run(15)
    assert(count(s.fires_lit) == 2, "lit " .. count(s.fires_lit))
    for _, at in pairs(s.fires_lit) do assert(at[1] < 500) end
end)

case("no held flame, nothing burns and nothing is scanned", function()
    local s = new()
    s.props = { { name = "sack a", position = { 30, 0, 0 } } }
    s.session() s.run(10)
    assert(count(s.fires_lit) == 0)
end)

case("a torch hit sets the victim alight; the burn hurts through the game's applier and ends", function()
    local s = new()
    local foe = { handle = 7, record_id = 70, position = { 100, 0, 0 } }
    s.rows[2] = foe
    s.session()
    s.hit({ source = "weapon", handle = 7, record_id = 70, weapon_id = 0x1F, attacker = { is_player = true } })
    s.run(10)
    local dealt = s.damage[7] or 0
    assert(dealt > 0.06 and dealt < 0.12, "burn " .. dealt)
    assert(count(s.fx) == 0, "flames removed when it ends")
end)

case("an unlucky torch swing does not ignite; a blocked one never does", function()
    local s = new{ random = 0.9 }
    s.rows[2] = { handle = 7, position = { 100, 0, 0 } }
    s.session()
    s.hit({ source = "weapon", handle = 7, weapon_id = 0x1F, attacker = { is_player = true } })
    s.run(3) assert(not s.damage[7])
    local t = new()
    t.rows[2] = { handle = 7, position = { 100, 0, 0 } } t.session()
    t.hit({ source = "weapon", handle = 7, weapon_id = 0x1F, blocked = true, attacker = { is_player = true } })
    t.run(3) assert(not t.damage[7])
end)

case("a knocked-down character rolls the flames out sooner", function()
    local s = new()
    s.rows[2] = { handle = 7, position = { 100, 0, 0 }, down = true }
    s.session() s.send("fire.ignite", { handle = 7, seconds = 6 }) s.run(10)
    assert(s.damage[7] < 0.06, "down burn " .. s.damage[7])
end)

case("a flaming weapon ignites every victim while it lasts, then stops", function()
    local s = new{ random = 0.99 }
    s.rows[2] = { handle = 7, position = { 100, 0, 0 } }
    s.rows[3] = { handle = 8, position = { -400, 0, 0 } }
    s.session() s.send("fire.weapon", { seconds = 5 })
    s.hit({ source = "weapon", handle = 7, weapon_id = 0x1234, attacker = { is_player = true } })
    s.run(6)
    s.hit({ source = "weapon", handle = 8, weapon_id = 0x1234, attacker = { is_player = true } })
    s.run(4)
    assert(s.damage[7] and not s.damage[8])
end)

case("a cone catches who and what is in front, not behind, and not the caster", function()
    local s = new()
    s.rows[2] = { handle = 7, position = { 200, 0, 20 } }
    s.rows[3] = { handle = 8, position = { -200, 0, 0 } }
    s.props = { { name = "crate mtob a01", position = { 150, 0, -30 } }, { name = "crate mtob a02", position = { 0, 0, 300 } } }
    s.session() s.held = { 0x1F } s.run(4) s.held = {}   -- the catalogue fills while a flame is out
    s.send("fire.ignite", { cone = { origin = { 0, 0, 0 }, dir = { 1, 0, 0 }, length = 350, angle = 30 }, health = 0.05 })
    s.run(1)
    assert(s.damage[7] and s.damage[7] >= 0.05 and not s.damage[8] and #s.player_damage == 0)
    local front = 0 for _, at in pairs(s.fires_lit) do if at[1] == 150 then front = front + 1 end end
    assert(front == 1 and count(s.fires_lit) == 1)
end)

case("fire passes from a burning character to one beside them, and from a brazier to who stands in it", function()
    local s = new()
    s.rows[2] = { handle = 7, position = { 100, 0, 0 } }
    s.rows[3] = { handle = 8, position = { 140, 0, 0 } }
    s.session() s.send("fire.ignite", { handle = 7 }) s.run(3)
    assert(s.damage[8], "spread")
    local t = new{ native_fire = { 500, 0, 0 } }
    t.rows[2] = { handle = 9, position = { 520, 0, 0 } }
    t.session() t.run(3) assert(t.damage[9], "brazier")
end)

case("the player burns too, at a reduced share", function()
    local s = new() s.session() s.send("fire.ignite", { target = "player", seconds = 4 }) s.run(6)
    local total = 0 for _, h in ipairs(s.player_damage) do total = total + h end
    assert(total > 0.05 and total < 0.1, "player " .. total)
end)

case("the dead burn worse", function()
    local s = new()
    s.rows[2] = { handle = 7, position = { 100, 0, 0 }, roles = { { name = "Undead" } } }
    s.rows[3] = { handle = 8, position = { -900, 0, 0 } }
    s.session() s.send("fire.ignite", { handle = 7, seconds = 4 }) s.send("fire.ignite", { handle = 8, seconds = 4 }) s.run(6)
    assert(s.damage[7] > s.damage[8] * 1.4)
end)

case("never more than 4 staged calls in a callback, with a crowd burning", function()
    local s = new()
    for i = 1, 10 do s.rows[#s.rows + 1] = { handle = 100 + i, position = { i * 300, 0, 0 } } end
    s.session()
    for i = 1, 10 do s.send("fire.ignite", { handle = 100 + i }) end
    s.run(3)
    assert(s.max_calls == 4 and count(s.damage) == 10)
end)

case("without the requested fire calls props never burn (logged once) but people still do", function()
    local s = new{ no_fire = true, no_fx = true } s.held = { 0x1F }
    s.props = { { name = "sack a", position = { 50, 0, 0 } } }
    s.rows[2] = { handle = 7, position = { 100, 0, 0 } }
    s.session() s.send("fire.ignite", { handle = 7 }) s.run(3)
    assert(s.lights.burn1, "glow stands in for body flames")
    s.run(5) assert(not s.lights.burn1, "the glow goes out with the burn")
    local notes = 0 for _, l in ipairs(s.logs) do if l:find("world.light_fire") then notes = notes + 1 end end
    assert(notes == 1 and s.damage[7] and count(s.fires_lit) == 0)
end)

case("leaving for the menu or another level drops every fire and burn", function()
    local s = new()
    s.rows[2] = { handle = 7, position = { 100, 0, 0 } }
    s.session() s.send("fire.ignite", { handle = 7, seconds = 10 }) s.run(1)
    local before = s.damage[7]
    s.level = 2 s.run(3)
    assert(s.damage[7] - before < 0.03, "stopped at the level change")
    s.handlers["runtime.phase"]({ phase = "menu" })
    for _, t in ipairs(s.timers) do assert(t.fn == nil) end
end)

case("bad messages are refused with a warning, not an error", function()
    local s = new() s.session()
    s.send("fire.ignite", { cone = { origin = "here" } }) s.send("fire.weapon", { seconds = -1 }) s.send("fire.ignite", 3)
    local warns = 0 for _, l in ipairs(s.logs) do if l:find("^warn") then warns = warns + 1 end end
    assert(warns == 3)
end)

case("burns leave marks: alight while burning, scorch that stays after", function()
    local s = new()
    s.rows[2] = { handle = 7, record_id = 70, position = { 100, 0, 0 } }
    s.session() s.send("fire.ignite", { handle = 7, seconds = 6 }) s.run(3)
    assert(s.marks["70:fire.burning"] == 1 and s.marks["70:fire.scorch"] >= 16)
    s.run(6)
    assert(s.marks["70:fire.burning"] == nil and s.marks["70:fire.scorch"] >= 48 and s.marks["70:fire.scorch"] <= 64)
    s.send("fire.ignite", { target = "player", seconds = 2 }) s.run(1)
    assert(s.marks["player:fire.burning"] == 1)
end)

case("a flaming weapon marks the player for ExCamera's blade flames, and clears it when it ends", function()
    local s = new() s.session() s.send("fire.weapon", { seconds = 3 }) s.run(1)
    assert(s.marks["player:fire.blade"] == 1)
    s.run(3) assert(s.marks["player:fire.blade"] == nil)
end)

case("hands the runtime reports: a lit torch heats props, an NPC's burning sword ignites on a hit, an unlit torch does not", function()
    local s = new()
    s.player.held, s.player.held_lit = { right = 0x1F }, { right = true }
    s.props = { { name = "sack a", position = { 50, 0, 0 } } }
    s.rows[2] = { handle = 7, position = { 3000, 0, 0 }, held = { right = 0x1F }, held_lit = { right = false } }
    s.session() s.run(4)
    assert(count(s.fires_lit) == 1, "the player's lit torch")
    s.hit({ source = "weapon", handle = 1, is_player = true, weapon_id = 0x9999, weapon_lit = true, attacker = { is_player = false } })
    s.hit({ source = "weapon", handle = 1, is_player = true, weapon_id = 0x1F, weapon_lit = false, attacker = { is_player = false } })
    s.run(2)
    assert(#s.player_damage > 0, "a burning blade ignites")
    local t = new()
    t.player.held, t.player.held_lit = { right = 0x1F }, { right = false }
    t.props = { { name = "sack a", position = { 50, 0, 0 } } }
    t.session() t.run(4) assert(count(t.fires_lit) == 0, "an unlit torch heats nothing")
end)

case("with name prefixes one call a scan finds the props; an old runtime falls back to exact names", function()
    local s = new{ prefixes = true } s.held = { 0x1F }
    s.props = { { name = "sack a", position = { 50, 0, 0 } }, { name = "barrel rusty a1", position = { 60, 0, 0 } } }
    s.session() s.run(1)
    local calls = s.nearby_calls
    assert(calls >= 1 and calls <= 3, "calls " .. calls)
    s.run(4)
    assert(count(s.fires_lit) == 1, "the sack, not the iron barrel")
    local t = new() t.held = { 0x1F }
    t.props = { { name = "sack a", position = { 50, 0, 0 } } }
    t.session() t.run(6) assert(count(t.fires_lit) == 1, "exact names on an older runtime")
end)

case("each burn tick tells Injuries what it dealt, NPC by handle and the player", function()
    local s = new()
    s.rows[2] = { handle = 7, position = { 100, 0, 0 } }
    s.session() s.send("fire.ignite", { handle = 7, seconds = 4, health = 0.05 }) s.send("fire.ignite", { target = "player", seconds = 2 })
    s.run(6)
    assert(math.abs(s.injuries[7] - s.damage[7]) < 1e-9 and s.injuries[7] > 0.1)
    local total = 0 for _, h in ipairs(s.player_damage) do total = total + h end
    assert(math.abs(s.injuries.player - total) < 1e-9)
end)

print(passed .. " passed")
