-- Flight hints: when a flight path you know gets you to the current step faster than walking, the window says so and
-- the arrow points at the flight master first (2026-10-14, the maintainer: from Camp Taurajo The Ashenvale Hunt was
-- 4,500 yards on foot). The planner flies where its route expects you to be; this is the addon's own check, for a
-- player who is somewhere else. Known flight paths come from the client: its flight points on your continent's map
-- (C_TaxiMap.GetTaxiNodesForMap, discovered or not), what a taxi map has shown this character (char.flights), and
-- Orgrimmar for Orcs and Trolls, who start with it. The first version read only the taxi map, so a character that
-- hadn't talked to a flight master since knew none (2026-10-14, the maintainer in Camp Taurajo: no hint). /boost
-- flights prints what it knows and why there's no hint.
local _, BXP = ...
local Api = BXP.Api

-- The planner's travel model (tools/goplanner/planner/model.go): run speed, the walking detour, flight speed, the
-- flight's detour and the time to talk, take off and land.
local RUN_SPEED, DETOUR = 7.0, 1.25
local FLIGHT_SPEED, FLIGHT_DETOUR, FLY_OVERHEAD = 32.0, 1.3, 10.0
local MIN_WALK = 800  -- yards: a walk shorter than this is never worth a flight
local MIN_GAIN = 60   -- seconds a flight must save to be suggested; once suggested, it stays while it saves any
-- Steps that are travel already, or that a flight can't help.
local NO_HINT = { fly = true, flightpath = true, hearth = true, die = true, note = true }

-- The town of a taxi map node's name: "Crossroads, The Barrens" -> "crossroads" (lower case, no leading "the").
local function townKey(name)
    if type(name) ~= "string" then return nil end
    name = name:match("^([^,]+)") or name
    return (name:lower():gsub("^the ", ""))
end
BXP.FlightTownKey = townKey

-- Whether a flight master's town is one of the known taxi node names: the planner's town names are the client's
-- (Grom'gol Base Camp, Stormwind City), the taxi map's are shorter (Grom'gol, Stormwind).
local function known(master, flights)
    local town = townKey(master.town)
    for name in pairs(flights) do
        local node = townKey(name)
        if node and (town == node or town:sub(1, #node + 1) == node .. " " or node:sub(1, #town + 1) == town .. " ") then
            return true
        end
    end
    return false
end

-- Whether this character already has a town's flight path: a guide's "get the flight path" step is done then
-- (2026-10-20, the maintainer at Tarren Mill: the step stayed up for a path they had).
function BXP:KnowsFlight(town)
    return known({ town = town }, self:KnownFlights())
end

-- The flight paths shown on the taxi map now: every node the map lists as here or reachable.
local function taxiNodes()
    local out = {}
    if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID then
        local mapID = Api.plain(GetTaxiMapID())
        local reachable = Enum and Enum.FlightPathState and Enum.FlightPathState.Reachable or 1
        local current = Enum and Enum.FlightPathState and Enum.FlightPathState.Current or 0
        for _, node in ipairs(mapID and C_TaxiMap.GetAllTaxiNodes(mapID) or {}) do
            local state, name = Api.plain(node.state), Api.plain(node.name)
            if name and (state == current or state == reachable) then out[#out + 1] = name end
        end
    elseif NumTaxiNodes and TaxiNodeName and TaxiNodeGetType then
        for i = 1, (Api.plain(NumTaxiNodes()) or 0) do
            local kind = Api.plain(TaxiNodeGetType(i))
            if kind == "CURRENT" or kind == "REACHABLE" then out[#out + 1] = Api.plain(TaxiNodeName(i)) end
        end
    end
    return out
end

BXP:On("TAXIMAP_OPENED", function()
    BXP.char.flights = BXP.char.flights or {}
    for _, name in ipairs(taxiNodes()) do BXP.char.flights[name] = true end
end)

-- The continent map the player is on (the player's map and the maps it sits in, up to a continent), or nil.
local function continentMap()
    local mapID = Api.plain(C_Map.GetBestMapForUnit("player"))
    local continent = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
    for _ = 1, 6 do
        local info = mapID and C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == continent then return mapID end
        mapID = info.parentMapID
    end
end

-- The client's flight points on the player's continent: { [name] = discovered }, only those it says either way of
-- (a client whose nodes carry no isUndiscovered tells nothing), and how many it listed.
function BXP:MapFlightPoints()
    local out, listed = {}, 0
    local mapID = continentMap()
    if not (mapID and C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap) then return out, listed end
    for _, node in ipairs(C_TaxiMap.GetTaxiNodesForMap(mapID) or {}) do
        listed = listed + 1
        local name, undiscovered = Api.plain(node.name), Api.plain(node.isUndiscovered)
        if name and undiscovered ~= nil then out[name] = not undiscovered end
    end
    return out, listed
end

-- The flight paths this character knows: the client's discovered flight points, the taxi map's, and Orgrimmar for an
-- Orc or Troll; a point the client calls undiscovered isn't, whatever else says so.
function BXP:KnownFlights()
    local flights = {}
    for name in pairs(self.char.flights or {}) do flights[name] = true end
    local race = Api.plain(select(2, UnitRace("player")))
    if (race == "Orc" or race == "Troll") and Api.plain(UnitFactionGroup("player")) == "Horde" then
        flights["Orgrimmar"] = true
    end
    for name, discovered in pairs(self:MapFlightPoints()) do flights[name] = discovered or nil end
    return flights
end

local function yards(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- The known flight masters on a continent, with their world positions.
local function mastersOn(continent, flights)
    local side = Api.plain(UnitFactionGroup("player"))
    local out = {}
    for _, m in ipairs(BXP.FlightMasters and BXP.FlightMasters[side] or {}) do
        if known(m, flights) then
            local c, x, y = Api.WorldPosition(m.map, m.x / 100, m.y / 100)
            if c == continent then out[#out + 1] = { master = m, x = x, y = y } end
        end
    end
    return out
end

-- A flight that gets to the step's target faster than walking there, or nil: { from = master, to = master, saves =
-- seconds }. Every pair of known flight masters on your continent is tried (walk to one, fly, walk from the other),
-- timed as the planner times them. keep: the hint shown for this step before, kept while it still saves time.
-- With no hint, the second value says why (for /boost flights).
function BXP:FlightHint(step, keep)
    if not step then return nil, "no step" end
    if NO_HINT[step.kind] or step.dungeon then return nil, "a travel step" end
    if Api.plain(UnitOnTaxi("player")) then return nil, "on a flight" end
    local dist, dx, dy = self:ArrowTarget(step)
    if not dist then return nil, "the step is on another continent or has no spot" end
    if dist < MIN_WALK then return nil, ("%d yards: walked"):format(dist) end
    local pc, px, py = Api.PlayerWorldPosition()
    if not pc then return nil, "your position is unknown here" end
    local tx, ty = px + dx, py + dy
    local list = mastersOn(pc, self:KnownFlights())
    if #list < 2 then return nil, ("%d of your flight paths on this continent"):format(#list) end
    local walk = dist * DETOUR / RUN_SPEED
    local best, bestTime
    for _, a in ipairs(list) do
        local toA = yards(px, py, a.x, a.y) * DETOUR / RUN_SPEED
        for _, b in ipairs(list) do
            if a ~= b then
                local t = toA + FLY_OVERHEAD + yards(a.x, a.y, b.x, b.y) * FLIGHT_DETOUR / FLIGHT_SPEED
                    + yards(b.x, b.y, tx, ty) * DETOUR / RUN_SPEED
                if not bestTime or t < bestTime then best, bestTime = { from = a.master, to = b.master }, t end
            end
        end
    end
    local saves = walk - bestTime
    local same = keep and keep.from == best.from and keep.to == best.to
    if saves < (same and 0 or MIN_GAIN) then
        return nil, ("%d yards: walking %s, the best flight (%s to %s) %s"):format(dist, BXP.FormatDuration(walk),
            best.from.town, best.to.town, BXP.FormatDuration(bestTime))
    end
    best.saves = saves
    return best
end

-- /boost flights: the flight paths the addon knows on this continent, and the hint for the current step or why none.
function BXP:PrintFlights()
    local points, listed = self:MapFlightPoints()
    local said = 0
    for _ in pairs(points) do said = said + 1 end
    self:Print(("The client lists %d flight points on this continent, %d of them as discovered or not."):format(listed, said))
    local pc = Api.PlayerWorldPosition()
    local names = {}
    for _, a in ipairs(pc and mastersOn(pc, self:KnownFlights()) or {}) do names[#names + 1] = a.master.town end
    table.sort(names)
    self:Print(#names > 0 and "Your flight paths here: " .. table.concat(names, ", ") or "No flight paths known here.")
    local hint, why = self:FlightHint(self:TargetStep())
    self:Print(hint and self.FlightHintText(hint) or "No flight hint: " .. tostring(why) .. ".")
end

-- The window's line for a hint.
function BXP.FlightHintText(hint)
    return ("Faster by air: fly from %s to %s (saves about %d min). The arrow points to %s."):format(
        hint.from.town, hint.to.town, math.max(1, math.floor(hint.saves / 60 + 0.5)), hint.from.name)
end

-- The hint follows the player: worked out once a second for the step the arrow points at; the window redraws when it
-- comes, goes or changes.
BXP:On("BXP_READY", function()
    C_Timer.NewTicker(1, function()
        local step = BXP:TargetStep()
        local old = BXP.flightHint
        local hint = BXP:FlightHint(step, old and old.step == step and old or nil)
        if hint then hint.step = step end
        BXP.flightHint = hint
        if (old and BXP.FlightHintText(old)) ~= (hint and BXP.FlightHintText(hint)) then BXP:Fire("BXP_REFRESH") end
    end)
end)
