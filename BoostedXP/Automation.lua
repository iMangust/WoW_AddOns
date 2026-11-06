-- Quest automation: accepts and turns in the guide's quests at NPCs. Only quests in the
-- next few steps count, so a route can hold a turn-in for later on purpose.
-- Hold Shift while talking to an NPC to do it by hand.
local _, BXP = ...
local Api = BXP.Api

local LOOKAHEAD = 8

-- The upcoming step of this kind that lists questID, if any.
local function wantedStep(questID, kind)
    questID = Api.plain(questID)
    local guide, start = BXP.guide, BXP.baseIndex
    if not guide or not start or not questID then return nil end
    local seen = 0
    for i = start, #guide.steps do
        local step = guide.steps[i]
        if BXP:Ahead(guide, i) and BXP:IsOpen(step) then
            if step.kind == kind then
                for _, id in ipairs(BXP:LiveQuests(step)) do
                    if Api.plain(id) == questID then return step end
                end
            end
            seen = seen + 1
            if seen >= LOOKAHEAD then break end
        end
    end
end
BXP.WantedStep = wantedStep

local function enabled(option)
    local auto = BXP.db and BXP.db.automation
    return auto and auto.enabled and auto[option] and not IsShiftKeyDown()
end

BXP:On("GOSSIP_SHOW", function()
    if not enabled("gossip") then return end
    for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
        local qid = Api.plain(q.questID)
        if q.isComplete and wantedStep(qid, "turnin") then
            return C_GossipInfo.SelectActiveQuest(qid)
        end
    end
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
        local qid = Api.plain(q.questID)
        if wantedStep(qid, "accept") then
            return C_GossipInfo.SelectAvailableQuest(qid)
        end
    end
end)

-- Older-style NPCs that list quests without a gossip menu.
BXP:On("QUEST_GREETING", function()
    if not enabled("gossip") then return end
    for i = 1, GetNumActiveQuests() do
        local _, isComplete = GetActiveTitle(i)
        if isComplete and wantedStep(Api.plain(GetActiveQuestID(i)), "turnin") then
            return SelectActiveQuest(i)
        end
    end
    for i = 1, GetNumAvailableQuests() do
        local questID = select(5, GetAvailableQuestInfo(i))
        if wantedStep(Api.plain(questID), "accept") then
            return SelectAvailableQuest(i)
        end
    end
end)

BXP:On("QUEST_DETAIL", function()
    if enabled("accept") and wantedStep(Api.plain(GetQuestID()), "accept") then AcceptQuest() end
end)

BXP:On("QUEST_PROGRESS", function()
    if enabled("turnin") and IsQuestCompletable() and wantedStep(Api.plain(GetQuestID()), "turnin") then
        CompleteQuest()
    end
end)

BXP:On("QUEST_COMPLETE", function()
    if not enabled("turnin") then return end
    local step = wantedStep(Api.plain(GetQuestID()), "turnin")
    if not step then return end
    local choices = GetNumQuestChoices()
    if choices <= 1 then
        GetQuestReward(choices)
    elseif step.reward then
        GetQuestReward(step.reward)
    else
        BXP:Print("Pick your quest reward.")
    end
end)

-- Not offered: the NPC the current step sends you to is talking to you and doesn't offer the step's quest (a
-- prerequisite the route missed, a level it needs). This runs with automation off too. The step says so, and
-- the export reports it (BoostedXPCharDB.notOffered), so routes get fixed without anyone typing a note.
local MAX_NOT_OFFERED = 50
BXP.notOffered = {}  -- step key -> quest IDs not offered, this session

-- A step set aside for not being offered comes back when its NPC offers the quest after all (or the quest is had),
-- even if the window is on another step by then.
local function reconsider(offered)
    for key, missing in pairs(BXP.notOffered) do
        local back = true
        for _, id in ipairs(missing) do
            if not (offered[id] or Api.IsQuestInLog(id) or Api.IsQuestTurnedIn(id)) then back = false end
        end
        if back then
            BXP.notOffered[key], BXP.flexSkip[key] = nil, nil
            BXP:Refresh()
        end
    end
end

local function checkOffered(offered)
    reconsider(offered)
    local guide, step = BXP.guide, BXP:CurrentStep()
    if not (guide and step and step.kind == "accept" and step.npc) or Api.NpcName() ~= step.npc then return end
    local missing = {}
    for _, id in ipairs(BXP:LiveQuests(step)) do
        if not offered[id] and not Api.IsQuestInLog(id) and not Api.IsQuestTurnedIn(id) then
            missing[#missing + 1] = id
        end
    end
    if #missing == 0 then return end  -- offered (reconsider took the warning off)
    local list = BoostedXPCharDB.notOffered or {}
    BoostedXPCharDB.notOffered = list
    local ids = {}
    for id in pairs(offered) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(missing) do
        local entry
        for _, e in ipairs(list) do
            if e.guide == guide.id and e.quest == id then entry = e end
        end
        if not entry then
            entry = { guide = guide.id, quest = id, count = 0 }
            list[#list + 1] = entry
        end
        entry.t, entry.level, entry.step, entry.index = GetServerTime(), Api.PlayerLevel(), step.key, BXP.currentIndex
        entry.npc, entry.offered, entry.count = step.npc, ids, entry.count + 1
    end
    while #list > MAX_NOT_OFFERED do table.remove(list, 1) end
    if not BXP.notOffered[step.key] then
        local titles = {}
        for _, id in ipairs(missing) do titles[#titles + 1] = Api.GetQuestTitle(id) or tostring(id) end
        BXP:Print(("%s doesn't offer %s to you yet. Click > (Next) to skip it; it's reported with your next "
            .. "/boost export."):format(step.npc, table.concat(titles, ", ")))
    end
    BXP.notOffered[step.key] = missing
    BXP.flexSkip[step.key] = true  -- flex moves on to the next quest step it can do (it comes back, see reconsider)
    BXP:Refresh()
end

local function gossipOffered()
    local offered = {}
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
        local id = Api.plain(q.questID)
        if id then offered[id] = true end
    end
    return offered
end

local function greetingOffered()
    local offered = {}
    for i = 1, GetNumAvailableQuests() do
        local id = Api.plain(select(5, GetAvailableQuestInfo(i)))
        if id then offered[id] = true end
    end
    return offered
end

-- The window is judged a moment after it opens, from what it offers then. Read at once it is often wrong: after an
-- accept it opens again before the quest log has the quest (an export, 2026-10-12: Plainstrider Menace "not
-- offered" in the same second as it was taken), and after a hand-in it can still show the list from before (four more,
-- taken a second after the hand-in). By then the accept has moved the guide on, or the window has the quest.
local SETTLE = 1  -- seconds
local judging = {}  -- step key -> true while a look is pending

local function judgeLater(read)
    local step = BXP:CurrentStep()
    local here = step and step.kind == "accept" and step.npc
    if not (here or next(BXP.notOffered)) then return end
    local key = here and step.key or "*"
    if judging[key] then return end
    judging[key] = true
    C_Timer.After(SETTLE, function()
        judging[key] = nil
        checkOffered(read())
    end)
end

BXP:On("GOSSIP_SHOW", function() judgeLater(gossipOffered) end)
BXP:On("QUEST_GREETING", function() judgeLater(greetingOffered) end)

local function forgetNotOffered(questID)
    local list = BoostedXPCharDB and BoostedXPCharDB.notOffered
    if not (list and questID) then return end
    for i = #list, 1, -1 do
        if list[i].quest == questID then
            table.remove(list, i)
        end
    end
    if #list == 0 then
        BoostedXPCharDB.notOffered = nil
    end
end

BXP:On("QUEST_ACCEPTED", function(_, a, b)
    local id = Api.plain(b) or Api.plain(a)
    if id then
        forgetNotOffered(id)
        reconsider({})
    end
end)

BXP:On("QUEST_TURNED_IN", function(_, questID)
    local id = Api.plain(questID)
    if id then
        forgetNotOffered(id)
        reconsider({})
    end
end)
