-- Thin wrappers over the modern (Midnight-era) API that the Forever client uses.
local _, BXP = ...

local Api = {}
BXP.Api = Api

-- Midnight can hand back "secret" values that error on comparison or math.
-- Treat them as unknown.
local function plain(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end
Api.plain = plain

-- The addon's version from its TOC: a release's number, or for a test build deploy.py installed, "0.5.2-dev <commit>".
function Api.AddonVersion()
    return C_AddOns and C_AddOns.GetAddOnMetadata and plain(C_AddOns.GetAddOnMetadata("BoostedXP", "Version")) or nil
end

-- The quest window's NPC (never a player: an item's quest may name the player).
function Api.NpcName()
    if not (UnitExists and plain(UnitExists("npc"))) or (UnitIsPlayer and plain(UnitIsPlayer("npc"))) then return nil end
    return UnitName and plain(UnitName("npc")) or nil
end

function Api.IsQuestTurnedIn(questID)
    return C_QuestLog.IsQuestFlaggedCompleted(questID) and true or false
end

function Api.IsQuestInLog(questID)
    return C_QuestLog.GetLogIndexForQuestID(questID) ~= nil
end

-- True when the quest is in the log with every objective done.
function Api.IsQuestReady(questID)
    return Api.IsQuestInLog(questID) and C_QuestLog.IsComplete(questID) and true or false
end

-- How many of an item the player carries (bags), 0 if the API isn't there.
function Api.ItemCount(itemID)
    local n = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)
    return Api.plain(n) or 0
end

function Api.GetQuestTitle(questID)
    local title = C_QuestLog.GetTitleForQuestID(questID)
    if title and title ~= "" then return title end
    return BXP.QuestTitles[questID]
end

-- The names the game gives the player's place: zone, subzone and minimap text (empty ones left out).
function Api.LocationNames()
    local out = {}
    for _, fn in ipairs({ GetZoneText, GetSubZoneText, GetMinimapZoneText }) do
        local name = fn and plain(fn())
        if type(name) == "string" and name ~= "" then out[#out + 1] = name end
    end
    return out
end

-- Array of { text, finished } for a quest in the log.
function Api.GetObjectives(questID)
    local out = {}
    for i, o in ipairs(C_QuestLog.GetQuestObjectives(questID) or {}) do
        out[i] = { text = o.text or "", finished = o.finished and true or false,
                   have = plain(o.numFulfilled) or 0, need = plain(o.numRequired) or 0 }
    end
    return out
end

function Api.PlayerLevel()
    return plain(UnitLevel("player")) or 1
end

-- uiMapID, x, y (0-1) of the player, or nil inside instances and other unmapped places.
function Api.PlayerMapPosition()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local x, y = plain(pos.x), plain(pos.y)
    if not x or not y or (x == 0 and y == 0) then return nil end
    return mapID, x, y
end

-- continentID, worldX, worldY (yards) for a map position, or nil.
function Api.WorldPosition(mapID, x, y)
    local continentID, world = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    if not continentID or not world then return nil end
    return continentID, world.x, world.y
end

function Api.PlayerWorldPosition()
    local mapID, x, y = Api.PlayerMapPosition()
    if not mapID then return nil end
    return Api.WorldPosition(mapID, x, y)
end
