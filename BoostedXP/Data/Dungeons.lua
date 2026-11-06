-- Dungeons a route can include. Steps tagged `dungeon = "<key>"` show unless the player turned
-- dungeons off (/boost dungeons off, or /boost dungeon <key> off); steps tagged `nodungeon = "<key>"`
-- (a catch-up grind) show only then. Levels are Forever's recommended ranges where known.
-- Keys match the planner's (tools/goplanner/planner/dungeons.go).
local _, BXP = ...

BXP.Dungeons = {
    { key = "RFC", name = "Ragefire Chasm", minLevel = 13 },
    { key = "HOT", name = "The Hall of Thanes", minLevel = 13, maxLevel = 18 },
    { key = "ROL", name = "Ruins of Lordaeron", minLevel = 15, maxLevel = 20 },
    { key = "WC", name = "Wailing Caverns", minLevel = 17 },
    { key = "DM", name = "The Deadmines", minLevel = 17 },  -- Classic's range: Forever's not seen yet
    { key = "SFK", name = "Shadowfang Keep", minLevel = 21 },
    { key = "BFD", name = "Blackfathom Deeps", minLevel = 22 },
    { key = "STOCKS", name = "The Stockades", minLevel = 24 },
    { key = "EXW", name = "Excavation Site: Wetlands", minLevel = 24, maxLevel = 29 },
    { key = "DAL", name = "City of Dalaran", minLevel = 28, maxLevel = 33 },
    { key = "GNOMER", name = "Gnomeregan", minLevel = 29 },
    { key = "RFK", name = "Razorfen Kraul", minLevel = 29 },
    { key = "SMGY", name = "Scarlet Monastery: Graveyard", minLevel = 28, maxLevel = 36 },
    { key = "SMLIB", name = "Scarlet Monastery: Library", minLevel = 32, maxLevel = 39 },
    { key = "SMARM", name = "Scarlet Monastery: Armory", minLevel = 36, maxLevel = 42 },
    { key = "SMCATH", name = "Scarlet Monastery: Cathedral", minLevel = 38, maxLevel = 45 },
    { key = "DROWNED", name = "The Drowned City", minLevel = 35, maxLevel = 40 },
    { key = "RFD", name = "Razorfen Downs", minLevel = 37 },
    { key = "KROLDOK", name = "Krol'dok Stronghold", minLevel = 40, maxLevel = 45 },
    { key = "ULDA", name = "Uldaman", minLevel = 41 },
    { key = "ZF", name = "Zul'Farrak", minLevel = 44 },
    { key = "MARA", name = "Maraudon", minLevel = 46 },
    { key = "ALCAZ", name = "Alcaz Prison", minLevel = 48, maxLevel = 53 },
    { key = "ST", name = "The Temple of Atal'Hakkar", minLevel = 50 },
    { key = "BRD", name = "Blackrock Depths", minLevel = 52 },
    { key = "LBRS", name = "Lower Blackrock Spire", minLevel = 55 },
    { key = "UBRS", name = "Upper Blackrock Spire", minLevel = 55 },
    { key = "DIRE", name = "Dire Maul", minLevel = 55 },
    { key = "BLACKMAW", name = "Blackmaw Hold", minLevel = 55, maxLevel = 60 },
    { key = "SCHOLO", name = "Scholomance", minLevel = 58 },
    { key = "STRAT", name = "Stratholme", minLevel = 58 },
    { key = "SHAPERS", name = "Shaper's Terrace", minLevel = 58, maxLevel = 60 },
}

BXP.DungeonsByKey = {}
for _, d in ipairs(BXP.Dungeons) do BXP.DungeonsByKey[d.key] = d end
