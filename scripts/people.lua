-- Burning characters: who is alight, for how long, the damage it does, how it spreads between people
-- and from fires, and how it shows. A character on the ground rolls the flames out faster.
--
-- Damage goes through the game's own damage applier (character:damage, player.damage), never a
-- health write. The flames on the body need the runtime's effects.attach_fire; until then the nearest
-- burning characters glow with a placed light. Burns leave marks other mods draw (characters.set_mark):
-- "fire.burning" (1 while alight) and "fire.scorch" (0..255, how burnt; it never fades in a level), for
-- the ExCamera skin bake to char skin and cloth (excamera/BURN-MARKS.md).
local config = require("config")

local people = {}

local burning = {}          -- handle -> {handle, record_id, is_player, left, position, down, missing, fx, undead}
local pending = {}          -- handle -> {health, balance}: damage owed, paid in its own callback
local fx_on, fx_off = {}, {}
local glow_names = { "burn1", "burn2", "burn3" }
local glowing = {}          -- light name -> true
local undead_roles = { Undead = true, Corpse = true }
local serial = 0
local warned = {}
local marks = {}            -- mark target ("player" or a record id) -> {burning, scorch, sent_burning, sent_scorch}
local MARK_TARGETS = 15     -- the runtime keeps 32 marks an addon: two names each, and main.lua's "fire.blade"

local function warn_once(what, text)
    if not warned[what] then
        warned[what] = true
        log.info(text)
    end
end

local function distance(a, b)
    local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function mark_target(state)
    if state.is_player then
        return "player"
    end
    return (state.record_id or 0) ~= 0 and state.record_id or nil
end

local function mark_of(state)
    local target = mark_target(state)
    if not target then
        return nil
    end
    local mark = marks[target]
    if not mark then
        local n = 0
        for _ in pairs(marks) do
            n = n + 1
        end
        if n >= MARK_TARGETS then
            return nil
        end
        mark = { burning = 0, scorch = 0, sent_burning = 0, sent_scorch = 0 }
        marks[target] = mark
    end
    return mark
end

local function chance(per_second, dt)
    return math.random() < 1 - (1 - per_second) ^ dt
end

function people.is_burning(handle)
    return burning[handle] ~= nil
end

function people.count()
    local n = 0
    for _ in pairs(burning) do
        n = n + 1
    end
    return n
end

-- Sets a character alight (or keeps one burning longer). `who` is a characters.read row or a
-- character.hit event (both carry `handle`), or a table {handle, record_id, is_player, position}.
-- Returns true when it caught now.
function people.ignite(who, seconds, strength)
    local handle = who and who.handle
    if not handle or who.dead then
        return false
    end
    local person = config.person
    seconds = math.min(seconds or person.seconds, person.max_seconds)
    local state = burning[handle]
    if state then
        state.left = math.min(math.max(state.left, seconds), person.max_seconds)
        state.strength = math.max(state.strength, strength or 1)
        return false
    end
    if people.count() >= person.max then
        return false
    end
    serial = serial + 1
    burning[handle] = { handle = handle, record_id = who.record_id, is_player = who.is_player == true,
                        left = seconds, strength = strength or 1, position = who.position, missing = 0,
                        fx = "b" .. serial }
    fx_on[#fx_on + 1] = burning[handle]
    local mark = mark_of(burning[handle])
    if mark then
        mark.burning = 1
    end
    return true
end

local function owe(handle, health, balance)
    local debt = pending[handle] or { health = 0, balance = 0 }
    debt.health = debt.health + health
    debt.balance = debt.balance + balance
    pending[handle] = debt
end

-- Immediate damage on top of a burn (a gout of fire), paid with the next damage flush.
function people.scorch(who, health, balance)
    if who and who.handle and not who.dead then
        owe(who.handle, health or 0, balance or 0)
    end
end

local function put_out(handle)
    local state = burning[handle]
    burning[handle] = nil
    if state then
        fx_off[#fx_off + 1] = state.fx
        local mark = mark_of(state)
        if mark then
            mark.burning = 0
        end
    end
end

-- One step: `rows` is this pulse's characters.snapshot; `fires` the positions that set people alight
-- (burning props and native fires). Returns the characters that caught this step.
function people.step(now, dt, rows, fires)
    local person = config.person
    local caught = {}
    local by_handle = {}
    for _, row in ipairs(rows) do
        if row.handle then
            by_handle[row.handle] = row
        end
    end
    for handle, state in pairs(burning) do
        local row = by_handle[handle]
        if not row then
            -- Out of the list for a while: gone, not merely unread for a pulse.
            state.missing = state.missing + dt
            if state.missing > 2 then
                put_out(handle)
            end
        elseif row.dead then
            put_out(handle)
        else
            state.missing, state.position, state.down = 0, row.position, row.down
            state.left = state.left - dt * (row.down and person.down or 1)
            if state.left <= 0 then
                put_out(handle)
            else
                local share = (state.is_player and person.player or 1) * (state.undead and person.undead or 1) * state.strength
                owe(handle, person.health * dt * share, person.balance * dt * share)
                local mark = mark_of(state)
                if mark then
                    mark.scorch = math.min(255, mark.scorch + config.marks.rate * dt * state.strength)
                end
            end
        end
    end
    -- Spreading: from burning people to those beside them, and from fires to those standing in them.
    for _, row in ipairs(rows) do
        if row.handle and row.position and not row.dead and not burning[row.handle] then
            local caught_now = false
            for handle, state in pairs(burning) do
                if handle ~= row.handle and state.position
                    and distance(state.position, row.position) <= person.spread_reach
                    and chance(person.spread_chance, dt) then
                    caught_now = true
                    break
                end
            end
            if not caught_now then
                for _, fire in ipairs(fires) do
                    if distance(fire.position, row.position) <= (fire.reach or person.catch_reach)
                        and chance(person.catch_chance, dt) then
                        caught_now = true
                        break
                    end
                end
            end
            if caught_now and people.ignite(row, person.seconds) then
                caught[#caught + 1] = row
            end
        end
    end
    return caught
end

-- Burning characters as heat sources for props.
function people.sources(out)
    for _, state in pairs(burning) do
        if state.position then
            out[#out + 1] = { position = state.position, heat = config.person.heat, reach = config.person.reach }
        end
    end
end

-- Burning NPCs whose roles are not known yet (the dead burn worse); the caller reads details once.
function people.need_roles()
    for _, state in pairs(burning) do
        if state.undead == nil and not state.is_player then
            return true
        end
    end
    return false
end

function people.learn_roles(rows)
    for _, row in ipairs(rows) do
        local state = row.handle and burning[row.handle]
        if state and state.undead == nil then
            state.undead = false
            for _, role in ipairs(row.roles or {}) do
                if undead_roles[role.name] then
                    state.undead = true
                end
            end
        end
    end
    for _, state in pairs(burning) do
        if state.undead == nil then
            state.undead = false
        end
    end
end

function people.owes()
    return next(pending) ~= nil
end

-- The Injuries mod bakes the burn into the skin and soot into clothes from what each tick dealt.
local function tell_injuries(row, health)
    if addons and addons.send and health > 0 then
        addons.send(config.injuries, "injuries.burn", { target = row.is_player and "player" or { handle = row.handle },
                                                        amount = health })
    end
end

-- Pays the damage owed, in its own callback (the game's damage applier is a staged call: 4 a callback).
-- Returns true when more is owed than this callback could pay.
function people.flush_damage()
    local view = api.has_capability("characters.read") and characters.snapshot()
    if not view then
        return false
    end
    local calls = 0
    for _, row in ipairs(view.characters) do
        local debt = row.handle and pending[row.handle]
        if debt and calls < 4 then
            pending[row.handle] = nil
            local health, balance = math.min(debt.health, 1), math.min(debt.balance, 1)
            if row.is_player then
                if player and player.damage and api.has_capability("player.damage") then
                    pcall(player.damage, balance, health, false)
                    calls = calls + 1
                    tell_injuries(row, health)
                else
                    warn_once("player", "the player cannot be burnt: this runtime has no player.damage")
                end
            elseif row.damage and not row.dead then
                pcall(row.damage, row, { health = health, balance = balance, can_fall = false })
                calls = calls + 1
                tell_injuries(row, health)
            end
        end
    end
    -- Debts of characters no longer listed are dropped.
    for handle in pairs(pending) do
        local listed = false
        for _, row in ipairs(view.characters) do
            if row.handle == handle then
                listed = true
                break
            end
        end
        if not listed then
            pending[handle] = nil
        end
    end
    return next(pending) ~= nil
end

local function can_attach()
    return effects and effects.attach_fire ~= nil and api.has_capability("effects.fire")
end

-- Flames on bodies (requested effects.attach_fire), in their own callback.
function people.flush_fx()
    if not can_attach() then
        fx_on, fx_off = {}, {}
        return
    end
    for _, name in ipairs(fx_off) do
        pcall(effects.remove_fire, name)
    end
    fx_off = {}
    for _, state in ipairs(fx_on) do
        if burning[state.handle] then
            pcall(effects.attach_fire, state.fx, state.is_player and "player" or { handle = state.handle },
                  { size = 0.5 * state.strength })
        end
    end
    fx_on = {}
end

-- Without body flames, the three burning characters nearest `here` glow (placed lights, moved each tick).
function people.flush_glow(here)
    if can_attach() or not (lights and lights.place and api.has_capability("world.lights")) then
        return
    end
    local list = {}
    for _, state in pairs(burning) do
        if state.position then
            list[#list + 1] = state
        end
    end
    if here then
        table.sort(list, function(a, b) return distance(a.position, here) < distance(b.position, here) end)
    end
    local light = config.light
    local used = {}
    for i, name in ipairs(glow_names) do
        local state = list[i]
        if state then
            -- A little flicker: fire is never steady.
            local flicker = 0.8 + 0.4 * math.random()
            local ok = pcall(lights.place, name, {
                position = { state.position[1], state.position[2] + light.up, state.position[3] },
                color = light.color, range = light.range, intensity = light.intensity * flicker,
                glow = { size = light.glow, color = { 1, 0.55, 0.2 } } })
            used[name] = ok
        end
    end
    for name in pairs(glowing) do
        if not used[name] then
            pcall(lights.remove, name)
        end
    end
    glowing = used
end

-- Marks that changed (alight or out, or scorch grown by a step), in their own callback.
function people.marks_due()
    for _, mark in pairs(marks) do
        if mark.burning ~= mark.sent_burning or math.floor(mark.scorch) >= mark.sent_scorch + config.marks.step
            or (mark.scorch >= 255 and mark.sent_scorch < 255) then
            return true
        end
    end
    return false
end

function people.flush_marks()
    if not (characters and characters.set_mark and api.has_capability("characters.marks")) then
        return
    end
    for target, mark in pairs(marks) do
        if mark.burning ~= mark.sent_burning then
            if pcall(characters.set_mark, target, config.marks.burning, mark.burning) then
                mark.sent_burning = mark.burning
            end
        end
        local scorch = math.floor(mark.scorch)
        if scorch >= mark.sent_scorch + config.marks.step or (scorch >= 255 and mark.sent_scorch < 255) then
            if pcall(characters.set_mark, target, config.marks.scorch, scorch) then
                mark.sent_scorch = scorch
            end
        end
    end
end

function people.has_fx()
    return #fx_on > 0 or #fx_off > 0
end

function people.reset()
    burning, pending, fx_on, fx_off, marks = {}, {}, {}, {}, {}
    if next(glowing) and lights and lights.remove then
        for name in pairs(glowing) do
            pcall(lights.remove, name)
        end
    end
    glowing = {}
end

return people
