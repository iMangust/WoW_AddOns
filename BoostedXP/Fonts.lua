-- Font objects shared by the guide window and the arrow. They follow one size setting
-- (/boost font <size>) and use the client's own font file, so every locale renders.
-- Loaded before any file that creates text with them.
local _, BXP = ...

local fonts = {
    title = CreateFont("BoostedXPFontTitle"),
    step = CreateFont("BoostedXPFontStep"),
    current = CreateFont("BoostedXPFontCurrent"),  -- the step the arrow points at: where you're heading
    detail = CreateFont("BoostedXPFontDetail"),
    small = CreateFont("BoostedXPFontSmall"),  -- the window's footer
}
local OFFSET = { title = -2, current = 3, step = 0, detail = -1, small = -3 }  -- against the chosen size
BXP.Fonts = fonts
for _, font in pairs(fonts) do font:SetFontObject(GameFontHighlight) end  -- until ApplyFonts runs

function BXP:ApplyFonts()
    local file = GameFontHighlight:GetFont()
    local size = self.db.window.fontSize
    for key, font in pairs(fonts) do
        font:SetFont(file, size + OFFSET[key], "")
        font:SetShadowOffset(1, -1)
        font:SetShadowColor(0, 0, 0, 1)
        font:SetTextColor(1, 1, 1)
    end
    fonts.title:SetTextColor(1, 0.82, 0)
end

BXP:On("BXP_LOADED", function() BXP:ApplyFonts() end)
