-- Guide registry and the step engine: works out which step is current and when it's done.
--
-- A guide is a table registered with BXP:RegisterGuide. Each step has exactly one kind key:
--   accept = questID | {ids}     turnin = ...     complete = ...
--   go = "Place"                 level = 6         sethome = "Razor Hill"
--   flightpath = "Crossroads"    fly = "Crossroads"  hearth = "Razor Hill"
--   train = true | "text"        vendor = "Item"   note = "text"
--   (vendor: buy a quest item; item = itemID, count, quest = the quest it's for; done once
--   the bags hold count, or the quest is ready or turned in)
--   loot = "Item"                (kill npc and loot an item a quest needs first, e.g. the key to the chest that
--   starts it; item = itemID, count, quest = that quest; done once the bags hold it or the quest is taken)
--   die = true                   (die on purpose; done once a spirit healer resurrects you, or once you're at the
--   healer it sends you to, healer = { x, y [, "Zone"] }, having walked there)
-- Optional fields: at = { x, y [, "Zone"] } (0-100 map coords, zone defaults to guide.zone),
-- npc, text (extra detail line; on complete steps it gives way to the live objectives once
-- the quests are in the log), hint (tip that always shows, e.g. objectives on the way; with
-- onway = quest IDs, their live objectives replace it once they're in the log),
-- objectives (complete: the part of a split quest the step covers, { [questID] = { objective names } }),
-- radius (yards, for go), areas (complete: its hunting areas, { x, y [, "Zone"], r = yards, q = quest };
-- the arrow leads to the nearest open one and hides inside it; accept: where the mob that drops the quest's
-- starting item lives, led to until the quest is taken), class / race (file names or lists),
-- dungeon (key from Data/Dungeons.lua), reward (choice index for automated turn-ins),
-- verify (true while the step still needs checking in the Forever client),
-- eta (planner's predicted seconds from the guide's start, kept with each split for tuning),
-- requires (quest IDs that must be turned in before an accept step's quest is offered),
-- fromitem (accept: the quest starts from an item, its ID or true when unknown: the step waits until the item is in
-- the bags, and so do steps needing the quest), drops (complete: { [questID] = text } for quests whose starting item
-- this hunt's mobs drop, shown under "Also work on" until the quest is taken).
--
-- Progress is saved per step key (kind plus quests, e.g. "accept:792"), so it survives
-- regenerated guides. Skipping a step marks it done. If a later step requires a quest
-- whose steps were skipped, those steps come back; skipping one of them again drops
-- that quest and everything that requires it.
-- Guide ids are lowercase so they can be typed in /boost guide <id>.
local _, BXP = ...
local Api, Zones = BXP.Api, BXP.Zones

BXP.guides = {}
BXP.guideList = {}

local KINDS = {
    "accept", "turnin", "complete", "go", "level", "sethome",
    "flightpath", "fly", "hearth", "train", "vendor", "loot", "note", "die",
}
local QUEST_KINDS = { accept = true, turnin = true, complete = true }

-- Flex: the window shows the planned next step, unless a step among the next few quest steps that the player
-- can do right now is clearly closer. Planned progress (baseIndex, splits, automation) never moves with it.
local FLEX_WINDOW = 8     -- open quest steps looked at from the planned next one
local FLEX_SAVING = 150   -- yards a step must be closer by to be worth skipping ahead
local FLEX_HOP = 30       -- yards of cost for every step skipped
local FAR = 100000        -- a step whose distance isn't known (other continent, no coordinates)
BXP.StepKinds, BXP.QuestKinds = KINDS, QUEST_KINDS

local GO_RADIUS = 12      -- yards
local IN_PROGRESS_AHEAD = 5  -- steps looked at for hunts whose progress shows under the current step
local NEARBY = 50         -- yards past a later hunt's pocket within which its quest is worked now ("Also work on")
local HEARTHSTONE = 8690  -- spell ID

-- Stable identity of a step across regenerated guides.
local function stepKey(step, seen)
    local base
    if step.quests then
        local ids = {}
        for i, id in ipairs(step.quests) do ids[i] = id end
        table.sort(ids)
        base = step.kind .. ":" .. table.concat(ids, ",")
    else
        base = step.kind .. ":" .. tostring(step[step.kind])
    end
    seen[base] = (seen[base] or 0) + 1
    return seen[base] == 1 and base or (base .. "#" .. seen[base])
end

function BXP:RegisterGuide(guide)
    local seen = {}
    for i, step in ipairs(guide.steps) do
        step.index = i
        for _, kind in ipairs(KINDS) do
            if step[kind] ~= nil then
                step.kind = kind
                break
            end
        end
        if not step.kind then
            error(("BoostedXP: guide %s step %d has no step kind"):format(guide.id, i))
        end
        if QUEST_KINDS[step.kind] then
            local q = step[step.kind]
            step.quests = type(q) == "table" and q or { q }
        end
        if step.at then step.at.zone = step.at[3] or guide.zone end
        if step.healer then step.healer.zone = step.healer[3] or guide.zone end
        for _, area in ipairs(step.areas or {}) do area.zone = area[3] or guide.zone end
        step.owner = guide
        step.key = stepKey(step, seen)
    end
    guide.acceptOf = {}  -- questID -> its accept step (WaitsForItem follows requires through them)
    guide.acceptsOf = {} -- questID -> its accept steps (AcceptPending O(1) lookup)
    for _, step in ipairs(guide.steps) do
        if step.kind == "accept" then
            for _, id in ipairs(step.quests) do
                guide.acceptOf[id] = guide.acceptOf[id] or step
                local list = guide.acceptsOf[id]
                if not list then
                    list = {}
                    guide.acceptsOf[id] = list
                end
                list[#list + 1] = step
            end
        end
    end
    -- What each step builds on (WaitsForLevel): a turn-in, the last hunt for its quest before it; an accept, the
    -- last turn-in before it of each quest it requires.
    for i, step in ipairs(guide.steps) do
        local wanted, kind = nil, nil
        if step.kind == "turnin" then wanted, kind = step.quests, "complete" end
        if step.kind == "accept" then wanted, kind = step.requires, "turnin" end
        for _, id in ipairs(wanted or {}) do
            for j = i - 1, 1, -1 do
                local s = guide.steps[j]
                if s.kind == kind and tContains(s.quests, id) then
                    step.after = step.after or {}
                    step.after[#step.after + 1] = { step = s, quest = id }
                    break
                end
            end
        end
    end
    if self.guides[guide.id] then
        for i, g in ipairs(self.guideList) do
            if g.id == guide.id then self.guideList[i] = guide; break end
        end
    else
        table.insert(self.guideList, guide)
    end
    self.guides[guide.id] = guide
end

local function matches(filter, value)
    if filter == nil then return true end
    if type(filter) ~= "table" then return filter == value end
    for _, f in ipairs(filter) do
        if f == value then return true end
    end
    return false
end

-- Per-guide tables in the character's saved variables (done, returned, dropped, splits).
function BXP:CharTable(name, guideID)
    local all = self.char[name]
    local t = all[guideID]
    if not t then
        t = {}
        all[guideID] = t
    end
    return t
end

function BXP:IsDropped(questID)
    return self.guide ~= nil and self:CharTable("dropped", self.guide.id)[questID] == true
end

-- Whether the guide can't get you a quest: you don't have it or turned it in, and its accept step requires a quest
-- you haven't turned in and don't have that no accept step of this guide gives (it came in an earlier guide: a Dwarf
-- shaman who started at 20-25 had been sent to Terenthis for How Big a Threat?, whose first part is in 15-20,
-- 2026-10-14), or one that is itself out of reach. A prerequisite in this guide is left to Resurface.
function BXP:OutOfReach(questID, guide, depth)
    depth = depth or 0
    local accept = guide and guide.acceptOf and guide.acceptOf[questID]
    if not accept or not accept.requires or depth > 20 then return false end
    if Api.IsQuestTurnedIn(questID) or Api.IsQuestInLog(questID) then return false end
    for _, req in ipairs(accept.requires) do
        if not Api.IsQuestTurnedIn(req) and not Api.IsQuestInLog(req)
                and (not guide.acceptOf[req] or self:OutOfReach(req, guide, depth + 1)) then
            return true
        end
    end
    return false
end

-- Quests of a step the player hasn't dropped and can do: a shared hunting step marks a class-only quest
-- (only = { [questID] = { classes } }), which other classes leave out; nor quests out of reach (OutOfReach).
function BXP:LiveQuests(step)
    local out, class = {}, nil
    for _, id in ipairs(step.quests or {}) do
        local only = step.only and step.only[id]
        if only then class = class or Api.plain(select(2, UnitClass("player"))) end
        if not self:IsDropped(id) and (not only or matches(only, class))
                and not self:OutOfReach(id, step.owner or self.guide) then
            out[#out + 1] = id
        end
    end
    return out
end

-- A hunting step may cover only part of a quest (objectives = { [questID] = { names } }): the planner works a
-- quest's objectives separately when they lie far apart or their mobs differ in level (Encroachment's Razormane
-- Quilboars and Scouts at level 6 with the fruit, its Dustrunners and Battleguards from 8). Names are found in the
-- quest's objective texts, any case. Returns the step's objectives of the quest and whether they are a part; names
-- that match none of them leave the step the whole quest.
function BXP:StepObjectives(step, id)
    local all = Api.GetObjectives(id)
    local names = step.objectives and step.objectives[id]
    if not names then return all, false end
    local out = {}
    for _, o in ipairs(all) do
        local text = (o.text or ""):lower()
        for _, name in ipairs(names) do
            if text:find(name:lower(), 1, true) then
                out[#out + 1] = o
                break
            end
        end
    end
    if #out == 0 then return all, false end
    return out, true
end

-- Whether a hunting step is through with a quest: ready or handed in, or its part of the objectives finished.
function BXP:HuntDone(step, id)
    if Api.IsQuestTurnedIn(id) or Api.IsQuestReady(id) then return true end
    if not (step.objectives and step.objectives[id]) or not Api.IsQuestInLog(id) then return false end
    local objectives, part = self:StepObjectives(step, id)
    if not part then return false end
    for _, o in ipairs(objectives) do
        if not o.finished then return false end
    end
    return true
end

-- Dungeons are on unless /boost dungeons off (all) or /boost dungeon <key> off (one).
function BXP:DungeonOn(key)
    return not self.db.noDungeons and self.db.dungeons[key] ~= false
end

-- Seconds of extra grinding ahead for a character without a dungeon (nil key: every dungeon that is off):
-- the catch-up steps (nodungeon) of the faction's guides that the character hasn't reached yet.
function BXP:SkippedDungeonGrind(key)
    local faction = Api.plain(UnitFactionGroup("player"))
    local level = Api.PlayerLevel()
    local total, parts = 0, {}
    for _, g in ipairs(self.guideList) do
        if not g.side and g.faction == faction then
            for _, step in ipairs(g.steps) do
                local k = step.nodungeon
                if k and (key == nil or key == k) and not self:DungeonOn(k) and step.grind and step.level > level then
                    total = total + step.grind
                    parts[#parts + 1] = (self.DungeonsByKey[k] and self.DungeonsByKey[k].name or k) .. " "
                        .. self.FormatDuration(step.grind)
                end
            end
        end
    end
    return total, parts
end

-- Whether a step waits for the player's level: its own minlevel, or a step it builds on that waits. A turn-in
-- whose quest's hunt opens at a later level can't be done before it (unless the quest is ready already), nor
-- can an accept that needs that quest handed in: at level 7 the guide had a level 8 hunt's turn-in up next.
-- The level a step waits for (its own minlevel, or a step it builds on that waits), or nil when it doesn't.
function BXP:LevelNeeded(step)
    local need = step.minlevel and Api.PlayerLevel() < step.minlevel and step.minlevel or nil
    for _, dep in ipairs(step.after or {}) do
        local done = Api.IsQuestTurnedIn(dep.quest) or (dep.step.kind == "complete" and Api.IsQuestReady(dep.quest))
        local depNeed = not done and self:LevelNeeded(dep.step)
        if depNeed and (not need or depNeed > need) then need = depNeed end
    end
    return need
end

-- A step that applies to this character and still needs doing, but waits for its level: Coming up lists it with the
-- level (2026-10-11: Accept Vile Familiars, from level 2, was missing from Coming up at level 1).
function BXP:OpensLater(step)
    -- A step waiting for a quest's starting item isn't listed: the item may never drop, and the hunt's "Also work on"
    -- says to look for it.
    if not self:WaitsForLevel(step) or self:WaitsForItem(step) or not self:StepApplies(step, true) then return false end
    if QUEST_KINDS[step.kind] then return not self:IsStepClear(step) end
    return self:DoneTable(step.owner.id)[step.key] ~= true
end

function BXP:WaitsForLevel(step)
    if step.minlevel and Api.PlayerLevel() < step.minlevel then return true end
    for _, dep in ipairs(step.after or {}) do
        local done = Api.IsQuestTurnedIn(dep.quest) or (dep.step.kind == "complete" and Api.IsQuestReady(dep.quest))
        if not done and self:WaitsForLevel(dep.step) then return true end
    end
    return false
end

-- Whether a step waits for an item that starts a quest (the maintainer, 2026-10-12: "Accept Nibbled-On Book" must
-- never be the step to do unless you have the item): an accept from an item until it's in the bags (an unknown item:
-- until the quest is taken, from the bags), and an accept needing a quest that waits so. Returns the waiting accept.
function BXP:WaitsForItem(step)
    if step.kind ~= "accept" then return nil end
    if step.fromitem then
        local have = type(step.fromitem) == "number" and Api.ItemCount(step.fromitem) > 0
        for _, id in ipairs(step.quests) do
            if not have and not Api.IsQuestInLog(id) and not Api.IsQuestTurnedIn(id) then return step end
        end
        return nil
    end
    local acceptOf = step.owner and step.owner.acceptOf or {}
    for _, id in ipairs(step.requires or {}) do
        local a = acceptOf[id]
        if a and a ~= step and not Api.IsQuestTurnedIn(id) and not Api.IsQuestInLog(id) then
            local waiting = self:WaitsForItem(a)
            if waiting then return waiting end
        end
    end
    return nil
end

-- Whether a step isn't open yet: it waits for the player's level or for a quest's starting item.
function BXP:Waits(step)
    return self:WaitsForLevel(step) or self:WaitsForItem(step) ~= nil
end

function BXP:StepApplies(step, anyLevel)
    if step.class and not matches(step.class, Api.plain(select(2, UnitClass("player")))) then return false end
    if step.race and not matches(step.race, Api.plain(select(2, UnitRace("player")))) then return false end
    if step.dungeon and not self:DungeonOn(step.dungeon) then return false end
    if step.nodungeon and self:DungeonOn(step.nodungeon) then return false end  -- the catch-up grind for skippers
    if self:IsClassStepHidden(step) then return false end
    if not anyLevel and self:Waits(step) then return false end  -- not open yet
    if step.quests and #self:LiveQuests(step) == 0 then return false end
    -- A drop that only comes after another quest (Shadumbra's Head after quest 6383, 2026-10-13) is no step for a
    -- quest that is out of reach.
    if step.kind == "loot" and step.quest and self:OutOfReach(step.quest, step.owner or self.guide) then return false end
    for _, id in ipairs(step.requires or {}) do
        if self:IsDropped(id) then return false end
    end
    return true
end

-- A training step's trainer: your class's (your side's, from BXP.Trainers) nearest to the step's spot, or to you
-- when it names none. The guide is planned as a warrior and names the warrior trainer in town (2026-10-13, the
-- maintainer: point the arrow at the trainer); a step trained on the way names no spot at all.
function BXP:StepTrainer(step)
    local side = Api.plain(UnitFactionGroup("player"))
    local class = Api.plain(select(2, UnitClass("player")))
    local list = self.Trainers and self.Trainers[side] and self.Trainers[side][class]
    if not list then return nil end
    local fc, fx, fy
    local mapID = step.at and Zones.Resolve(step.at.zone)
    if mapID then fc, fx, fy = Api.WorldPosition(mapID, step.at[1] / 100, step.at[2] / 100)
    else fc, fx, fy = Api.PlayerWorldPosition() end
    if not fc then return nil end
    local best, bestD
    for _, t in ipairs(list) do
        local c, x, y = Api.WorldPosition(t.map, t.x / 100, t.y / 100)
        local d = c == fc and (x - fx) ^ 2 + (y - fy) ^ 2
        if d and (not bestD or d < bestD) then best, bestD = t, d end
    end
    return best
end

-- Target of a step as uiMapID and 0-1 coordinates, or nil. A training step's is your class's trainer.
function BXP:StepMapPosition(step)
    if step and step.kind == "train" then
        local t = self:StepTrainer(step)
        if t then return t.map, t.x / 100, t.y / 100 end
    end
    local at = step and step.at
    if not at then return nil end
    local mapID = Zones.Resolve(at.zone)
    if not mapID then return nil end
    return mapID, at[1] / 100, at[2] / 100
end

-- Yards from the player to a map position (0-1), plus the world-space offset (dx north, dy west).
-- Nil when either position is unknown or they're on different continents.
function BXP:OffsetTo(mapID, x, y)
    local tc, tx, ty = Api.WorldPosition(mapID, x, y)
    local pc, px, py = Api.PlayerWorldPosition()
    if not tc or not pc or tc ~= pc then return nil end
    local dx, dy = tx - px, ty - py
    return math.sqrt(dx * dx + dy * dy), dx, dy
end

-- Yards from the player to the step's target, plus the world-space offset, as OffsetTo.
function BXP:StepDistance(step)
    local mapID, x, y = self:StepMapPosition(step)
    if not mapID then return nil end
    return self:OffsetTo(mapID, x, y)
end

-- Yards to a map position, or nil when it's on another continent or unknown.
function BXP:DistanceTo(mapID, x, y)
    return (self:OffsetTo(mapID, x, y))
end

local check = {}

function check.accept(step)
    for _, id in ipairs(BXP:LiveQuests(step)) do
        if not Api.IsQuestInLog(id) and not Api.IsQuestTurnedIn(id) then return false end
    end
    return true
end

function check.turnin(step)
    for _, id in ipairs(BXP:LiveQuests(step)) do
        if not Api.IsQuestTurnedIn(id) then return false end
    end
    return true
end

function check.complete(step)
    for _, id in ipairs(BXP:LiveQuests(step)) do
        if not BXP:HuntDone(step, id) then return false end
    end
    return true
end

function check.vendor(step)
    if step.quest and (Api.IsQuestTurnedIn(step.quest) or Api.IsQuestReady(step.quest)) then return true end
    return step.item ~= nil and Api.ItemCount(step.item) >= (step.count or 1)
end

function check.loot(step)
    local q = step.quest
    if q and (Api.IsQuestInLog(q) or Api.IsQuestTurnedIn(q)) then return true end
    return step.item ~= nil and Api.ItemCount(step.item) >= (step.count or 1)
end

-- A die step is done by the resurrection, not by where the player stands (standing by the healer had marked the
-- death after Thazz'ril's Pick done ahead of time, 2026-10-11): back from a ghost (PLAYER_UNGHOST, spirit healer or
-- corpse run) since the step before it was finished, so dying a little early counts (the coven's mobs, the pick in
-- the bags); or moved on without dying: the first turn-in after it is handed in (one who walked back to Sen'jin and
-- handed in was still told to die there, 2026-10-09).
local DIE_TURNIN_AHEAD = 5  -- steps looked at for that turn-in
function check.die(step)
    local guide = step.owner
    if not guide or not step.index then return false end
    local back = BoostedXPCharDB and BoostedXPCharDB.unghostAt
    local before = step.index > 1 and guide.steps[step.index - 1]
    local split = before and BXP:CharTable("splits", guide.id)[before.key]
    if back and split and back >= split.t then return true end
    for i = step.index + 1, math.min(#guide.steps, step.index + DIE_TURNIN_AHEAD) do
        local s = guide.steps[i]
        if s.kind == "turnin" and BXP:StepApplies(s, true) then return check.turnin(s) end
    end
    return false
end

function check.level(step)
    return Api.PlayerLevel() >= step.level
end

function check.go(step)
    local dist = BXP:StepDistance(step)
    return dist ~= nil and dist <= (step.radius or GO_RADIUS)
end

function check.sethome(step)
    local bound = Api.plain(GetBindLocation())
    return bound and step.sethome and bound:lower() == step.sethome:lower()
end

-- On the taxi, or already at the destination (a flight too short to catch, or one that ended before the step came up).
function check.fly(step)
    if UnitOnTaxi("player") then return true end
    local want = (step.fly or ""):lower()
    for _, name in ipairs(Api.LocationNames()) do
        if name:lower() == want then return true end
    end
    return false
end

-- The flight path is already known (the client lists the point as discovered, or its taxi map was opened before).
function check.flightpath(step)
    return BXP:KnowsFlight(step.flightpath) and true or false
end

-- Already at the destination (walked there, or never left).
function check.hearth(step)
    local want = (step.hearth or ""):lower()
    for _, name in ipairs(Api.LocationNames()) do
        if name:lower() == want then return true end
    end
    return false
end

-- A training step you are already past: you trained at its level or higher (a trainer step of 22 for a player who
-- trained at 24 without the addon's step, 2026-10-18). It finishes by event too (FinishTraining).
function check.train(step)
    return step.minlevel ~= nil and (BXP.char.trainedLevel or 0) >= step.minlevel
end

-- Whether a step is done right now by game state. Kinds without a check
-- (note) finish by event or by hand; a flightpath step also by event (the flight master's map opens).
function BXP:IsStepSatisfied(step)
    local fn = check[step.kind]
    return fn and fn(step) or false
end

-- Whether an earlier accept step of the step's own guide is still waiting to take the quest: until then a
-- hunting or turn-in step for a quest the player doesn't have yet isn't skipped, it is just not its turn.
function BXP:AcceptPending(step, id)
    local guide = step.owner
    if not guide then return false end
    local from, returned = self:CursorIndex(guide) or 1, self:CharTable("returned", guide.id)
    local stepIndex = step.index or 1
    local accepts = guide.acceptsOf and guide.acceptsOf[id]
    if accepts then
        for _, s in ipairs(accepts) do
            local j = s.index or 1
            if j < stepIndex and (j >= from or returned[s.key]) and self:StepApplies(s)
                    and not self:IsStepSatisfied(s) then
                return true
            end
        end
        return false
    end
    if guide.acceptsOf then return false end
    for j = 1, stepIndex - 1 do
        local s = guide.steps[j]
        if s.kind == "accept" and (j >= from or returned[s.key]) and tContains(s.quests, id) and self:StepApplies(s)
                and not self:IsStepSatisfied(s) then
            return true
        end
    end
    return false
end

-- Done, or impossible to do: a hunting or turn-in step whose quests the player doesn't have (not in the log,
-- not handed in) and that no accept step of the guide will still take is skipped. The guide's current step
-- uses this, so a drifting player isn't stuck on a step for a quest they never took; placement
-- (IsStepSatisfied) keeps the strict meaning of done.
function BXP:IsStepClear(step)
    if self:IsStepSatisfied(step) then return true end
    if step.kind ~= "complete" and step.kind ~= "turnin" then return false end
    for _, id in ipairs(self:LiveQuests(step)) do
        local finished = Api.IsQuestTurnedIn(id) or (step.kind == "complete" and self:HuntDone(step, id))
        if not finished and (Api.IsQuestInLog(id) or self:AcceptPending(step, id)) then return false end
    end
    return true
end

function BXP:DoneTable(guideID)
    return self:CharTable("done", guideID)
end

-- Where the guide reads from. Next and Back move it; neither marks a step done, so a step you skipped is still
-- there when you come back to it. A guide never read starts at its first step; a character from before the
-- pointer, at the first step its old done marks left unmarked (steps waiting for a level stay ahead).
function BXP:Cursor(guide)
    local c = self:CursorIndex(guide)
    if c then return c end
    c = #guide.steps + 1
    local done = self:DoneTable(guide.id)
    for i, step in ipairs(guide.steps) do
        if done[step.key] ~= true then
            c = i
            break
        end
    end
    self:SetCursor(guide, c)
    return c
end

-- The pointer is kept as the step's key (and its index for when that step is gone): a re-planned guide
-- renumbers its steps, and the character should stay at the same step, not the same number.
function BXP:SetCursor(guide, i)
    local step = guide.steps[i]
    self.char.cursor[guide.id] = { key = step and step.key or "end", index = i }
end

function BXP:CursorIndex(guide)
    local c = self.char.cursor[guide.id]
    if type(c) == "number" then return c end  -- saved before keys were kept
    if type(c) ~= "table" then return nil end
    if c.key == "end" then return #guide.steps + 1 end
    for i, step in ipairs(guide.steps) do
        if step.key == c.key then return i end
    end
    return math.min(c.index or 1, #guide.steps + 1)
end

-- Whether a step still needs doing. A quest step: until the game says it's done, or it can't happen (a hunt or
-- turn-in for a quest you don't have that nothing ahead takes). Any other step: until its check or event
-- finishes it; once satisfied it stays done (a go step doesn't come back when you walk on).
function BXP:IsOpen(step)
    if not self:StepApplies(step) then return false end
    if QUEST_KINDS[step.kind] then return not self:IsStepClear(step) end
    local done = self:DoneTable(step.owner.id)
    if done[step.key] == true then return false end
    if self:IsStepSatisfied(step) then
        done[step.key] = true
        return false
    end
    return true
end

-- Whether going Back should stop at a step: it still needs doing, and a hunt or turn-in only for a quest in the
-- log (its accept comes before it).
function BXP:NeedsDoing(step)
    if not self:StepApplies(step) then return false end
    if not QUEST_KINDS[step.kind] then
        return self:DoneTable(step.owner.id)[step.key] ~= true and not self:IsStepSatisfied(step)
    end
    if self:IsStepSatisfied(step) then return false end
    if step.kind == "accept" then return true end
    for _, id in ipairs(self:LiveQuests(step)) do
        if Api.IsQuestInLog(id) then return true end
    end
    return false
end

function BXP:CurrentStep()
    return self.guide and self.currentIndex and self.guide.steps[self.currentIndex]
end

-- A step whose prerequisite you skipped (its steps are behind the pointer, not turned in) brings that quest's
-- steps back, ahead of everything else; the steps you skipped in between stay skipped.
function BXP:Resurface(guide, i)
    local returned = self:CharTable("returned", guide.id)
    local from = self:Cursor(guide)
    local any = false
    for _, req in ipairs(guide.steps[i].requires or {}) do
        if not Api.IsQuestTurnedIn(req) and not self:IsDropped(req) then
            for j = 1, math.min(i, from) - 1 do
                local s = guide.steps[j]
                if not returned[s.key] and s.quests and tContains(s.quests, req) and self:StepApplies(s)
                        and not self:IsStepSatisfied(s) then
                    returned[s.key] = true
                    -- Only a step that's open once back counts: FindCurrent lets go of one that isn't, and bringing it
                    -- back again looped forever ("script ran too long": Neeru Fireblade's turn-in, whose accept
                    -- waited for Skull Rock's level, 2026-10-09).
                    if self:IsOpen(s) then any = true else returned[s.key] = nil end
                end
            end
        end
    end
    return any
end

-- The step to do: a step brought back for a later quest first (Resurface), or one Next passed while it waited for
-- the player's level, now reached; else the first open step from the pointer on. Steps behind the pointer are
-- skipped, not done: Back reaches them again.
function BXP:FindCurrent(guide)
    local returned, waited = self:CharTable("returned", guide.id), self:CharTable("waited", guide.id)
    local from = self:Cursor(guide)
    for j = 1, from - 1 do
        local step = guide.steps[j]
        if returned[step.key] then
            if self:IsOpen(step) then return j end
            returned[step.key] = nil  -- done since it came back
        end
        if waited[step.key] and not self:Waits(step) then
            if self:IsOpen(step) then return j end
            waited[step.key] = nil  -- done (or no longer wanted) by the time the level came
        end
    end
    for j = from, #guide.steps do
        if self:IsOpen(guide.steps[j]) then return j end
    end
end

-- Whether a step is in play: from the pointer on, or brought back.
function BXP:Ahead(guide, i)
    return i >= self:Cursor(guide) or self:CharTable("returned", guide.id)[guide.steps[i].key] == true
end

-- Whether a quest step can be done in the game right now (its quests are in the right state).
function BXP:Actionable(step)
    local live = self:LiveQuests(step)
    if step.kind == "accept" then
        for _, id in ipairs(step.requires or {}) do
            if not Api.IsQuestTurnedIn(id) and not self:IsDropped(id) then return false end
        end
        return true
    elseif step.kind == "complete" then
        for _, id in ipairs(live) do
            if not (Api.IsQuestInLog(id) or Api.IsQuestTurnedIn(id)) then return false end
        end
        return true
    elseif step.kind == "turnin" then
        for _, id in ipairs(live) do
            if not (Api.IsQuestReady(id) or Api.IsQuestTurnedIn(id)) then return false end
        end
        return true
    end
    return false
end

-- The step to show: the planned next one (first), or a clearly closer one the player can do now. Only quest
-- steps are reordered; a travel, training or vendor step in between is a wall. Keeps its last pick while it
-- stays about as good, so the window doesn't flicker as the player walks.
BXP.flexSkip = {}

function BXP:FlexPick(guide, first)
    if self.flexHold then  -- the step Back went to stays shown until it's done or the player moves on
        if first and guide.steps[first].key == self.flexHold then return first end
        self.flexHold = nil
    end
    if first and guide.steps[first].kind == "level" then
        -- A grind step waits while a quest step ahead can be done now (taken, hunted, handed in): working on quests
        -- gets the level too. It only shows when nothing is doable (the maintainer, 2026-10-09: Zephras Isle said to
        -- grind to level 2 with a level 1 quest on offer). Travel steps ahead are still walls.
        for i = first + 1, math.min(#guide.steps, first + 2 * FLEX_WINDOW) do
            local step = guide.steps[i]
            if not QUEST_KINDS[step.kind] and step.kind ~= "level" then break end
            if QUEST_KINDS[step.kind] and self:Ahead(guide, i) and self:IsOpen(step) and self:Actionable(step) then
                return i
            end
        end
        return first
    end
    if not first or not self.db.flex or not QUEST_KINDS[guide.steps[first].kind] then return first end
    local scores, skipped = {}, 0
    for i = first, #guide.steps do
        local step = guide.steps[i]
        if self:Ahead(guide, i) and not self.flexSkip[step.key] and self:IsOpen(step) then
            if not QUEST_KINDS[step.kind] then break end
            if self:Actionable(step) then scores[i] = (self:StepDistance(step) or FAR) + FLEX_HOP * skipped end
            skipped = skipped + 1
            if skipped >= FLEX_WINDOW then break end
        end
    end
    local best
    for i, score in pairs(scores) do
        if not best or score < scores[best] or (score == scores[best] and i < best) then best = i end
    end
    if not best then return first end
    local last = self.currentIndex
    if last and last ~= first and scores[last] and scores[last] <= scores[best] + FLEX_SAVING / 2 then best = last end
    if best ~= first and scores[first] and scores[best] + FLEX_SAVING > scores[first] then return first end
    return best
end

function BXP:Refresh()
    local guide = self.guide
    if not guide then return end
    local current = self:FindCurrent(guide)
    for _ = 1, #guide.steps do  -- each round brings back new steps; never more rounds than steps
        if not (current and self:Resurface(guide, current)) then break end
        current = self:FindCurrent(guide)
    end
    if not current and guide.side then return self:LeaveSideGuide(true) end
    if not current and guide.next and self.guides[guide.next] then
        self:Print(("Finished %s. Next up: %s."):format(guide.name, self.guides[guide.next].name))
        return self:SetGuide(guide.next, true)
    end
    if current ~= self.baseIndex then  -- planned progress: the first open step
        self:RecordSplits(guide, self.baseIndex, current)
        self.baseIndex = current
    end
    self.goIndex = self:FlexPick(guide, current)  -- where to go, even while looking back at a done step
    local pick = self.viewIndex or self.goIndex
    if pick ~= self.currentIndex then
        self.currentIndex = pick
        self:Fire("BXP_STEP_CHANGED", self:CurrentStep())
    end
    self:AnnounceClassWork()
    self:Fire("BXP_REFRESH")
end

function BXP:IsClassQuestHidden(questID)
    local hidden = self.char and self.char.classHidden
    return hidden ~= nil and (hidden[questID] == true or hidden[tostring(questID)] == true)
end

function BXP:IsClassStepHidden(step)
    if not (step.owner and step.owner.side) then return false end
    if step.classLineKey and self:IsClassQuestHidden(step.classLineKey) then return true end
    for _, qid in ipairs(step.quests or {}) do
        if self:IsClassQuestHidden(qid) then return true end
    end
    return false
end

function BXP:ClassQuestLines(guide)
    guide = guide or self:ClassGuide()
    if not guide then return {} end
    local lines = {}
    local lineByQuest = {}
    local race = Api.plain(select(2, UnitRace("player")))
    local class = Api.plain(select(2, UnitClass("player")))
    local curLine = nil
    local prevTurninNpc = nil
    local leadIn = {}

    for _, step in ipairs(guide.steps) do
        if matches(step.class, class) and matches(step.race, race) then
            local qid = step.quests and step.quests[1]
            if qid then
                local minlevel = step.minlevel or 1
                local isNew = false
                if not curLine then
                    isNew = true
                elseif curLine.minlevel ~= minlevel then
                    isNew = true
                elseif step.kind == "accept" and not curLine.questSet[qid] then
                    if not prevTurninNpc or not step.npc or prevTurninNpc ~= step.npc then
                        isNew = true
                    end
                end

                if isNew then
                    if lineByQuest[qid] then
                        curLine = lineByQuest[qid]
                    else
                        local title = Api.GetQuestTitle(qid) or tostring(qid)
                        curLine = {
                            id = qid,
                            key = qid,
                            name = title,
                            minlevel = minlevel,
                            quests = {},
                            questSet = {},
                            steps = {},
                        }
                        lines[#lines + 1] = curLine
                    end
                end

                if #leadIn > 0 then
                    for _, s in ipairs(leadIn) do
                        s.classLineKey = curLine.key
                        if s.minlevel and s.minlevel < curLine.minlevel then
                            curLine.minlevel = s.minlevel
                        end
                        curLine.steps[#curLine.steps + 1] = s
                    end
                    leadIn = {}
                end

                for _, id in ipairs(step.quests or {}) do
                    if not curLine.questSet[id] then
                        curLine.questSet[id] = true
                        curLine.quests[#curLine.quests + 1] = id
                        lineByQuest[id] = curLine
                    end
                end
                step.classLineKey = curLine.key
                curLine.steps[#curLine.steps + 1] = step
                if step.kind == "turnin" then
                    prevTurninNpc = step.npc
                end
            elseif curLine then
                step.classLineKey = curLine.key
                curLine.steps[#curLine.steps + 1] = step
            else
                leadIn[#leadIn + 1] = step
            end
        end
    end
    return lines
end

function BXP:IsClassLineHidden(line)
    if not (self.char and self.char.classHidden) then return false end
    local hidden = self.char.classHidden
    if hidden[line.key] or hidden[tostring(line.key)] or hidden[line.id] or hidden[tostring(line.id)] then
        return true
    end
    if #line.quests > 0 then
        local allHidden = true
        for _, qid in ipairs(line.quests) do
            if not hidden[qid] and not hidden[tostring(qid)] then
                allHidden = false
                break
            end
        end
        if allHidden then return true end
    end
    return false
end

function BXP:IsClassLineComplete(line)
    if not line or not line.quests or #line.quests == 0 then return true end
    local last = line.quests[#line.quests]
    if Api.IsQuestTurnedIn(last) then return true end
    local allDone = true
    for _, qid in ipairs(line.quests) do
        if not Api.IsQuestTurnedIn(qid) then
            allDone = false
            break
        end
    end
    if allDone then return true end
    if #line.steps > 0 then
        local allSat = true
        for _, s in ipairs(line.steps) do
            if not self:IsStepSatisfied(s) then
                allSat = false
                break
            end
        end
        if allSat then return true end
    end
    return false
end

function BXP:HideClassLine(line)
    self.char.classHidden = self.char.classHidden or {}
    self.char.classHidden[line.key] = true
    self.char.classHidden[tostring(line.key)] = true
    for _, qid in ipairs(line.quests or {}) do
        self.char.classHidden[qid] = true
        self.char.classHidden[tostring(qid)] = true
    end
    self:Refresh()
end

function BXP:UnhideClassLine(line)
    if not self.char.classHidden then return end
    self.char.classHidden[line.key] = nil
    self.char.classHidden[tostring(line.key)] = nil
    for _, qid in ipairs(line.quests or {}) do
        self.char.classHidden[qid] = nil
        self.char.classHidden[tostring(qid)] = nil
    end
    self:Refresh()
end

function BXP:AvailableClassLines(guide)
    local lines = self:ClassQuestLines(guide)
    local out = {}
    local level = Api.plain(UnitLevel("player")) or 1
    for _, l in ipairs(lines) do
        if level >= l.minlevel and not self:IsClassLineComplete(l) then
            out[#out + 1] = l
        end
    end
    return out
end

function BXP:FindClassLine(target, guide, preferHidden)
    if not target or target == "" then return nil end
    local avail = self:AvailableClassLines(guide)
    local all = self:ClassQuestLines(guide)
    local num = tonumber(target)
    if num then
        if preferHidden then
            if all[num] and self:IsClassLineHidden(all[num]) then return all[num], num end
            if avail[num] and self:IsClassLineHidden(avail[num]) then return avail[num], num end
        end
        if avail[num] then return avail[num], num end
        if all[num] then return all[num], num end
        for i, l in ipairs(avail) do
            if l.key == num or l.questSet[num] then return l, i end
        end
        for i, l in ipairs(all) do
            if l.key == num or l.questSet[num] then return l, i end
        end
        for i, l in ipairs(avail) do
            if l.minlevel == num then return l, i end
        end
        for i, l in ipairs(all) do
            if l.minlevel == num then return l, i end
        end
    end
    local lower = tostring(target):lower()
    for i, l in ipairs(avail) do
        if l.name:lower():find(lower, 1, true) then return l, i end
    end
    for i, l in ipairs(all) do
        if l.name:lower():find(lower, 1, true) then return l, i end
    end
    return nil
end

-- Class quests live in a side guide (side = true, classes = {...}) next to the main route:
-- its steps open with the player's level (minlevel), the window says when some are open,
-- and /boost class goes there and back.
function BXP:ClassGuide()
    local faction = Api.plain(UnitFactionGroup("player"))
    local race = Api.plain(select(2, UnitRace("player")))
    local class = Api.plain(select(2, UnitClass("player")))
    for _, g in ipairs(self.guideList) do
        if g.side and g.faction == faction and matches(g.races, race) and matches(g.classes, class) then return g end
    end
end

-- The class guide and its first open step, when the player is in another guide.
function BXP:ClassWorkAvailable()
    local g = self:ClassGuide()
    if not g or self.guide == g then return nil end
    local i = self:FindCurrent(g)
    if i then return g, g.steps[i] end
end

function BXP:AnnounceClassWork()
    local g, step = self:ClassWorkAvailable()
    local key = g and (g.id .. ":" .. step.key)
    if key and key ~= self.classAnnounced then
        self:Print("Class quests are available: " .. self:StepText(step) .. ". Click [C] on the guide window or type /boost class to view them.")
    end
    self.classAnnounced = key
end

function BXP:LeaveSideGuide(nothingOpen)
    local back = self.char.returnGuide
    self.char.returnGuide = nil
    if back and self.guides[back] and not self.guides[back].side then
        self:Print((nothingOpen and "No more class quests are available for now. " or "") .. "Back to " .. self.guides[back].name .. ".")
        return self:SetGuide(back)
    end
    return self:StartWherePlayerIs()
end

function BXP:ToggleClassGuide()
    if self.guide and self.guide.side then return self:LeaveSideGuide(false) end
    local g = self:ClassWorkAvailable()
    if not g then return self:Print("No class quests are available for your character right now.") end
    self.char.returnGuide = self.guide and self.guide.id
    self:SetGuide(g.id)
end

-- Quests in the log that skipped steps left behind: unfinished, with every hunting step of theirs behind the
-- pointer and none ahead. Without this the guide would say nothing about a quest the player still holds.
function BXP:PassedOverQuests()
    local out, guide = {}, self.guide
    if not guide or guide.side then return out end
    local skipped, open = {}, {}
    for i, step in ipairs(guide.steps) do
        if step.kind == "complete" and self:StepApplies(step) then
            for _, id in ipairs(self:LiveQuests(step)) do
                if not self:Ahead(guide, i) then
                    if not skipped[id] then skipped[id] = true; out[#out + 1] = id end
                else
                    open[id] = true
                end
            end
        end
    end
    local left = {}
    for _, id in ipairs(out) do
        if not open[id] and Api.IsQuestInLog(id) and not Api.IsQuestReady(id) then left[#left + 1] = id end
    end
    return left
end

-- The current step followed by up to count-1 later steps that still need doing: from the planned next one,
-- so a step the current pick skipped over is still listed.
function BXP:UpcomingSteps(count)
    local out = {}
    local guide, start, pick = self.guide, self.baseIndex, self.currentIndex
    if not guide or not start or not pick then return out end
    out[1] = guide.steps[pick]
    for i = start, #guide.steps do
        local step = guide.steps[i]
        if #out >= count then break end
        if i ~= pick and (i == start or (self:Ahead(guide, i) and (self:IsOpen(step) or self:OpensLater(step)))) then
            out[#out + 1] = step
        end
    end
    return out
end

-- Remember when steps finished (server time, level, XP) so routes can be tuned
-- against real play. Only forward progress counts; logins and skips back don't.
-- A character past a guide's levels (a level 22 opening the Durotar guide) ticks through
-- steps it did long ago: that's no measure of the route, so nothing is recorded.
function BXP:InGuideLevels(guide)
    return guide.levels == nil or Api.PlayerLevel() <= guide.levels[2] + 1
end

function BXP:RecordSplits(guide, from, to)
    if not from or (to and to <= from) or not self:InGuideLevels(guide) then return end
    local splits = self:CharTable("splits", guide.id)
    local now = GetServerTime()
    for i = from, (to or #guide.steps + 1) - 1 do
        local step = guide.steps[i]
        if not splits[step.key] and self:StepApplies(step) then
            splits[step.key] = { t = now, level = Api.PlayerLevel(), xp = Api.plain(UnitXP("player")), eta = step.eta,
                                 play = BoostedXPCharDB.playtime and BoostedXPCharDB.playtime[guide.id] }
        end
    end
end

-- Planned seconds from the start of the current step to the guide's top level (guide.reach is
-- the planner's route time plus the grinding it still needs). Nil for guides without one.
-- How far a hunting step has come, 0-1: each of its quests counts the same, by the share of its objectives
-- fulfilled (one ready or handed in is whole). Quests not in the log yet count as not started.
function BXP:StepProgress(step)
    if not step or step.kind ~= "complete" then return 0 end
    local sum, n = 0, 0
    for _, id in ipairs(self:LiveQuests(step)) do
        n = n + 1
        if self:HuntDone(step, id) then
            sum = sum + 1
        elseif Api.IsQuestInLog(id) then
            local have, need = 0, 0
            for _, o in ipairs((self:StepObjectives(step, id))) do
                local want = o.need > 0 and o.need or 1
                have, need = have + (o.finished and want or math.min(o.have, want)), need + want
            end
            sum = sum + (need > 0 and have / need or 0)
        end
    end
    return n > 0 and sum / n or 0
end

-- Planned seconds left to the guide's top level: from the step before the current one, plus as much of the
-- current hunting step as its objectives say is done, so it counts down with every kill and pickup.
function BXP:TimeRemaining()
    local guide, i = self.guide, self.baseIndex
    if not (guide and guide.reach and i) then return nil end
    local from = 0
    for j = i - 1, 1, -1 do
        if guide.steps[j].eta then
            from = guide.steps[j].eta
            break
        end
    end
    local step = guide.steps[i]
    if step.eta and step.eta > from then
        from = from + (step.eta - from) * self:StepProgress(step)
    end
    return math.max(0, guide.reach - from)
end

-- "3 hr 12 min" from an hour up, "54 min" under it.
function BXP.FormatDuration(seconds)
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 1 then return "under a minute" end
    if minutes < 60 then return minutes .. " min" end
    local hours, rest = math.floor(minutes / 60), minutes % 60
    return rest == 0 and (hours .. " hr") or (hours .. " hr " .. rest .. " min")
end

-- Seconds behind the planner's prediction (negative: ahead), from playing time: the last
-- split's lead or lag, or more once the current step runs past its predicted finish. Nil
-- for guides without predictions.
function BXP:Pace()
    local guide, step = self.guide, self:CurrentStep()
    local play = guide and BoostedXPCharDB.playtime and BoostedXPCharDB.playtime[guide.id]
    if not (play and step and step.eta) then return nil end
    local last
    for key, s in pairs(self:CharTable("splits", guide.id)) do
        if type(key) == "string" and s.eta and s.play and (not last or s.play > last.play) then last = s end
    end
    local over = play - step.eta
    return last and math.max(last.play - last.eta, over) or math.max(0, over)
end

-- handover: the guide before was finished and hands over to this one; the Next history goes on, so Back retraces into
-- it. Any other switch forgets the last guide's session state (a Back after the hand-over to Horde 10-15 had used
-- 1-10's step 118 as a 10-15 step, 2026-10-09).
function BXP:SetGuide(id, handover)
    local guide = self.guides[id]
    if not guide then return false end
    self.guide, self.currentIndex, self.baseIndex, self.viewIndex = guide, nil, nil, nil
    self.flexSkip = {}  -- flex picks set aside with Next, for this session
    self.flexHold = nil
    if not handover then self.history = {} end
    self.char.guide = id
    self:Refresh()
    return true
end

-- Drop a quest and, in turn, every quest whose accept step requires it.
function BXP:DropQuest(questID)
    local dropped = self:CharTable("dropped", self.guide.id)
    if dropped[questID] then return end
    dropped[questID] = true
    for _, step in ipairs(self.guide.steps) do
        if step.requires and tContains(step.requires, questID) then
            for _, id in ipairs(step.quests or {}) do self:DropQuest(id) end
        end
    end
end

-- Move on past the shown step without marking it done: Back shows it again. A step that came back because a
-- later quest needs it drops its quests instead. On a flex pick, Next sets the pick aside and shows the
-- planned step. While looking back at earlier steps (Back), Next steps forward until the guide is current.
-- Where each Next left from, newest last (this session only): Back retraces them, across guides too. A player may skip
-- ahead to see what's coming, into the next guide, and Back to where they were (the maintainer, 2026-10-09).
local HISTORY_MAX = 100

function BXP:NextStep()
    local guide, step = self.guide, self:CurrentStep()
    if not step then return end
    if not self.viewIndex then
        self.history = self.history or {}
        local h = self.history
        h[#h + 1] = { guide = guide.id, cursor = self:Cursor(guide), index = self.currentIndex, shown = step.key }
        if #h > HISTORY_MAX then table.remove(h, 1) end
    end
    self.flexHold = nil
    if self.viewIndex then
        local base = self.baseIndex or #guide.steps + 1
        local j = self.viewIndex + 1
        while j < base and not self:StepApplies(guide.steps[j]) do j = j + 1 end
        if j >= base then
            self.viewIndex = nil
        elseif self:NeedsDoing(guide.steps[j]) then
            self.viewIndex = nil
            self:SetCursor(guide, j)
        else
            self.viewIndex = j
        end
        return self:Refresh()
    end
    local returned = self:CharTable("returned", guide.id)
    if returned[step.key] then
        returned[step.key] = nil
        for _, id in ipairs(self:LiveQuests(step)) do
            if not Api.IsQuestTurnedIn(id) then self:DropQuest(id) end
        end
    elseif self.currentIndex ~= self.baseIndex then
        self.flexSkip[step.key] = true
    elseif self.currentIndex < self:Cursor(guide) then  -- a step that came back once its level was reached
        self:CharTable("waited", guide.id)[step.key] = nil
    else
        -- Steps the pointer passes that only wait for the player's level come back once it's reached: Encroachment's
        -- second half (from level 8) was passed by a Next on a later step and never shown (2026-10-09).
        local waited = self:CharTable("waited", guide.id)
        for j = self:Cursor(guide), self.currentIndex - 1 do
            local s = guide.steps[j]
            if (s.minlevel and self:WaitsForLevel(s)) or self:WaitsForItem(s) then waited[s.key] = true end
        end
        self:SetCursor(guide, self.currentIndex + 1)
    end
    self:Refresh()
end

-- Back one step. One that still needs doing becomes the current step again (the guide reads from it); one
-- that's done (turned in, gathered, finished) is only shown, crossed out, and progress stays where it is.
function BXP:PreviousStep()
    local guide = self.guide
    if not guide then return end
    -- Undo the last Next: the pointer back where it was, the step that was shown shown again, in its guide (a Next
    -- that finished a guide handed over to the next one). Steps done since stay done; one undone Next per Back
    -- (skipping Winds in the Desert at Rezlak, automation took Stormy Potential, and Back showed that one crossed out
    -- before reaching Winds, 2026-10-09). With nothing to undo, Back goes one step at a time.
    local entry = not self.viewIndex and self.history and table.remove(self.history)
    local back = entry and self.guides[entry.guide]
    if back then
        if back ~= guide then
            self.guide, self.char.guide, self.currentIndex, self.baseIndex = back, back.id, nil, nil
            self.flexSkip = {}
        end
        self.flexSkip[entry.shown] = nil
        self:SetCursor(back, entry.cursor)
        local shown = back.steps[entry.index]
        self.flexHold = shown and shown.key == entry.shown and entry.shown or nil
        return self:Refresh()
    end
    local from = self.currentIndex or self.baseIndex or #guide.steps + 1
    if not self.viewIndex and self.baseIndex and self.baseIndex < from then
        -- Showing a closer step (flex) ahead of the planned one: back goes before the planned step. From the pick it
        -- stopped at the planned step, a turn-in that wasn't ready, and flex picked the same step again: a player who
        -- had skipped Thwarting Kolkar Aggression's hunt by mistake couldn't get back to it (2026-10-09).
        from = self.baseIndex
    end
    for i = from - 1, 1, -1 do
        local step = guide.steps[i]
        if self:StepApplies(step) then
            if self:NeedsDoing(step) then
                self.viewIndex = nil
                self:SetCursor(guide, i)
                self.flexSkip = {}
                self.flexHold = step.key  -- shown even if flex knows a closer step
            else
                self.viewIndex = i
            end
            break
        end
    end
    self:Refresh()
end

-- The step the arrow and map pin point at: the one to do, not an earlier done step being looked at.
function BXP:TargetStep()
    if self:ViewingDone() then return self.guide and self.goIndex and self.guide.steps[self.goIndex] end
    return self:CurrentStep()
end

-- Whether the shown step is an earlier one that's already done (shown crossed out).
function BXP:ViewingDone()
    return self.viewIndex ~= nil and self.currentIndex == self.viewIndex
end

function BXP:ResetGuide()
    if not self.guide then return end
    for _, name in ipairs({ "done", "returned", "waited", "dropped", "splits", "cursor" }) do self.char[name][self.guide.id] = nil end
    self.currentIndex, self.baseIndex, self.viewIndex = nil, nil, nil
    self:Refresh()
end

-- Where this character stands in the guides: each guide of its faction and race scores
-- for fitting its level, for its quests in the log right now (the strongest sign of where
-- the player is), for how much of it is done already, and for being in its zone. Returns
-- the best guide and the step after the last one done there, or nil.
function BXP:FindPlace()
    local faction = Api.plain(UnitFactionGroup("player"))
    local race = Api.plain(select(2, UnitRace("player")))
    local level = Api.PlayerLevel()
    local zones = {}
    local mapID = Api.plain(C_Map.GetBestMapForUnit("player"))
    for _ = 1, 3 do  -- the player's map and the maps it sits in (Orgrimmar counts for Durotar)
        local info = mapID and C_Map.GetMapInfo(mapID)
        if not info then break end
        zones[info.name] = true
        mapID = info.parentMapID
    end
    local best
    for _, g in ipairs(self.guideList) do
        if not g.side and g.faction == faction and matches(g.races, race) and not self:MovedOnFrom(g) then
            -- Start after the step that best splits done from not done (the highest running
            -- count of done minus open quest steps), not after the last done step: a quest
            -- done long before the route gets to it would skip everything in between.
            local total, done, inLog, seen, balance, top, at = 0, 0, 0, {}, 0, 0, 1
            local working  -- the first step that hunts or hands in a quest in the log
            for i, step in ipairs(g.steps) do
                -- buying or looting a held quest's item comes before its hunt
                if not working and step.quest and Api.IsQuestInLog(step.quest) and self:StepApplies(step)
                        and self:NeedsDoing(step) then
                    working = i
                end
                if QUEST_KINDS[step.kind] and self:StepApplies(step) then
                    total = total + 1
                    local satisfied = self:IsStepSatisfied(step)
                    if satisfied then
                        done, balance = done + 1, balance + 1
                        if balance > top then top, at = balance, i + 1 end
                    else
                        balance = balance - 1
                    end
                    for _, id in ipairs(step.quests) do
                        local held = Api.IsQuestInLog(id)
                        if not seen[id] and held then seen[id], inLog = true, inLog + 1 end
                        if held and not working and not satisfied and step.kind ~= "accept" then working = i end
                    end
                end
            end
            -- Never before the work on the quests in the log: a Skyborne at Sentinel Hill with Goretusk Liver Pie and
            -- Patrolling Westfall (step 80 of Alliance 10-15) who had skipped the Stormwind and Elwynn steps before
            -- it had far more steps open than done, so the split stayed at step 1 (2026-10-10).
            if working and working > at then at = working end
            local fits = level >= g.levels[1] - 1 and level <= g.levels[2]
            local finished = total > 0 and done == total
            if (fits or inLog > 0) and not (finished and inLog == 0) then
                local score = (fits and 10 or 0) + 3 * inLog + (zones[g.zone] and 5 or 0) + 5 * done / math.max(total, 1)
                if not best or score > best.score then best = { id = g.id, at = at, score = score } end
            end
        end
    end
    if best then return best.id, best.at end
end

-- Whether the character has moved on from a guide to the one after it: at that guide's level, with one of its own
-- quests (not one the two share) done or in the log. Quests skipped in the earlier guide don't hold the character
-- there: a level 12 Skyborne at step 14 of Alliance 10-15, who had passed over the Strange Hermit's quests, was sent
-- back to Zephras Isle by guide current (2026-10-10).
function BXP:MovedOnFrom(g)
    local n = g.next and self.guides[g.next]
    if not n or Api.PlayerLevel() < n.levels[1] - 1 then return false end
    local own = {}
    for _, step in ipairs(g.steps) do
        for _, id in ipairs(step.quests or {}) do own[id] = true end
    end
    for _, step in ipairs(n.steps) do
        if QUEST_KINDS[step.kind] and self:StepApplies(step) then
            for _, id in ipairs(step.quests) do
                if not own[id] and (Api.IsQuestInLog(id) or Api.IsQuestTurnedIn(id)) then return true end
            end
        end
    end
    return false
end

-- Start the character where it stands: the guide FindPlace picks, read from its spot (skipped quests come
-- back if a later one needs them). Earlier marks of that guide are cleared first, so running it again
-- re-places the character. Records no splits: this is catching up, not playing the route.
function BXP:StartWherePlayerIs()
    local id, at = self:FindPlace()
    if not id then return nil end
    local guide = self.guides[id]
    -- Steps before the spot are behind the pointer: skipped, not done. Hunts and turn-ins of quests passed
    -- over there skip themselves (nothing ahead takes them).
    self.char.done[id], self.char.returned[id], self.char.waited[id] = nil, nil, nil
    self:SetCursor(guide, math.min(at, #guide.steps + 1))
    self:SetGuide(id)
    local step = self:CurrentStep()
    self:Print(("Starting %s at step %d%s."):format(guide.name, self.baseIndex or #guide.steps,
        step and (": " .. self:StepText(step)) or ""))
    return id
end

-- Step text ---------------------------------------------------------------------

local VERB = { accept = "Accept", turnin = "Turn in", complete = "Complete" }
local NPC_JOIN = { accept = " from ", turnin = " to " }

-- The step's quests still to do for its kind: a hunt leaves out quests ready or handed in, a turn-in those
-- handed in, an accept those already taken. Title and details name only these, so a quest finished earlier
-- (The Great Outdoors, done at Brakk's campfire right after The Adventurer) isn't asked for again. When all
-- are done (a step looked back at, crossed out) it names them all.
function BXP:OpenQuests(step)
    local live, out = self:LiveQuests(step), {}
    for _, id in ipairs(live) do
        local done
        if step.kind == "complete" then
            done = self:HuntDone(step, id)
        elseif step.kind == "turnin" then
            done = Api.IsQuestTurnedIn(id)
        else
            done = Api.IsQuestInLog(id) or Api.IsQuestTurnedIn(id)
        end
        if not done then out[#out + 1] = id end
    end
    return #out > 0 and out or live
end

local function questNames(step)
    local names = {}
    for _, id in ipairs(BXP:OpenQuests(step)) do
        names[#names + 1] = "|cffffd100" .. (Api.GetQuestTitle(id) or ("quest " .. id)) .. "|r"
    end
    return table.concat(names, ", ")
end

function BXP:StepText(step)
    local k, s = step.kind, nil
    if k == "complete" and step.dungeon and #step.quests > 2 then
        local d = self.DungeonsByKey[step.dungeon]
        s = ("Do %s (%d quests)"):format(d and d.name or step.dungeon, #step.quests)
    elseif k == "accept" and step.fromitem then
        s = "Start " .. questNames(step) .. " from your bags"
    elseif QUEST_KINDS[k] then
        s = VERB[k] .. " " .. questNames(step)
        if step.npc and NPC_JOIN[k] then s = s .. NPC_JOIN[k] .. step.npc end
    elseif k == "go" then s = "Go to " .. step.go
    elseif k == "level" then s = "Grind to level " .. step.level
    elseif k == "sethome" then s = "Set your hearthstone at " .. step.sethome
    elseif k == "flightpath" then s = "Get the flight path at " .. step.flightpath
    elseif k == "fly" then s = "Fly to " .. step.fly
    elseif k == "hearth" then
        s = "Hearth to " .. step.hearth
        local bound = Api.plain(GetBindLocation())
        if bound and bound ~= "" and bound:lower() ~= (step.hearth or ""):lower() then
            s = s .. " (bound to " .. bound .. ")"
        end
    elseif k == "die" then s = "Die on purpose"
    elseif k == "train" then s = step.train == true and "Visit your class trainer" or step.train
    elseif k == "vendor" then
        s = "Buy " .. ((step.count or 1) > 1 and (step.count .. " ") or "") .. step.vendor
        if step.npc then s = s .. " from " .. step.npc end
    elseif k == "loot" then
        if step.open and step.npc then s = "Loot " .. step.loot .. " from " .. step.npc  -- a chest, a sack
        else s = step.npc and ("Kill " .. step.npc .. " and loot " .. step.loot) or ("Get " .. step.loot) end
    else s = step[k] end
    if step.dungeon then s = "|cff66ccff[" .. step.dungeon .. "]|r " .. s end
    return s
end

-- A complete step's live objectives, once every quest is in the log (or ready), say
-- the same as its planned text, so the text is left out.
local function liveObjectives(step)
    if step.kind ~= "complete" then return false end
    for _, id in ipairs(BXP:LiveQuests(step)) do
        if not (Api.IsQuestTurnedIn(id) or Api.IsQuestReady(id) or (Api.IsQuestInLog(id) and #Api.GetObjectives(id) > 0)) then
            return false
        end
    end
    return true
end

-- Extra lines under a step: its note and hint, then live objectives for complete steps.
-- Quests in the log, not finished, that a later hunting step works in a pocket near the player: worked now, wherever
-- the player hunted (2026-10-11: Cutting Teeth hunted among the northern boars, 4 of 6 Wayward Weapons picked up,
-- and the walk back passed more while the guide only spoke of Zureetha). Not the step's own quests, nor a step still
-- waiting for the player's level (Practical Prey's level 7-8 tigers listed to a level 5, who died, 2026-10-11).
function BXP:NearbyQuests(step)
    local guide, out = self.guide, {}
    if not guide or not step.index then return out end
    local own, open = {}, {}
    for _, id in ipairs(self:LiveQuests(step)) do own[id] = true end
    local any = false
    for i = step.index + 1, #guide.steps do
        local later = guide.steps[i]
        if later.complete and later.areas and not self:WaitsForLevel(later) then
            for _, area in ipairs(later.areas) do
                local id = area.q
                if id and not own[id] and open[id] == nil then
                    open[id] = Api.IsQuestInLog(id) and not Api.IsQuestReady(id)
                    any = any or open[id]
                end
            end
        end
    end
    if not any then return out end
    local seen = {}
    for i = step.index + 1, #guide.steps do
        local later = guide.steps[i]
        if later.complete and later.areas and not self:WaitsForLevel(later) then
            for _, area in ipairs(later.areas) do
                local id = area.q
                if id and open[id] and not seen[id] then
                    local mapID = Zones.Resolve(area.zone or later.zone or guide.zone)
                    local d = mapID and self:OffsetTo(mapID, area[1] / 100, area[2] / 100)
                    if d and d <= area.r + NEARBY then
                        seen[id] = true
                        out[#out + 1] = id
                    end
                end
            end
        end
    end
    return out
end

-- Quests in the log whose hunting step the guide passed over because it waits for the player's level, with that
-- level: still mentioned while the guide is on later steps (2026-10-11: Sarkoth, from level 3, taken at level 2 and then
-- not mentioned anywhere until the level came). The step itself comes back once the level is reached.
function BXP:WaitingQuests(step)
    local guide, out, levels = self.guide, {}, {}
    if not guide or not step.index then return out, levels end
    local own = {}
    for _, id in ipairs(self:LiveQuests(step)) do own[id] = true end
    for i = 1, step.index - 1 do
        local s = guide.steps[i]
        if s.complete and s.minlevel and self:WaitsForLevel(s) then
            for _, id in ipairs(self:LiveQuests(s)) do
                if not own[id] and not levels[id] and Api.IsQuestInLog(id) and not Api.IsQuestReady(id) then
                    out[#out + 1], levels[id] = id, s.minlevel
                end
            end
        end
    end
    return out, levels
end

function BXP:StepDetails(step)
    local lines = {}
    local missing = self.notOffered[step.key]
    if missing then
        local titles = {}
        for _, id in ipairs(missing) do titles[#titles + 1] = Api.GetQuestTitle(id) or tostring(id) end
        lines[#lines + 1] = ("|cffff9900%s doesn't offer %s to you yet.|r |cff808080Click > to skip it.|r"):format(
            step.npc or "The NPC", table.concat(titles, ", "))
    end
    if step.text and not liveObjectives(step) then lines[#lines + 1] = step.text end
    -- The step's own objectives come first, right under it: after the "On the way" list they read as that quest's
    -- (Vanquish the Betrayers' Kul Tiras sailors showed up under For Honor's raider gear).
    if step.kind == "complete" then
        -- Several quests in one step share a hunting area: list each one the player has, with its objectives.
        local held, missing, live = {}, {}, self:LiveQuests(step)
        for _, id in ipairs(live) do
            if Api.IsQuestInLog(id) then
                held[#held + 1] = id
            elseif not Api.IsQuestTurnedIn(id) then
                missing[#missing + 1] = Api.GetQuestTitle(id) or tostring(id)
            end
        end
        local several = #held + #missing > 1  -- handed-in quests are out of it
        if several and not step.dungeon then lines[#lines + 1] = "|cff66ccffAll in the same area: work on them together.|r" end
        for _, id in ipairs(held) do
            local ready = self:HuntDone(step, id)
            if several then
                local title = Api.GetQuestTitle(id) or tostring(id)
                lines[#lines + 1] = ready and ("|cff808080" .. title .. " (done)|r") or ("|cffffd100" .. title .. "|r")
            end
            if not (several and ready) then
                for _, o in ipairs((self:StepObjectives(step, id))) do
                    local color = o.finished and "|cff808080" or "|cffffffff"
                    lines[#lines + 1] = color .. "- " .. o.text .. "|r"
                end
            end
        end
        if #missing == 1 and not several then
            lines[#lines + 1] = "|cffff6060" .. missing[1] .. " is not in your quest log.|r"
        elseif #missing > 0 then  -- one quiet line for the quests this player doesn't have
            lines[#lines + 1] = "|cff808080Not in your log: " .. table.concat(missing, ", ") .. "|r"
        end
    end
    local alsoShown = {}
    do
        -- Quests to work on along the way: once they're in the log, show their live objectives; and the quests in
        -- the log whose later hunts lie around the player now.
        local tracked, any = {}, false
        for _, id in ipairs(step.onway or {}) do
            if Api.IsQuestInLog(id) then
                any = true
                if not Api.IsQuestReady(id) then tracked[#tracked + 1] = id; alsoShown[id] = true end
            end
        end
        if step.hint and not any and not step.onway then
            -- The planned "On the way, ..." text assumes those quests are in the log: without them (an accept
            -- still waiting for your level) it would send you after objectives you can't get yet.
            lines[#lines + 1] = "|cff66ccff" .. step.hint .. "|r"
        end
        local waiting, levels = self:WaitingQuests(step)
        for _, id in ipairs(waiting) do
            if not alsoShown[id] then tracked[#tracked + 1] = id; alsoShown[id] = true end
        end
        for _, id in ipairs(self:NearbyQuests(step)) do
            if not alsoShown[id] then tracked[#tracked + 1] = id; alsoShown[id] = true end
        end
        -- Mobs here that drop a quest's starting item: until the quest is taken.
        local drops = {}
        for id, text in pairs(step.drops or {}) do
            if not Api.IsQuestInLog(id) and not Api.IsQuestTurnedIn(id) and not self:IsDropped(id) then
                drops[#drops + 1] = { id = id, text = text }
            end
        end
        table.sort(drops, function(a, b) return a.id < b.id end)
        if #tracked > 0 or #drops > 0 then
            lines[#lines + 1] = "|cff66ccffAlso work on:|r"
            for _, d in ipairs(drops) do lines[#lines + 1] = "|cffffd100" .. d.text .. "|r" end
            for _, id in ipairs(tracked) do
                local note = levels[id] and ("|cff808080 (level " .. levels[id] .. ")|r") or ""
                lines[#lines + 1] = "|cffffd100" .. (Api.GetQuestTitle(id) or tostring(id)) .. "|r" .. note
                for _, o in ipairs(Api.GetObjectives(id)) do
                    lines[#lines + 1] = (o.finished and "|cff808080" or "|cffffffff") .. "- " .. o.text .. "|r"
                end
            end
        end
    end
    if step.verify then lines[#lines + 1] = "|cffff9900Not yet checked in Forever; the location may be off.|r" end
    if self.guide and self:CharTable("returned", self.guide.id)[step.key] then
        lines[#lines + 1] = "|cff66ccffBack because a later quest needs it. Skip it again to drop both.|r"
    end
    if step.kind ~= "complete" then
        -- Quests in the log that an upcoming hunting step finishes keep showing their progress,
        -- whatever the current step is (a turn-in on the way, an escort): live objectives.
        local shown = {}
        for _, id in ipairs(step.onway or {}) do shown[id] = true end
        for id in pairs(alsoShown) do shown[id] = true end
        local lead = true
        for _, next in ipairs(self:UpcomingSteps(IN_PROGRESS_AHEAD)) do
            if next ~= step and next.kind == "complete" then
                for _, id in ipairs(self:LiveQuests(next)) do
                    if not shown[id] and Api.IsQuestInLog(id) and not Api.IsQuestReady(id) then
                        shown[id] = true
                        if lead then lines[#lines + 1] = "|cff66ccffIn progress:|r"; lead = false end
                        lines[#lines + 1] = "|cffffd100" .. (Api.GetQuestTitle(id) or tostring(id)) .. "|r"
                        for _, o in ipairs(Api.GetObjectives(id)) do
                            lines[#lines + 1] = (o.finished and "|cff808080" or "|cffffffff") .. "- " .. o.text .. "|r"
                        end
                    end
                end
            end
        end
    end
    if step.kind == "accept" then
        for _, id in ipairs(step.requires or {}) do
            if not Api.IsQuestTurnedIn(id) then
                lines[#lines + 1] = "|cffff6060Needs " .. (Api.GetQuestTitle(id) or id) .. " turned in first.|r"
            end
        end
    end
    if step.kind == "turnin" then
        for _, id in ipairs(self:LiveQuests(step)) do
            if not Api.IsQuestInLog(id) and not Api.IsQuestTurnedIn(id) then
                lines[#lines + 1] = "|cffff6060" .. (Api.GetQuestTitle(id) or id) .. " is not in your quest log: skipped.|r"
            end
        end
    end
    return lines
end

-- Events --------------------------------------------------------------------------

local pending = false
local function queueRefresh()
    if pending then return end
    pending = true
    C_Timer.After(0.1, function()
        pending = false
        BXP:Refresh()
    end)
end
BXP.QueueRefresh = queueRefresh

for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED",
        "PLAYER_LEVEL_UP", "ZONE_CHANGED_NEW_AREA" }) do
    BXP:On(event, queueRefresh)
end

-- Talking to a flight master learns its flight path.
BXP:On("TAXIMAP_OPENED", function()
    local step = BXP:CurrentStep()
    if step and step.kind == "flightpath" then BXP:NextStep() end
end)

-- Coming back from a ghost (spirit healer or corpse) finishes a death skip.
-- Back from the spirit healer finishes the die step the guide is on (the planned one, even while looking back at an
-- earlier step): marked done, so Back over it later shows it crossed out like any finished step. It used to only
-- move past it, and going Back made it the step to do again (the maintainer, 2026-10-09).
BXP:On("PLAYER_UNGHOST", function()
    BoostedXPCharDB.unghostAt = GetServerTime()  -- for a die step that comes up after it (check.die)
    local guide = BXP.guide
    local step = guide and BXP.baseIndex and guide.steps[BXP.baseIndex]
    if step and step.kind == "die" then
        BXP:DoneTable(guide.id)[step.key] = true
        BXP:Refresh()
    end
end)

BXP:On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
    if unit ~= "player" or Api.plain(spellID) ~= HEARTHSTONE then return end
    local step = BXP:CurrentStep()
    if step and (step.kind == "hearth" or step.hearth) then
        local bound = Api.plain(GetBindLocation())
        if bound and bound ~= "" and step.hearth and bound:lower() ~= step.hearth:lower() then
            BXP:Print(("Hearthstone is bound to %s, not %s. Guide step kept."):format(bound, step.hearth))
            return
        end
        BXP:NextStep()
    end
end)

-- Training steps finish at a class trainer: when a spell is learned there, or its window closes. Every open
-- training step up to your level counts (training early finishes the step before the guide gets there; each
-- carries its level as minlevel). A profession trainer (cooking in Razor Hill) doesn't count.
function BXP:FinishTraining()
    local guide = self.guide
    if not guide then return end
    local done, any = self:DoneTable(guide.id), false
    for i = self:Cursor(guide), #guide.steps do
        local step = guide.steps[i]
        if step.kind == "train" and done[step.key] ~= true and self:StepApplies(step) then
            done[step.key], any = true, true
        end
    end
    if any then self:Refresh() end
end

-- Spells waiting at the trainer: the route plans a training step where it predicts your level, so ahead of it
-- (a warrior at Razor Hill at 6, the route said 5) nothing would say so. Near your class's trainer (your side's:
-- BXP.Trainers, from tools/bxp trainers) with spells waiting, the window says so. The level you trained at is kept
-- (char.trainedLevel); a save from before counts its finished training steps.
local TRAINER_NEAR = 60  -- yards

function BXP:TrainedLevel()
    if self.char.trainedLevel then return self.char.trainedLevel end
    local best = 1
    if self.guide then
        local done = self:DoneTable(self.guide.id)
        for _, step in ipairs(self.guide.steps) do
            if step.kind == "train" and done[step.key] == true and (step.minlevel or 0) > best then best = step.minlevel end
        end
    end
    return best
end

-- The training level waiting (your even level, if you haven't trained at it), or nil.
function BXP:SpellsWaiting()
    local level = Api.PlayerLevel()
    local waiting = level - level % 2
    if waiting >= 2 and waiting > self:TrainedLevel() then return waiting end
end

-- Your class's trainer within TRAINER_NEAR yards: only your side's trainers (and neutral ones), never the other's.
function BXP:NearbyTrainer()
    local side = Api.plain(UnitFactionGroup("player"))
    local class = Api.plain(select(2, UnitClass("player")))
    local list = self.Trainers and self.Trainers[side] and self.Trainers[side][class]
    local best, nearest
    for _, t in ipairs(list or {}) do
        local d = self:DistanceTo(t.map, t.x / 100, t.y / 100)
        if d and d <= TRAINER_NEAR and (not nearest or d < nearest) then best, nearest = t, d end
    end
    return best
end

-- The reminder line, or nil: spells waiting and the trainer right here.
function BXP:TrainReminder()
    local waiting = self:SpellsWaiting()
    local trainer = waiting and self:NearbyTrainer()
    if trainer then
        return ("Train now: your level %d spells are waiting, and %s is right here."):format(waiting, trainer.name), waiting
    end
end

local atClassTrainer = false
local function trained()
    if not atClassTrainer then return end
    BXP.char.trainedLevel = math.max(BXP.char.trainedLevel or 1, Api.PlayerLevel())
    BXP:FinishTraining()
    BXP:Fire("BXP_REFRESH")
end
BXP:OnValid("TRAINER_SHOW", function()
    atClassTrainer = not (IsTradeskillTrainer and IsTradeskillTrainer())
end)
BXP:OnValid("TRAINER_CLOSED", function()
    trained()
    atClassTrainer = false
end)
BXP:OnValid("LEARNED_SPELL_IN_TAB", trained)
BXP:OnValid("LEARNED_SPELL_IN_SKILL_LINE", trained)

BXP:On("BXP_READY", function()
    local id = BXP.char.guide
    if id and BXP.guides[id] then
        BXP:SetGuide(id)
    elseif not BXP:StartWherePlayerIs() then  -- first load: start where the character stands
        BXP:Print("No guide covers your character yet. Type /boost list to see the available guides.")
        return
    end
    -- The trainer reminder follows where you stand: a chat note once per level, and the window line.
    local reminded
    C_Timer.NewTicker(2, function()
        local text, level = BXP:TrainReminder()
        if text and reminded ~= level then BXP:Print(text) end
        if (text ~= nil) ~= (BXP.trainShown == true) then BXP:Fire("BXP_REFRESH") end
        BXP.trainShown = text ~= nil
        if text then reminded = level end
    end)
    -- "Also work on" follows the player: redraw when the quests worked around them change.
    local nearby
    C_Timer.NewTicker(1, function()
        local step = BXP:CurrentStep()
        local now = step and table.concat(BXP:NearbyQuests(step), ",") or ""
        if nearby ~= nil and now ~= nearby then BXP:Fire("BXP_REFRESH") end
        nearby = now
    end)
    -- Position-based steps (go, sethome, fly, level) are polled for the current step only.
    C_Timer.NewTicker(0.5, function()
        local step = BXP:CurrentStep()
        if step and not QUEST_KINDS[step.kind] and BXP:DoneTable(BXP.guide.id)[step.key] == nil
                and BXP:IsStepSatisfied(step) then
            BXP:Refresh()
        end
    end)
end)
