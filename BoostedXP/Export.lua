-- /boost export: the play data that improves the routes, as text to paste into the form on
-- boostedxp.com. Addons can't send anything themselves, so this is copy and paste.
-- Readable JSON, so players see exactly what they share: class, race, levels, fights, step
-- times, quests seen (givers, map markers, objective spots), /boost where spots and /boost
-- feedback notes (each with the step it was written at), and guide quests an NPC didn't
-- offer (with the step, level and what was offered instead). No character, realm or account
-- names are included: just a random ID made once per character, so the route tools keep
-- only a character's newest export (each one holds everything before it).
local _, BXP = ...
local Api = BXP.Api

local Export = {}
BXP.Export = Export

local MAX_CHARS = 240000 -- boostedxp.com takes up to 250,000
local PACKED = "BXPZ1:"   -- starts a packed export: the JSON deflated and base64-encoded (boostedxp.com unpacks it)
local SPOTS_KEPT = 12    -- objective spots per quest, when the export is over the limit (30 are recorded)
local MAX_FEEDBACK = 50  -- notes kept: the newest
local MAX_MESSAGE = 250  -- characters per note (a chat line holds 255)

local function isList(t)
    local n = #t
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode(v, out)
    local kind = type(v)
    if kind == "table" then
        if next(v) ~= nil and isList(v) then
            out[#out + 1] = "["
            for i, x in ipairs(v) do
                if i > 1 then out[#out + 1] = "," end
                encode(x, out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                encode(tostring(k), out)
                out[#out + 1] = ":"
                encode(v[k], out)
            end
            out[#out + 1] = "}"
        end
    elseif kind == "string" then
        out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c)
            return ESCAPES[c] or ("\\u%04x"):format(c:byte())
        end) .. '"'
    elseif kind == "number" then
        out[#out + 1] = (v % 1 == 0 and v >= -2^53 and v <= 2^53) and ("%d"):format(v) or ("%.6g"):format(v)
    elseif kind == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = "null"
    end
end
Export.encode = function(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

local function stepSplits()
    local out = {}
    for gid, steps in pairs(BoostedXPCharDB.splits or {}) do
        for key, s in pairs(steps) do
            if type(key) == "string" then
                out[gid] = out[gid] or {}
                out[gid][key] = s
            end
        end
    end
    return out
end

-- 16 random hex digits, made on the first export and kept: not derived from any name.
local function characterID()
    if not BoostedXPCharDB.exportID then
        local digits = {}
        for i = 1, 16 do digits[i] = ("%x"):format(math.random(0, 15)) end
        BoostedXPCharDB.exportID = table.concat(digits)
    end
    return BoostedXPCharDB.exportID
end

local function tail(list, n)
    local out = {}
    for i = math.max(1, #list - n + 1), #list do out[#out + 1] = list[i] end
    return out
end

-- /boost feedback <message>: a player's note about the route, kept with the step on screen and
-- where they stood, so a report like "the NPC isn't here" points at the step that's wrong.
-- Returns the note, or nil when the message is empty.
function Export.AddFeedback(message)
    message = strtrim(message or "")
    if message == "" then return nil end
    local guide, step = BXP.guide, BXP:CurrentStep()
    local mapID, x, y = Api.PlayerMapPosition()
    local note = {
        t = GetServerTime(), level = Api.PlayerLevel(), message = message:sub(1, MAX_MESSAGE),
        guide = guide and guide.id, index = step and BXP.currentIndex, step = step and step.key,
        stepText = step and (BXP:StepText(step):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")),
        mapID = mapID, x = x and math.floor(x * 1000 + 0.5) / 10, y = y and math.floor(y * 1000 + 0.5) / 10,
    }
    BoostedXPCharDB.feedback = BoostedXPCharDB.feedback or {}
    local list = BoostedXPCharDB.feedback
    list[#list + 1] = note
    while #list > MAX_FEEDBACK do table.remove(list, 1) end
    return note
end

-- n entries of a list spread over all of it, the first and the last included.
local function evenly(list, n)
    if n <= 0 or #list == 0 then return {} end
    if n == 1 then return { list[1] } end
    local out = {}
    for i = 1, n do out[i] = list[1 + math.floor((i - 1) * (#list - 1) / (n - 1) + 0.5)] end
    return out
end

-- The quests with at most cap objective spots each (copies: the saved data stays as it is).
local function thinned(quests, cap)
    local out = {}
    for id, q in pairs(quests or {}) do
        if q.spots and #q.spots > cap then
            local copy = {}
            for k, v in pairs(q) do copy[k] = v end
            copy.spots = evenly(q.spots, cap)
            out[id] = copy
        else
            out[id] = q
        end
    end
    return out
end

-- The export text. Over the site's limit, what goes first is what the routes use least: the XP events (only a
-- debug printout reads them), then spots beyond SPOTS_KEPT per quest, and only then the oldest fights, halving them
-- until it fits (a long run had kept 1 fight, 2026-10-12: its quests and step times filled the form).
function Export.Build()
    local db, log = BoostedXPCharDB, BoostedXPCharDB.log or {}
    local version, build = GetBuildInfo()
    local fights, xp, cap = #(log.fights or {}), #(log.xp or {}), nil
    local function encode()
        return Export.encode({
            format = "BoostedXP export", version = 1, character = characterID(),
            addon = Api.AddonVersion(),
            -- the client's language: a Russian client's quest titles and NPC names are Russian, which the planner
            -- leaves out of English guides
            client = { version = version, build = tonumber(build) }, locale = GetLocale(),
            class = log.class or Api.plain(select(2, UnitClass("player"))),
            race = Api.plain(select(2, UnitRace("player"))), level = Api.PlayerLevel(),
            log = { levels = log.levels, fights = tail(log.fights or {}, fights), xp = tail(log.xp or {}, xp) },
            splits = stepSplits(), playtime = db.playtime, quests = cap and thinned(db.quests, cap) or db.quests,
            places = db.places, feedback = db.feedback, notOffered = db.notOffered,
        })
    end
    local text = encode()
    if #text > MAX_CHARS and xp > 0 then xp = 0; text = encode() end
    if #text > MAX_CHARS then cap = SPOTS_KEPT; text = encode() end
    while #text > MAX_CHARS and fights > 0 do
        fights = math.floor(fights / 2)
        text = encode()
    end
    while #text > MAX_CHARS and (cap or 0) > 0 do
        cap = math.floor((cap or SPOTS_KEPT) / 2)
        text = encode()
    end
    return text
end

-- The export packed to paste fast: the client takes 30-60 seconds to paste 240,000 characters into an edit box
-- (2026-10-17; line breaks didn't help), and the JSON deflates to a fifth or less. Nil if the client lacks the API,
-- or it fails, or packing doesn't make it shorter: the readable text goes out then.
function Export.Pack(text)
    local util = C_EncodingUtil
    if not (util and util.CompressString and util.EncodeBase64) then return nil end
    local ok, packed = pcall(function() return PACKED .. util.EncodeBase64(util.CompressString(text)) end)
    if ok and type(packed) == "string" and #packed < #text then return packed end
end

local frame
local function window()
    if frame then return frame end
    frame = CreateFrame("Frame", "BoostedXPExport", UIParent, "BackdropTemplate")
    frame:SetSize(560, 360)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    frame:SetBackdropColor(0, 0, 0, 0.9)
    frame:SetBackdropBorderColor(0.2, 0.8, 0.5, 0.8)
    frame:EnableMouse(true)
    local help = frame:CreateFontString(nil, "OVERLAY", "BoostedXPFontDetail")
    help:SetPoint("TOPLEFT", 10, -10)
    help:SetPoint("RIGHT", frame, "RIGHT", -10, 0)
    help:SetJustifyH("LEFT")
    help:SetText("Thanks for helping! Press Ctrl+C to copy, then paste it at boostedxp.com. "
        .. "No character, realm or account names are in it. It's packed so it pastes fast; boostedxp.com can show what's in it.")
    frame.help = help
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -54)
    scroll:SetPoint("BOTTOMRIGHT", -30, 36)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject("BoostedXPFontDetail")
    edit:SetWidth(510)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    scroll:SetScrollChild(edit)
    frame.edit = edit
    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(80, 22)
    close:SetPoint("BOTTOMRIGHT", -10, 8)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)
    return frame
end

-- A chat line asking for an export on reaching level 5 and 10, then every level after 10 (the maintainer's call,
-- 2026-10-08): addons can't send anything themselves, so players have to be asked. Says how many /boost feedback
-- notes wait for it; /boost remind off stops it.
function Export.Remind(level)
    if not BXP.db.remindExport or not level then return end
    if level <= 10 and level % 5 ~= 0 then return end
    local char = BoostedXPCharDB
    local notes = 0
    for _, note in ipairs(char.feedback or {}) do
        if (note.t or 0) > (char.exportedAt or 0) then notes = notes + 1 end
    end
    local waiting = notes == 1 and " Your feedback note goes out with it."
        or notes > 1 and (" Your %d feedback notes go out with it."):format(notes) or ""
    BXP:Print(("Level %d! Help improve the routes: type /boost export and paste it at boostedxp.com.%s "
        .. "|cff808080(/boost remind off to stop these)|r"):format(level, waiting))
end

BXP:On("PLAYER_LEVEL_UP", function(_, level) Export.Remind(Api.plain(level) or Api.PlayerLevel()) end)

function Export.Show()
    local text = Export.Build()
    local packed = Export.Pack(text)
    BoostedXPCharDB.exportedAt = GetServerTime()
    local shown = packed or text
    local f = window()
    f.edit:SetText(shown)
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
    BXP:Print(("export ready: %d characters, selected; press Ctrl+C to copy."):format(#shown))
    return shown
end
