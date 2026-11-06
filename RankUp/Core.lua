-- RankUp: keep checked abilities on your action bars at their highest known rank.
-- Target: WoW Forever (Interface 16001, Mainline-family "Camelot" API).

local ADDON, ns = ...
local RU = {}
ns.RU = RU
_G.RankUp = RU

local PLAYER_BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
local ITEM_SPELL = (Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell) or 1
local GENERAL_LINE = (Enum and Enum.SpellBookSkillLineIndex and Enum.SpellBookSkillLineIndex.General) or 1
local CURSOR_RETRIES = 10

RU.abilities = {}   -- array of ability records, sorted by name
RU.byName = {}      -- name -> record
RU.rankOwner = {}   -- spellID (any rank) -> record
RU.pending = false

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99RankUp|r: " .. msg)
end
RU.Print = Print

-- Forever/Midnight secret values: never compare or index with one.
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function InitDB()
    RankUpDB = RankUpDB or {}
    local db = RankUpDB
    db.enabled = db.enabled or {}     -- [abilityName] = true
    if db.notify == nil then db.notify = true end
    db.version = 1
    RU.db = db
end

------------------------------------------------------------------------
-- Spellbook scan
------------------------------------------------------------------------

-- Returns true for skill lines that hold the player's class abilities
-- (everything except General, guild perks and hidden/off-spec lines).
local function IsClassLine(index, info)
    if index == GENERAL_LINE then return false end
    if not info or info.isGuild or info.shouldHide then return false end
    if info.offSpecID then return false end
    return true
end

function RU:ScanSpellbook()
    local abilities, byName, rankOwner = {}, {}, {}
    local numLines = C_SpellBook.GetNumSpellBookSkillLines() or 0
    for line = 1, numLines do
        local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
        if IsClassLine(line, info) then
            local first = info.itemIndexOffset + 1
            local last = info.itemIndexOffset + info.numSpellBookItems
            for slot = first, last do
                local item = C_SpellBook.GetSpellBookItemInfo(slot, PLAYER_BANK)
                if item and not IsSecret(item.itemType) and not IsSecret(item.spellID)
                    and not IsSecret(item.actionID) and not IsSecret(item.name)
                    and item.itemType == ITEM_SPELL and not item.isPassive and not item.isOffSpec then
                    local spellID = item.spellID or item.actionID
                    local name = item.name
                    if spellID and name and name ~= "" then
                        local rec = byName[name]
                        if not rec then
                            rec = { name = name, icon = item.iconID, ranks = {}, lowRanks = {}, lowBases = {}, line = info.name }
                            byName[name] = rec
                            abilities[#abilities + 1] = rec
                        end
                        rec.ranks[#rec.ranks + 1] = spellID
                        rankOwner[spellID] = rec
                        -- also map the base actionID (if it differs) so overridden spells match
                        if item.actionID and item.actionID ~= spellID then
                            rankOwner[item.actionID] = rec
                        end
                        local isLow = C_SpellBook.IsSpellBookItemLowRank(slot, PLAYER_BANK)
                        local baseID = item.actionID or spellID
                        if not IsSecret(isLow) then
                            if isLow then
                                rec.lowRanks[spellID], rec.lowRanks[baseID] = true, true
                                rec.lowBases[baseID] = true
                            elseif isLow == false then
                                -- Same name is not proof of a rank chain. Never choose
                                -- between distinct highest ranks by spellbook order.
                                if rec.bestBaseID and rec.bestBaseID ~= baseID then rec.ambiguous = true end
                                rec.bestID, rec.bestBaseID = spellID, baseID
                                rec.bestSlot, rec.bestSub = slot, item.subName
                                rec.icon = item.iconID
                            end
                        end
                    end
                end
            end
        end
    end
    for _, rec in ipairs(abilities) do
        if rec.ambiguous then
            rec.bestID, rec.bestBaseID, rec.bestSlot = nil, nil, nil
        elseif rec.bestID then
            rec.lowRanks[rec.bestID], rec.lowRanks[rec.bestBaseID] = nil, nil
        end
    end
    table.sort(abilities, function(a, b) return a.name < b.name end)
    self.abilities, self.byName, self.rankOwner = abilities, byName, rankOwner
    return abilities
end

------------------------------------------------------------------------
-- Action bar upgrade
------------------------------------------------------------------------

-- Returns a list of {slot=, rec=, from=} for every bar slot holding a
-- lower rank of a checked ability.
function RU:FindOutdated()
    local out, seen = {}, {}
    for _, rec in ipairs(self.abilities) do
        if self.db.enabled[rec.name] and rec.bestID then
            for baseID in pairs(rec.lowBases) do
                -- The default search set is All. Ask the client for real slots;
                -- never probe invalid slots or assume a fixed number of bars.
                for _, slot in ipairs(C_ActionBar.FindSpellActionButtons(baseID) or {}) do
                    if not IsSecret(slot) and not seen[slot] then
                        local actionType, id = GetActionInfo(slot)
                        if not IsSecret(actionType) and not IsSecret(id)
                            and actionType == "spell" and rec.lowRanks[id] then
                            seen[slot] = true
                            out[#out + 1] = { slot = slot, rec = rec, from = id }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end

local function PickupBest(rec)
    -- Re-resolve the slot right before pickup; slot indices shift when spells are learned.
    if rec.bestSlot then
        local item = C_SpellBook.GetSpellBookItemInfo(rec.bestSlot, PLAYER_BANK)
        if item and not IsSecret(item.spellID) and not IsSecret(item.actionID)
            and item.itemType == ITEM_SPELL and not item.isPassive and not item.isOffSpec
            and (item.spellID == rec.bestID or item.actionID == rec.bestBaseID) then
            C_SpellBook.PickupSpellBookItem(rec.bestSlot, PLAYER_BANK)
            return
        end
    end
    C_Spell.PickupSpell(rec.bestBaseID)
end

local function CursorIsEmpty()
    local kind = GetCursorInfo()
    return not IsSecret(kind) and kind == nil
end

function RU:QueueUpgrade(reason)
    if self.upgradeQueued then return end
    self.upgradeQueued = true
    C_Timer.After(0.5, function()
        RU.upgradeQueued = false
        RU:Upgrade(reason)
    end)
end

-- Main entry. reason is only used for chat output.
function RU:Upgrade(reason, attempt)
    if self.upgrading then return 0 end -- cursor events can fire synchronously
    attempt = attempt or 0
    if InCombatLockdown() then
        self.pending = true
        return 0
    end
    if not CursorIsEmpty() then
        self.pending = true
        -- Bounded polling, then CURSOR_CHANGED resumes when the player is done.
        if attempt < CURSOR_RETRIES and not self.cursorRetryQueued then
            self.cursorRetryQueued = true
            C_Timer.After(1, function()
                RU.cursorRetryQueued = false
                RU:Upgrade(reason, attempt + 1)
            end)
        end
        return 0
    end
    self.pending, self.upgrading = false, true
    self:ScanSpellbook()

    local todo = self:FindOutdated()
    local changed, names, seen = 0, {}, {}
    for _, job in ipairs(todo) do
        if InCombatLockdown() or not CursorIsEmpty() then self.pending = true break end
        -- Do not overwrite a macro, flyout or another spell installed since discovery.
        local kind, id = GetActionInfo(job.slot)
        if not IsSecret(kind) and not IsSecret(id) and kind == "spell" and id == job.from then
            local picked = pcall(PickupBest, job.rec)
            local cursorType = GetCursorInfo()
            if not picked or IsSecret(cursorType) or cursorType ~= "spell" then
                -- An unexpected cursor is not ours to clear.
                self.pending = true
                break
            end
            kind, id = GetActionInfo(job.slot)
            cursorType = GetCursorInfo()
            if InCombatLockdown() or IsSecret(kind) or IsSecret(id) or IsSecret(cursorType)
                or kind ~= "spell" or id ~= job.from or cursorType ~= "spell" then
                self.pending = true
                break
            end
            local placed = pcall(PlaceAction, job.slot)
            local newKind, newID = GetActionInfo(job.slot)
            local verified = placed and not IsSecret(newKind) and not IsSecret(newID)
                and newKind == "spell" and (newID == job.rec.bestID or newID == job.rec.bestBaseID)
            if verified then
                changed = changed + 1
                if not seen[job.rec.name] then
                    seen[job.rec.name] = true
                    local sub = job.rec.bestSub
                    names[#names + 1] = (sub and sub ~= "") and (job.rec.name .. " (" .. sub .. ")") or job.rec.name
                end
            else
                self.pending = true
            end
            -- PlaceAction may swap the old spell onto the cursor or empty it.
            -- Only clear a spell from our transaction, never an item/flyout/etc.
            cursorType = GetCursorInfo()
            if not InCombatLockdown() and not IsSecret(cursorType) and cursorType == "spell" then
                ClearCursor()
            elseif not CursorIsEmpty() then
                self.pending = true
                break
            end
            if not verified then break end
        end
    end
    self.upgrading = false

    if self.db.notify and changed > 0 then
        Print(("upgraded %d button%s: %s"):format(changed, changed == 1 and "" or "s", table.concat(names, ", ")))
    elseif reason == "manual" and self.db.notify then
        if #todo == 0 then
            Print("no eligible lower-rank buttons found.")
        else
            Print("update incomplete; no button changes were verified.")
        end
    end
    if self.OnScanned then self:OnScanned() end
    return changed
end

------------------------------------------------------------------------
-- Selection helpers (used by UI and slash commands)
------------------------------------------------------------------------

function RU:IsEnabled(name) return self.db.enabled[name] == true end

function RU:SetEnabled(name, on)
    self.db.enabled[name] = on and true or nil
    if self.OnScanned then self:OnScanned() end
end

function RU:SetAll(on)
    for _, rec in ipairs(self.abilities) do self.db.enabled[rec.name] = on and true or nil end
    if self.OnScanned then self:OnScanned() end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local f = CreateFrame("Frame")
RU.eventFrame = f

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        InitDB()
    elseif event == "PLAYER_LOGIN" then
        RU:ScanSpellbook()
        -- Catch ranks trained while the addon was off or before it was installed.
        C_Timer.After(3, function() RU:Upgrade("login") end)
    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" or event == "SPELLS_CHANGED" then
        -- Neither event's docs guarantee ordering. Rescan after either one,
        -- coalescing bursts; a later book refresh must also get an upgrade pass.
        if RU.db then RU:QueueUpgrade("learned") end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if RU.pending then RU:Upgrade("combat") end
    elseif event == "CURSOR_CHANGED" then
        if RU.pending and not RU.upgrading and CursorIsEmpty() then RU:QueueUpgrade("cursor") end
    end
end)

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
f:RegisterEvent("SPELLS_CHANGED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("CURSOR_CHANGED")
