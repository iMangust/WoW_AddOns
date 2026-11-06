-- Waypoint arrow that points at the current step's location, plus a map pin for it.
-- The arrow is a named, movable frame, so the client saves where the player drags it.
local _, BXP = ...
local Api, Zones = BXP.Api, BXP.Zones

local arrow = CreateFrame("Frame", "BoostedXPArrow", UIParent)
arrow:SetSize(48, 48)
arrow:SetPoint("TOP", UIParent, "TOP", 0, -140)
arrow:SetClampedToScreen(true)
arrow:SetMovable(true)
arrow:EnableMouse(true)
arrow:RegisterForDrag("LeftButton")
-- /boost lock freezes the arrow with the window: no dragging, and clicks pass through it to the world.
arrow:SetScript("OnDragStart", function() if not BXP.db.window.locked then arrow:StartMoving() end end)
arrow:SetScript("OnDragStop", arrow.StopMovingOrSizing)
arrow:Hide()
BXP.arrowFrame = arrow

local tex = arrow:CreateTexture(nil, "ARTWORK")
tex:SetAllPoints()
tex:SetTexture("Interface\\AddOns\\BoostedXP\\Media\\arrow")

-- A green halo of the arrow's own shape, for the few seconds after arriving.
local glow = arrow:CreateTexture(nil, "OVERLAY")
glow:SetPoint("CENTER")
glow:SetSize(68, 68)
glow:SetTexture("Interface\\AddOns\\BoostedXP\\Media\\arrow")
glow:SetBlendMode("ADD")
glow:SetVertexColor(0.3, 1, 0.3)
glow:Hide()

local label = arrow:CreateFontString(nil, "OVERLAY", "BoostedXPFontDetail")
label:SetPoint("TOP", arrow, "BOTTOM", 0, -2)
BXP.arrowLabel = label

local TWO_PI = 2 * math.pi
local HERE = 8          -- yards: on top of a step's spot (an NPC, a flight master), the arrow hides
local AREA_RADIUS = 60  -- yards: a hunting step's reach around its spot when the guide lists no areas
local EDGE = 10         -- yards past the edge before the arrow comes back, so it doesn't flicker there
local GLOW = 3          -- seconds the arrow glows green on arriving...
local FADE = 0.6        -- ...then fades out over this, and stays hidden while you're there
local PULSE = 1         -- seconds per glow pulse

-- Rotation for the arrow texture. World offsets: dx toward north, dy toward west.
-- GetPlayerFacing() and Texture:SetRotation() both count counter-clockwise from north.
function BXP.ArrowAngle(dx, dy, facing)
    return (math.atan2(dy, dx) - facing) % TWO_PI
end

local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
local scratchLive = {}
BXP.scratchLive = scratchLive

-- Where the arrow points, and within how many yards of it the arrow hides: a hunting step's nearest area (by its
-- edge) whose quest is still open, since the step's own spot is only the middle between its areas, which can lie a
-- thousand yards apart; inside it the mobs are all around and pointing anywhere only turned the arrow red. A loot
-- step for an item that starts a quest lists the dropping mob's areas the same way, until the item or the quest is had.
-- Other steps point at their spot and hide on top of it. Returns dist, dx, dy, reach and what it points at.
function BXP:ArrowTarget(step)
    local hunt = step.complete ~= nil and not step.dungeon
    local drop = step.loot ~= nil and step.areas ~= nil  -- a mob's drop that starts a quest: kill it in any of these
    if (hunt or drop) and step.areas then
        local live = wipe(scratchLive)
        if hunt then
            for _, id in ipairs(self:LiveQuests(step)) do live[id] = not self:HuntDone(step, id) end
        elseif step.quest then
            live[step.quest] = not Api.IsQuestInLog(step.quest) and not Api.IsQuestTurnedIn(step.quest)
                and not (step.item and Api.ItemCount(step.item) > 0)
        end
        local best, bd, bx, by
        for _, area in ipairs(step.areas) do
            local mapID = live[area.q] and Zones.Resolve(area.zone)
            local d, dx, dy
            if mapID then d, dx, dy = self:OffsetTo(mapID, area[1] / 100, area[2] / 100) end
            if d and (not best or d - area.r < bd - best.r) then best, bd, bx, by = area, d, dx, dy end
        end
        if best then return bd, bx, by, best.r, best end
    end
    local dist, dx, dy = self:StepDistance(step)
    return dist, dx, dy, hunt and AREA_RADIUS or step.radius or HERE, step
end

-- How the arrow looks t seconds after arriving: its alpha and its glow's, or nil once it's gone.
function BXP.ArrivalLook(t)
    if t >= GLOW + FADE then return nil end
    local fade = t < GLOW and 1 or 1 - (t - GLOW) / FADE
    local pulse = 0.5 + 0.5 * math.cos(t * TWO_PI / PULSE)  -- brightest on arriving
    return fade, fade * (0.35 + 0.65 * pulse)
end

-- Arriving is counted per step, within reach of its target (EDGE yards more once there, so no flicker at the edge).
-- A hunting step targets its nearest pocket, which changes as you move among them: that's no new arrival, and the
-- green glow shows only on first reaching the step, not again on coming back into its pockets (2026-10-11: the glow
-- kept coming back while the player moved around Cutting Teeth's boars). Returns whether arrived, and the seconds
-- since the glow started (huge: no glow).
function BXP.Arrive(a, step, dist, reach, now)
    local was = a.arrived and a.step == step
    a.arrived, a.step = dist <= reach + (was and EDGE or 0), step
    if a.arrived and not was then
        a.at = a.glowed == step and -math.huge or now
        a.glowed = step
    end
    return a.arrived, now - (a.at or now)
end

local arrival = {}
local lastDist, lastMasterName, lastStep, lastStatus

local function update()
    local step = BXP:TargetStep()
    local dist, dx, dy, reach
    local hint = BXP.flightHint
    local master = step and hint and hint.step == step and hint.from  -- a flight is faster (Flight.lua): its master first
    if master then
        dist, dx, dy = BXP:OffsetTo(master.map, master.x / 100, master.y / 100)
        reach, step = HERE, master
    elseif step then
        dist, dx, dy, reach = BXP:ArrowTarget(step)
    end
    local facing = Api.plain(GetPlayerFacing())
    if not dist or not facing then
        tex:Hide()
        glow:Hide()
        local status = step and step.at and "No direction here" or ""
        if status ~= lastStatus then
            lastDist, lastMasterName, lastStep, lastStatus = nil, nil, nil, status
            label:SetText(status)
        end
        return
    end
    lastStatus = nil
    -- Arrived: the arrow glows green, then hides until you're EDGE yards back out (no flicker at the edge).
    local arrived, since = BXP.Arrive(arrival, step, dist, reach, GetTime())
    local angle = BXP.ArrowAngle(dx, dy, facing)
    if arrived then
        if lastStep ~= "arrived" then
            lastDist, lastMasterName, lastStep = nil, nil, "arrived"
            label:SetText("")
        end
        local alpha, glowAlpha = BXP.ArrivalLook(since)
        if not alpha then
            tex:Hide()
            glow:Hide()
            return
        end
        tex:SetVertexColor(0.3, 1, 0.3)
        tex:SetAlpha(alpha)
        glow:SetAlpha(glowAlpha)
        glow:SetRotation(angle)
        glow:Show()
        tex:SetRotation(angle)
        tex:Show()
        return
    end
    glow:Hide()
    tex:SetAlpha(1)
    local off = math.abs((angle + math.pi) % TWO_PI - math.pi)  -- 0 = straight ahead
    if off < 0.3 then
        tex:SetVertexColor(0.3, 1, 0.3)
    elseif off < 1.3 then
        tex:SetVertexColor(1, 0.85, 0.2)
    else
        tex:SetVertexColor(1, 0.35, 0.3)
    end
    tex:SetRotation(angle)
    tex:Show()
    local rounded = math.floor(dist)
    local masterName = master and master.name
    if rounded ~= lastDist or masterName ~= lastMasterName or step ~= lastStep then
        lastDist = rounded
        lastMasterName = masterName
        lastStep = step
        label:SetText(master and ("%d yd to %s"):format(dist, master.name) or ("%d yd"):format(dist))
    end
end

local elapsed = 0
arrow:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 0.05 then return end
    elapsed = 0
    update()
end)

local pinned = false

-- Whether a step's spot is on another map than the player's: the game marks nothing for it from here.
local function elsewhere(step)
    local mapID = BXP:StepMapPosition(step)
    local here = Api.plain(C_Map.GetBestMapForUnit("player"))
    return mapID ~= nil and here ~= nil and mapID ~= here
end

-- The game already marks a quest step's NPC and area (the "!" and "?" on the minimap, the blue area), and
-- the pin would sit on top of them: by default only travel and other steps get a pin, and quest steps in another
-- zone (the player had to google where Bishop Farthing was, 2026-10-13).
local function wantsPin(step)
    local mode = BXP.db.pinMode
    return step ~= nil and (mode == "all" or (mode == "travel" and (not BXP.QuestKinds[step.kind] or elsewhere(step))))
end

local function syncPin(target)
    local mapID, x, y = BXP:StepMapPosition(target)
    local inBounds = x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1
    local mappable = mapID and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(mapID)
    if wantsPin(target) and inBounds and mappable then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        pinned = true
    elseif pinned then
        C_Map.ClearUserWaypoint()
        pinned = false
    end
end

function BXP:SyncPin() syncPin(self:TargetStep()) end

function BXP:UpdateArrow()
    local step = self:TargetStep()
    arrow:SetScale(self.db.arrow.scale)
    arrow:EnableMouse(not self.db.window.locked)
    arrow:SetShown(self.db.arrow.shown and step ~= nil and (step.at ~= nil or self:StepMapPosition(step) ~= nil))
end

function BXP:ToggleArrow()
    self.db.arrow.shown = not self.db.arrow.shown
    self:UpdateArrow()
    return self.db.arrow.shown
end

BXP:On("BXP_STEP_CHANGED", function()
    syncPin(BXP:TargetStep())
    BXP:UpdateArrow()
end)

-- Walking into the step's zone takes the pin of a quest step away again.
BXP:On("ZONE_CHANGED_NEW_AREA", function() syncPin(BXP:TargetStep()) end)
