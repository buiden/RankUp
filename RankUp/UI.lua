-- RankUp UI: checklist of the class's active abilities.

local ADDON, ns = ...
local RU = ns.RU

local ROW_H, ROWS, WIDTH = 26, 14, 330
local panel, scroll, content, countText
local rows = {}

local function Refresh()
    if not panel or not panel:IsShown() then return end
    local list = RU.abilities
    content:SetHeight(math.max(1, #list * ROW_H))
    for i, rec in ipairs(list) do
        local row = rows[i]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row:SetSize(WIDTH - 44, ROW_H)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

            row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
            row.check:SetSize(24, 24)
            row.check:SetPoint("LEFT", 2, 0)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(20, 20)
            row.icon:SetPoint("LEFT", row.check, "RIGHT", 4, 0)

            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.label:SetJustifyH("LEFT")

            row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            row.rank:SetPoint("RIGHT", -4, 0)
            row.rank:SetWidth(70)
            row.label:SetPoint("RIGHT", row.rank, "LEFT", -6, 0)
            row.label:SetHeight(ROW_H)

            row.check:SetScript("OnClick", function(self)
                RU:SetEnabled(self.abilityName, self:GetChecked())
                if self:GetChecked() then RU:Upgrade("checked") end
            end)
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                if not self.spellID then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(self.spellID)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", GameTooltip_Hide)
            rows[i] = row
        end
        row.spellID = rec.bestID
        row.check.abilityName = rec.name
        row.check:SetChecked(RU:IsEnabled(rec.name))
        row.icon:SetTexture(rec.icon)
        row.label:SetText(rec.name)
        local sub = rec.bestSub
        row.rank:SetText((sub and sub ~= "") and sub or (#rec.ranks > 1 and (#rec.ranks .. " ranks") or ""))
        row:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end

    local on = 0
    for _, rec in ipairs(list) do if RU:IsEnabled(rec.name) then on = on + 1 end end
    countText:SetText(("%d / %d auto-ranked"):format(on, #list))
end
RU.OnScanned = Refresh

local function Build()
    panel = CreateFrame("Frame", "RankUpFrame", UIParent, "BasicFrameTemplateWithInset")
    panel:Hide() -- new frames are shown by default; first Toggle must open it
    panel:SetSize(WIDTH, 120 + ROWS * ROW_H)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "RankUpFrame") -- Esc closes it

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.title:SetPoint("TOP", 0, -5)
    local className, classFile = UnitClass("player")
    panel.title:SetText("RankUp")
    -- UnitClass.className is conditionally secret in this API surface.
    if not issecretvalue(className) and className then
        local color = (classFile and C_ClassColor and C_ClassColor.GetClassColor(classFile)) or nil
        panel.title:SetText("RankUp - " .. (color and color:WrapTextInColorCode(className) or className))
    end

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 14, -32)
    hint:SetWidth(WIDTH - 28)
    hint:SetJustifyH("LEFT")
    hint:SetText("Checked spells are swapped to their highest rank on your bars whenever you train a new rank.")

    scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -62)
    scroll:SetPoint("BOTTOMRIGHT", -32, 64)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(WIDTH - 44, 1)
    scroll:SetScrollChild(content)

    local function MakeButton(text, w, anchor, x, onClick)
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetSize(w, 22)
        b:SetPoint(anchor, x, 14)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    MakeButton("All", 50, "BOTTOMLEFT", 12, function() RU:SetAll(true); RU:Upgrade("checked"); Refresh() end)
    MakeButton("None", 56, "BOTTOMLEFT", 64, function() RU:SetAll(false); Refresh() end)
    MakeButton("Update now", 96, "BOTTOMRIGHT", -12, function() RU:Upgrade("manual") end)

    countText = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("BOTTOM", 0, 42)

    panel:SetScript("OnShow", function() RU:ScanSpellbook(); Refresh() end)
end

function RU:Toggle()
    if not panel then Build() end
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

-- Addon compartment (minimap addon button) entry from the .toc
function RankUp_OnCompartmentClick() RU:Toggle() end

SLASH_RANKUP1 = "/rankup"
SLASH_RANKUP2 = "/ru"
SlashCmdList.RANKUP = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "" then
        RU:Toggle()
    elseif msg == "now" or msg == "update" then
        RU:Upgrade("manual")
    elseif msg == "all" then
        RU:ScanSpellbook(); RU:SetAll(true); RU:Upgrade("checked")
    elseif msg == "none" then
        RU:SetAll(false); RU.Print("all abilities unchecked.")
    elseif msg == "quiet" then
        RU.db.notify = not RU.db.notify
        RU.Print("chat messages " .. (RU.db.notify and "on" or "off") .. ".")
    else
        RU.Print("/rankup (window), /rankup now, /rankup all, /rankup none, /rankup quiet")
    end
end
