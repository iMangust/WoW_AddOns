-- Zone name -> uiMapID. Forever keeps the Classic map IDs (ForeverDB's map links use
-- them), so these are listed directly. Zones that are not listed (e.g. new Forever
-- zones) are found by scanning C_Map, and the player's real position overrides both.
local _, BXP = ...

local KNOWN = {
    ["Durotar"] = 1411,
    ["Mulgore"] = 1412,
    ["The Barrens"] = 1413,
    ["Kalimdor"] = 1414,
    ["Eastern Kingdoms"] = 1415,
    ["Arathi Highlands"] = 1417,
    ["Badlands"] = 1418,
    ["Blasted Lands"] = 1419,
    ["Tirisfal Glades"] = 1420,
    ["Silverpine Forest"] = 1421,
    ["Western Plaguelands"] = 1422,
    ["Eastern Plaguelands"] = 1423,
    ["Hillsbrad Foothills"] = 1424,
    ["Alterac Mountains"] = 1416,
    ["The Hinterlands"] = 1425,
    ["Dun Morogh"] = 1426,
    ["Searing Gorge"] = 1427,
    ["Burning Steppes"] = 1428,
    ["Elwynn Forest"] = 1429,
    ["Duskwood"] = 1431,
    ["Loch Modan"] = 1432,
    ["Redridge Mountains"] = 1433,
    ["Stranglethorn Vale"] = 1434,
    ["Swamp of Sorrows"] = 1435,
    ["Westfall"] = 1436,
    ["Wetlands"] = 1437,
    ["Teldrassil"] = 1438,
    ["Darkshore"] = 1439,
    ["Ashenvale"] = 1440,
    ["Thousand Needles"] = 1441,
    ["Stonetalon Mountains"] = 1442,
    ["Desolace"] = 1443,
    ["Feralas"] = 1444,
    ["Dustwallow Marsh"] = 1445,
    ["Tanaris"] = 1446,
    ["Azshara"] = 1447,
    ["Felwood"] = 1448,
    ["Un'Goro Crater"] = 1449,
    ["Silithus"] = 1451,
    ["Winterspring"] = 1452,
    ["Stormwind City"] = 1453,
    ["Orgrimmar"] = 1454,
    ["Ironforge"] = 1455,
    ["Thunder Bluff"] = 1456,
    ["Darnassus"] = 1457,
    ["Undercity"] = 1458,
    ["Mount Hyjal"] = 2482,
    ["Zephras Isle"] = 2521,
    ["Darkspear Islands"] = 2524,
    ["Riverglades"] = 2548,
    ["Shen'dralas"] = 2652,
}

local Zones = { known = KNOWN }
BXP.Zones = Zones

local scanned

local function scan()
    scanned = {}
    for id = 1, 3000 do
        local info = C_Map.GetMapInfo(id)
        if info and info.mapType == Enum.UIMapType.Zone and info.name and not scanned[info.name] then
            scanned[info.name] = id
        end
    end
end

function Zones.Resolve(name)
    if type(name) == "number" then return name end
    local learned = BXP.db and BXP.db.zones[name]
    if learned then return learned end
    if KNOWN[name] then return KNOWN[name] end
    if not scanned then scan() end
    return scanned[name]
end

-- Remember the player's current zone name -> map ID, which beats any guess.
function Zones.Learn()
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    if info and info.mapType == Enum.UIMapType.Zone and info.name then
        BXP.db.zones[info.name] = mapID
    end
end

BXP:On("ZONE_CHANGED_NEW_AREA", function() if BXP.db then Zones.Learn() end end)
BXP:On("BXP_READY", function() Zones.Learn() end)
