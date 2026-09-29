_addon.name = 'AutoClaim'
_addon.author = 'You'
_addon.version = '5.24'

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

-- Mobs that have recently performed an action against the player are
-- prioritized over ordinary unclaimed mobs. This is tracked from the
-- Windower action event because mob.target_index is not reliable for NPCs.
local recent_attackers = {}
local ATTACKER_PRIORITY_DURATION = 3.0

-- A failed/expired target is temporarily ignored by the scanner.
local failed_targets = {}
local FAILED_TARGET_COOLDOWN = 1.5

-- How long to wait for the server to reflect a direct claim packet
-- before allowing another packet attempt.
local CLAIM_RESPONSE_TIMEOUT = 0.20
local CLAIM_MAX_WAIT = 60.0
-- If the claim action goes on recast without us receiving ownership,
-- do not sit on the mob. Release it so the scanner can keep watching it.
-- A short grace period allows a slightly delayed claim update to arrive.
local CLAIM_RECAST_RELEASE_GRACE = 0.50

local FACE_INTERVAL = 0.05
local last_face = 0
local last_engage = 0
local ENGAGE_RETRY = 0.40

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
-- Scanner
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

local function remember_attacker(mob_id)
    if mob_id then
        recent_attackers[mob_id] = os.clock() + ATTACKER_PRIORITY_DURATION
    end
end

local function is_recent_attacker(mob_id)
    local expires = recent_attackers[mob_id]

    if not expires then
        return false
    end

    if os.clock() >= expires then
        recent_attackers[mob_id] = nil
        return false
    end

    return true
end

local function cleanup_recent_attackers()
    local now = os.clock()

    for mob_id, expires in pairs(recent_attackers) do
        if now >= expires then
            recent_attackers[mob_id] = nil
        end
    end
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

    -- We can only claim unclaimed mobs, or continue with one already
    -- claimed by us.
    return mob.claim_id == 0 or mob.claim_id == nil or mob.claim_id == player.id
end

local function find_mob()
    local player = windower.ffxi.get_player()

    if not player then
        return nil
    end

    local player_mob = windower.ffxi.get_mob_by_target('me')

    if not player_mob then
        return nil
    end

    local mobs = windower.ffxi.get_mob_array()

    if not mobs then
        return nil
    end

    cleanup_recent_attackers()

    ------------------------------------------------------------
    -- PRIORITY 1:
    -- A mob that actually attacked us recently wins immediately.
    ------------------------------------------------------------

    local attacker = nil
    local attacker_distance = MAX_DISTANCE

    for _, mob in pairs(mobs) do
        if is_eligible_mob(mob, player)
        and is_recent_attacker(mob.id) then
            local dist = math.sqrt(mob.distance or 999999)

            if dist <= attacker_distance then
                attacker = mob
                attacker_distance = dist
            end
        end
    end

    if attacker then
        return attacker
    end

    ------------------------------------------------------------
    -- PRIORITY 2:
    -- If we already have multiple mobs claimed by us (for example,
    -- because we aggroed 3 mobs at once), keep working through those
    -- mobs before claiming a fresh one.
    --
    -- This is the important distinction from the old scanner:
    -- claim_id == player.id means the mob is already ours, so we
    -- should NOT send another claim attempt just to select it.
    ------------------------------------------------------------

    local owned = nil
    local owned_distance = MAX_DISTANCE

    for _, mob in pairs(mobs) do
        if is_eligible_mob(mob, player)
        and mob.claim_id == player.id then
            local dist = math.sqrt(mob.distance or 999999)

            if dist <= owned_distance then
                owned = mob
                owned_distance = dist
            end
        end
    end

    if owned then
        return owned
    end

    ------------------------------------------------------------
    -- PRIORITY 3:
    -- Nothing is attacking us and we don't already own another mob,
    -- so claim the nearest fresh/unclaimed matching mob.
    ------------------------------------------------------------

    local closest = nil
    local closest_distance = MAX_DISTANCE

    for _, mob in pairs(mobs) do
        if is_eligible_mob(mob, player)
        and (mob.claim_id == 0 or mob.claim_id == nil) then
            local dist = math.sqrt(mob.distance or 999999)

            if dist <= closest_distance then
                closest = mob
                closest_distance = dist
            end
        end
    end

    return closest
end

------------------------------------------------------------
-- Claim state machine
------------------------------------------------------------

local function claim_mob(mob)
    -- Every newly selected mob goes through the exact same claim path,
    -- even if it is already claimed by us / already attacking us.
    -- Do NOT gate target selection on the local recast table here.
    -- Windower's recast data can briefly lag the actual ready state, and
    -- the claim loop below is the single place that decides when to send
    -- the claim action.

    -- One and only one claim can exist at a time.
    if busy or locked_target then
        return
    end

    claim_generation = claim_generation + 1
    local my_generation = claim_generation

    busy = true
    locked_target = mob.id

    local claim_started = os.clock()
    local claim_sent_at = nil
    local claim_action_sent = false
    local last_claim_action = 0
    local next_target_refresh = 0
    local last_attack = 0

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

        locked_target = nil
        busy = false
        claim_generation = claim_generation + 1
    end

    local function engage_loop()
        if not active() then
            return
        end

        local player = windower.ffxi.get_player()
        local current = windower.ffxi.get_mob_by_id(mob.id)

        if not player or not current or not current.hpp or current.hpp <= 0 then
            release('Claim target disappeared.')
            return
        end

        if current.claim_id ~= player.id then
            release('Lost claim on ' .. current.name .. '.', true)
            return
        end

        ------------------------------------------------------------
        -- HARD ENGAGE LOOP
        --
        -- We do not assume that target_mob() means the client has
        -- actually accepted the target yet. Re-establish the exact
        -- target, verify <t>, face it, then issue both normal /attack
        -- and the raw engage packet. Repeat until player.status == 1.
        --
        -- busy stays TRUE for the entire loop, so the scanner cannot
        -- select another mob while we are trying to engage this one.
        ------------------------------------------------------------

        target_mob(current)
        face_target(current)

        if player.status == 1 then
            -- Stay locked on the live combat target. The main watchdog will
            -- clear locked_target when this mob dies/disappears, which then
            -- allows the scanner to select the next mob and run the normal
            -- claim sequence.
            return
        end

        local target = windower.ffxi.get_mob_by_target('t')

        -- Give the injected target a chance to become the real client
        -- target. If something else has <t>, do not attack it.
        if not target or target.id ~= current.id then
            coroutine.schedule(engage_loop, 0.05)
            return
        end

        local now = os.clock()

        -- Normal client engage command.
        if now - last_attack >= 0.15 then
            target_mob(current)
            face_target(current)
            windower.chat.input('/attack <t>')
            last_attack = now
        end

        -- Raw engage packet as a second, independent path.
        if now - last_engage >= 0.15 then
            target_mob(current)
            face_target(current)
            engage(current)
            last_engage = now
        end

        -- Verify again very quickly. If the client did not enter
        -- engaged status, repeat the entire target -> face -> engage
        -- sequence against THIS SAME MOB.
        coroutine.schedule(engage_loop, 0.10)
    end

    local function claim_loop()
        if not active() then
            return
        end

        local current = windower.ffxi.get_mob_by_id(mob.id)
        local player = windower.ffxi.get_player()

        if not current or not current.hpp or current.hpp <= 0 or not player then
            release('Claim target disappeared.')
            return
        end

        -- If somebody else gets it, THIS claim is finished. Only then may
        -- another target be selected.
        if current.claim_id and current.claim_id ~= 0
            and current.claim_id ~= player.id then
            release('Target already claimed. Looking for next mob.', true)
            return
        end

        local now = os.clock()

        -- Keep the exact mob targeted/faced, but do not let this become a
        -- selection mechanism. There is still only one locked target.
        if now >= next_target_refresh then
            target_mob(current)
            face_target(current)
            next_target_refresh = now + 0.05
        end

        -- CLAIM CONFIRMED.
        -- The claim is complete, so hand combat over to the main watchdog.
        -- Keep locked_target set until this mob actually dies/disappears.
        -- That gives the watchdog a persistent opportunity to engage the mob
        -- if the first /attack or raw engage packet does not take.
        if current.claim_id == player.id and claim_action_sent then
            windower.add_to_chat(
                158,
                '[AutoClaim] *** CLAIMED *** ' .. current.name
            )

            target_mob(current)
            face_target(current)

            -- Claim work is finished. The prerender watchdog now owns the
            -- engage/re-engage job while locked_target remains this mob.
            busy = false

            -- Give engagement an immediate attempt instead of waiting for
            -- the next watchdog interval. The watchdog will retry every
            -- ENGAGE_RETRY seconds until player.status == 1.
            windower.chat.input('/attack <t>')
            engage(current)
            last_engage = now

            return
        end

        -- If a direct packet was sent, give the server a short window to reflect
        -- the result, then retry DIRECTLY against the same mob. We NEVER
        -- fall back to /ja or /ma <t>, because that would reintroduce the
        -- target-sync race. The short window keeps claim attempts fast
        -- without ever releasing the locked target while the claim is pending.
        if claim_sent_at then
            if now - claim_sent_at < CLAIM_RESPONSE_TIMEOUT then
                coroutine.schedule(claim_loop, 0.05)
                return
            end

            claim_sent_at = nil
        end

        local recast = claim_recast()

        if recast > 0 then
            -- Stay on the newly selected target until the claim ability is
            -- actually available. This also handles a brief stale recast
            -- value from Windower without silently skipping the claim.
            coroutine.schedule(claim_loop, 0.05)
            return
        end

        if not CLAIM_ACTION_ID or not CLAIM_PACKET_CATEGORY then
            release(
                'Could not resolve ' .. CLAIM_TYPE:upper() .. ' ' .. CLAIM_ABILITY .. '.',
                true
            )
            return
        end

        -- No menu/chat dependency. The packet goes directly to THIS mob.
        if now - last_claim_action >= 0.15 then
            target_mob(current)
            face_target(current)

            if send_claim_action(current) then
                claim_action_sent = true

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
-- Incoming combat priority
------------------------------------------------------------

-- A monster can attack us before the scanner has selected anything.
-- The action event gives us a reliable signal that the monster actually
-- acted on the player. We remember it briefly so the scanner can claim
-- that monster before choosing a different nearby mob.
windower.register_event('action', function(action)
    if not enabled or not action or not action.actor_id or not action.targets then
        return
    end

    local player = windower.ffxi.get_player()

    if not player then
        return
    end

    local actor = windower.ffxi.get_mob_by_id(action.actor_id)

    if not actor
        or not actor.is_npc
        or actor.spawn_type ~= 16
        or not actor.hpp
        or actor.hpp <= 0
        or not target_name_matches(actor) then
        return
    end

    for _, target in pairs(action.targets) do
        if target and target.id == player.id then
            remember_attacker(actor.id)
            return
        end
    end
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
    --
    -- If the player dies while AutoClaim is enabled, immediately shut
    -- the addon down. This prevents any pending claim/engage/upkeep
    -- coroutines from continuing while dead.
    ------------------------------------------------------------

    local player_dead = player.status == 2
        or (player.vitals and player.vitals.hp and player.vitals.hp <= 0)

    if player_dead then
        enabled = false
        busy = false
        locked_target = nil
        claim_generation = claim_generation + 1

        windower.add_to_chat(
            123,
            '[AutoClaim] OFF - player died.'
        )

        return
    end

    ------------------------------------------------------------
    -- LOCKED TARGET BRANCH
    --
    -- While locked_target exists, there is NO scanner.
    -- This is true during claim attempts, claim confirmation, and engagement.
    ------------------------------------------------------------

    if locked_target then
        local mob = windower.ffxi.get_mob_by_id(locked_target)

        if not mob or not mob.hpp or mob.hpp <= 0 then
            locked_target = nil
            busy = false
            claim_generation = claim_generation + 1
            return
        end

        if mob.claim_id and mob.claim_id ~= 0
            and mob.claim_id ~= player.id then
            locked_target = nil
            busy = false
            claim_generation = claim_generation + 1
            return
        end

        if now - last_face >= FACE_INTERVAL then
            target_mob(mob)
            face_target(mob)
            last_face = now
        end

        --------------------------------------------------------
        -- Engage watchdog after claim confirmation.
        --------------------------------------------------------

        if not busy
        and player.status ~= 1
        and mob.claim_id == player.id
        and now - last_engage >= ENGAGE_RETRY then

            target_mob(mob)
            face_target(mob)
            engage(mob)
            last_engage = now

            local generation = claim_generation

            coroutine.schedule(function()
                if generation ~= claim_generation
                    or not locked_target
                    or locked_target ~= mob.id then
                    return
                end

                local p = windower.ffxi.get_player()
                local current = windower.ffxi.get_mob_by_id(mob.id)

                if p
                and p.status ~= 1
                and current
                and current.hpp
                and current.hpp > 0
                and current.claim_id == p.id then

                    target_mob(current)
                    face_target(current)
                    windower.chat.input('/attack <t>')
                    last_engage = os.clock()
                end
            end, 0.15)
        end

        -- Only run upkeep after combat-critical work has had a chance to run.
        -- In particular, this prevents an expired Enlight II from stealing
        --
        -- If we are actively engaged and the buff is still present, upkeep
        -- does nothing. If the buff genuinely disappeared, upkeep may restore
        -- it, but only after the engage checks above have completed.
        if not busy and upkeep_tick(now, player) then
            return
        end

        return
    end

    ------------------------------------------------------------
    -- NO LOCK: scanner is allowed.
    ------------------------------------------------------------

    if busy then
        return
    end

    if player.status == 1 then
        return
    end

    if now - last_scan < SCAN_INTERVAL then
        return
    end

    last_scan = now

    local mob = find_mob()

    if mob then
        claim_mob(mob)
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
        '[AutoClaim] Loaded v' .. _addon.version .. ' - target filters + multi-aggro priority + upkeep'
    )

    windower.add_to_chat(
        158,
        '[AutoClaim] //ac on'
    )
end)
