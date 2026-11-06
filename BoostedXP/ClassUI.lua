-- The Class Quests UI: an interactive window to view, follow, skip, or unhide class quest chains.
local _, BXP = ...
local Api = BXP.Api
local fonts = BXP.Fonts

local ClassUI = {}
BXP.ClassUI = ClassUI

local frame
local rows = {}

local function createClassWindow()
    if frame then return frame end

    local f = CreateFrame("Frame", "BoostedXPClassUI", UIParent, "BackdropTemplate")
    f:SetSize(480, 360)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() f:StartMoving() end)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, 0.9)
    f:SetBackdropBorderColor(0.2, 0.8, 0.5, 0.8)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "BoostedXPFontTitle")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Class Quests")
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetText("X")
    close:SetScript("OnClick", function() f:Hide() end)
    f.closeBtn = close

    local desc = f:CreateFontString(nil, "OVERLAY", "BoostedXPFontDetail")
    desc:SetPoint("TOPLEFT", 14, -36)
    desc:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    desc:SetJustifyH("LEFT")
    desc:SetText("Choose which class quest chains to follow or skip. Skipped chains won't trigger guide reminders.")
    f.desc = desc

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 10, -56)
    divider:SetPoint("TOPRIGHT", -10, -56)
    divider:SetColorTexture(0.3, 0.6, 0.45, 0.4)

    local emptyNote = f:CreateFontString(nil, "OVERLAY", "BoostedXPFontDetail")
    emptyNote:SetPoint("CENTER", f, "CENTER", 0, 0)
    emptyNote:SetText("No class quests found for your character.")
    emptyNote:Hide()
    f.emptyNote = emptyNote

    local scroll = CreateFrame("ScrollFrame", "BoostedXPClassScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -64)
    scroll:SetPoint("BOTTOMRIGHT", -32, 44)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(436, 240)
    scroll:SetScrollChild(content)
    f.content = content
    f.scroll = scroll

    -- Bottom action buttons
    local skipAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    skipAll:SetSize(110, 22)
    skipAll:SetPoint("BOTTOMLEFT", 12, 12)
    skipAll:SetText("Skip All Open")
    skipAll:SetScript("OnClick", function()
        local avail = BXP:AvailableClassLines()
        for _, l in ipairs(avail) do BXP:HideClassLine(l) end
        ClassUI:Update()
    end)
    f.skipAllBtn = skipAll

    local unhideAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    unhideAll:SetSize(90, 22)
    unhideAll:SetPoint("LEFT", skipAll, "RIGHT", 6, 0)
    unhideAll:SetText("Unhide All")
    unhideAll:SetScript("OnClick", function()
        local all = BXP:ClassQuestLines()
        for _, l in ipairs(all) do BXP:UnhideClassLine(l) end
        ClassUI:Update()
    end)
    f.unhideAllBtn = unhideAll

    local guideBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    guideBtn:SetSize(140, 22)
    guideBtn:SetPoint("LEFT", unhideAll, "RIGHT", 6, 0)
    guideBtn:SetText("Toggle Class Guide")
    guideBtn:SetScript("OnClick", function()
        BXP:ToggleClassGuide()
        f:Hide()
    end)
    f.guideBtn = guideBtn

    local closeBtn2 = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    closeBtn2:SetSize(70, 22)
    closeBtn2:SetPoint("BOTTOMRIGHT", -12, 12)
    closeBtn2:SetText("Close")
    closeBtn2:SetScript("OnClick", function() f:Hide() end)
    f.closeBtn2 = closeBtn2

    if UISpecialFrames then
        table.insert(UISpecialFrames, "BoostedXPClassUI")
    end

    f.rows = rows
    frame = f
    BXP.classUIFrame = f
    return f
end

local function getOrCreateRow(i, parent)
    if rows[i] then return rows[i] end

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(436, 28)

    local title = row:CreateFontString(nil, "OVERLAY", "BoostedXPFontDetail")
    title:SetPoint("LEFT", 4, 0)
    title:SetPoint("RIGHT", -150, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    row.title = title

    local followBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    followBtn:SetSize(65, 20)
    followBtn:SetPoint("RIGHT", -75, 0)
    followBtn:SetText("Follow")
    row.followBtn = followBtn

    local skipBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    skipBtn:SetSize(68, 20)
    skipBtn:SetPoint("RIGHT", -2, 0)
    skipBtn:SetText("Skip")
    row.skipBtn = skipBtn

    rows[i] = row
    return row
end

function ClassUI:Update()
    local f = createClassWindow()
    local all = BXP:ClassQuestLines()
    local level = Api.plain(UnitLevel("player")) or 1
    local class = Api.plain(select(2, UnitClass("player"))) or "Class"

    f.title:SetText(("Class Quests (%s)"):format(class:sub(1, 1):upper() .. class:sub(2):lower()))

    if #all == 0 then
        f.emptyNote:Show()
        f.scroll:Hide()
        f.skipAllBtn:Disable()
        f.unhideAllBtn:Disable()
        f.guideBtn:Disable()
        for _, r in ipairs(rows) do r:Hide() end
        return
    end

    f.emptyNote:Hide()
    f.scroll:Show()
    f.skipAllBtn:Enable()
    f.unhideAllBtn:Enable()
    f.guideBtn:Enable()

    local y = -2
    for i, line in ipairs(all) do
        local row = getOrCreateRow(i, f.content)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f.content, "TOPLEFT", 0, y)
        y = y - 30

        local completed = BXP:IsClassLineComplete(line)
        local hidden = BXP:IsClassLineHidden(line)
        local locked = level < line.minlevel

        local statusTag
        if completed then
            statusTag = "|cff808080[Completed]|r"
            row.followBtn:Hide()
            row.skipBtn:Hide()
        elseif hidden then
            statusTag = "|cffff6060[Skipped]|r"
            row.followBtn:Show()
            row.followBtn:Enable()
            row.skipBtn:Show()
            row.skipBtn:Enable()
            row.skipBtn:SetText("Unhide")
        elseif locked then
            statusTag = ("|cff808080[Req L%d]|r"):format(line.minlevel)
            row.followBtn:Hide()
            row.skipBtn:Show()
            row.skipBtn:Enable()
            row.skipBtn:SetText("Skip")
        else
            statusTag = "|cff33ff99[Open]|r"
            row.followBtn:Show()
            row.followBtn:Enable()
            row.skipBtn:Show()
            row.skipBtn:Enable()
            row.skipBtn:SetText("Skip")
        end

        row.title:SetText(("%d. %s %s (L%d)"):format(i, statusTag, line.name, line.minlevel))

        row.followBtn:SetScript("OnClick", function()
            BXP:UnhideClassLine(line)
            BXP.char.returnGuide = BXP.guide and BXP.guide.id
            local cg = BXP:ClassGuide()
            if cg then
                BXP:SetGuide(cg.id)
                if line.steps and line.steps[1] and line.steps[1].index then
                    BXP:SetCursor(cg, line.steps[1].index)
                    BXP.currentIndex = line.steps[1].index
                    BXP.baseIndex = line.steps[1].index
                    BXP:Refresh()
                end
            end
            f:Hide()
        end)

        row.skipBtn:SetScript("OnClick", function()
            if BXP:IsClassLineHidden(line) then
                BXP:UnhideClassLine(line)
            else
                BXP:HideClassLine(line)
            end
            ClassUI:Update()
        end)

        row:Show()
    end

    for j = #all + 1, #rows do
        rows[j]:Hide()
    end

    f.content:SetHeight(math.max(240, math.abs(y) + 10))
end

function BXP:OpenClassUI()
    local f = createClassWindow()
    ClassUI:Update()
    f:Show()
    return f
end

function ClassUI:Toggle()
    local f = createClassWindow()
    if f:IsShown() then
        f:Hide()
        return false
    else
        self:Update()
        f:Show()
        return true
    end
end

function BXP:ToggleClassQuests()
    if self.ClassUI then
        return self.ClassUI:Toggle()
    end
end
