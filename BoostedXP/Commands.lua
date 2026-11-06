-- Slash commands and key bindings.
local _, BXP = ...
local Api = BXP.Api

BINDING_HEADER_BOOSTEDXP = "BoostedXP"
BINDING_NAME_BOOSTEDXP_NEXT = "Next step"
BINDING_NAME_BOOSTEDXP_BACK = "Previous step"
BINDING_NAME_BOOSTEDXP_TOGGLE = "Toggle guide window"
BINDING_NAME_BOOSTEDXP_CLASS = "Toggle class quests"
BINDING_NAME_BOOSTEDXP_ARROW = "Toggle waypoint arrow"

local function onOff(arg, current)
    if arg == "on" then return true end
    if arg == "off" then return false end
    return not current
end

local function state(v) return v and "|cff33ff99on|r" or "|cffff6060off|r" end

local commands = {}

function commands.next() BXP:NextStep() end
function commands.back() BXP:PreviousStep() end

function commands.reset()
    BXP:ResetGuide()
    BXP:Print("Progress reset for this guide.")
end

function commands.list()
    for _, g in ipairs(BXP.guideList) do
        BXP:Print(("%s - %s (%s, levels %d-%d)%s"):format(g.id, g.name, g.faction, g.levels[1], g.levels[2],
                                                         g.draft and (g.played and (" - draft, about %d%% played"):format(
                                                             math.floor(g.played * 100 + 0.5)) or " - draft, not played yet") or ""))
    end
end

function commands.guide(id)
    if id == "current" then
        if not BXP:StartWherePlayerIs() then BXP:Print("No guide covers your character yet. Type /boost list.") end
    elseif not BXP:SetGuide(id) then
        BXP:Print("Unknown guide '" .. (id or "") .. "'. Type /boost list, or /boost guide current.")
    end
end

function commands.arrow(subcmd, arg)
    if subcmd == "scale" then
        local scale = tonumber(arg)
        if not scale then
            local current = BXP.db.arrow.scale or 1
            return BXP:Print(("Arrow scale is %.2f. Use /boost arrow scale <0.5-2.0>."):format(current))
        end
        scale = math.max(0.5, math.min(2.0, scale))
        BXP.db.arrow.scale = scale
        BXP:UpdateArrow()
        return BXP:Print(("Arrow scale set to %.2f."):format(scale))
    end
    if subcmd == "on" or subcmd == "off" then
        BXP.db.arrow.shown = (subcmd == "on")
        BXP:UpdateArrow()
        return BXP:Print("Waypoint arrow " .. state(BXP.db.arrow.shown) .. ".")
    end
    local shown = BXP:ToggleArrow()
    BXP:Print("Waypoint arrow " .. state(shown) .. ".")
end

function commands.font(arg)
    local size = tonumber(arg)
    if not size or size < 10 or size > 24 then
        return BXP:Print("Font size is " .. BXP.db.window.fontSize .. ". Use /boost font <10-24>.")
    end
    BXP.db.window.fontSize = math.floor(size)
    BXP:ApplyFonts()
    BXP:UpdateWindow()
end

function commands.log(arg)
    if arg == "reset" then
        BXP.Log.Reset()
        return BXP:Print("Play log cleared.")
    end
    local lines = BXP.Log.Summary()
    if #lines == 0 then return BXP:Print("Nothing logged yet. Play for a bit: fights, rests and travel are recorded.") end
    for _, line in ipairs(lines) do BXP:Print(line) end
end

function commands.auto(arg)
    local auto = BXP.db.automation
    auto.enabled = onOff(arg, auto.enabled)
    BXP:Print("Quest automation " .. state(auto.enabled) .. ". Hold Shift at an NPC to skip it.")
end

-- What turning a dungeon off costs: the grinding the guides add to make up its XP.
local function skipWarning(key)
    local total, parts = BXP:SkippedDungeonGrind(key)
    if total > 0 then
        BXP:Print(("|cffff9900Without dungeons the guide will have you grind significantly more: about %s (%s).|r")
            :format(BXP.FormatDuration(total), table.concat(parts, ", ")))
        BXP:Print("Dungeon quests pay far more XP than their mobs. Turn them back on with /boost dungeons on.")
    else
        BXP:Print("No dungeon is ahead in your guides yet; nothing to make up.")
    end
end

function commands.dungeons(arg)
    if arg == "on" or arg == "off" then
        BXP.db.noDungeons = arg == "off" or nil
        if arg == "on" then BXP.db.dungeons = {} end  -- also the ones turned off one by one
        BXP:Print("Dungeon steps " .. state(arg == "on"))
        if arg == "off" then skipWarning() end
        return BXP:Refresh()
    end
    BXP:Print("Dungeon steps are " .. state(not BXP.db.noDungeons) .. " (/boost dungeons on|off).")
    for _, d in ipairs(BXP.Dungeons) do
        local levels = d.maxLevel and ("%d-%d"):format(d.minLevel, d.maxLevel) or (d.minLevel .. "+")
        BXP:Print(("%s %s (%s): %s"):format(d.key, d.name, levels, state(BXP:DungeonOn(d.key))))
    end
    BXP:Print("Turn one off or on with /boost dungeon <key> off|on")
end

function commands.dungeon(key, arg)
    key = key and key:upper()
    local d = key and BXP.DungeonsByKey[key]
    if not d then return commands.dungeons() end
    local on = onOff(arg, BXP:DungeonOn(key))
    if on then BXP.db.dungeons[key] = nil else BXP.db.dungeons[key] = false end  -- nil is the default, on
    BXP:Print(d.name .. " steps " .. state(on))
    if not on then skipWarning(key) end
    BXP:Refresh()
end

-- Prints the player's position as a step location, for writing and fixing routes.
local MAX_PLACES = 200  -- positions kept from /boost where

-- Prints the position and keeps it (with an optional note, e.g. /boost where weapon) in
-- BoostedXPCharDB.places, where tools/bxp calibrate reads it after a /reload.
function commands.where(...)
    local mapID, x, y = BXP.Api.PlayerMapPosition()
    if not mapID then return BXP:Print("Position unavailable here.") end
    local info = C_Map.GetMapInfo(mapID)
    local zone = info and info.name or "?"
    BXP:Print(('at = { %.1f, %.1f, "%s" }  (uiMapID %d)'):format(x * 100, y * 100, zone, mapID))
    local note = table.concat({ ... }, " ")
    BoostedXPCharDB.places = BoostedXPCharDB.places or {}
    local places = BoostedXPCharDB.places
    places[#places + 1] = { t = GetServerTime(), mapID = mapID, zone = zone,
                            x = math.floor(x * 1000 + 0.5) / 10, y = math.floor(y * 1000 + 0.5) / 10,
                            note = note ~= "" and note or nil }
    while #places > MAX_PLACES do table.remove(places, 1) end
end

-- /boost probe <questID ...>: what the game's API reveals about quests, including ones not
-- in the log (a development experiment: which calls give positions?). Results go to
-- BoostedXPCharDB.probe and chat. Each call is guarded: some don't exist in every client.
local PROBE_MAPS = { 1411, 1413, 1412, 1442, 1414 }  -- Durotar, Barrens, Mulgore, Stonetalon, Kalimdor

local function try(fn, ...)
    if type(fn) ~= "function" then return "missing" end
    local out = { pcall(fn, ...) }
    if not out[1] then return "error" end
    local vals = {}
    for i = 2, #out do
        local v = BXP.Api.plain(out[i])
        if type(v) == "table" then
            local parts = {}
            for k, x in pairs(v) do
                local px = BXP.Api.plain(x)
                if type(px) ~= "table" then parts[#parts + 1] = tostring(k) .. "=" .. tostring(px) end
            end
            table.sort(parts)
            v = "{" .. table.concat(parts, " ") .. "}"
        end
        vals[#vals + 1] = tostring(v)
    end
    return #vals > 0 and table.concat(vals, ", ") or "nothing"
end

local function probe(id)
    local Q, here = C_QuestLog, BXP.Api.PlayerMapPosition()
    local r = { inLog = try(Q.GetLogIndexForQuestID, id), title = try(Q.GetTitleForQuestID, id),
                objectives = try(Q.GetQuestObjectives, id), waypoint = try(Q.GetNextWaypoint, id),
                poi = try(QuestPOIGetIconInfo, id) }
    for _, mapID in ipairs(here and { here, unpack(PROBE_MAPS) } or PROBE_MAPS) do
        r["waypoint@" .. mapID] = try(Q.GetNextWaypointForMap, id, mapID)
        r["questLine@" .. mapID] = try(C_QuestLine and C_QuestLine.GetQuestLineInfo, id, mapID)
        r["task@" .. mapID] = try(C_TaskQuest and C_TaskQuest.GetQuestLocation, id, mapID)
    end
    BoostedXPCharDB.probe = BoostedXPCharDB.probe or {}
    BoostedXPCharDB.probe[id] = r
    local found = {}
    for k, v in pairs(r) do
        if v ~= "missing" and v ~= "nothing" and v ~= "error" and k ~= "inLog" and k ~= "title" and k ~= "objectives" then
            found[#found + 1] = k
        end
    end
    table.sort(found)
    BXP:Print(("probe %d %s: %s"):format(id, r.title, #found > 0 and table.concat(found, ", ") or "no positions"))
end

function commands.probe(...)
    local ids = {}
    for _, a in ipairs({ ... }) do
        if tonumber(a) then ids[#ids + 1] = tonumber(a) end
        if a == "log" and C_QuestLog.GetNumQuestLogEntries then  -- compare: quests the player has
            for i = 1, BXP.Api.plain(C_QuestLog.GetNumQuestLogEntries()) or 0 do
                local info = C_QuestLog.GetInfo(i)
                local id = info and not BXP.Api.plain(info.isHeader) and BXP.Api.plain(info.questID)
                if id and id > 0 and #ids < 12 then ids[#ids + 1] = id end
            end
        end
    end
    if #ids == 0 then return BXP:Print("/boost probe <questID ...>") end
    for _, id in ipairs(ids) do
        if C_QuestLog.RequestLoadQuestByID then pcall(C_QuestLog.RequestLoadQuestByID, id) end
    end
    BXP:Print("probing " .. #ids .. " quests in 3 s (asking the server for their data first)")
    C_Timer.After(3, function() for _, id in ipairs(ids) do probe(id) end end)
end

function commands.class(action, ...)
    local g = BXP:ClassGuide()
    if not g then
        return BXP:Print("No class quests are available for your character right now.")
    end

    if BXP.guide and BXP.guide.side and (not action or action == "back" or action == "leave") then
        return BXP:ToggleClassGuide()
    end

    if action == "guide" or action == "toggle" then
        return BXP:ToggleClassGuide()
    end

    if not action or action == "" or action == "ui" or action == "show" or action == "window" or action == "open" then
        return BXP:OpenClassUI()
    end

    local rawArgs = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v and v ~= "" then rawArgs[#rawArgs + 1] = v end
    end
    local target = #rawArgs > 0 and table.concat(rawArgs, " ") or nil

    if tonumber(action) and (target == "skip" or target == "hide") then
        action, target = target, action
    elseif tonumber(action) and (target == "unhide" or target == "show") then
        action, target = target, action
    elseif tonumber(action) and (target == "follow") then
        action, target = "follow", action
    end

    if action == "skip" or action == "hide" then
        local arg = target
        local avail = BXP:AvailableClassLines(g)
        local unhiddenAvail = {}
        for _, l in ipairs(avail) do
            if not BXP:IsClassLineHidden(l) then unhiddenAvail[#unhiddenAvail + 1] = l end
        end
        if not arg or arg == "" then
            if #unhiddenAvail == 0 then
                return BXP:Print("No available class quest lines to skip.")
            end
            if #unhiddenAvail == 1 then
                local line = unhiddenAvail[1]
                BXP:HideClassLine(line)
                if BXP.ClassUI and BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.ClassUI:Update() end
                return BXP:Print(("Class quest line '%s' (level %d) hidden. Type /boost class unhide 1 to bring it back."):format(line.name, line.minlevel))
            end
            return BXP:Print("Type /boost class skip <#|all> to skip an available class quest line.")
        end
        if arg == "all" then
            if #unhiddenAvail == 0 then return BXP:Print("No available class quest lines to skip.") end
            for _, l in ipairs(unhiddenAvail) do BXP:HideClassLine(l) end
            if BXP.ClassUI and BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.ClassUI:Update() end
            return BXP:Print("All available class quest lines skipped.")
        end
        local line, idx = BXP:FindClassLine(arg, g)
        if not line then
            return BXP:Print("Unknown class quest line '" .. arg .. "'. Type /boost class to view them.")
        end
        BXP:HideClassLine(line)
        if BXP.ClassUI and BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.ClassUI:Update() end
        local tag = idx and (tostring(idx) .. " ") or ""
        return BXP:Print(("Class quest line %s'%s' (level %d) hidden. Type /boost class unhide %s to bring it back."):format(
            tag, line.name, line.minlevel, idx and tostring(idx) or line.name))
    end

    if action == "unhide" or action == "show" then
        local arg = target
        local all = BXP:ClassQuestLines(g)
        local hiddenList = {}
        for _, l in ipairs(all) do
            if BXP:IsClassLineHidden(l) then hiddenList[#hiddenList + 1] = l end
        end
        if not arg or arg == "" then
            if #hiddenList == 0 then
                return BXP:Print("No class quest lines are currently hidden.")
            end
            if #hiddenList == 1 then
                local line = hiddenList[1]
                BXP:UnhideClassLine(line)
                if BXP.ClassUI and BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.ClassUI:Update() end
                return BXP:Print(("Class quest line '%s' (level %d) unhidden."):format(line.name, line.minlevel))
            end
            return BXP:Print("Type /boost class unhide <#|all> to unhide a class quest line.")
        end
        if arg == "all" then
            if #hiddenList == 0 then return BXP:Print("No class quest lines are currently hidden.") end
            for _, l in ipairs(all) do BXP:UnhideClassLine(l) end
            if BXP.ClassUI and BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.ClassUI:Update() end
            return BXP:Print("All class quest lines unhidden.")
        end
        local line, idx = BXP:FindClassLine(arg, g, true)
        if not line then
            return BXP:Print("Unknown class quest line '" .. arg .. "'. Type /boost class to view them.")
        end
        BXP:UnhideClassLine(line)
        if BXP.ClassUI and BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.ClassUI:Update() end
        local tag = idx and (tostring(idx) .. " ") or ""
        return BXP:Print(("Class quest line %s'%s' (level %d) unhidden."):format(tag, line.name, line.minlevel))
    end

    if action == "follow" or tonumber(action) then
        local arg = action == "follow" and (target or "1") or action
        local line = BXP:FindClassLine(arg, g)
        if not line then
            return BXP:Print("Unknown class quest line '" .. tostring(arg) .. "'. Type /boost class to view them.")
        end
        BXP:UnhideClassLine(line)
        BXP.char.returnGuide = BXP.guide and BXP.guide.id
        BXP:SetGuide(g.id)
        if line.steps and line.steps[1] and line.steps[1].index then
            BXP:SetCursor(g, line.steps[1].index)
            BXP.currentIndex = line.steps[1].index
            BXP.baseIndex = line.steps[1].index
            BXP:Refresh()
        end
        if BXP.classUIFrame and BXP.classUIFrame:IsShown() then BXP.classUIFrame:Hide() end
        return BXP:Print(("Following %s in %s. Type /boost class to return to your guide."):format(line.name, g.name))
    end

    if action == "list" or action == "text" then
        local all = BXP:ClassQuestLines(g)
        local level = BXP.Api.plain(UnitLevel("player")) or 1
        BXP:Print("Class quest lines for your character:")
        for i, l in ipairs(all) do
            local complete = BXP:IsClassLineComplete(l)
            local hidden = BXP:IsClassLineHidden(l)
            local status
            if complete then
                status = "|cff808080[completed]|r"
            elseif hidden then
                status = "|cffff6060[hidden]|r"
            elseif level < l.minlevel then
                status = ("|cff808080[level %d]|r"):format(l.minlevel)
            else
                status = "|cff33ff99[open]|r"
            end
            BXP:Print(("%d. %s %s (level %d)"):format(i, status, l.name, l.minlevel))
        end
        return BXP:Print("Type /boost class skip <#> to skip, or /boost class unhide <#> to unhide.")
    end

    if action == "help" then
        BXP:Print("/boost class - open the class quests UI window")
        BXP:Print("/boost class skip <#> | hide <#> - skip a class quest line so the UI won't prompt you")
        BXP:Print("/boost class unhide <#> | show <#> - unhide a previously skipped class quest line")
        BXP:Print("/boost class follow <#> - switch to your class guide to follow that quest line")
        BXP:Print("/boost class list - list all class quest lines in text")
        BXP:Print("/boost class guide - toggle between your class guide and your main guide")
        return
    end

    return BXP:OpenClassUI()
end

-- What the guide sees for the current step: for working out why a step doesn't move on.
function commands.status()
    local guide, step = BXP.guide, BXP:CurrentStep()
    if not (guide and step) then return BXP:Print("No current step.") end
    local done = BXP:DoneTable(guide.id)[step.key]
    BXP:Print(("%s, step %s (shown %s), key %s, marked %s, applies %s, done by the game %s, clear %s"):format(
        guide.id, tostring(BXP.baseIndex), tostring(BXP.currentIndex), step.key,
        done == nil and "open" or tostring(done), tostring(BXP:StepApplies(step)), tostring(BXP:IsStepSatisfied(step)),
        tostring(BXP:IsStepClear(step))))
    for _, id in ipairs(step.quests or {}) do
        local bits = { "in log " .. tostring(Api.IsQuestInLog(id)), "ready " .. tostring(Api.IsQuestReady(id)),
                       "turned in " .. tostring(Api.IsQuestTurnedIn(id)), "dropped " .. tostring(BXP:IsDropped(id)) }
        BXP:Print(("  %d %s: %s"):format(id, tostring(Api.GetQuestTitle(id)), table.concat(bits, ", ")))
        for _, o in ipairs(Api.GetObjectives(id)) do
            BXP:Print(("    %s [%s]"):format(o.text, o.finished and "done" or "open"))
        end
    end
end

function commands.pin(arg)
    if arg == "all" or arg == "off" or arg == "travel" then
        BXP.db.pinMode = arg
    else
        BXP:Print("Map pin: " .. BXP.db.pinMode .. ". /boost pin travel (default: only steps the game doesn't mark), "
            .. "all, or off.")
        return
    end
    BXP:Print("Map pin: " .. arg)
    BXP:SyncPin()
end

function commands.flex(arg)
    BXP.db.flex = onOff(arg, BXP.db.flex)
    BXP:Print("Flex (the closest step you can do now) " .. state(BXP.db.flex))
    BXP:Refresh()
end

function commands.flights() BXP:PrintFlights() end
function commands.export() BXP.Export.Show() end
function commands.options() BXP:OpenOptions() end

function commands.show()
    BXP.db.window.shown = true
    BXP:UpdateWindow()
    BXP:Print("Guide window shown. /boost hide hides it.")
end

function commands.lock()
    BXP.db.window.locked = true
    BXP:UpdateWindow()
    BXP:UpdateArrow()
    BXP:Print("Guide window and arrow locked: they can't be moved or resized. /boost unlock frees them.")
end

function commands.unlock()
    BXP.db.window.locked = false
    BXP:UpdateWindow()
    BXP:UpdateArrow()
    BXP:Print("Guide window and arrow unlocked: drag them to move them; the window's bottom-right corner resizes it.")
end

function commands.hide()
    BXP.db.window.shown = false
    BXP:UpdateWindow()
    BXP:Print("Guide window hidden. /boost show brings it back.")
end

function commands.toggle()
    local shown = BXP:ToggleWindow()
    if shown then
        BXP:Print("Guide window shown. /boost hide hides it.")
    else
        BXP:Print("Guide window hidden. /boost show brings it back.")
    end
end
commands.t = commands.toggle

function commands.scale(arg)
    local scale = tonumber(arg)
    if not scale then
        local current = BXP.db.window.scale or 1
        return BXP:Print(("Guide window scale is %.2f. Use /boost scale <0.5-2.0>."):format(current))
    end
    scale = math.max(0.5, math.min(2.0, scale))
    BXP.db.window.scale = scale
    BXP:UpdateWindow()
    BXP:Print(("Guide window scale set to %.2f."):format(scale))
end

function commands.remind(arg)
    BXP.db.remindExport = onOff(arg, BXP.db.remindExport)
    BXP:Print("Export reminders (levels 5 and 10, then every level) " .. state(BXP.db.remindExport))
end

-- /boost announce [party|say|yell] [on|off]: one channel, or all of them; alone, how they stand.
function commands.announce(which, arg)
    local opts = BXP.db.announce
    if which == "on" or which == "off" then
        opts.party, opts.say, opts.yell = which == "on", which == "on", false
    elseif which == "party" or which == "say" or which == "yell" then
        opts[which] = onOff(arg, opts[which])
    elseif which then
        return BXP:Print("Type /boost announce [party|say|yell] [on|off].")
    end
    BXP:Print(("Level-up announcements, the first that applies: party %s (when grouped), say %s, yell %s")
        :format(state(opts.party), state(opts.say), state(opts.yell)))
end

-- Gets the message as typed (the dispatcher lowercases and splits everything else).
function commands.feedback(message)
    local note = BXP.Export.AddFeedback(message)
    if not note then
        return BXP:Print("Type /boost feedback <what's wrong or missing>, at the step it's about.")
    end
    local where = note.step and ("step %d of %s"):format(note.index, BXP.guide.name) or "no guide step"
    BXP:Print(("Thanks! Noted at %s. It goes out with your next /boost export."):format(where))
end

function commands.help()
    BXP:Print("/boost - the options (also under Esc > Options > AddOns)")
    BXP:Print("/boost show | hide | toggle - the guide window; /boost scale <0.5-2.0> - adjust window scale")
    BXP:Print("/boost lock | unlock - keep the window and arrow from being moved or resized")
    BXP:Print("/boost next | back | reset | list | guide <id> | guide current (pick up where you stand)")
    BXP:Print("/boost class [skip|unhide|follow|list] - view, skip, or follow available class quest lines")
    BXP:Print("/boost status | arrow [scale] | pin [travel|all|off] | font <size> | auto [on|off] | flex [on|off] | dungeons [on|off] | dungeon <key> [on|off] | where [note] | log [reset]")
    BXP:Print("/boost flights - the flight paths the guide knows you have, and whether flying beats walking to this step")
    BXP:Print("/boost export - your play data, to paste at boostedxp.com and improve the routes")
    BXP:Print("/boost feedback <message> - note what's wrong at this step; it goes out with your next export")
    BXP:Print("/boost remind [on|off] - the chat reminder to export (levels 5 and 10, then every level)")
    BXP:Print("/boost announce [party|say|yell] [on|off] - tell others when you level up, and how long the level took")
end

SLASH_BOOSTEDXP1 = "/boost"
SLASH_BOOSTEDXP2 = "/boostedxp"
SlashCmdList.BOOSTEDXP = function(msg)
    msg = strtrim(msg or "")
    local cmd, a, b, c, d, e, f = strsplit(" ", msg:lower())
    if cmd == "" then return BXP:OpenOptions() end  -- a new player's first try: the options, which say the rest
    if cmd == "feedback" then return commands.feedback(msg:match("^%S+%s*(.*)$")) end
    local fn = commands[cmd]
    if fn then fn(a, b, c, d, e, f) else commands.help() end
end
