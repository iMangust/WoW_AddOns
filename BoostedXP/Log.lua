-- Play log for tuning the route planner: how fast this character really kills, rests
-- and moves at each level. It runs during any play, with or without a guide, and keeps
-- per-level totals plus the most recent fights. Nothing leaves the computer: the
-- planner tools read it from the SavedVariables file.
local _, BXP = ...
local Api = BXP.Api

local MAX_FIGHTS = 400   -- recent fights kept in full
local MAX_XP_EVENTS = 300  -- recent XP gains kept raw, to work out how rested XP is spent
local XP_GRACE = 5       -- seconds after combat in which XP still counts as kill XP
local SAMPLE = 1         -- seconds between position samples
local MOVING = 1.5       -- yards per sample that count as moving

local Log = {}
BXP.Log = Log

local log            -- BoostedXPCharDB.log
local fight          -- the fight in progress, or the last one within XP_GRACE
local fightEnded     -- GetTime() when the last fight ended
local inCombat = false
local lastXP, lastMax, lastLevel, lastRest
local lastPos
local trackTargetGUID

local function plain(v) return Api.plain(v) end

local function restPool()
    return GetXPExhaustion and plain(GetXPExhaustion()) or 0
end

local function levelStats(level)
    local t = log.levels[level]
    if not t then
        t = { combat = 0, still = 0, moving = 0, mounted = 0, yards = 0, fights = 0, kills = 0,
              killXP = 0, restedXP = 0, questXP = 0, otherXP = 0, deaths = 0, grouped = 0 }
        log.levels[level] = t
    end
    return t
end

function Log.Start()
    BoostedXPCharDB.log = BoostedXPCharDB.log or {}
    log = BoostedXPCharDB.log
    log.version = 1
    log.levels = log.levels or {}
    log.fights = log.fights or {}
    log.xp = log.xp or {}
    log.class = plain(select(2, UnitClass("player")))
    lastXP, lastMax, lastLevel = plain(UnitXP("player")), plain(UnitXPMax("player")), Api.PlayerLevel()
    lastRest = restPool()
end

-- XP gained since the last update, across a level-up.
local function xpGained()
    local xp, max, level = plain(UnitXP("player")), plain(UnitXPMax("player")), Api.PlayerLevel()
    if not xp or not lastXP then
        lastXP, lastMax, lastLevel = xp, max, level
        return 0
    end
    local gained = xp - lastXP
    if level > (lastLevel or level) and lastMax then gained = (lastMax - lastXP) + xp end
    lastXP, lastMax, lastLevel = xp, max, level
    return math.max(0, gained)
end

local function onXP()
    if not log then return end
    if trackTargetGUID then trackTargetGUID() end
    local gained = xpGained()
    if gained <= 0 then return end
    local rest = restPool()
    -- The rested pool counts XP earned at double rate, so it drops by twice the bonus
    -- (confirmed in the Forever beta, 2026-10-04). log.xp keeps the raw numbers.
    local rested = math.max(0, math.min(gained, math.floor(((lastRest or 0) - rest) / 2)))
    local now = GetTime()
    local fighting = fight ~= nil and (inCombat or (fightEnded ~= nil and now - fightEnded <= XP_GRACE))
    table.insert(log.xp, { t = GetServerTime(), gained = gained, restBefore = lastRest, restAfter = rest,
                           level = Api.PlayerLevel(), kill = fighting or nil,
                           mob = fighting and fight.mob or nil })
    while #log.xp > MAX_XP_EVENTS do table.remove(log.xp, 1) end
    lastRest = rest
    local stats = levelStats(Api.PlayerLevel())
    if fighting then
        fight.kills = fight.kills + 1
        fight.xp = fight.xp + gained - rested
        fight.rested = fight.rested + rested
        stats.kills = stats.kills + 1
        stats.killXP = stats.killXP + gained - rested
        stats.restedXP = stats.restedXP + rested
    else
        stats.otherXP = stats.otherXP + gained
    end
end

-- Copy a finished fight's kills and XP (some arrive just after combat) into its record.
local function close()
    if fight and fight.record then
        fight.record.kills, fight.record.xp, fight.record.rested = fight.kills, fight.xp, fight.rested
    end
    fight = nil
end

local function onCombatStart()
    if not log then return end
    close()
    if trackTargetGUID then trackTargetGUID() end
    inCombat = true
    local level = Api.PlayerLevel()
    local classification = UnitClassification and plain(UnitClassification("target"))
    local npc = plain(UnitExists("target")) and not (UnitIsPlayer and plain(UnitIsPlayer("target")))
    fight = {
        t = GetServerTime(), start = GetTime(), level = level, kills = 0, xp = 0, rested = 0,
        mob = plain(UnitExists("target")) and plain(UnitLevel("target")) or nil,
        name = npc and UnitName and plain(UnitName("target")) or nil,  -- the mob, never a player
        elite = classification ~= nil and classification ~= "normal" and classification ~= "minus" or nil,
        group = IsInGroup and IsInGroup() or nil,
    }
end

local function onCombatEnd()
    if not log or not fight then return end
    if trackTargetGUID then trackTargetGUID() end
    inCombat = false
    fightEnded = GetTime()
    fight.dur = math.floor((fightEnded - fight.start) * 10 + 0.5) / 10
    local stats = levelStats(fight.level)
    stats.combat = stats.combat + fight.dur
    stats.fights = stats.fights + 1
    if fight.group then stats.grouped = stats.grouped + 1 end
    local record = { t = fight.t, dur = fight.dur, level = fight.level, mob = fight.mob, elite = fight.elite,
                     group = fight.group, name = fight.name }
    fight.record = record
    table.insert(log.fights, record)
    while #log.fights > MAX_FIGHTS do table.remove(log.fights, 1) end
end

local function settle()
    if fight and fight.record and not inCombat and fightEnded and GetTime() - fightEnded > XP_GRACE then close() end
end

-- Time out of combat, split into standing still (resting, eating, looting, talking)
-- and moving, with the distance covered.
-- Seconds played in each guide (BoostedXPCharDB.playtime): breaks and logouts don't count,
-- so splits and the window's pace compare real playing time with the planner's. A
-- guide already under way starts at its current step's predicted time (on pace).
local function countPlaytime()
    local guide = BXP.guide
    if not (guide and BoostedXPCharDB) or (UnitIsAFK and plain(UnitIsAFK("player"))) or not BXP:InGuideLevels(guide) then
        return
    end
    local playtime = BoostedXPCharDB.playtime or {}
    BoostedXPCharDB.playtime = playtime
    if playtime[guide.id] == nil then
        local before = BXP.baseIndex and guide.steps[BXP.baseIndex - 1]
        playtime[guide.id] = before and before.eta or 0
    end
    playtime[guide.id] = playtime[guide.id] + SAMPLE
end

local function sample()
    settle()
    countPlaytime()
    if not log or UnitOnTaxi("player") or UnitIsDeadOrGhost("player") then
        lastPos = nil
        return
    end
    local continent, x, y = Api.PlayerWorldPosition()
    if not continent or inCombat then  -- in combat: only keep the position to measure from
        lastPos = continent and { continent, x, y } or nil
        return
    end
    local stats = levelStats(Api.PlayerLevel())
    if lastPos and lastPos[1] == continent then
        local d = math.sqrt((x - lastPos[2]) ^ 2 + (y - lastPos[3]) ^ 2)
        if d >= MOVING then
            stats.moving = stats.moving + SAMPLE
            stats.yards = stats.yards + d
            if IsMounted and IsMounted() then stats.mounted = stats.mounted + SAMPLE end
        else
            stats.still = stats.still + SAMPLE
        end
    end
    lastPos = { continent, x, y }
end
Log.Sample = sample

BXP:On("PLAYER_XP_UPDATE", function(_, unit) if unit == nil or unit == "player" then onXP() end end)
BXP:On("PLAYER_REGEN_DISABLED", onCombatStart)
BXP:On("PLAYER_REGEN_ENABLED", onCombatEnd)
-- Quests seen in play (BoostedXPCharDB.quests): ID, title, and where and from whom each was
-- accepted and turned in, with the XP. New Forever quests reach the fan sites late; this
-- lets the planner add them from one playthrough.
local MAX_QUESTS = 1000

local function questRecord(id)
    BoostedXPCharDB.quests = BoostedXPCharDB.quests or {}
    local quests = BoostedXPCharDB.quests
    if not quests[id] then
        local n = 0
        for _ in pairs(quests) do n = n + 1 end
        if n >= MAX_QUESTS then return nil end
        quests[id] = {}
    end
    local q = quests[id]
    q.title = q.title or plain(C_QuestLog.GetTitleForQuestID(id))
    return q
end

local npcName = BXP.Api.NpcName

-- The game closes the quest window, and the "npc" unit with it, before QUEST_ACCEPTED fires
-- (3 givers in 4 went unrecorded), so the NPC is noted per quest while the window is open.
local dialogNPC = {}  -- questID -> NPC name

local function noteNPC()
    local id, name = GetQuestID and plain(GetQuestID()), npcName()
    if id and id ~= 0 and name then dialogNPC[id] = name end
end
-- A quest started from an item in the bags shows its window with the item's ID (QUEST_DETAIL's questStartItemID):
-- the export carries it, so the planner learns what starts a quest no database places (Nibbled-On Book, 2026-10-12).
local startItem = {}  -- questID -> item ID
BXP:OnFirst("QUEST_DETAIL", function(_, itemID)
    noteNPC()
    local id, item = GetQuestID and plain(GetQuestID()), plain(itemID)
    if id and id ~= 0 and type(item) == "number" and item ~= 0 then startItem[id] = item end
end)
BXP:OnFirst("QUEST_PROGRESS", noteNPC)
BXP:OnFirst("QUEST_COMPLETE", noteNPC)

local function here(id)
    local mapID, x, y = Api.PlayerMapPosition()
    local npc = id and dialogNPC[id] or npcName()
    if id then dialogNPC[id] = nil end
    return { t = GetServerTime(), level = Api.PlayerLevel(), mapID = mapID, npc = npc,
             x = x and math.floor(x * 1000 + 0.5) / 10, y = y and math.floor(y * 1000 + 0.5) / 10 }
end

BXP:On("QUEST_ACCEPTED", function(_, a, b)
    local id = plain(b) or plain(a)  -- (questID), or (logIndex, questID) in older clients
    local q = BoostedXPCharDB and id and questRecord(id)
    if q then
        q.accepted = here(id)
        q.accepted.item, startItem[id] = startItem[id], nil
    end
end)

BXP:On("QUEST_TURNED_IN", function(_, questID, xpReward)
    if log then
        local stats = levelStats(Api.PlayerLevel())
        stats.questXP = stats.questXP + (plain(xpReward) or 0)
    end
    local q = plain(questID) and questRecord(plain(questID))
    if q then
        q.turnedIn = here(plain(questID))
        q.turnedIn.xp = plain(xpReward)
    end
end)

-- Where quest objectives tick up (BoostedXPCharDB.quests[id].spots): a kill or pickup
-- that counted, with the player's position. New Forever quests often have no objective
-- positions in any database; these give the planner real hunting areas.
local MAX_SPOTS = 30  -- per quest
local counts = {}  -- questID -> { [objective] = numFulfilled } last seen

-- The game's map marker for a quest in the log (the blue area's center while it's being
-- worked, the turn-in once it's done): the client has every quest's objective area, but
-- only shows it for quests in the log. Kept as q.marker and q.markerDone, map percentages.
local function questMarker(id)
    local mapID = plain(C_Map.GetBestMapForUnit("player"))
    if mapID and C_QuestLog.GetQuestsOnMap then
        for _, poi in ipairs(C_QuestLog.GetQuestsOnMap(mapID) or {}) do
            if plain(poi.questID) == id and plain(poi.x) then return mapID, plain(poi.x), plain(poi.y) end
        end
    end
    if C_QuestLog.GetNextWaypoint then
        local m, x, y = C_QuestLog.GetNextWaypoint(id)
        if plain(m) and plain(x) then return plain(m), plain(x), plain(y) end
    end
end

local function noteMarker(id)
    local known = BoostedXPCharDB.quests and BoostedXPCharDB.quests[id]
    local key = Api.IsQuestReady(id) and "markerDone" or "marker"
    if known and known[key] then return end
    local mapID, x, y = questMarker(id)
    local q = mapID and questRecord(id)
    if q then
        q[key] = { mapID = mapID, x = math.floor(x * 1000 + 0.5) / 10, y = math.floor(y * 1000 + 0.5) / 10 }
    end
end

local recentTargetGUID, recentTargetTime

local function creatureIDFromGUID(guid)
    if not guid or type(guid) ~= "string" then return nil end
    local kind, _, _, _, _, idStr = strsplit("-", guid)
    if (kind == "Creature" or kind == "Vehicle") and idStr then
        return tonumber(idStr)
    elseif guid:find("^0x") and #guid >= 12 then
        local entryHex = guid:sub(7, 10)
        return tonumber(entryHex, 16)
    end
    return nil
end

local function trackTargetGUID()
    local guid = UnitGUID and plain(UnitGUID("target"))
    if guid and creatureIDFromGUID(guid) then
        recentTargetGUID = guid
        recentTargetTime = GetTime()
    end
end

local function onLootOpened()
    if GetLootSourceInfo then
        local guid = plain(GetLootSourceInfo(1))
        if guid and creatureIDFromGUID(guid) then
            recentTargetGUID = guid
            recentTargetTime = GetTime()
            return
        end
    end
    trackTargetGUID()
end

local function currentCreatureID()
    local guid = UnitGUID and plain(UnitGUID("target"))
    local cid = creatureIDFromGUID(guid)
    if cid then return cid end
    if recentTargetGUID and recentTargetTime and (GetTime() - recentTargetTime) <= 15 then
        return creatureIDFromGUID(recentTargetGUID)
    end
    return nil
end

BXP:On("PLAYER_TARGET_CHANGED", trackTargetGUID)
BXP:On("LOOT_OPENED", onLootOpened)

local function noteProgress()
    if not (BoostedXPCharDB and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return end
    for i = 1, plain(C_QuestLog.GetNumQuestLogEntries()) or 0 do
        local info = C_QuestLog.GetInfo(i)
        local id = info and not plain(info.isHeader) and plain(info.questID)
        if id and id > 0 then
            noteMarker(id)
            local seen, now = counts[id], {}
            for oi, o in ipairs(C_QuestLog.GetQuestObjectives(id) or {}) do
                now[oi] = plain(o.numFulfilled) or 0
                if seen and now[oi] > (seen[oi] or now[oi]) then
                    local q = questRecord(id)
                    if q then
                        local cid = currentCreatureID()
                        q.spots = q.spots or {}
                        if #q.spots < MAX_SPOTS then
                            local spot = here()
                            spot.npc, spot.objective = nil, oi
                            if cid and cid > 0 then
                                spot.mob = cid
                            end
                            q.spots[#q.spots + 1] = spot
                        end
                        if cid and cid > 0 then
                            q.droppers = q.droppers or {}
                            local key = tostring(oi)
                            q.droppers[key] = q.droppers[key] or {}
                            local found = false
                            for _, mid in ipairs(q.droppers[key]) do
                                if mid == cid then found = true; break end
                            end
                            if not found then
                                table.insert(q.droppers[key], cid)
                            end
                        end
                    end
                end
            end
            counts[id] = now
        end
    end
end
BXP:On("QUEST_LOG_UPDATE", noteProgress)

-- Quests already in the log at login (accepted before this was recorded): ID and title.
local function noteQuestLog()
    if not (C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return end
    for i = 1, plain(C_QuestLog.GetNumQuestLogEntries()) or 0 do
        local info = C_QuestLog.GetInfo(i)
        local id = info and not plain(info.isHeader) and plain(info.questID)
        if id and id > 0 then questRecord(id) end
    end
end
BXP:On("PLAYER_DEAD", function()
    if log then
        local stats = levelStats(Api.PlayerLevel())
        stats.deaths = stats.deaths + 1
    end
end)
BXP:On("BXP_READY", function()
    Log.Start()
    noteQuestLog()
    C_Timer.NewTicker(SAMPLE, sample)
end)

-- Summary for /boost log: one line per level with time logged, kill rate and downtime.
function Log.Summary()
    local out = {}
    local levels = {}
    for level in pairs(log and log.levels or {}) do levels[#levels + 1] = level end
    table.sort(levels)
    for _, level in ipairs(levels) do
        local s = log.levels[level]
        local busy = s.combat + s.still + s.moving
        if busy >= 30 then
            local perHour = function(xp) return xp / busy * 3600 end
            out[#out + 1] = ("L%d: %d min logged, %d fights (%.0fs avg), %d kills, %.0f XP/h from kills%s, %d%% resting, %.1f yd/s moving"):format(
                level, busy / 60, s.fights, s.fights > 0 and s.combat / s.fights or 0, s.kills, perHour(s.killXP),
                s.restedXP > 0 and (" (+%.0f rested)"):format(perHour(s.restedXP)) or "",
                100 * s.still / busy, s.moving > 0 and s.yards / s.moving or 0)
        end
    end
    return out
end

function Log.Reset()
    if log then
        log.levels, log.fights, log.xp = {}, {}, {}
    end
end
