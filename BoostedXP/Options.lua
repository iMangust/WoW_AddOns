-- The options panel: Esc > Options > AddOns > BoostedXP, or /boost options. The settings the slash commands
-- change, as checkboxes and buttons, for players who look there first (one typed /boost, saw nothing and left).
local _, BXP = ...

local FONT_MIN, FONT_MAX = 10, 24
local PAD = 16

-- The frame the game's options show is `canvas`; the controls sit in `panel`, the child of a scroll frame inside it,
-- since they are taller than the options window leaves room for (the maintainer, 2026-10-20: the page ran off the
-- bottom). The scroll bar's room is on the right.
local canvas = CreateFrame("Frame", "BoostedXPOptions", UIParent)
canvas.name = "BoostedXP"
canvas:Hide()
local scroll = CreateFrame("ScrollFrame", "BoostedXPOptionsScroll", canvas, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -4)
scroll:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -30, 4)
local panel = CreateFrame("Frame", nil, scroll)
panel:SetSize(560, 700)  -- until it is laid out and fitted (below)
scroll:SetScrollChild(panel)
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    self:SetVerticalScroll(math.max(0, math.min(range, (self:GetVerticalScroll() or 0) - delta * 40)))
end)

-- The game's regular sizes, not its small ones (the maintainer found the small text hard to read).
local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", PAD, -PAD)
title:SetText("BoostedXP")
-- Which build this is (the maintainer, 2026-10-11: test builds between releases say their commit).
local version = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 0)
version:SetTextColor(0.6, 0.6, 0.6)
version:SetText(BXP.Api.AddonVersion() and "version " .. BXP.Api.AddonVersion() or "")
-- Text wraps inside the panel: anchored on the right too (the intro had run past the panel's edge).
local function wrapped(text)
    text:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(true)
end

local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
wrapped(intro)
intro:SetText("A step-by-step leveling guide with a waypoint arrow.")  -- the commands are listed at the bottom

-- Each switch reads and writes the saved setting itself, so the panel always shows what the slash commands set.
local SWITCHES = {
    { "Show the guide window (/boost show, /boost hide)",
      function() return BXP.db.window.shown end,
      function(on) BXP.db.window.shown = on; BXP:UpdateWindow() end },
    { "Lock the guide window and arrow: no moving or resizing (/boost lock, /boost unlock)",
      function() return BXP.db.window.locked end,
      function(on) BXP.db.window.locked = on; BXP:UpdateWindow(); BXP:UpdateArrow() end },
    { "Show the waypoint arrow",
      function() return BXP.db.arrow.shown end,
      function(on) BXP.db.arrow.shown = on; BXP:UpdateArrow() end },
    { "Accept and turn in guide quests for me (hold Shift at an NPC to skip it)",
      function() return BXP.db.automation.enabled end,
      function(on) BXP.db.automation.enabled = on end },
    { "Suggest a closer step I can do right now",
      function() return BXP.db.flex end,
      function(on) BXP.db.flex = on; BXP:Refresh() end },
    { "Include dungeon steps (dungeon quests pay far more XP than grinding)",
      function() return not BXP.db.noDungeons end,
      function(on)
          BXP.db.noDungeons = not on or nil
          if on then BXP.db.dungeons = {} end  -- also the ones turned off one by one
          BXP:Refresh()
      end },
    { "Remind me in chat to send my play data (/boost export)",
      function() return BXP.db.remindExport end,
      function(on) BXP.db.remindExport = on end },
}

local checks = {}
local function checkbox(label, get, set)
    local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    local text = cb.Text or cb.text  -- the template's label, where it has one
    if type(text) ~= "table" then
        text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    end
    text:SetFontObject("GameFontHighlight")
    text:SetText(label)
    cb.label, cb.get = label, get
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    checks[#checks + 1] = cb
    return cb, text
end

local last = intro
for i, s in ipairs(SWITCHES) do
    local cb = checkbox(s[1], s[2], s[3])
    cb:SetPoint("TOPLEFT", last, "BOTTOMLEFT", i == 1 and -2 or 0, i == 1 and -14 or -2)
    last = cb
end

-- Level-up announcements (Announce.lua): the label, then the three switches in a row of their own below it (beside
-- it they ran past the scroll frame's right edge: "Yell" was cut off, 2026-10-20).
local announceLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
announceLabel:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 4, -8)
announceLabel:SetText("Announce my level-ups in chat (the first that applies):")
local beside, firstAnnounce
for _, s in ipairs({ { "party", "Party (when grouped)" }, { "say", "Say" }, { "yell", "Yell" } }) do
    local key = s[1]
    local cb, text = checkbox(s[2], function() return BXP.db.announce[key] end,
        function(on) BXP.db.announce[key] = on end)
    if beside then cb:SetPoint("LEFT", beside, "RIGHT", 8, 0) else cb:SetPoint("TOPLEFT", announceLabel, "BOTTOMLEFT", -4, -2) end
    firstAnnounce = firstAnnounce or cb
    beside = text
end
last = firstAnnounce

-- A button at least `width` wide and wide enough for its label, whatever the font (the maintainer, 2026-10-20: "Reset the
-- window's position and size" touched the button's edges).
local BUTTON_PAD = 28
local function fitButton(b, width)
    local label = b.GetFontString and b:GetFontString()
    local text = label and label:GetStringWidth()
    if type(text) == "number" and text + BUTTON_PAD > width then b:SetWidth(text + BUTTON_PAD) end
end

local function button(text, width, onClick)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    fitButton(b, width)
    return b
end

-- Font size of the guide window: - and + rather than a slider, whose templates differ between clients.
local fontLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
fontLabel:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 4, -12)
local function setFont(size)
    BXP.db.window.fontSize = math.max(FONT_MIN, math.min(FONT_MAX, size))
    fontLabel:SetText(("Guide text size: %d"):format(BXP.db.window.fontSize))
    BXP:ApplyFonts()
    BXP:UpdateWindow()
end
local smaller = button("-", 26, function() setFont(BXP.db.window.fontSize - 1) end)
smaller:SetPoint("LEFT", fontLabel, "RIGHT", 10, 0)
local bigger = button("+", 26, function() setFont(BXP.db.window.fontSize + 1) end)
bigger:SetPoint("LEFT", smaller, "RIGHT", 4, 0)

-- Background opacity of the guide window, in tenths: the text stays solid.
local opacityLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
opacityLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -16)
local function setOpacity(value)
    BXP.db.window.opacity = math.floor(math.max(0, math.min(1, value)) * 10 + 0.5) / 10
    opacityLabel:SetText(("Window opacity: %d%%"):format(BXP.db.window.opacity * 100))
    BXP:UpdateWindow()
end
local clearer = button("-", 26, function() setOpacity(BXP.db.window.opacity - 0.1) end)
clearer:SetPoint("LEFT", opacityLabel, "RIGHT", 10, 0)
local darker = button("+", 26, function() setOpacity(BXP.db.window.opacity + 0.1) end)
darker:SetPoint("LEFT", clearer, "RIGHT", 4, 0)

-- Window size: dragging its bottom-right corner sets the same two. The height is the most the window takes: it fills
-- it with as many Coming up steps as fit. Unset, the width follows the text size and the height its two steps.
local widthLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
widthLabel:SetPoint("TOPLEFT", opacityLabel, "BOTTOMLEFT", 0, -16)
local heightLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
heightLabel:SetPoint("TOPLEFT", widthLabel, "BOTTOMLEFT", 0, -16)
local function sizeLabels()
    local db = BXP.db.window
    widthLabel:SetText(db.width and ("Window width: %d"):format(db.width) or "Window width: automatic")
    heightLabel:SetText(db.height and ("Window height: %d"):format(db.height) or "Window height: automatic")
end
local function resize(dw, dh)
    local w, h = BXP:WindowSize()
    local db = BXP.db.window
    BXP:SetWindowSize((db.width or w or 320) + dw, (dw == 0 or db.height) and ((db.height or h or 300) + dh) or nil)
    sizeLabels()
end
local narrower = button("-", 26, function() resize(-20, 0) end)
narrower:SetPoint("LEFT", widthLabel, "RIGHT", 10, 0)
local wider = button("+", 26, function() resize(20, 0) end)
wider:SetPoint("LEFT", narrower, "RIGHT", 4, 0)
local shorter = button("-", 26, function() resize(0, -40) end)
shorter:SetPoint("LEFT", heightLabel, "RIGHT", 10, 0)
local taller = button("+", 26, function() resize(0, 40) end)
taller:SetPoint("LEFT", shorter, "RIGHT", 4, 0)
local sizeHint = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sizeHint:SetPoint("TOPLEFT", heightLabel, "BOTTOMLEFT", 0, -6)
sizeHint:SetText("|cff808080Or drag the guide window's bottom-right corner. A taller window lists more steps coming up.|r")

local pick = button("Pick the guide for my character", 230, function()
    if not BXP:StartWherePlayerIs() then BXP:Print("No guide covers your character yet. Type /boost list.") end
end)
pick:SetPoint("TOPLEFT", sizeHint, "BOTTOMLEFT", -4, -16)
local reset = button("Reset window position and size", 230, function()
    BXP:ResetWindowPosition()
    sizeLabels()
end)
reset:SetPoint("LEFT", pick, "RIGHT", 8, 0)
local export = button("Export my play data", 230, function() BXP.Export.Show() end)
export:SetPoint("TOPLEFT", pick, "BOTTOMLEFT", 0, -8)
local classBtn = button("Class quests", 230, function() BXP:OpenClassUI() end)
classBtn:SetPoint("LEFT", export, "RIGHT", 8, 0)

local help = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
help:SetPoint("TOPLEFT", export, "BOTTOMLEFT", 4, -18)
wrapped(help)
help:SetSpacing(3)
help:SetText(table.concat({
    "/boost - these options; /boost show, /boost hide - the guide window; /boost lock, /boost unlock - keep it in place",
    "/boost next, /boost back - skip the current step, or go back one",
    "/boost class - open class quests window; /boost list, /boost guide <id> - list the guides, or switch to one",
    "/boost feedback <message> - note what's wrong at this step (it goes out with /boost export)",
    "/boost help - every command",
}, "\n"))

-- The scrolled page is as wide as the scroll frame and as tall as its contents, top of the title to bottom of the help.
-- The text wraps once the width is set, so the height is measured a frame later, and again when the frame resizes.
local function fit()
    local width = scroll:GetWidth()
    if width and width > 0 then panel:SetWidth(width) end
    local top, bottom = title:GetTop(), help:GetBottom()
    if top and bottom and top > bottom then
        local scale = panel.GetEffectiveScale and panel:GetEffectiveScale() or 1
        local h = (scale and scale > 0) and ((top - bottom) / scale) or (top - bottom)
        panel:SetHeight(h + 2 * PAD)
    end
end
local function fitSoon()
    fit()
    if C_Timer and C_Timer.After then C_Timer.After(0, fit) end
end
scroll:SetScript("OnSizeChanged", fitSoon)

-- Shown from the game's options or /boost options: always the settings as they are now, from the top.
canvas:SetScript("OnShow", function()
    for _, cb in ipairs(checks) do cb:SetChecked(cb.get() and true or false) end
    fontLabel:SetText(("Guide text size: %d"):format(BXP.db.window.fontSize))
    opacityLabel:SetText(("Window opacity: %d%%"):format(BXP.db.window.opacity * 100))
    sizeLabels()
    scroll:SetVerticalScroll(0)
    fitSoon()
end)

-- The game's options: the Settings API in this client; the older interface options as a fallback.
local category
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    category = Settings.RegisterCanvasLayoutCategory(canvas, canvas.name)
    Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(canvas)
end

function BXP:OpenOptions()
    if InCombatLockdown and InCombatLockdown() then
        return self:Print("The options open after combat. Type /boost again then.")
    end
    if category and Settings.OpenToCategory then
        Settings.OpenToCategory(category.GetID and category:GetID() or category.ID)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(canvas)
    else
        self:Print("No options window in this client: type /boost help for the commands.")
    end
end

BXP.Options = { fitButton = fitButton, announceLabel = announceLabel, reset = reset, canvas = canvas, scroll = scroll, panel = panel, title = title, help = help, fit = fit, version = version, checks = checks, category = category, setFont = setFont, setOpacity = setOpacity, resize = resize, classBtn = classBtn }
