-- BoostedXP: a free step-by-step leveling guide for WoW Forever.
-- Core: shared namespace, saved variables and a small event/message bus.
local addonName, BXP = ...
_G.BoostedXP = BXP

BXP.name = addonName

local DEFAULTS = {
    automation = { enabled = true, accept = true, turnin = true, gossip = true },
    dungeons = {},  -- [dungeonKey] = false when the player turned that dungeon off; dungeons are on by default
    -- noDungeons: true when /boost dungeons off turned all of them off
    window = { shown = true, scale = 1, fontSize = 15, opacity = 0.8, locked = false },  -- opacity: the background, 0-1
    arrow = { shown = true, scale = 1 },
    pinMode = "travel",  -- the map pin: "travel" (steps the game doesn't mark itself), "all" or "off"
    remindExport = true,  -- a chat line asking for /boost export at levels 5 and 10, then every level (/boost remind)
    announce = { party = true, say = true, yell = false },  -- level-up announcements (Announce.lua, /boost announce)
    flex = true,    -- suggest a clearly closer step the player can do now (/boost flex off for the planned order)
    zones = {},     -- zone name -> uiMapID learned from the player's real position
}

local CHAR_DEFAULTS = {
    guide = nil,    -- id of the active guide
    done = {},      -- done[guideId][stepKey] = true: a step other than a quest step finished (check or event)
    cursor = {},    -- cursor[guideId] = { key, index }: the step the guide reads from (Next and Back move it)
    trainedLevel = nil,  -- the level last trained at a class trainer (the trainer reminder)
    flights = {},   -- flights[taxi node name] = true: flight paths the taxi map has shown (Flight.lua's hints)
    returned = {},  -- returned[guideId][stepKey]: skipped step brought back for a later quest
    waited = {},    -- waited[guideId][stepKey]: a step Next passed while it waited for the player's level
    dropped = {},   -- dropped[guideId][questID]: quests the player chose not to do
    splits = {},    -- splits[guideId][stepKey] = { t, level, xp } when the step finished
    classHidden = {}, -- classHidden[key] = true: class quest lines the player chose to skip/hide
}

-- Copy missing keys from defaults into saved, recursing into tables.
local function applyDefaults(saved, defaults)
    for k, v in pairs(defaults) do
        if saved[k] == nil then
            saved[k] = type(v) == "table" and applyDefaults({}, v) or v
        elseif type(v) == "table" and type(saved[k]) == "table" then
            applyDefaults(saved[k], v)
        end
    end
    return saved
end

-- Handlers for WoW events and internal messages share one table; internal message
-- names start with "BXP_" and are never registered on the frame.
local handlers = {}
local frame = CreateFrame("Frame")

function BXP:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if not event:find("^BXP_") then frame:RegisterEvent(event) end
    end
    table.insert(handlers[event], fn)
end

-- A handler that runs before the others of its event: Log.lua notes the quest window's NPC before automation accepts
-- the quest, which closes the window (automation-accepted quests had no giver recorded, 2026-10-12).
function BXP:OnFirst(event, fn)
    self:On(event, fn)
    local list = handlers[event]
    table.insert(list, 1, table.remove(list))
end

-- For events whose name differs between clients (LEARNED_SPELL_IN_TAB, LEARNED_SPELL_IN_SKILL_LINE): registering
-- an event the client doesn't know raises an error, so ask it first. Returns whether it was registered.
function BXP:OnValid(event, fn)
    if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then return false end
    self:On(event, fn)
    return true
end

function BXP:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do list[i](event, ...) end
end

frame:SetScript("OnEvent", function(_, event, ...) BXP:Fire(event, ...) end)

function BXP:Print(...)
    local msg = strjoin(" ", tostringall(...))
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99BoostedXP|r: " .. msg)
end

BXP:On("ADDON_LOADED", function(_, name)
    if name ~= addonName then return end
    BoostedXPDB = applyDefaults(BoostedXPDB or {}, DEFAULTS)
    BoostedXPCharDB = applyDefaults(BoostedXPCharDB or {}, CHAR_DEFAULTS)
    BXP.db = BoostedXPDB
    BXP.char = BoostedXPCharDB
    -- Progress used to be saved by step number, which regenerated guides reshuffle.
    -- Old skip marks are cleared; old split times are kept in oldSplits for tuning.
    for guideID, t in pairs(BoostedXPCharDB.done) do
        for k in pairs(t) do
            if type(k) == "number" then t[k] = nil end
        end
    end
    for guideID, t in pairs(BoostedXPCharDB.splits) do
        for k, v in pairs(t) do
            if type(k) == "number" then
                BoostedXPCharDB.oldSplits = BoostedXPCharDB.oldSplits or {}
                BoostedXPCharDB.oldSplits[guideID] = BoostedXPCharDB.oldSplits[guideID] or {}
                BoostedXPCharDB.oldSplits[guideID][k] = v
                t[k] = nil
            end
        end
    end
    BXP:Fire("BXP_LOADED")
end)

BXP:On("PLAYER_LOGIN", function()
    BXP:Fire("BXP_READY")
end)
