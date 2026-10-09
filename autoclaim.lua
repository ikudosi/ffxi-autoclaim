_addon.name = 'AutoClaim'
_addon.author = 'You'
_addon.version = '8.0'

_addon.commands = {'ac', 'autoclaim'}

local packets = require('packets')
local res = require('resources')

local MAX_DISTANCE = 20
local SCAN_INTERVAL = 0.25

-- Claim configuration
local CLAIM_TYPE = 'ja'          -- 'ja' or 'ma'
local CLAIM_ABILITY = 'Provoke'
local CLAIM_RECAST_ID = nil
local CLAIM_ACTION_ID = nil
local CLAIM_PACKET_CATEGORY = nil

local enabled = false
local last_scan = 0
local TARGET_ONLY_NAME = nil

-- Target States: IDLE, CLAIMING, ENGAGED
local state = 'IDLE'
local current_target = nil
local claim_sent_time = 0
local CLAIM_TIMEOUT = 1.5 -- Max seconds to wait for server response after sending claim packet

-- Blacklist setup for failed claims
local failed_targets = {}
local FAILED_TARGET_COOLDOWN = 2.0

-- Combat retry cadences
local FACE_INTERVAL = 0.25
local last_face = 0
local last_engage = 0
local ENGAGE_RETRY = 0.75

------------------------------------------------------------
-- State & Target Helpers
------------------------------------------------------------

local function reset_state(message, blacklist_id)
    if blacklist_id then
        failed_targets[blacklist_id] = os.clock() + FAILED_TARGET_COOLDOWN
    end

    if message then
        windower.add_to_chat(123, '[AutoClaim] ' .. message)
    end

    state = 'IDLE'
    current_target = nil
    claim_sent_time = 0
end

local function target_mob(mob)
    local player = windower.ffxi.get_player()
    if not player or not mob then return false end

    packets.inject(packets.new('incoming', 0x058, {
        ['Player'] = player.id,
        ['Target'] = mob.id,
        ['Player Index'] = player.index,
    }))
    return true
end

local function face_target(mob)
    local player = windower.ffxi.get_mob_by_id(windower.ffxi.get_player().id)
    if not player or not mob then return end

    local angle = (math.atan2(mob.y - player.y, mob.x - player.x) * 180 / math.pi) * -1
    windower.ffxi.turn(angle:radian())
end

local function resolve_claim_ability()
    CLAIM_RECAST_ID = nil
    CLAIM_ACTION_ID = nil
    CLAIM_PACKET_CATEGORY = nil

    if CLAIM_TYPE == 'ma' then
        local spell = res.spells:with('en', CLAIM_ABILITY)
        if spell then
            CLAIM_RECAST_ID = spell.recast_id
            CLAIM_ACTION_ID = spell.id
            CLAIM_PACKET_CATEGORY = 0x03
        end
    else
        local ability = res.job_abilities:with('en', CLAIM_ABILITY)
        if ability then
            CLAIM_RECAST_ID = ability.recast_id
            CLAIM_ACTION_ID = ability.id
            CLAIM_PACKET_CATEGORY = 0x09
        end
    end
end

local function claim_recast()
    if not CLAIM_RECAST_ID or not CLAIM_ACTION_ID then return 999 end

    if CLAIM_TYPE == 'ma' then
        local recasts = windower.ffxi.get_spell_recasts()
        return recasts and recasts[CLAIM_RECAST_ID] or 0
    end

    local recasts = windower.ffxi.get_ability_recasts()
    return recasts and recasts[CLAIM_RECAST_ID] or 0
end

local function is_eligible_mob(mob, player)
    if not mob or not mob.id or not mob.index or not mob.name
        or not player or mob.id == player.id or not mob.is_npc
        or not mob.hpp or mob.hpp <= 0 or not mob.valid_target
        or mob.spawn_type ~= 16 then
        return false
    end

    -- Skip if on failure cooldown
    if failed_targets[mob.id] and os.clock() < failed_targets[mob.id] then
        return false
    end

    -- Name filter check
    if TARGET_ONLY_NAME and TARGET_ONLY_NAME ~= '' then
        if mob.name:lower() ~= TARGET_ONLY_NAME:lower() then
            return false
        end
    end

    return mob.claim_id == 0 or mob.claim_id == nil or mob.claim_id == player.id
end

local function find_best_target()
    local player = windower.ffxi.get_player()
    if not player then return nil end

    local mobs = windower.ffxi.get_mob_array()
    if not mobs then return nil end

    local closest = nil
    local closest_distance = MAX_DISTANCE

    for _, mob in pairs(mobs) do
        if is_eligible_mob(mob, player) then
            local dist = math.sqrt(mob.distance or 999999)
            if dist <= closest_distance then
                closest = mob
                closest_distance = dist
            end
        end
    end

    return closest
end

local function send_claim_action(mob)
    if not mob or not CLAIM_ACTION_ID or not CLAIM_PACKET_CATEGORY then return false end

    local packet = packets.new('outgoing', 0x01A, {
        ['Target'] = mob.id,
        ['Target Index'] = mob.index,
        ['Category'] = CLAIM_PACKET_CATEGORY,
        ['Param'] = CLAIM_ACTION_ID,
        ['X Offset'] = 0, ['Z Offset'] = 0, ['Y Offset'] = 0,
    })
    packets.inject(packet)
    return true
end

local function start_engagement(mob)
    local player = windower.ffxi.get_player()
    if not player or not mob then return end

    target_mob(mob)
    face_target(mob)
    windower.chat.input('/attack <t>')

    local packet = packets.new('outgoing', 0x01A, {
        ['Target'] = mob.id,
        ['Target Index'] = mob.index,
        ['Category'] = 0x02,
        ['Param'] = 0,
        ['X Offset'] = 0, ['Z Offset'] = 0, ['Y Offset'] = 0,
    })
    packets.inject(packet)

    windower.add_to_chat(158, '[AutoClaim] Engage -> ' .. mob.name)
    last_engage = os.clock()
end

------------------------------------------------------------
-- Out-of-Range Feedback
------------------------------------------------------------

windower.register_event('incoming text', function(original, modified, mode)
    if not enabled or state == 'IDLE' or not current_target then return end

    local text = modified or original or ''
    if text:find(' is out of range%.', 1, false) then
        local mob_id = current_target
        reset_state('Target out of range. Releasing and blacklisting.', mob_id)
    end
end)

------------------------------------------------------------
-- Main State Watchdog (Prerender)
------------------------------------------------------------

windower.register_event('prerender', function()
    if not enabled then return end

    local now = os.clock()
    local player = windower.ffxi.get_player()
    if not player then return end

    -- Death check
    if player.status == 2 or (player.vitals and player.vitals.hp and player.vitals.hp <= 0) then
        enabled = false
        reset_state('OFF - player died.')
        return
    end

    --------------------------------------------------------
    -- STATE 1: IDLE / SCANNING
    --------------------------------------------------------
    if state == 'IDLE' then
        if player.status == 1 then return end -- Don't scan if engaged manually
        if now - last_scan < SCAN_INTERVAL then return end

        last_scan = now
        local mob = find_best_target()

        if mob then
            if claim_recast() > 0 then return end -- Wait for claim ability to be off recast

            current_target = mob.id
            state = 'CLAIMING'
            claim_sent_time = now

            target_mob(mob)
            face_target(mob)

            if send_claim_action(mob) then
                windower.add_to_chat(158, string.format('[AutoClaim] Claiming %s (%.1f yalms)...', mob.name, math.sqrt(mob.distance or 999999)))
            else
                reset_state('Failed to send claim action packet.')
            end
        end

    --------------------------------------------------------
    -- STATE 2: CLAIMING (Waiting for server confirmation)
    --------------------------------------------------------
    elseif state == 'CLAIMING' then
        local mob = windower.ffxi.get_mob_by_id(current_target)

        -- Target disappeared or died
        if not mob or not mob.hpp or mob.hpp <= 0 then
            reset_state('Claim target disappeared or died.')
            return
        end

        -- Target was claimed by someone else
        if mob.claim_id and mob.claim_id ~= 0 and mob.claim_id ~= player.id then
            reset_state('Target claimed by another player.', mob.id)
            return
        end

        -- SUCCESS: Target is officially ours!
        if mob.claim_id == player.id then
            windower.add_to_chat(158, '[AutoClaim] *** CLAIMED *** ' .. mob.name)
            state = 'ENGAGED'
            start_engagement(mob)
            return
        end

        -- TIMEOUT: We sent the packet, but server hasn't given us claim_id in 1.5s
        if now - claim_sent_time > CLAIM_TIMEOUT then
            reset_state('Claim packet timed out without confirmation.', mob.id)
            return
        end

        -- Keep facing target while waiting on packet
        if now - last_face >= FACE_INTERVAL then
            target_mob(mob)
            face_target(mob)
            last_face = now
        end

    --------------------------------------------------------
    -- STATE 3: ENGAGED / COMBAT
    --------------------------------------------------------
    elseif state == 'ENGAGED' then
        local mob = windower.ffxi.get_mob_by_id(current_target)

        -- Target dead, missing, or claim lost
        if not mob or not mob.hpp or mob.hpp <= 0 or (mob.claim_id and mob.claim_id ~= player.id) then
            reset_state()
            return
        end

        -- Keep facing active target
        if now - last_face >= FACE_INTERVAL then
            target_mob(mob)
            face_target(mob)
            last_face = now
        end

        -- Retry auto-attack if client dropped combat stance
        if player.status ~= 1 and now - last_engage >= ENGAGE_RETRY then
            start_engagement(mob)
        end
    end
end)

------------------------------------------------------------
-- Commands & Initialization
------------------------------------------------------------

windower.register_event('addon command', function(...)
    local args = {...}
    local command = args[1] and args[1]:lower() or ''

    if command == 'on' then
        enabled = true
        reset_state()
        windower.add_to_chat(158, string.format('[AutoClaim] ON - range %.1f yalms | %s %s', MAX_DISTANCE, CLAIM_TYPE:upper(), CLAIM_ABILITY))
    elseif command == 'off' then
        enabled = false
        reset_state('[AutoClaim] OFF')
    elseif command == 'range' then
        local value = tonumber(args[2])
        if value and value > 0 then
            MAX_DISTANCE = value
            windower.add_to_chat(158, string.format('[AutoClaim] Scan range set to %.1f yalms.', MAX_DISTANCE))
        end
    elseif command == 'target_only' then
        if not args[2] or args[2]:lower() == 'off' then
            TARGET_ONLY_NAME = nil
            windower.add_to_chat(158, '[AutoClaim] Target filter cleared.')
        else
            TARGET_ONLY_NAME = table.concat({select(2, ...)}, ' ')
            windower.add_to_chat(158, '[AutoClaim] Target filter set to: ' .. TARGET_ONLY_NAME)
        end
    elseif command == 'type' then
        if args[2] and (args[2]:lower() == 'ja' or args[2]:lower() == 'ma') then
            CLAIM_TYPE = args[2]:lower()
            resolve_claim_ability()
            windower.add_to_chat(158, '[AutoClaim] Type set to ' .. CLAIM_TYPE:upper())
        end
    elseif command == 'ability' then
        if args[2] then
            CLAIM_ABILITY = table.concat({select(2, ...)}, ' ')
            resolve_claim_ability()
            windower.add_to_chat(158, '[AutoClaim] Ability set to ' .. CLAIM_ABILITY)
        end
    end
end)

windower.register_event('load', function()
    resolve_claim_ability()
    windower.add_to_chat(158, '[AutoClaim] Loaded v' .. _addon.version)
end)
