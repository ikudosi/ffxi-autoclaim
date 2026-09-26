_addon.name = 'AutoClaim'
_addon.author = 'You'
_addon.version = '5.6'

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

-- Weapon-skill cycle. The index resets whenever a new fight is claimed.
local WEAPON_SKILLS = {'Victory Smite'}
local WS_INDEX = 1

local enabled = false
local locked_target = nil
local busy = false
local claim_generation = 0
local last_scan = 0

-- A failed/expired target is temporarily ignored by the scanner.
local failed_targets = {}
local FAILED_TARGET_COOLDOWN = 1.5

-- How long to wait for the server to reflect a direct claim packet
-- before allowing another packet attempt.
local CLAIM_RESPONSE_TIMEOUT = 0.20
local CLAIM_MAX_WAIT = 60.0

local WS_TP = 1000
local WS_DELAY = 1.0
local FACE_INTERVAL = 0.05
local last_face = 0
local last_ws = 0
local last_engage = 0
local ENGAGE_RETRY = 0.40

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

local function current_weapon_skill()
    if #WEAPON_SKILLS == 0 then
        return nil
    end

    return WEAPON_SKILLS[WS_INDEX]
end

local function advance_weapon_skill()
    if #WEAPON_SKILLS == 0 then
        return
    end

    WS_INDEX = WS_INDEX + 1

    if WS_INDEX > #WEAPON_SKILLS then
        WS_INDEX = 1
    end
end

local function reset_weapon_skill_cycle()
    WS_INDEX = 1
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

    local closest = nil
    local closest_distance = MAX_DISTANCE

    for _, mob in pairs(mobs) do
        if mob
        and mob.id
        and mob.index
        and mob.name
        and mob.id ~= player.id                 -- NEVER target ourselves
        and mob.is_npc
        and mob.hpp
        and mob.hpp > 0
        and mob.valid_target
        and mob.spawn_type == 16
        and (mob.claim_id == 0 or mob.claim_id == nil)
        and not is_target_blacklisted(mob.id) then

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
-- Weapon skill
------------------------------------------------------------

local function use_weapon_skill()
    local player = windower.ffxi.get_player()

    if not player or player.status ~= 1 then
        return
    end

    if not locked_target then
        return
    end

    local locked = windower.ffxi.get_mob_by_id(locked_target)

    if not locked
    or not locked.hpp
    or locked.hpp <= 0
    or locked.claim_id ~= player.id then
        return
    end

    if not player.vitals or player.vitals.tp < WS_TP then
        return
    end

    local target = windower.ffxi.get_mob_by_target('t')

    if not target or target.id ~= locked.id then
        return
    end

    local weapon_skill = current_weapon_skill()

    if not weapon_skill then
        return
    end

    windower.add_to_chat(
        158,
        string.format(
            '[AutoClaim] WS: %s (%d TP) [%d/%d]',
            weapon_skill,
            player.vitals.tp,
            WS_INDEX,
            #WEAPON_SKILLS
        )
    )

    windower.chat.input('/ws "' .. weapon_skill .. '" <t>')
    advance_weapon_skill()
end

------------------------------------------------------------
-- Claim state machine
------------------------------------------------------------

local function claim_mob(mob)
    -- One and only one claim can exist at a time.
    if busy or locked_target then
        return
    end

    claim_generation = claim_generation + 1
    local my_generation = claim_generation

    busy = true
    locked_target = mob.id
    reset_weapon_skill_cycle()

    local claim_started = os.clock()
    local claim_sent_at = nil
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
            busy = false
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
        -- This check is deliberately independent of <t>. The claim action
        -- was sent directly to this mob's ID/index, so another player's
        -- target selection cannot make our claim packet hit the wrong mob.
        if current.claim_id == player.id then
            windower.add_to_chat(
                158,
                '[AutoClaim] *** CLAIMED *** ' .. current.name
            )

            target_mob(current)
            face_target(current)

            local function handoff_to_engage()
                if not active() then
                    return
                end

                local p = windower.ffxi.get_player()
                local target = windower.ffxi.get_mob_by_id(mob.id)

                if not p or not target or not target.hpp or target.hpp <= 0 then
                    release('Claim target disappeared.')
                    return
                end

                target_mob(target)
                face_target(target)

                if not target_matches(target) then
                    coroutine.schedule(handoff_to_engage, 0.05)
                    return
                end

                engage_loop()
            end

            coroutine.schedule(handoff_to_engage, 0.05)
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
            if now - claim_started >= CLAIM_MAX_WAIT then
                release(
                    string.format(
                        'Waited %.0fs for %s on %s. Releasing target.',
                        CLAIM_MAX_WAIT,
                        CLAIM_ABILITY,
                        current.name
                    ),
                    true
                )
                return
            end

            coroutine.schedule(claim_loop, 0.20)
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
        -- WS only after we actually own the locked mob.
        --------------------------------------------------------

        if player.status == 1
        and player.vitals
        and player.vitals.tp >= WS_TP
        and now - last_ws >= WS_DELAY
        and mob.claim_id == player.id then

            target_mob(mob)
            face_target(mob)

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
                and p.status == 1
                and p.vitals
                and p.vitals.tp >= WS_TP
                and current
                and current.hpp
                and current.hpp > 0
                and current.claim_id == p.id then

                    target_mob(current)
                    face_target(current)
                    local weapon_skill = current_weapon_skill()

                    if weapon_skill then
                        windower.chat.input('/ws "' .. weapon_skill .. '" <t>')
                        advance_weapon_skill()
                        last_ws = os.clock()
                    end
                end
            end, 0.05)
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
    windower.add_to_chat(158, '//ac type <ja|ma>')
    windower.add_to_chat(158, '//ac ability <name>')
    windower.add_to_chat(158, '//ac ws <name> [<name> ...]')
    windower.add_to_chat(158, '//ac timeout <seconds>')
    windower.add_to_chat(158, '[AutoClaim] WS names can be quoted or separated with |')
end

local function parse_ws_arguments(args)
    local skills = {}

    for i = 2, #args do
        local value = args[i]

        if value and value ~= '' then
            -- Also support: //ac ws "Victory Smite"|"Howling Fist"
            for skill in value:gmatch('[^|]+') do
                skill = skill:gsub('^%s+', ''):gsub('%s+$', '')
                skill = skill:gsub('^"(.*)"$', '%1')

                if skill ~= '' then
                    skills[#skills + 1] = skill
                end
            end
        end
    end

    return skills
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
        reset_weapon_skill_cycle()

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
            reset_weapon_skill_cycle()
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

    elseif command == 'ws' then

        local skills = parse_ws_arguments(args)

        if #skills == 0 then
            windower.add_to_chat(
                123,
                '[AutoClaim] Usage: //ac ws "Victory Smite" "Howling Fist"'
            )
            windower.add_to_chat(
                123,
                '[AutoClaim] Or: //ac ws Victory Smite|Howling Fist'
            )
            return
        end

        WEAPON_SKILLS = skills
        reset_weapon_skill_cycle()

        windower.add_to_chat(
            158,
            string.format(
                '[AutoClaim] WS cycle set: %s',
                table.concat(WEAPON_SKILLS, ' -> ')
            )
        )

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
                '[AutoClaim] %s | locked=%s | %s %s id=%s recast=%.1fs | timeout=%.2fs | WS=%s [%d/%d]',
                enabled and 'ON' or 'OFF',
                target_name,
                CLAIM_TYPE:upper(),
                CLAIM_ABILITY,
                tostring(CLAIM_ACTION_ID or 'nil'),
                claim_recast(),
                CLAIM_RESPONSE_TIMEOUT,
                current_weapon_skill() or 'none',
                WS_INDEX,
                #WEAPON_SKILLS
            )
        )

    elseif command == 'help' then

        print_usage()
    end
end)

------------------------------------------------------------
-- Load
------------------------------------------------------------

windower.register_event('load', function()
    resolve_claim_ability()

    windower.add_to_chat(
        158,
        '[AutoClaim] Loaded v5.6 - direct packet claim'
    )

    windower.add_to_chat(
        158,
        '[AutoClaim] //ac on'
    )
end)
