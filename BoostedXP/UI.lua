-- Guide window: the current step with its details and objectives, then, below a divider,
-- the next few steps.
local _, BXP = ...

local PAD = 8
local COMING_UP = 2  -- steps listed after the current one: more was too much to take in (2026-10-08)
local MAX_COMING_UP = 8  -- a window given a height fills it with up to this many
local MIN_WIDTH, MAX_WIDTH, MIN_HEIGHT, MAX_HEIGHT = 240, 900, 120, 1000
BXP.WindowLimits = { MIN_WIDTH, MAX_WIDTH, MIN_HEIGHT, MAX_HEIGHT }

local Api = BXP.Api
local fonts = BXP.Fonts

-- The window's width: the one the player set (dragging the corner, or the options), else from the text size.
local function width()
    return BXP.db.window.width or math.max(320, BXP.db.window.fontSize * 25)
end
local sizing = false  -- the player is dragging the corner

local win = CreateFrame("Frame", "BoostedXPWindow", UIParent, "BackdropTemplate")
win:SetSize(320, 80)
local function homePosition()
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", UIParent, "LEFT", 40, 270)  -- the quest tracker owns the top right
end
homePosition()

-- The top-left corner stays put while the window grows and shrinks: anchored by its middle, it had moved away from
-- the cursor on every Next and Back (the maintainer, 2026-10-09), and the game re-anchors a dragged frame by
-- whichever corner is nearest.
local function anchorTop()
    local point = win:GetPoint(1)
    local left, top = win:GetLeft(), win:GetTop()
    if point == "TOPLEFT" or not (left and top) then return end
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end
win:SetClampedToScreen(true)
win:SetMovable(true)
win:EnableMouse(true)
win:RegisterForDrag("LeftButton")
win:SetScript("OnDragStart", function() if not BXP.db.window.locked then win:StartMoving() end end)
win:SetScript("OnDragStop", function()
    win:StopMovingOrSizing()
    anchorTop()
end)
win:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
win:SetBackdropColor(0, 0, 0, 0.8)  -- UpdateWindow applies the opacity setting
BXP.windowFrame = win
win:Hide()

-- Resizing: drag the bottom-right corner. The width is the window's; the height is the most it may take, filled
-- with as many Coming up steps as fit.
win:SetResizable(true)
if win.SetResizeBounds then win:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)
elseif win.SetMinResize then win:SetMinResize(MIN_WIDTH, MIN_HEIGHT); win:SetMaxResize(MAX_WIDTH, MAX_HEIGHT) end
local grip = CreateFrame("Button", nil, win)
grip:SetSize(14, 14)
grip:SetPoint("BOTTOMRIGHT", -1, 1)
grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
grip:SetScript("OnMouseDown", function()
    if BXP.db.window.locked then return end
    sizing = true
    win:StartSizing("BOTTOMRIGHT")
end)
BXP.windowGrip = grip
grip:SetScript("OnMouseUp", function()
    win:StopMovingOrSizing()
    sizing = false
    anchorTop()
    BXP:SetWindowSize(win:GetWidth(), win:GetHeight())
end)
win:SetScript("OnSizeChanged", function() if sizing then BXP:UpdateWindow() end end)

local title = win:CreateFontString(nil, "OVERLAY", "BoostedXPFontTitle")
title:SetPoint("TOPLEFT", PAD, -6)
title:SetPoint("RIGHT", win, "RIGHT", -86, 0)
title:SetJustifyH("LEFT")
title:SetWordWrap(false)

local function headerButton(text, offsetX, tooltip, onClick)
    local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    b:SetSize(24, 18)
    b:SetPoint("TOPRIGHT", offsetX, -4)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end
headerButton(">", -6, "Next step (skip)", function() BXP:NextStep() end)
headerButton("<", -32, "Previous step", function() BXP:PreviousStep() end)
local classHeaderBtn = headerButton("C", -58, "Class quests: view, skip, or follow chains", function() BXP:OpenClassUI() end)
BXP.classHeaderBtn = classHeaderBtn

local classNoticeBtn = CreateFrame("Button", nil, win)
classNoticeBtn:Hide()
classNoticeBtn:SetScript("OnClick", function() BXP:OpenClassUI() end)
classNoticeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Class quests - click to view and manage class quest chains")
    GameTooltip:Show()
end)
classNoticeBtn:SetScript("OnLeave", GameTooltip_Hide)
BXP.classNoticeBtn = classNoticeBtn

local paceFrame = CreateFrame("Frame", nil, win)
paceFrame:EnableMouse(true)
paceFrame:RegisterForDrag("LeftButton")
paceFrame:SetScript("OnDragStart", function() if not BXP.db.window.locked then win:StartMoving() end end)
paceFrame:SetScript("OnDragStop", function()
    win:StopMovingOrSizing()
    anchorTop()
end)
BXP.paceFrame = paceFrame

local function formatPaceSeconds(sec)
    local s = math.floor(math.abs(sec) + 0.5)
    if s < 60 then return s .. "s" end
    local m = math.floor(s / 60)
    local rem = s % 60
    return rem > 0 and (m .. "m " .. rem .. "s") or (m .. "m")
end

local function showPaceTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:SetText("Route Pacing", 1, 1, 1)
    local pace = BXP.Pace and BXP:Pace()
    local paceText
    if pace then
        if pace < -5 then
            paceText = ("Pace: %s ahead of route"):format(formatPaceSeconds(pace))
        elseif pace > 5 then
            paceText = ("Pace: %s behind route"):format(formatPaceSeconds(pace))
        else
            paceText = "Pace: on pace"
        end
    else
        paceText = "Pace: on pace"
    end
    GameTooltip:AddLine(paceText, 0.2, 1, 0.6)

    local guide = BXP.guide
    local left = BXP.TimeRemaining and BXP:TimeRemaining()
    if guide and left then
        GameTooltip:AddLine(("Estimated time to level %d: %s"):format(guide.levels[2], BXP.FormatDuration(left)), 0.8, 0.8, 0.8)
    end
    local step = BXP.CurrentStep and BXP:CurrentStep()
    if step and step.eta then
        GameTooltip:AddLine(("Current step ETA: %s"):format(BXP.FormatDuration(step.eta)), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

paceFrame:SetScript("OnEnter", function(self) showPaceTooltip(self) end)
paceFrame:SetScript("OnLeave", GameTooltip_Hide)

local stepFrames = {}
BXP.stepFrames = stepFrames

local function showStepTooltip(owner, step)
    if not step then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local titleText = BXP:StepText(step):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    GameTooltip:SetText(titleText, 1, 1, 1)

    if step.quests and #step.quests > 0 then
        for _, qid in ipairs(step.quests) do
            local qtitle = Api.GetQuestTitle(qid) or ("Quest " .. qid)
            GameTooltip:AddLine(("[%d] %s"):format(qid, qtitle), 1, 0.82, 0)
            local objs = Api.GetObjectives(qid)
            if objs and #objs > 0 then
                for _, o in ipairs(objs) do
                    local status = o.finished and " (Completed)" or ""
                    local r, g, b = 0.9, 0.9, 0.9
                    if o.finished then r, g, b = 0.5, 0.5, 0.5 end
                    GameTooltip:AddLine("  - " .. o.text .. status, r, g, b)
                end
            end
        end
    end
    if step.text then
        GameTooltip:AddLine(step.text, 0.9, 0.9, 0.9, true)
    end
    if step.npc then
        GameTooltip:AddLine("NPC: " .. step.npc, 0.7, 0.7, 0.7)
    end
    if step.at and step.at.zone then
        GameTooltip:AddLine(("Location: %.1f, %.1f (%s)"):format(step.at[1], step.at[2], step.at.zone), 0.7, 0.7, 0.7)
    end
    GameTooltip:Show()
end

local function getStepFrame(index)
    local sf = stepFrames[index]
    if not sf then
        sf = CreateFrame("Frame", nil, win)
        sf:EnableMouse(true)
        sf:RegisterForDrag("LeftButton")
        sf:SetScript("OnDragStart", function() if not BXP.db.window.locked then win:StartMoving() end end)
        sf:SetScript("OnDragStop", function()
            win:StopMovingOrSizing()
            anchorTop()
        end)
        sf:SetScript("OnEnter", function(self)
            if self.step then showStepTooltip(self, self.step) end
        end)
        sf:SetScript("OnLeave", GameTooltip_Hide)
        stepFrames[index] = sf
    end
    return sf
end

local divider = win:CreateTexture(nil, "ARTWORK")
divider:SetHeight(1)
local footerLine = win:CreateTexture(nil, "ARTWORK")  -- above the footer: draft status and how to help
footerLine:SetHeight(1)

-- The border and lines: a soft green that fades with the background's opacity (bright green had looked bold,
-- and stayed at 0%: the maintainer, 2026-10-09). The lines keep a trace, so the parts stay apart.
local function lineColors(opacity)
    win:SetBackdropBorderColor(0.3, 0.6, 0.45, 0.6 * opacity)
    for _, line in ipairs({ divider, footerLine }) do line:SetColorTexture(0.3, 0.6, 0.45, 0.15 + 0.3 * opacity) end
end

local rows = {}

-- Back where it starts, at its own size, and shown (the options panel's button): the game keeps a dragged window's spot.
function BXP:ResetWindowPosition()
    if win.SetUserPlaced then win:SetUserPlaced(false) end
    homePosition()
    self.db.window.shown = true
    self.db.window.width, self.db.window.height = nil, nil
    self:UpdateWindow()
end

-- The size the player chose (nil: automatic), kept within the limits.
function BXP:SetWindowSize(w, h)
    local db = self.db.window
    db.width = w and math.floor(math.max(MIN_WIDTH, math.min(MAX_WIDTH, w)) + 0.5) or nil
    db.height = h and math.floor(math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, h)) + 0.5) or nil
    self:UpdateWindow()
end

function BXP:WindowSize() return win:GetWidth(), win:GetHeight() end

function BXP:UpdateWindow()
    if not self.db.window.shown then
        win:Hide()
        return
    end
    win:SetScale(self.db.window.scale)
    grip:SetShown(not self.db.window.locked)  -- locked (/boost lock): no moving, no resizing
    local opacity = self.db.window.opacity or 0.8
    win:SetBackdropColor(0, 0, 0, opacity)  -- the background only: text stays solid
    lineColors(opacity)
    local w = sizing and win:GetWidth() or width()
    if not sizing then win:SetWidth(w) end
    win:Show()
    if not sizing then anchorTop() end  -- a position the game restored from its layout cache may use any corner
    local maxHeight = sizing and win:GetHeight() or self.db.window.height
    local height
    -- A window with a height fills it: as many Coming up steps as fit, fewer when the steps run long.
    for comingUp = maxHeight and MAX_COMING_UP or COMING_UP, 0, -1 do
        height = self:DrawWindow(w, comingUp)
        if not maxHeight or height <= maxHeight then break end
    end
    if not sizing then win:SetHeight(height) end
    if classHeaderBtn then
        classHeaderBtn:SetText(self:ClassWorkAvailable() and "|cff33ff99C|r" or "C")
    end
end

function BXP:ToggleWindow()
    self.db.window.shown = not self.db.window.shown
    self:UpdateWindow()
    return self.db.window.shown
end

-- Lays out the window's text for a width and a number of Coming up steps; returns the height it takes.
function BXP:DrawWindow(width, comingUp)
    local n, y = 0, -(self.db.window.fontSize + 16)
    -- strike: draw a line through each wrapped line of the text (a font string can't strike through itself).
    local function add(text, font, indent, strike)
        n = n + 1
        local fs = rows[n]
        if not fs then
            fs = win:CreateFontString(nil, "OVERLAY")
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(true)
            fs.strikes = {}
            rows[n] = fs
        end
        fs:SetFontObject(font)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + indent, y)
        local rowWidth = width - 2 * PAD - indent
        fs:SetWidth(rowWidth)
        fs:SetText(text)
        fs:Show()
        local lines = strike and math.max(1, fs:GetNumLines() or 1) or 0
        local lineHeight = fs:GetStringHeight() / math.max(lines, 1)
        for k = 1, math.max(lines, #fs.strikes) do
            local line = fs.strikes[k]
            if k <= lines then
                if not line then
                    line = win:CreateTexture(nil, "OVERLAY")
                    line:SetColorTexture(0.75, 0.75, 0.75, 0.9)
                    fs.strikes[k] = line
                end
                local w = rowWidth
                if lines == 1 then
                    w = math.min(rowWidth, fs:GetStringWidth())
                else
                    local rem = fs:GetStringWidth() - (lines - 1) * rowWidth
                    if k == lines and rem > 24 then
                        w = math.min(rowWidth, rem)
                    end
                end
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", win, "TOPLEFT", PAD + indent, y - (k - 0.5) * lineHeight)
                line:SetSize(math.max(8, w), 1)
                line:Show()
            elseif line then
                line:Hide()
            end
        end
        y = y - fs:GetStringHeight() - 4
    end

    local guide = self.guide
    if not guide then
        title:SetText("BoostedXP")
        add("No guide selected. Type /boost list.", fonts.detail, 0)
        paceFrame:Hide()
        for j = 1, #stepFrames do
            stepFrames[j]:Hide()
            stepFrames[j].step = nil
        end
    else
        -- The step count first, then the guide's name: the title is cut at the arrows, and the count is what changes.
        title:SetText(("|cff808080%d/%d|r  %s"):format(self.baseIndex or #guide.steps, #guide.steps, guide.name))
        local left = self:TimeRemaining()
        if left then
            add(("|cff808080Time remaining until level %d:|r %s"):format(guide.levels[2], BXP.FormatDuration(left)),
                fonts.detail, 0)
        end
        local train = self:TrainReminder()
        if train then add("|cff33ff99" .. train .. "|r", fonts.detail, 0) end
        local flight = self.flightHint
        if flight and flight.step == self:TargetStep() then
            add("|cff33ff99" .. BXP.FlightHintText(flight) .. "|r", fonts.detail, 0)
        end
        if self.baseIndex and self.currentIndex ~= self.baseIndex and not self.viewIndex then
            add("|cff808080Closer, so this one first.|r", fonts.detail, 0)  -- the planned one leads Coming up
        end
        if guide.side then
            add("|cffffd100Class quests.|r |cff808080Click [C] or /boost class to view lines or return.|r", fonts.detail, 0)
            classNoticeBtn:Hide()
        elseif self:ClassWorkAvailable() then
            add("|cffffd100Class quests are available: click here.|r", fonts.detail, 0)
            local fs = rows[n]
            if fs then
                classNoticeBtn:ClearAllPoints()
                classNoticeBtn:SetPoint("TOPLEFT", fs, "TOPLEFT", 0, 0)
                classNoticeBtn:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 0, 0)
                classNoticeBtn:Show()
            end
        else
            classNoticeBtn:Hide()
        end
        local paceBottomY = y
        paceFrame:ClearAllPoints()
        paceFrame:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, -4)
        paceFrame:SetPoint("RIGHT", win, "RIGHT", -86, 0)
        paceFrame:SetHeight(math.max(18, -paceBottomY))
        paceFrame:Show()
        -- Quests the player skipped but still holds: after the current step, the last thing before Coming up (at
        -- the top they read as the step to do; the maintainer, 2026-10-09).
        local function stillOpen()
            local passed = self:PassedOverQuests()
            if #passed == 0 then return end
            y = y - 4
            add("|cffff9900Still open (skipped in the guide):|r", fonts.detail, 0)
            for _, id in ipairs(passed) do
                local parts = {}
                for _, o in ipairs(Api.GetObjectives(id)) do
                    if not o.finished then parts[#parts + 1] = o.text end
                end
                add("|cffffd100" .. (Api.GetQuestTitle(id) or tostring(id)) .. "|r |cffffffff"
                    .. table.concat(parts, ", ") .. "|r", fonts.detail, 10)
            end
        end
        local steps = self:UpcomingSteps(1 + comingUp)
        if #steps == 0 then
            add("|cff33ff99Guide complete!|r", fonts.step, 0)
            stillOpen()
        end
        for i, step in ipairs(steps) do
            local stepStartY = y
            local stepEndY
            if i == 1 and self:ViewingDone() then  -- looking back at a step that's done: crossed out
                local plain = self:StepText(step):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
                add("|cff808080" .. plain .. "|r", fonts.step, 0, true)
                add("|cff808080Already done. Next goes forward again, Back further back.|r", fonts.detail, 14)
                stepEndY = y
            elseif i == 1 then
                add("|cff33ff99>|r " .. self:StepText(step), fonts.current, 0)
                for _, line in ipairs(self:StepDetails(step)) do add(line, fonts.detail, 14) end
                stepEndY = y
            end
            if i == 1 then
                stillOpen()
            else
                if i == 2 then
                    y = y - 4
                    divider:ClearAllPoints()
                    divider:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, y)
                    divider:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, y)
                    y = y - 5
                    add("|cff808080Coming up|r", fonts.detail, 0)
                    stepStartY = y
                end
                local need = self:LevelNeeded(step)
                add("|cff909090" .. self:StepText(step) .. (need and (" (level " .. need .. ")") or "") .. "|r", fonts.detail, 10)
                stepEndY = y
            end
            local sf = getStepFrame(i)
            sf:ClearAllPoints()
            sf:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, stepStartY)
            sf:SetSize(width - 2 * PAD, math.max(12, stepStartY - (stepEndY or y)))
            sf.step = step
            sf:Show()
        end
        for j = #steps + 1, #stepFrames do
            stepFrames[j]:Hide()
            stepFrames[j].step = nil
        end
        y = y - 4
        footerLine:ClearAllPoints()
        footerLine:SetPoint("TOPLEFT", win, "TOPLEFT", PAD, y)
        footerLine:SetPoint("TOPRIGHT", win, "TOPRIGHT", -PAD, y)
        y = y - 5
        if guide.draft then
            local part = guide.played and math.floor(guide.played * 100 + 0.5) or 0
            add(part > 0 and ("|cffff9900Draft: about %d%% of this route has been played.|r"):format(part)
                or "|cffff9900Draft: this route hasn't been played yet.|r", fonts.small, 0)
        end
        add("|cff808080Help improve it:|r /boost export", fonts.small, 0)
        add("|cff808080Something wrong here?|r /boost feedback <note>", fonts.small, 0)
    end
    footerLine:SetShown(guide ~= nil)
    divider:SetShown(guide ~= nil and n > 0 and comingUp > 0 and #self:UpcomingSteps(2) > 1)
    for i = n + 1, #rows do
        rows[i]:Hide()
        for _, line in ipairs(rows[i].strikes) do line:Hide() end
    end
    return -y + 4
end

BXP:On("BXP_REFRESH", function() BXP:UpdateWindow() end)
BXP:On("BXP_READY", function()  -- the time left follows the step; the ticker keeps the window fresh
    C_Timer.NewTicker(10, function() if BXP.db.window.shown then BXP:UpdateWindow() end end)
end)
BXP:On("BXP_READY", function() BXP:UpdateWindow() end)
