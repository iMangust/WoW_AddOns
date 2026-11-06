-- Level-up announcements: "[BoostedXP] I just leveled from 6 to 7 in 01:02:03!", once, in the first channel switched on
-- that applies: party chat when grouped, else /say, else /yell (BXP.db.announce; party and say on, yell off: no spam
-- when they're all on). The time is the time played at the
-- level, as /played tells it: counted here while logged in, or taken from /played when the player types it. A level
-- the addon didn't see start (installed part way) is announced without a time.
--
-- The client only sends /say and /yell outside instances from a key press or click, never from an event: those wait
-- for the player's next key press or click (a keyboard frame that lets every key through, and clicks on the world).
local _, BXP = ...
local Api = BXP.Api

local SAVE_EVERY = 30
local Announce = {}
BXP.Announce = Announce

local mark  -- GetTime() when BoostedXPCharDB.levelTime.played was last brought up to date

local function record() return BoostedXPCharDB and BoostedXPCharDB.levelTime end

-- Brings the saved time at this level up to date (it's saved on logout and every SAVE_EVERY seconds).
local function catchUp()
    local lt = record()
    if not (lt and mark) then return end
    local now = GetTime()
    lt.played = lt.played + (now - mark)
    mark = now
end

-- Seconds played at the current level, or nil when the addon didn't see the level start.
function Announce.LevelSeconds()
    catchUp()
    local lt = record()
    return lt and lt.whole and lt.played or nil
end

function Announce.Clock(seconds)
    seconds = math.floor(seconds + 0.5)
    return ("%02d:%02d:%02d"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

function Announce.Message(from, to, seconds)
    local took = seconds and (" in %s"):format(Announce.Clock(seconds)) or ""
    return ("[BoostedXP] I just leveled from %d to %d%s!"):format(from, to, took)
end

local function send(msg, chatType)
    local sendChat = C_ChatInfo and C_ChatInfo.SendChatMessage or SendChatMessage
    sendChat(msg, chatType)
end

-- /say and /yell outside instances, waiting for a key press or click.
local pending = {}
local keys = CreateFrame("Frame")
keys:Hide()
keys:EnableKeyboard(true)
keys:SetPropagateKeyboardInput(true)  -- every key still reaches the game; this frame only notices it

local function sendPending()
    if #pending == 0 then return end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end
    for _, p in ipairs(pending) do send(p[1], p[2]) end
    pending = {}
    keys:Hide()
end
keys:SetScript("OnKeyDown", sendPending)
if WorldFrame and WorldFrame.HookScript then WorldFrame:HookScript("OnMouseDown", sendPending) end
Announce.SendPending = sendPending

local function sendOpen(msg, chatType)
    if IsInInstance and IsInInstance() then return send(msg, chatType) end
    pending[#pending + 1] = { msg, chatType }
    keys:Show()
end

local function inParty()
    return IsInGroup(LE_PARTY_CATEGORY_HOME)
end

-- One message: party chat when grouped and on, else /say when on, else /yell when on.
function Announce.LevelUp(from, to, seconds)
    local opts = BXP.db.announce
    local msg = Announce.Message(from, to, seconds)
    if opts.party and inParty() then
        send(msg, "PARTY")
    elseif opts.say then
        sendOpen(msg, "SAY")
    elseif opts.yell then
        sendOpen(msg, "YELL")
    end
end

BXP:On("BXP_READY", function()
    local char, level = BoostedXPCharDB, Api.PlayerLevel()
    local lt = char.levelTime
    if not lt or lt.level ~= level then
        -- A new character is seen from the start; any other level began before the addon counted it.
        local fresh = level == 1 and (Api.plain(UnitXP("player")) or 0) == 0
        char.levelTime = { level = level, played = 0, whole = fresh }
    end
    mark = GetTime()
    C_Timer.NewTicker(SAVE_EVERY, catchUp)
end)

BXP:On("PLAYER_LOGOUT", catchUp)

-- The player typed /played (or something asked for it): the game's own time at this level.
BXP:On("TIME_PLAYED_MSG", function(_, _, thisLevel)
    local lt, played = record(), Api.plain(thisLevel)
    if not (lt and played) then return end
    lt.played, lt.whole, mark = played, true, GetTime()
end)

BXP:On("PLAYER_LEVEL_UP", function(_, level)
    local to = Api.plain(level) or Api.PlayerLevel()
    local seconds = Announce.LevelSeconds()
    BoostedXPCharDB.levelTime = { level = to, played = 0, whole = true }
    mark = GetTime()
    Announce.LevelUp(to - 1, to, seconds)
end)
