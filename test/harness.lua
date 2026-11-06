-- Mock WoW client for RankUp. Run: lua5.1 test/harness.lua <addon dir>
local dir = arg[1] or "RankUp"
local failures, passes = 0, 0
local function check(cond, msg)
    if cond then passes = passes + 1 else failures = failures + 1; print("FAIL: " .. msg) end
end

-- ---------------- mock state ----------------
local chat = {}
local timers = {}
local combat = false
local cursor = nil            -- {type="spell", id=} or {type="item"}
local bars = {}               -- slot -> {type, id}
local book = {}               -- spellbook slots (player bank)
local lines = {}              -- skill lines
local events = {}             -- event -> {frames}
local placed = 0
local pickupHook, placeHook, clearHook, actionHook
local blockPickup, blockPlace = false, false
local secretValues = {}
local fire
local function cursorChanged() if fire then fire("CURSOR_CHANGED") end end

local function rebuildBook(spells)
    -- spells: list of {name, id, sub, line, passive}
    -- lines: 1 General, 2 Class
    book = {}
    lines = { { name = "General", items = {} }, { name = "Paladin", items = {} }, { name = "Guild", items = {}, isGuild = true } }
    for _, s in ipairs(spells) do table.insert(lines[s.line].items, s) end
    local offset = 0
    for _, l in ipairs(lines) do
        l.offset = offset
        for _, s in ipairs(l.items) do offset = offset + 1; book[offset] = s end
    end
end

local function isLowRank(slot)
    local s = book[slot]
    if s.low ~= nil then return s.low end
    for _, o in pairs(book) do
        if o.name == s.name and o.rank and s.rank and o.rank > s.rank then return true end
    end
    return false
end

Enum = { SpellBookSpellBank = { Player = 0, Pet = 1 }, SpellBookItemType = { None = 0, Spell = 1, FutureSpell = 2, PetAction = 3, Flyout = 4 },
         SpellBookSkillLineIndex = { General = 1, Class = 2, MainSpec = 3, OffSpecStart = 4 } }

C_SpellBook = {
    GetNumSpellBookSkillLines = function() return #lines end,
    GetSpellBookSkillLineInfo = function(i)
        local l = lines[i]; if not l then return nil end
        return { name = l.name, iconID = 1, itemIndexOffset = l.offset, numSpellBookItems = #l.items, isGuild = l.isGuild or false, shouldHide = l.shouldHide or false, offSpecID = l.offSpecID }
    end,
    GetSpellBookItemInfo = function(slot, bank)
        assert(bank == 0, "bank must be Player")
        local s = book[slot]; if not s then return nil end
        return { actionID = s.base or s.id, spellID = s.id, itemType = s.itemType or (s.future and 2 or 1), name = s.name, subName = s.sub or "", iconID = 100 + s.id, isPassive = s.passive or false, isOffSpec = s.offSpec or false }
    end,
    IsSpellBookItemLowRank = function(slot, bank) return isLowRank(slot) end,
    PickupSpellBookItem = function(slot, bank)
        assert(bank == 0 and not combat, "invalid pickup")
        assert(not cursor, "pickup stole an occupied cursor")
        if blockPickup then return end
        local s = book[slot]
        cursor = { type = "spell", id = s.base or s.id }
        if pickupHook then pickupHook() end
        cursorChanged()
    end,
}
C_Spell = { PickupSpell = function(id)
    assert(not combat and not cursor, "unsafe spell pickup")
    if blockPickup then return end
    cursor = { type = "spell", id = id }
    if pickupHook then pickupHook() end
    cursorChanged()
end }
C_ActionBar = {
    HasAction = function(slot) return bars[slot] ~= nil end,
    FindSpellActionButtons = function(id)
        local slots = {}
        for slot, a in pairs(bars) do
            if a.type == "spell" and a.id == id then slots[#slots + 1] = slot end
        end
        table.sort(slots)
        return #slots > 0 and slots or nil
    end,
}
-- Only the deprecated fallback supplies this global. Remove it in its test.
HasAction = C_ActionBar.HasAction
function GetActionInfo(slot)
    if actionHook then actionHook(slot) end
    local a = bars[slot]; if a then return a.type, a.id end
end
function PlaceAction(slot)
    assert(not combat, "PlaceAction in combat")
    if blockPlace then return end
    local old = bars[slot]
    bars[slot] = { type = cursor.type, id = cursor.id }
    cursor = old and { type = old.type, id = old.id } or nil
    placed = placed + 1
    if placeHook then placeHook(slot) end
    cursorChanged()
end
function ClearCursor() cursor = nil; if clearHook then clearHook() end; cursorChanged() end
function GetCursorInfo() if cursor then return cursor.type, cursor.id end end
function InCombatLockdown() return combat end
function issecretvalue(v) return secretValues[v] == true end
C_Timer = { After = function(t, fn) table.insert(timers, fn) end }
local function runTimers() local n = 0 while #timers > 0 and n < 50 do local fn = table.remove(timers, 1); fn(); n = n + 1 end end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
UISpecialFrames = {}
function tinsert(t, v) table.insert(t, v) end
function UnitClass() return "Paladin", "PALADIN" end
GameTooltip = {}
function GameTooltip_Hide() end
SlashCmdList = {}

-- minimal frame mock (enough for UI.lua to build)
local frameMT = {}
frameMT.__index = frameMT
for _, method in ipairs({"SetJustifyH", "SetTexture", "EnableMouse", "SetFrameStrata",
    "SetMovable", "RegisterForDrag", "StartMoving", "StopMovingOrSizing",
    "SetClampedToScreen", "SetScrollChild"}) do
    frameMT[method] = function() end
end
function frameMT.RegisterEvent(self, e) events[e] = events[e] or {}; table.insert(events[e], self) end
function frameMT.SetScript(self, k, fn) self.scripts[k] = fn end
function frameMT.IsShown(self) return self.shown end
function frameMT.Show(self)
    local wasShown = self.shown; self.shown = true
    if not wasShown and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function frameMT.Hide(self) self.shown = false end
function frameMT.GetChecked(self) return self.checked end
function frameMT.SetChecked(self, v) self.checked = v end
local fontStrings = {}
function frameMT.CreateFontString(self)
    local fs = setmetatable({ scripts = {}, parent = self }, frameMT)
    table.insert(fontStrings, fs)
    return fs
end
function frameMT.CreateTexture(self) return setmetatable({ scripts = {} }, frameMT) end
function frameMT.SetPoint(self, ...)
    self.points = self.points or {}; self.points[#self.points + 1] = {...}
end
function frameMT.SetWidth(self, w) self.width = w end
function frameMT.SetHeight(self, h) self.height = h end
function frameMT.SetSize(self, w, h) self.width, self.height = w, h end
function frameMT.SetText(self, text) self.text = text end
local created = {}
local validTemplates = {BasicFrameTemplateWithInset = true, UICheckButtonTemplate = true,
    UIPanelScrollFrameTemplate = true, UIPanelButtonTemplate = true}
function CreateFrame(kind, name, parent, template)
    assert(not template or validTemplates[template], "unknown frame template")
    local f = setmetatable({ scripts = {}, kind = kind, template = template, parent = parent, shown = true }, frameMT)
    if name then _G[name] = f end
    table.insert(created, f)
    return f
end

fire = function(e, ...)
    for _, fr in ipairs(events[e] or {}) do fr.scripts.OnEvent(fr, e, ...) end
end

-- ---------------- load addon ----------------
local ns = {}
for _, file in ipairs({ "Core.lua", "UI.lua" }) do
    local chunk = assert(loadfile(dir .. "/" .. file))
    chunk("RankUp", ns)
end
local RU = ns.RU

-- Paladin at level 10: Seal of Righteousness r1, Holy Light r1+r2, Blessing of Might r1; Devotion Aura r1; a passive; a General spell
local spells = {
    { name = "Auto Attack", id = 6603, line = 1 },
    { name = "Holy Light", id = 635, rank = 1, sub = "Rank 1", line = 2 },
    { name = "Holy Light", id = 639, rank = 2, sub = "Rank 2", line = 2 },
    { name = "Seal of Righteousness", id = 21084, rank = 1, sub = "Rank 1", line = 2 },
    { name = "Blessing of Might", id = 19740, rank = 1, sub = "Rank 1", line = 2 },
    { name = "Devotion Aura", id = 465, rank = 1, sub = "Rank 1", line = 2 },
    { name = "Plate Mail", id = 750, line = 2, passive = true },
    { name = "Guild Perk", id = 9999, line = 3 },
}
rebuildBook(spells)
bars = { [1] = { type = "spell", id = 6603 }, [2] = { type = "spell", id = 635 }, [3] = { type = "spell", id = 21084 },
         [4] = { type = "spell", id = 19740 }, [5] = { type = "spell", id = 465 }, [14] = { type = "spell", id = 635 },
         [6] = { type = "macro", id = 1 }, [72] = { type = "spell", id = 635 } }

fire("ADDON_LOADED", "RankUp")
check(type(RankUpDB) == "table", "DB created")
fire("PLAYER_LOGIN")

-- T1: list = class actives only, one row per ability
local names = {}
for _, r in ipairs(RU.abilities) do names[#names + 1] = r.name end
check(table.concat(names, ",") == "Blessing of Might,Devotion Aura,Holy Light,Seal of Righteousness", "ability list: " .. table.concat(names, ","))
check(RU.byName["Holy Light"].bestID == 639, "Holy Light best rank = 639")

-- T2: nothing checked -> login upgrade changes nothing
runTimers()
check(bars[2].id == 635, "unchecked spell untouched on login")

-- T3: check Holy Light via UI -> immediate upgrade of all 3 copies, other spells untouched
RU:Toggle()
check(RankUpFrame and RankUpFrame:IsShown(), "window opens")
RU:SetEnabled("Holy Light", true)
local n = RU:Upgrade("checked")
check(n == 3, "upgraded 3 Holy Light buttons, got " .. tostring(n))
check(bars[2].id == 639 and bars[14].id == 639 and bars[72].id == 639, "all Holy Light slots at rank 2")
check(bars[3].id == 21084 and bars[6].type == "macro" and bars[1].id == 6603, "other slots untouched")
check(cursor == nil, "cursor empty after upgrade")

-- T4: train new rank out of combat (event flow) for a checked + an unchecked spell
RU:SetEnabled("Seal of Righteousness", true)
table.insert(spells, { name = "Seal of Righteousness", id = 20287, rank = 2, sub = "Rank 2", line = 2 })
table.insert(spells, { name = "Devotion Aura", id = 10290, rank = 2, sub = "Rank 2", line = 2 })
rebuildBook(spells)
fire("LEARNED_SPELL_IN_SKILL_LINE", 20287, 2, false)
fire("SPELLS_CHANGED")
runTimers()
check(bars[3].id == 20287, "SoR upgraded after training")
check(bars[5].id == 465, "unchecked Devotion Aura NOT upgraded")
check(chat[#chat]:find("Seal of Righteousness") ~= nil, "chat reports upgrade: " .. tostring(chat[#chat]))

-- T5: learning in combat defers until PLAYER_REGEN_ENABLED
table.insert(spells, { name = "Holy Light", id = 647, rank = 3, sub = "Rank 3", line = 2 })
rebuildBook(spells)
combat = true
fire("LEARNED_SPELL_IN_SKILL_LINE", 647, 2, false)
fire("SPELLS_CHANGED")
runTimers()
check(bars[2].id == 639, "no change while in combat")
check(RU.pending == true, "pending flag set in combat")
combat = false
fire("PLAYER_REGEN_ENABLED")
check(bars[2].id == 647 and bars[14].id == 647 and bars[72].id == 647, "upgraded after combat ends")

-- T6: player is dragging something -> wait, don't steal the cursor
table.insert(spells, { name = "Holy Light", id = 1026, rank = 4, sub = "Rank 4", line = 2 })
rebuildBook(spells)
cursor = { type = "item", id = 123 }
fire("LEARNED_SPELL_IN_SKILL_LINE", 1026, 2, false)
fire("SPELLS_CHANGED")
-- run only the first timer (the 0.5s learned upgrade); it should reschedule itself
local fn = table.remove(timers, 1); fn()
check(bars[2].id == 647 and cursor and cursor.type == "item", "held item untouched while dragging")
cursor = nil
runTimers()
check(bars[2].id == 1026, "upgrade completes once cursor is free")

-- T7: unchecking stops future upgrades; persistence of choices
RU:SetEnabled("Holy Light", false)
check(RankUpDB.enabled["Holy Light"] == nil and RankUpDB.enabled["Seal of Righteousness"] == true, "saved selections")
table.insert(spells, { name = "Holy Light", id = 1042, rank = 5, sub = "Rank 5", line = 2 })
rebuildBook(spells)
fire("LEARNED_SPELL_IN_SKILL_LINE", 1042, 2, false); fire("SPELLS_CHANGED"); runTimers()
check(bars[2].id == 1026, "unchecked spell left at chosen rank")

-- T8: manually down-ranked button of a checked spell gets upgraded (documented behavior)
RU:SetEnabled("Holy Light", true)
RU:Upgrade("manual")
check(bars[2].id == 1042, "manual update upgrades to rank 5")

-- T9: slash commands
SlashCmdList.RANKUP("all")
check(RU:IsEnabled("Devotion Aura") and bars[5].id == 10290, "/rankup all checks and upgrades everything")
SlashCmdList.RANKUP("none")
check(not RU:IsEnabled("Holy Light"), "/rankup none")
SlashCmdList.RANKUP("bogus")
check(chat[#chat]:find("/rankup now") ~= nil, "help text")

-- T10: no PlaceAction happened during combat (asserts would have thrown) and no secret crash
secretValues[1042] = true
RU:SetEnabled("Holy Light", true)
bars[2] = { type = "spell", id = 1042 }
local ok, err = pcall(function() RU:Upgrade("manual") end)
check(ok, "secret value path does not error: " .. tostring(err))

-- Focused regressions: reset mutable state between independent scenarios.
local function reset()
    timers, chat, secretValues = {}, {}, {}
    combat, cursor = false, nil
    pickupHook, placeHook, clearHook, actionHook = nil, nil, nil, nil
    blockPickup, blockPlace = false, false
    RU.pending, RU.upgrading, RU.upgradeQueued, RU.cursorRetryQueued = false, false, false, false
    RU.db.enabled = { Heal = true }
    RU.db.notify = true
    rebuildBook({
        {name = "Heal", id = 10, rank = 1, line = 2},
        {name = "Heal", id = 20, rank = 2, line = 2},
    })
    bars = {[1] = {type = "spell", id = 10}}
end
local function scenario(name, fn)
    reset()
    local success, message = pcall(fn)
    check(success, name .. ": " .. tostring(message))
end

scenario("modern API without deprecated globals", function()
    HasAction = nil
    check(RU:Upgrade("manual") == 1 and bars[1].id == 20, "works without global HasAction")
end)
-- Keep the old global for the other regressions to isolate their failures.
HasAction = C_ActionBar.HasAction

scenario("LEARNED without a subsequent SPELLS_CHANGED", function()
    fire("LEARNED_SPELL_IN_SKILL_LINE", 20, 2, false); runTimers()
    check(bars[1].id == 20, "learned event schedules its own scan")
end)
scenario("reversed event order", function()
    fire("SPELLS_CHANGED"); fire("LEARNED_SPELL_IN_SKILL_LINE", 20, 2, false); runTimers()
    check(bars[1].id == 20, "reversed events still upgrade")
end)
scenario("spellbook settles after first timer", function()
    rebuildBook({{name = "Heal", id = 10, rank = 1, line = 2}})
    fire("LEARNED_SPELL_IN_SKILL_LINE", 20, 2, false); fire("SPELLS_CHANGED"); runTimers()
    rebuildBook({{name = "Heal", id = 10, rank = 1, line = 2}, {name = "Heal", id = 20, rank = 2, line = 2}})
    fire("SPELLS_CHANGED"); runTimers()
    check(bars[1].id == 20, "late spellbook refresh upgrades")
end)
scenario("event burst coalescing", function()
    for i = 1, 12 do fire("LEARNED_SPELL_IN_SKILL_LINE", 20, 2, false); fire("SPELLS_CHANGED") end
    check(#timers == 1, "one timer for a training burst")
    runTimers(); check(bars[1].id == 20 and #timers == 0, "burst finishes without polling")
end)
scenario("cursor held beyond retry limit", function()
    cursor = {type = "item", id = 777}
    RU:Upgrade("manual"); runTimers()
    check(RU.pending and cursor.id == 777, "long-held item preserved")
    cursor = nil; fire("CURSOR_CHANGED"); runTimers()
    check(bars[1].id == 20 and not RU.pending, "cursor release resumes without combat")
end)
scenario("unexpected pickup cursor", function()
    pickupHook = function() cursor = {type = "item", id = 777} end
    RU:Upgrade("manual")
    check(cursor and cursor.type == "item" and cursor.id == 777 and bars[1].id == 10, "unexpected item never cleared or placed")
end)
scenario("cursor changes between jobs", function()
    bars[2] = {type = "spell", id = 10}
    clearHook = function() cursor = {type = "item", id = 777}; clearHook = nil end
    RU:Upgrade("manual")
    check(cursor and cursor.id == 777 and bars[2].id == 10, "new cursor between jobs is untouched")
end)
scenario("placement blocked silently", function()
    blockPlace = true
    local n = RU:Upgrade("manual")
    check(n == 0 and bars[1].id == 10, "blocked placement is not counted")
    check(not chat[#chat] or not chat[#chat]:find("already"), "blocked placement never reports all current")
end)
scenario("pickup blocked silently", function()
    blockPickup = true
    check(RU:Upgrade("manual") == 0 and bars[1].id == 10, "blocked pickup leaves bar intact")
    check(not chat[#chat] or not chat[#chat]:find("already"), "blocked pickup never reports all current")
end)
scenario("combat begins during pickup", function()
    pickupHook = function() combat = true end
    RU:Upgrade("manual")
    check(bars[1].id == 10 and RU.pending, "no placement if pickup enters lockdown")
    pickupHook, combat, cursor = nil, false, nil
    fire("PLAYER_REGEN_ENABLED"); runTimers()
    check(bars[1].id == 20, "deferred transaction recovers")
end)
scenario("bar changes after discovery", function()
    bars[2] = {type = "spell", id = 10}
    placeHook = function() bars[2] = {type = "macro", id = 55} end
    RU:Upgrade("manual")
    check(bars[2].type == "macro" and bars[2].id == 55, "new macro is not overwritten by stale job")
end)
scenario("real slot enumeration and non-spell actions", function()
    bars[145], bars[180], bars[205] = {type = "spell", id = 10}, {type = "spell", id = 10}, {type = "spell", id = 10}
    bars[3], bars[4] = {type = "macro", id = 10}, {type = "flyout", id = 10}
    check(RU:Upgrade("manual") == 4, "all API-reported slots including beyond fixed ceiling")
    check(bars[145].id == 20 and bars[180].id == 20 and bars[205].id == 20, "extra bar copies upgraded")
    check(bars[3].type == "macro" and bars[4].type == "flyout", "macros and flyouts remain untouched")
end)
scenario("base and override IDs", function()
    rebuildBook({{name = "Heal", id = 110, base = 10, low = true, line = 2},
                 {name = "Heal", id = 120, base = 20, low = false, line = 2}})
    bars[2] = {type = "spell", id = 20}
    check(RU:Upgrade("manual") == 1, "highest base ID is not treated as a lower rank")
    check(RU:Upgrade("manual") == 0, "override/base upgrade is idempotent")
end)
scenario("ambiguous same-name spells", function()
    rebuildBook({{name = "Heal", id = 10, low = false, line = 2},
                 {name = "Heal", id = 20, low = false, line = 2}})
    check(RU:Upgrade("manual") == 0 and bars[1].id == 10, "same-name independent spells not cross-replaced")
end)
scenario("incomplete rank data", function()
    rebuildBook({{name = "Heal", id = 10, low = true, line = 2},
                 {name = "Heal", id = 20, low = true, line = 2}})
    check(RU:Upgrade("manual") == 0 and bars[1].id == 10, "no guessed highest rank when all entries are low")
end)
scenario("spellbook ordering is not rank ordering", function()
    rebuildBook({{name = "Heal", id = 20, rank = 2, line = 2},
                 {name = "Heal", id = 10, rank = 1, line = 2}})
    check(RU:Upgrade("manual") == 1 and bars[1].id == 20, "low-rank API, not slot order, selects rank")
end)
scenario("slot shift before pickup", function()
    actionHook = function()
        actionHook = nil
        rebuildBook({{name = "Other", id = 99, line = 2},
                     {name = "Heal", id = 10, rank = 1, line = 2},
                     {name = "Heal", id = 20, rank = 2, line = 2}})
    end
    check(RU:Upgrade("manual") == 1 and bars[1].id == 20, "stale book slot never picks unrelated spell")
end)
scenario("off-spec hidden passive and future entries", function()
    rebuildBook({{name = "Heal", id = 10, rank = 1, line = 2},
                 {name = "Heal", id = 20, rank = 2, line = 2},
                 {name = "Other spec", id = 30, offSpec = true, line = 2},
                 {name = "Future", id = 40, future = true, line = 2},
                 {name = "Flyout", id = 50, itemType = 4, line = 2},
                 {name = "Passive", id = 60, passive = true, line = 2}})
    RU:ScanSpellbook(); check(#RU.abilities == 1, "non-active spellbook entries excluded")
    lines[2].offSpecID = 65
    RU:ScanSpellbook(); check(#RU.abilities == 0, "off-spec line excluded")
    lines[2].offSpecID, lines[2].shouldHide = nil, true
    RU:ScanSpellbook(); check(#RU.abilities == 0, "hidden line excluded")
end)
scenario("secret action type and ID", function()
    secretValues.spell = true
    check(RU:Upgrade("manual") == 0 and bars[1].id == 10, "secret action type never compared")
    secretValues = {[10] = true}
    check(RU:Upgrade("manual") == 0 and bars[1].id == 10, "secret spell ID never used")
end)
scenario("checkbox refresh and bounded text", function()
    RankUpFrame:Show(); RU:ScanSpellbook(); RU:OnScanned()
    local row
    for _, f in ipairs(created) do
        if f.kind == "CheckButton" and f.abilityName == "Heal" then row = f.parent end
    end
    assert(row, "Heal row exists")
    row.check:SetChecked(false); row.check.scripts.OnClick(row.check)
    local refreshes = 0
    local refresh = RU.OnScanned
    RU.OnScanned = function(...) refreshes = refreshes + 1; refresh(...) end
    RU:SetEnabled("Heal", true)
    check(refreshes > 0, "selection changes refresh even when no upgrade runs")
    RU.OnScanned = refresh
    check(row.check:GetChecked(), "checkbox reflects selection helper")
    local bounded = false
    for _, point in ipairs(row.label.points or {}) do
        if point[1] == "RIGHT" and point[2] == row.rank then bounded = true end
    end
    check(bounded, "long ability names stop before rank column")
end)

scenario("PlaceAction can also leave an empty cursor", function()
    placeHook = function() cursor = nil end
    check(RU:Upgrade("manual") == 1 and bars[1].id == 20 and cursor == nil, "placement without a swap is supported")
end)
scenario("unexpected cursor after PlaceAction", function()
    placeHook = function() cursor = {type = "item", id = 777} end
    check(RU:Upgrade("manual") == 1, "successful bar write verified before cursor check")
    check(cursor and cursor.id == 777, "post-placement item is never cleared")
end)
scenario("placement throws rather than silently failing", function()
    local nativePlace = PlaceAction
    PlaceAction = function() error("action blocked") end
    local success, count = pcall(function() return RU:Upgrade("manual") end)
    PlaceAction = nativePlace
    check(success and count == 0 and bars[1].id == 10 and not RU.upgrading, "blocked action does not leave updater locked or report success")
end)
scenario("slot shifts after first of multiple copies", function()
    bars[2] = {type = "spell", id = 10}
    placeHook = function()
        rebuildBook({{name = "Other", id = 99, line = 2},
                     {name = "Heal", id = 10, rank = 1, line = 2},
                     {name = "Heal", id = 20, rank = 2, line = 2}})
    end
    check(RU:Upgrade("manual") == 2 and bars[2].id == 20, "every pickup revalidates the book slot")
end)
scenario("partial success reports only changed spells", function()
    rebuildBook({{name = "Heal", id = 10, rank = 1, line = 2}, {name = "Heal", id = 20, rank = 2, line = 2},
                 {name = "Other", id = 30, rank = 1, line = 2}, {name = "Other", id = 40, rank = 2, line = 2}})
    RU.db.enabled.Other = true; bars[2] = {type = "spell", id = 30}
    placeHook = function() blockPickup = true end
    check(RU:Upgrade("manual") == 1 and bars[2].id == 30, "partial write count is exact")
    check(chat[#chat]:find("Heal") and not chat[#chat]:find("Other"), "chat excludes failed jobs")
end)
scenario("ordinary held spell and macro are preserved", function()
    for _, kind in ipairs({"spell", "macro", "flyout"}) do
        cursor = {type = kind, id = 777}
        check(RU:Upgrade("manual") == 0 and cursor.id == 777 and cursor.type == kind, "held " .. kind .. " preserved")
    end
end)
scenario("layout footer and first toggle", function()
    RankUpFrame:Hide(); RU:Toggle(); check(RankUpFrame:IsShown(), "toggle reopens hidden panel")
    RU:Toggle(); check(not RankUpFrame:IsShown(), "toggle closes shown panel")
    local footer
    for _, fs in ipairs(fontStrings) do
        if fs.parent == RankUpFrame and fs.text and fs.text:find("auto%-ranked") then footer = fs end
    end
    assert(footer and footer.points, "footer exists")
    check(footer.points[1][1] == "BOTTOM" and footer.points[1][3] > 14 + 22,
        "footer sits above button row rather than overlapping it")
end)
scenario("secret class name is not concatenated", function()
    local oldUnitClass = UnitClass
    UnitClass = function() return "HiddenClass", "PALADIN" end
    secretValues.HiddenClass = true
    assert(loadfile(dir .. "/UI.lua"))("RankUp", ns)
    RU:Toggle()
    check(RankUpFrame:IsShown() and RankUpFrame.title.text == "RankUp", "secret class name uses safe title")
    UnitClass = oldUnitClass
end)

print(("RESULT: %d passed, %d failed, %d PlaceAction calls"):format(passes, failures, placed))
os.exit(failures == 0 and 0 or 1)
