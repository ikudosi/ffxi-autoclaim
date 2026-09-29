_addon.name = 'AutoClaim'
_addon.author = 'You'
_addon.version = '6.0'

_addon.commands = {'ac', 'autoclaim'}

local packets = require('packets')
local res = require('resources')

local MAX_DISTANCE = 16.5
local SCAN_INTERVAL = 0.25

-- Claim ability configuration.
local CLAIM_TYPE = 'ja'          -- 'ja' or 'ma'
local CLAIM_ABILITY = 'Provoke'
local CLAIM_RECAST_ID = nil
local CLAIM_ACTION_ID = nil
local CLAIM_PACKET_CATEGORY = nil

local enabled = false
local locked_target = nil
local busy = false
local claim_generation = 0
local last_scan = 0

-- Optional exact-name filter. When set, ONLY mobs with this exact name
-- (case-insensitive) are eligible for automatic claiming.
local TARGET_ONLY_NAME = nil

-- A failed/expired target is temporarily ignored by the scanner.
local failed_targets = {}
local FAILED_TARGET_COOLDOWN = 1.5

-- Give the server a short window to update claim_id after the claim packet.
local CLAIM_RESPONSE_TIMEOUT = 0.20

-- Keep the character pointed at the active mob and retry engagement at a
-- modest cadence. This is intentionally simple; no per-target state machine.
local FACE_INTERVAL = 0.25
local last_face = 0
local last_engage = 0
local ENGAGE_RETRY = 0.75

------------------------------------------------------------
-- Optional upkeep
------------------------------------------------------------
--
-- Disabled by default. Configure at runtime with:
--
--   //ac upkeep ja add "Majesty"
--   //ac upkeep ja add "Sentinel" 5
--   //ac upkeep ja remove "Sentinel"
--   //ac upkeep food "Grape Daifuku" 1800 60
--   //ac upkeep food off
--   //ac upkeep on
--
-- For Job Abilities, the Windower resource provides the buff status and
-- duration for normal buff-type JAs. The optional lead value says how many
-- seconds before the expected expiration we should refresh it.
--
-- Food uses the standard Food buff (ID 251) and a user-supplied duration,
-- because the food buff itself does not identify the remaining duration.
local UPKEEP_ENABLED = false
local UPKEEP_CHECK_INTERVAL = 0.50
local UPKEEP_JA_RETRY_DELAY = 2.0
local UPKEEP_FOOD_RETRY_DELAY = 10.0
local UPKEEP_MA_CAST_RETRY_DELAY = 8.0
local FOOD_BUFF_ID = 251

local UPKEEP_JAS = {}
local UPKEEP_MAS = {}
local UPKEEP_FOOD = nil
local upkeep_next_check = 0
local upkeep_food_expires = 0
local upkeep_food_next_attempt = 0

------------------------------------------------------------
-- Target / facing
------------------------------------------------------------

local function target_mob(mob)
    local player = windower.ffxi.get_player()

    if not player or not mob then
        return false
    end

    packets.inject(packets.new('incoming', 0x058, {
        ['Player'] = player.id,
        ['Target'] = mob.id,
        ['Player Index'] = player.index,
    }))

    return true
end

local function target_matches(mob)
    if not mob then
        return false
    end

    local target = windower.ffxi.get_mob_by_target('t')
    return target and target.id == mob.id
end

local function face_target(mob)
    local player = windower.ffxi.get_mob_by_id(
        windower.ffxi.get_player().id
    )

    if not player or not mob then
        return
    end

    local angle = (
        math.atan2(
            mob.y - player.y,
            mob.x - player.x
        ) * 180 / math.pi
    ) * -1

    windower.ffxi.turn(angle:radian())
end

local function get_distance(a, b)
    if not a or not b then
        return 999999
    end

    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z

    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

------------------------------------------------------------
-- Ability availability
------------------------------------------------------------

local function resolve_claim_ability()
    CLAIM_RECAST_ID = nil
    CLAIM_ACTION_ID = nil
    CLAIM_PACKET_CATEGORY = nil

    if CLAIM_TYPE == 'ma' then
        local spell = res.spells:with('en', CLAIM_ABILITY)

        if spell then
            CLAIM_RECAST_ID = spell.recast_id
            CLAIM_ACTION_ID = spell.id
            CLAIM_PACKET_CATEGORY = 0x03 -- Magic cast
        end
    else
        local ability = res.job_abilities:with('en', CLAIM_ABILITY)

        if ability then
            CLAIM_RECAST_ID = ability.recast_id
            CLAIM_ACTION_ID = ability.id
            CLAIM_PACKET_CATEGORY = 0x09 -- Job ability usage
        end
    end
end

local function claim_recast()
    if not CLAIM_RECAST_ID or not CLAIM_ACTION_ID then
        return 0
    end

    if CLAIM_TYPE == 'ma' then
        local recasts = windower.ffxi.get_spell_recasts()
        if not recasts then
            return 0
        end
        return recasts[CLAIM_RECAST_ID] or 0
    end

    local recasts = windower.ffxi.get_ability_recasts()
    if not recasts then
        return 0
    end
    return recasts[CLAIM_RECAST_ID] or 0
end

------------------------------------------------------------
-- Upkeep helpers
------------------------------------------------------------

local function player_has_buff(buff_id, player)
    if not buff_id or not player then
        return false
    end

    for _, active_id in pairs(player.buffs or {}) do
        if active_id == buff_id then
            return true
        end
    end

    return false
end

local function find_upkeep_ja(name)
    local needle = tostring(name):lower()

    for index, entry in ipairs(UPKEEP_JAS) do
        if entry.name:lower() == needle then
            return index, entry
        end
    end

    return nil
end

local function resolve_upkeep_ja(name)
    local ability = res.job_abilities:with('en', name)

    if not ability then
        return nil, 'Unable to resolve Job Ability: ' .. tostring(name)
    end

    if ability.prefix ~= '/jobability'
        or not ability.recast_id
        or ability.status == nil
        or not ability.duration
        or ability.duration <= 0 then
        return nil, string.format(
            '%s is not a renewable buff-type Job Ability according to Windower resources.',
            ability.en
        )
    end

    return {
        name = ability.en,
        id = ability.id,
        recast_id = ability.recast_id,
        buff_id = ability.status,
        duration = ability.duration,
        lead = 5,
        next_attempt = 0,
        active_until = 0,
        casting_until = 0,
    }
end

local function upkeep_recast(entry)
    local recasts = windower.ffxi.get_ability_recasts()

    if not recasts then
        return 999999
    end

    return recasts[entry.recast_id] or 999999
end

local function find_upkeep_ma(name)
    local needle = tostring(name):lower()

    for index, entry in ipairs(UPKEEP_MAS) do
        if entry.name:lower() == needle then
            return index, entry
        end
    end

    return nil
end

local function resolve_upkeep_ma(name)
    local spell = res.spells:with('en', name)

    if not spell then
        return nil, 'Unable to resolve spell: ' .. tostring(name)
    end

    if spell.prefix ~= '/magic'
        or not spell.recast_id
        or spell.status == nil
        or not spell.duration
        or spell.duration <= 0 then
        return nil, string.format(
            '%s is not a renewable buff-type magic spell according to Windower resources.',
            spell.en
        )
    end

    return {
        name = spell.en,
        id = spell.id,
        recast_id = spell.recast_id,
        buff_id = spell.status,
        duration = spell.duration,
        mp_cost = spell.mp_cost or 0,
        cast_time = spell.cast_time or 3,
        lead = 5,
        next_attempt = 0,
        active_until = 0,
        casting_until = 0,
        awaiting_buff = false,
    }
end

local function upkeep_spell_recast(entry)
    local recasts = windower.ffxi.get_spell_recasts()

    if not recasts then
        return 999999
    end

    return recasts[entry.recast_id] or 999999
end

local function initialize_upkeep_state(player)
    local now = os.clock()

    for _, entry in ipairs(UPKEEP_JAS) do
        if player_has_buff(entry.buff_id, player) then
            entry.active_until = now + math.max(1, entry.duration - entry.lead)
        else
            entry.active_until = 0
        end
    end

    for _, entry in ipairs(UPKEEP_MAS) do
        if player_has_buff(entry.buff_id, player) then
            entry.active_until = now + math.max(1, entry.duration - entry.lead)
        else
            entry.active_until = 0
        end
    end

    if UPKEEP_FOOD and player_has_buff(FOOD_BUFF_ID, player) then
        upkeep_food_expires = now + math.max(1, UPKEEP_FOOD.duration - UPKEEP_FOOD.lead)
    else
        upkeep_food_expires = 0
    end
end

local function use_upkeep_ja(entry, now, player)
    if not player
    or player.status > 1
    or now < entry.next_attempt then
        return false
    end

    local buff_active = player_has_buff(entry.buff_id, player)

    -- Trust the live buff list over the predicted expiry timestamp.  If the
    -- buff has already disappeared, refresh immediately even when the old
    -- active_until value has not been reached yet.
    if buff_active and now < entry.active_until then
        return false
    end

    if upkeep_recast(entry) > 0 then
        return false
    end

    windower.chat.input('/ja "' .. entry.name .. '" <me>')

    entry.next_attempt = now + UPKEEP_JA_RETRY_DELAY

    windower.add_to_chat(
        158,
        '[AutoClaim] Upkeep JA: ' .. entry.name
    )

    return true
end

local function upkeep_ma_is_casting(now)
    for _, entry in ipairs(UPKEEP_MAS) do
        if now < (entry.casting_until or 0) then
            return true
        end
    end

    return false
end

local function use_upkeep_ma(entry, now, player)
    if not player
    or player.status > 1
    or now < entry.next_attempt
    or now < (entry.casting_until or 0)
    then
        return false
    end

    local buff_active = player_has_buff(entry.buff_id, player)

    -- Once we submit a maintenance spell, do NOT submit it again merely
    -- because the buff list has not updated yet.  We wait for the gain-buff
    -- event (or the explicit retry timeout) instead.  This is important for
    -- spells such as Enlight II where the client/server buff event can lag
    -- behind the cast.
    if entry.awaiting_buff then
        if buff_active then
            entry.awaiting_buff = false
            entry.casting_until = 0
            entry.next_attempt = now
        elseif now < entry.next_attempt then
            return false
        else
            -- The previous cast has had plenty of time to resolve.  Allow
            -- exactly one retry, then enter the same waiting state again.
            entry.awaiting_buff = false
        end
    end

    -- The live buff list is authoritative while the buff is active.
    if buff_active then
        if now < entry.active_until then
            return false
        end

        -- The buff is actually present but our predicted expiry has arrived.
        -- Do not refresh it during combat until the server reports it gone.
        -- This prevents stale active_until data from causing recasts.
        return false
    end

    if upkeep_spell_recast(entry) > 0 then
        return false
    end

    if entry.mp_cost > 0
    and (not player.vitals or (player.vitals.mp or 0) < entry.mp_cost) then
        return false
    end

    windower.chat.input('/ma "' .. entry.name .. '" <me>')

    local cast_time = math.max(0.5, entry.cast_time or 3)
    entry.casting_until = now + cast_time + 0.75
    entry.next_attempt = now + UPKEEP_MA_CAST_RETRY_DELAY
    entry.awaiting_buff = true

    windower.add_to_chat(
        158,
        string.format(
            '[AutoClaim] Upkeep MA: %s (waiting for buff)',
            entry.name
        )
    )

    return true
end

local function use_upkeep_food(now, player)
    if not UPKEEP_FOOD
    or player.status ~= 0
    or now < upkeep_food_next_attempt
    or now < upkeep_food_expires then
        return false
    end

    if player_has_buff(FOOD_BUFF_ID, player) then
        upkeep_food_expires = now + math.max(1, UPKEEP_FOOD.duration - UPKEEP_FOOD.lead)
        return false
    end

    windower.chat.input('/item "' .. UPKEEP_FOOD.name .. '" <me>')

    upkeep_food_next_attempt = now + UPKEEP_FOOD_RETRY_DELAY

    windower.add_to_chat(
        158,
        '[AutoClaim] Upkeep Food: ' .. UPKEEP_FOOD.name
    )

    return true
end

local function upkeep_tick(now, player)
    if not UPKEEP_ENABLED
    or now < upkeep_next_check
    or not player
    or player.status > 1
    or busy then
        return false
    end

    upkeep_next_check = now + UPKEEP_CHECK_INTERVAL

    -- One maintenance action at a time.
    for _, entry in ipairs(UPKEEP_JAS) do
        if use_upkeep_ja(entry, now, player) then
            return true
        end
    end

    for _, entry in ipairs(UPKEEP_MAS) do
        if use_upkeep_ma(entry, now, player) then
            return true
        end
    end

    if use_upkeep_food(now, player) then
        return true
    end

    return false
end

local function print_upkeep_status()
    windower.add_to_chat(
        158,
        '[AutoClaim] Upkeep: ' .. (UPKEEP_ENABLED and 'ON' or 'OFF')
    )

    if #UPKEEP_JAS == 0 then
        windower.add_to_chat(158, '[AutoClaim] Upkeep JAs: none')
    else
        local player = windower.ffxi.get_player()

        for _, entry in ipairs(UPKEEP_JAS) do
            windower.add_to_chat(
                158,
                string.format(
                    '[AutoClaim] JA: %s | active=%s | recast=%.1fs | duration=%ds | lead=%ds',
                    entry.name,
                    player_has_buff(entry.buff_id, player) and 'yes' or 'no',
                    upkeep_recast(entry),
                    entry.duration,
                    entry.lead
                )
            )
        end
    end

    if #UPKEEP_MAS == 0 then
        windower.add_to_chat(158, '[AutoClaim] Upkeep MAs: none')
    else
        local player = windower.ffxi.get_player()

        for _, entry in ipairs(UPKEEP_MAS) do
            windower.add_to_chat(
                158,
                string.format(
                    '[AutoClaim] MA: %s | active=%s | recast=%.1fs | MP=%d/%d | duration=%ds | lead=%ds',
                    entry.name,
                    player_has_buff(entry.buff_id, player) and 'yes' or 'no',
                    upkeep_spell_recast(entry),
                    player and player.vitals and (player.vitals.mp or 0) or 0,
                    entry.mp_cost,
                    entry.duration,
                    entry.lead
                )
            )
        end
    end

    if UPKEEP_FOOD then
        local player = windower.ffxi.get_player()

        windower.add_to_chat(
            158,
            string.format(
                '[AutoClaim] Food: %s | active=%s | duration=%ds | lead=%ds',
                UPKEEP_FOOD.name,
                player_has_buff(FOOD_BUFF_ID, player) and 'yes' or 'no',
                UPKEEP_FOOD.duration,
                UPKEEP_FOOD.lead
            )
        )
    else
        windower.add_to_chat(158, '[AutoClaim] Food: none')
    end
end

------------------------------------------------------------
-- Engage
------------------------------------------------------------

local function send_action(mob, category, param)
    local packet = packets.new(
        'outgoing',
        0x01A,
        {
            ['Target'] = mob.id,
            ['Target Index'] = mob.index,
            ['Category'] = category,
            ['Param'] = param or 0,
            ['X Offset'] = 0,
            ['Z Offset'] = 0,
            ['Y Offset'] = 0,
        }
    )

    packets.inject(packet)
end

local function engage(mob)
    windower.add_to_chat(
        158,
        '[AutoClaim] Engage -> ' .. mob.name
    )

    send_action(mob, 0x02, 0)
end

local function send_claim_action(mob)
    if not mob or not CLAIM_ACTION_ID or not CLAIM_PACKET_CATEGORY then
        return false
    end

    local packet = packets.new(
        'outgoing',
        0x01A,
        {
            ['Target'] = mob.id,
            ['Target Index'] = mob.index,
            ['Category'] = CLAIM_PACKET_CATEGORY,
            ['Param'] = CLAIM_ACTION_ID,
            ['X Offset'] = 0,
            ['Z Offset'] = 0,
            ['Y Offset'] = 0,
        }
    )

    packets.inject(packet)
    return true
end

------------------------------------------------------------
-- Scanner / claim / engage
------------------------------------------------------------

local function target_name_matches(mob)
    if not mob then
        return false
    end

    if not TARGET_ONLY_NAME or TARGET_ONLY_NAME == '' then
        return true
    end

    return mob.name
        and mob.name:lower() == TARGET_ONLY_NAME:lower()
end

local function blacklist_target(mob_id)
    if mob_id then
        failed_targets[mob_id] = os.clock() + FAILED_TARGET_COOLDOWN
    end
end

local function is_target_blacklisted(mob_id)
    local expires = failed_targets[mob_id]

    if not expires then
        return false
    end

    if os.clock() >= expires then
        failed_targets[mob_id] = nil
        return false
    end

    return true
end

local function is_eligible_mob(mob, player)
    if not mob
        or not mob.id
        or not mob.index
        or not mob.name
        or not player
        or mob.id == player.id
        or not mob.is_npc
        or not mob.hpp
        or mob.hpp <= 0
        or not mob.valid_target
        or mob.spawn_type ~= 16
        or is_target_blacklisted(mob.id)
        or not target_name_matches(mob) then
        return false
    end

    return mob.claim_id == 0
        or mob.claim_id == nil
        or mob.claim_id == player.id
end

local function find_mob()
    local player = windower.ffxi.get_player()

    if not player then
        return nil
    end

    local mobs = windower.ffxi.get_mob_array()

    if not mobs then
        return nil
    end

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

local function clear_lock()
    locked_target = nil
    busy = false
    claim_generation = claim_generation + 1
end

local function start_engagement(mob)
    local player = windower.ffxi.get_player()

    if not player or not mob then
        return
    end

    target_mob(mob)
    face_target(mob)
    windower.chat.input('/attack <t>')
    engage(mob)
    last_engage = os.clock()
end

local function claim_mob(mob)
    if not enabled or busy or locked_target or not mob then
        return
    end

    claim_generation = claim_generation + 1
    local my_generation = claim_generation

    locked_target = mob.id
    busy = true

    local claim_sent_at = nil
    local last_claim_action = 0

    windower.add_to_chat(
        158,
        string.format(
            '[AutoClaim] Targeting %s (%.1f yalms)',
            mob.name,
            math.sqrt(mob.distance or 999999)
        )
    )

    local function active()
        return enabled
            and busy
            and claim_generation == my_generation
            and locked_target == mob.id
    end

    local function release(message, blacklist)
        if not active() then
            return
        end

        if message then
            windower.add_to_chat(123, '[AutoClaim] ' .. message)
        end

        if blacklist then
            blacklist_target(mob.id)
        end

        clear_lock()
    end

    local function claim_loop()
        if not active() then
            return
        end

        local player = windower.ffxi.get_player()
        local current = windower.ffxi.get_mob_by_id(mob.id)

        if not player or not current or not current.hpp or current.hpp <= 0 then
            release('Claim target disappeared.')
            return
        end

        -- Someone else got the mob while we were trying to claim it.
        if current.claim_id
            and current.claim_id ~= 0
            and current.claim_id ~= player.id then
            release('Target already claimed by someone else.', true)
            return
        end

        -- Claim range applies only during the claim step. Once claim is
        -- confirmed, combat is allowed to continue regardless of distance.
        local distance = math.sqrt(current.distance or 999999)
        if distance > MAX_DISTANCE then
            release(
                string.format(
                    '%s moved out of range (%.1f yalms). Looking for another mob.',
                    current.name,
                    distance
                ),
                false
            )
            return
        end

        target_mob(current)
        face_target(current)

        -- Already ours: there is nothing left to claim. Go straight to combat.
        if current.claim_id == player.id then
            windower.add_to_chat(
                158,
                '[AutoClaim] *** CLAIMED *** ' .. current.name
            )

            busy = false
            start_engagement(current)
            return
        end

        -- We sent the claim packet recently. Give FFXI a moment to update
        -- claim_id before deciding whether another attempt is necessary.
        local now = os.clock()
        if claim_sent_at and now - claim_sent_at < CLAIM_RESPONSE_TIMEOUT then
            coroutine.schedule(claim_loop, 0.05)
            return
        end

        if claim_sent_at then
            claim_sent_at = nil
        end

        if not CLAIM_ACTION_ID or not CLAIM_PACKET_CATEGORY then
            release(
                'Could not resolve ' .. CLAIM_TYPE:upper() .. ' ' .. CLAIM_ABILITY .. '.',
                true
            )
            return
        end

        -- If the ability is on recast, simply wait. The selected mob remains
        -- locked and the scanner does not jump to another target.
        if claim_recast() > 0 then
            coroutine.schedule(claim_loop, 0.05)
            return
        end

        -- This is the only place we actually attempt the claim ability.
        if now - last_claim_action >= 0.15 then
            if send_claim_action(current) then
                windower.add_to_chat(
                    158,
                    string.format(
                        '[AutoClaim] Direct %s -> %s',
                        CLAIM_TYPE:upper(),
                        current.name
                    )
                )

                last_claim_action = now
                claim_sent_at = now
            end
        end

        coroutine.schedule(claim_loop, 0.05)
    end

    claim_loop()
end

------------------------------------------------------------
-- Claim-range feedback
------------------------------------------------------------

-- Only treat an out-of-range message as a claim failure. Once the mob is
-- claimed and we are in combat, its movement must never make us abandon it.
windower.register_event('incoming text', function(original, modified, mode)
    if not enabled or not busy or not locked_target then
        return
    end

    local mob = windower.ffxi.get_mob_by_id(locked_target)

    if not mob or not mob.name then
        return
    end

    local expected = 'The ' .. mob.name .. ' is out of range.'

    if original == expected or modified == expected then
        local id = locked_target
        blacklist_target(id)
        clear_lock()

        windower.add_to_chat(
            123,
            '[AutoClaim] ' .. mob.name .. ' is out of range. Looking for another mob.'
        )
    end
end)

------------------------------------------------------------
-- Main watchdog
------------------------------------------------------------

windower.register_event('prerender', function()
    if not enabled then
        return
    end

    local now = os.clock()
    local player = windower.ffxi.get_player()

    if not player then
        return
    end

    ------------------------------------------------------------
    -- DEATH FAIL-SAFE
    ------------------------------------------------------------

    local player_dead = player.status == 2
        or (player.vitals and player.vitals.hp and player.vitals.hp <= 0)

    if player_dead then
        enabled = false
        clear_lock()

        windower.add_to_chat(
            123,
            '[AutoClaim] OFF - player died.'
        )

        return
    end

    ------------------------------------------------------------
    -- ACTIVE TARGET
    --
    -- One target at a time. Keep looking at it and keep trying to engage it
    -- until it dies, disappears, or we actually lose the claim.
    ------------------------------------------------------------

    if locked_target then
        local mob = windower.ffxi.get_mob_by_id(locked_target)

        if not mob or not mob.hpp or mob.hpp <= 0 then
            clear_lock()
            return
        end

        if mob.claim_id
            and mob.claim_id ~= 0
            and mob.claim_id ~= player.id then
            clear_lock()
            return
        end

        -- During the claim phase, claim_mob() handles range and ability use.
        -- During combat, there is deliberately NO distance check here.
        if now - last_face >= FACE_INTERVAL then
            target_mob(mob)
            face_target(mob)
            last_face = now
        end

        -- Once the mob is ours, engagement is the only combat action AutoClaim
        -- owns. AutoWS remains completely separate.
        if not busy and mob.claim_id == player.id then
            if player.status ~= 1 and now - last_engage >= ENGAGE_RETRY then
                start_engagement(mob)
            end
        end

        -- Upkeep may continue during combat, but never while a claim is in
        -- progress. This preserves the existing JA/MA/food behavior.
        if not busy and upkeep_tick(now, player) then
            return
        end

        return
    end

    ------------------------------------------------------------
    -- NO ACTIVE TARGET: scan only when we are not already engaged.
    ------------------------------------------------------------

    if busy or player.status == 1 then
        return
    end

    if now - last_scan < SCAN_INTERVAL then
        return
    end

    last_scan = now

    local mob = find_mob()

    if mob then
        claim_mob(mob)
        return
    end

    upkeep_tick(now, player)
end)

------------------------------------------------------------
-- Upkeep buff events
------------------------------------------------------------

windower.register_event('gain buff', function(buff_id)
    local now = os.clock()

    for _, entry in ipairs(UPKEEP_JAS) do
        if entry.buff_id == buff_id then
            entry.active_until = now + math.max(1, entry.duration - entry.lead)
            entry.next_attempt = now
            entry.casting_until = 0
            entry.awaiting_buff = false
        end
    end

    for _, entry in ipairs(UPKEEP_MAS) do
        if entry.buff_id == buff_id then
            entry.active_until = now + math.max(1, entry.duration - entry.lead)
            entry.next_attempt = now
            entry.casting_until = 0
            entry.awaiting_buff = false
        end
    end

    if UPKEEP_FOOD and buff_id == FOOD_BUFF_ID then
        upkeep_food_expires = now + math.max(1, UPKEEP_FOOD.duration - UPKEEP_FOOD.lead)
        upkeep_food_next_attempt = now
    end
end)

windower.register_event('lose buff', function(buff_id)
    local now = os.clock()

    for _, entry in ipairs(UPKEEP_JAS) do
        if entry.buff_id == buff_id then
            entry.active_until = 0
            if not entry.awaiting_buff then
                entry.next_attempt = now
                entry.casting_until = 0
            end
        end
    end

    for _, entry in ipairs(UPKEEP_MAS) do
        if entry.buff_id == buff_id then
            entry.active_until = 0
            if not entry.awaiting_buff then
                entry.next_attempt = now
                entry.casting_until = 0
            end
        end
    end

    if buff_id == FOOD_BUFF_ID then
        upkeep_food_expires = 0
        upkeep_food_next_attempt = now
    end
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------

local function print_usage()
    windower.add_to_chat(158, '[AutoClaim] Commands:')
    windower.add_to_chat(158, '//ac on | off | toggle | status')
    windower.add_to_chat(158, '//ac range <yalms>')
    windower.add_to_chat(158, '//ac target_only <mob name>')
    windower.add_to_chat(158, '//ac target_only off')
    windower.add_to_chat(158, '//ac type <ja|ma>')
    windower.add_to_chat(158, '//ac ability <name>')
    windower.add_to_chat(158, '//ac upkeep on | off | list | clear')
    windower.add_to_chat(158, '//ac upkeep ja add <name> [lead]')
    windower.add_to_chat(158, '//ac upkeep ja remove <name>')
    windower.add_to_chat(158, '//ac upkeep ma add <name> [lead]')
    windower.add_to_chat(158, '//ac upkeep ma remove <name>')
    windower.add_to_chat(158, '//ac upkeep food <item> <duration> [lead]')
    windower.add_to_chat(158, '//ac upkeep food off')
end

windower.register_event('addon command', function(...)
    local args = {...}
    local command = args[1] and args[1]:lower() or ''

    if command == 'on' then

        enabled = true

        windower.add_to_chat(
            158,
            string.format(
                '[AutoClaim] ON - scanning %.1f yalms | %s %s',
                MAX_DISTANCE,
                CLAIM_TYPE:upper(),
                CLAIM_ABILITY
            )
        )

    elseif command == 'off' then

        enabled = false
        busy = false
        locked_target = nil
        claim_generation = claim_generation + 1

        windower.add_to_chat(
            158,
            '[AutoClaim] OFF'
        )

    elseif command == 'toggle' then

        enabled = not enabled

        if not enabled then
            busy = false
            locked_target = nil
            claim_generation = claim_generation + 1
        end

        windower.add_to_chat(
            158,
            '[AutoClaim] ' ..
            (enabled and 'ON' or 'OFF')
        )

    elseif command == 'range' then

        local value = tonumber(args[2])

        if value and value > 0 then
            MAX_DISTANCE = value

            windower.add_to_chat(
                158,
                string.format(
                    '[AutoClaim] Scan range set to %.1f yalms.',
                    MAX_DISTANCE
                )
            )
        else
            windower.add_to_chat(
                123,
                '[AutoClaim] Usage: //ac range <yalms>'
            )
        end

    elseif command == 'target_only' then

        if not args[2] then
            windower.add_to_chat(
                123,
                '[AutoClaim] Usage: //ac target_only <mob name>'
            )
            windower.add_to_chat(
                123,
                '[AutoClaim] Or: //ac target_only off'
            )
            return
        end

        local parts = {}

        for i = 2, #args do
            parts[#parts + 1] = args[i]
        end

        local value = table.concat(parts, ' ')
        value = value:gsub('^%s+', ''):gsub('%s+$', '')
        value = value:gsub('^"(.*)"$', '%1')

        if value:lower() == 'off' or value == '' then
            TARGET_ONLY_NAME = nil

            windower.add_to_chat(
                158,
                '[AutoClaim] Target-only filter cleared.'
            )
        else
            TARGET_ONLY_NAME = value

            windower.add_to_chat(
                158,
                '[AutoClaim] Target-only filter set to: ' .. TARGET_ONLY_NAME
            )
        end

    elseif command == 'type' then

        local value = args[2] and args[2]:lower() or ''

        if value == 'ja' or value == 'ma' then
            CLAIM_TYPE = value
            resolve_claim_ability()

            windower.add_to_chat(
                158,
                string.format(
                    '[AutoClaim] Claim type set to %s.',
                    CLAIM_TYPE:upper()
                )
            )

            if not CLAIM_RECAST_ID or not CLAIM_ACTION_ID then
                windower.add_to_chat(
                    123,
                    '[AutoClaim] Warning: could not resolve ' ..
                    CLAIM_ABILITY
                )
            end
        else
            windower.add_to_chat(
                123,
                '[AutoClaim] Usage: //ac type <ja|ma>'
            )
        end

    elseif command == 'ability' then

        if not args[2] then
            windower.add_to_chat(
                123,
                '[AutoClaim] Usage: //ac ability <name>'
            )
            return
        end

        local parts = {}

        for i = 2, #args do
            parts[#parts + 1] = args[i]
        end

        CLAIM_ABILITY = table.concat(parts, ' ')
        resolve_claim_ability()

        windower.add_to_chat(
            158,
            string.format(
                '[AutoClaim] Claim ability set to %s (%s).',
                CLAIM_ABILITY,
                CLAIM_TYPE:upper()
            )
        )

        if not CLAIM_RECAST_ID or not CLAIM_ACTION_ID then
            windower.add_to_chat(
                123,
                '[AutoClaim] Warning: could not resolve that ability/spell.'
            )
        end

    elseif command == 'timeout' then

        local value = tonumber(args[2])

        if value and value > 0 then
            CLAIM_RESPONSE_TIMEOUT = value

            windower.add_to_chat(
                158,
                string.format(
                    '[AutoClaim] Claim response timeout set to %.2f seconds.',
                    CLAIM_RESPONSE_TIMEOUT
                )
            )
        else
            windower.add_to_chat(
                123,
                '[AutoClaim] Usage: //ac timeout <seconds>'
            )
        end

    elseif command == 'upkeep' then

        local subcommand = args[2] and args[2]:lower() or ''

        if subcommand == 'on' then
            UPKEEP_ENABLED = true

            local player = windower.ffxi.get_player()
            if player then
                initialize_upkeep_state(player)
            end

            windower.add_to_chat(158, '[AutoClaim] Upkeep ON')

        elseif subcommand == 'off' then
            UPKEEP_ENABLED = false
            windower.add_to_chat(158, '[AutoClaim] Upkeep OFF')

        elseif subcommand == 'list' or subcommand == '' then
            print_upkeep_status()

        elseif subcommand == 'clear' then
            UPKEEP_JAS = {}
            UPKEEP_MAS = {}
            UPKEEP_FOOD = nil
            upkeep_food_expires = 0
            upkeep_food_next_attempt = 0

            windower.add_to_chat(
                158,
                '[AutoClaim] Upkeep configuration cleared.'
            )

        elseif subcommand == 'ja' then

            local action = args[3] and args[3]:lower() or ''

            if action == 'add' then
                if not args[4] then
                    windower.add_to_chat(
                        123,
                        '[AutoClaim] Usage: //ac upkeep ja add <name> [lead]'
                    )
                    return
                end

                local parts = {}
                for i = 4, #args do
                    parts[#parts + 1] = args[i]
                end

                local lead = 5
                local last = tonumber(parts[#parts])

                if last then
                    lead = math.max(0, last)
                    parts[#parts] = nil
                end

                local name = table.concat(parts, ' ')
                name = name:gsub('^"(.*)"$', '%1')

                local entry, err = resolve_upkeep_ja(name)

                if not entry then
                    windower.add_to_chat(123, '[AutoClaim] ' .. err)
                    return
                end

                entry.lead = lead

                local existing_index = find_upkeep_ja(entry.name)

                if existing_index then
                    UPKEEP_JAS[existing_index] = entry
                    windower.add_to_chat(
                        158,
                        '[AutoClaim] Upkeep JA updated: ' .. entry.name
                    )
                else
                    UPKEEP_JAS[#UPKEEP_JAS + 1] = entry
                    windower.add_to_chat(
                        158,
                        '[AutoClaim] Upkeep JA added: ' .. entry.name
                    )
                end

                local player = windower.ffxi.get_player()
                if player then
                    initialize_upkeep_state(player)
                end

            elseif action == 'remove' then
                if not args[4] then
                    windower.add_to_chat(
                        123,
                        '[AutoClaim] Usage: //ac upkeep ja remove <name>'
                    )
                    return
                end

                local parts = {}
                for i = 4, #args do
                    parts[#parts + 1] = args[i]
                end

                local name = table.concat(parts, ' ')
                name = name:gsub('^"(.*)"$', '%1')

                local index, entry = find_upkeep_ja(name)

                if index then
                    table.remove(UPKEEP_JAS, index)
                    windower.add_to_chat(
                        158,
                        '[AutoClaim] Upkeep JA removed: ' .. entry.name
                    )
                else
                    windower.add_to_chat(
                        123,
                        '[AutoClaim] Upkeep JA not found: ' .. name
                    )
                end

            else
                windower.add_to_chat(
                    123,
                    '[AutoClaim] Usage: //ac upkeep ja add|remove <name> [lead]'
                )
            end

        elseif subcommand == 'ma' then

            local action = args[3] and args[3]:lower() or ''

            if action == 'add' then
                if not args[4] then
                    windower.add_to_chat(
                        123,
                        '[AutoClaim] Usage: //ac upkeep ma add <name> [lead]'
                    )
                    return
                end

                local parts = {}
                for i = 4, #args do
                    parts[#parts + 1] = args[i]
                end

                local lead = 5
                local last = tonumber(parts[#parts])

                if last then
                    lead = math.max(0, last)
                    parts[#parts] = nil
                end

                local name = table.concat(parts, ' ')
                name = name:gsub('^"(.*)"$', '%1')

                local entry, err = resolve_upkeep_ma(name)

                if not entry then
                    windower.add_to_chat(123, '[AutoClaim] ' .. err)
                    return
                end

                entry.lead = lead

                local existing_index = find_upkeep_ma(entry.name)

                if existing_index then
                    UPKEEP_MAS[existing_index] = entry
                    windower.add_to_chat(
                        158,
                        '[AutoClaim] Upkeep MA updated: ' .. entry.name
                    )
                else
                    UPKEEP_MAS[#UPKEEP_MAS + 1] = entry
                    windower.add_to_chat(
                        158,
                        '[AutoClaim] Upkeep MA added: ' .. entry.name
                    )
                end

                local player = windower.ffxi.get_player()
                if player then
                    initialize_upkeep_state(player)
                end

            elseif action == 'remove' then
                if not args[4] then
                    windower.add_to_chat(
                        123,
                        '[AutoClaim] Usage: //ac upkeep ma remove <name>'
                    )
                    return
                end

                local parts = {}
                for i = 4, #args do
                    parts[#parts + 1] = args[i]
                end

                local name = table.concat(parts, ' ')
                name = name:gsub('^"(.*)"$', '%1')

                local index, entry = find_upkeep_ma(name)

                if index then
                    table.remove(UPKEEP_MAS, index)
                    windower.add_to_chat(
                        158,
                        '[AutoClaim] Upkeep MA removed: ' .. entry.name
                    )
                else
                    windower.add_to_chat(
                        123,
                        '[AutoClaim] Upkeep MA not found: ' .. name
                    )
                end

            else
                windower.add_to_chat(
                    123,
                    '[AutoClaim] Usage: //ac upkeep ma add|remove <name> [lead]'
                )
            end

        elseif subcommand == 'food' then

            if not args[3] or args[3]:lower() == 'off' then
                UPKEEP_FOOD = nil
                upkeep_food_expires = 0
                upkeep_food_next_attempt = 0

                windower.add_to_chat(
                    158,
                    '[AutoClaim] Upkeep food disabled.'
                )
                return
            end

            -- Syntax:
            -- //ac upkeep food "Grape Daifuku" 1800 60
            -- duration is required; lead is optional.
            local raw = {}
            for i = 3, #args do
                raw[#raw + 1] = args[i]
            end

            local duration = tonumber(raw[#raw])
            if not duration or duration <= 0 then
                windower.add_to_chat(
                    123,
                    '[AutoClaim] Usage: //ac upkeep food <item> <duration> [lead]'
                )
                return
            end
            raw[#raw] = nil

            local lead = 60
            local possible_lead = tonumber(raw[#raw])
            if possible_lead then
                lead = math.max(0, possible_lead)
                raw[#raw] = nil
            end

            local item_name = table.concat(raw, ' ')
            item_name = item_name:gsub('^"(.*)"$', '%1')

            local item = res.items:with('en', item_name)

            if not item then
                windower.add_to_chat(
                    123,
                    '[AutoClaim] Unable to resolve food item: ' .. item_name
                )
                return
            end

            UPKEEP_FOOD = {
                name = item.en,
                id = item.id,
                duration = duration,
                lead = lead,
            }

            local player = windower.ffxi.get_player()
            if player then
                initialize_upkeep_state(player)
            end

            windower.add_to_chat(
                158,
                string.format(
                    '[AutoClaim] Upkeep food set: %s | duration=%ds | lead=%ds',
                    UPKEEP_FOOD.name,
                    UPKEEP_FOOD.duration,
                    UPKEEP_FOOD.lead
                )
            )

        else
            print_usage()
        end

    elseif command == 'status' then
        local target_name = 'none' 

        if locked_target then
            local mob = windower.ffxi.get_mob_by_id(locked_target)
            if mob then
                target_name = mob.name
            end
        end

        windower.add_to_chat(
            158,
            string.format(
                '[AutoClaim] %s | locked=%s | only=%s | %s %s id=%s recast=%.1fs | timeout=%.2fs',
                enabled and 'ON' or 'OFF',
                target_name,
                TARGET_ONLY_NAME or 'any',
                CLAIM_TYPE:upper(),
                CLAIM_ABILITY,
                tostring(CLAIM_ACTION_ID or 'nil'),
                claim_recast(),
                CLAIM_RESPONSE_TIMEOUT
            )
        )

        print_upkeep_status()

    elseif command == 'help' then

        print_usage()
    end
end)

------------------------------------------------------------
-- Load
------------------------------------------------------------

windower.register_event('load', function()
    resolve_claim_ability()

    local player = windower.ffxi.get_player()
    if player then
        initialize_upkeep_state(player)
    end

    windower.add_to_chat(
        158,
        '[AutoClaim] Loaded v' .. _addon.version .. ' - scan -> claim -> engage -> face + upkeep'
    )

    windower.add_to_chat(158,'[AutoClaim] To view list of commands type: //ac help')
end)
