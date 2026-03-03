---------------------------------------------------------------------------
-- Utils.lua — Shared utility functions
---------------------------------------------------------------------------
-- Provides helper routines used across every module: formatted chat
-- output, gold/silver/copper money strings, search-term parsing, and
-- a status-bar updater that optionally echoes to chat.
---------------------------------------------------------------------------

--- `ns` = addon-private namespace table shared across all .lua files.
--- See Core.lua header for full explanation of the namespace pattern.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Constants shared across modules
---------------------------------------------------------------------------
ns.VERSION      = "1.0.0"
ns.ADDON_PREFIX = "|cff33ff99[QuickFlip]|r "

-- Custom sound files bundled with the addon
ns.SOUND_DEAL      = "Interface\\AddOns\\QuickFlip\\notice.mp3"
ns.SOUND_PURCHASED = "Interface\\AddOns\\QuickFlip\\order-filled.mp3"

-- Auction House fee rate (5% cut on all sales)
ns.AH_FEE_RATE = 0.05

-- Scan state-machine constants (used by Scanner and Core)
ns.STATE_IDLE      = 0
ns.STATE_BROWSE    = 1  -- Waiting for AUCTION_HOUSE_BROWSE_RESULTS_UPDATED
ns.STATE_COMMODITY = 2  -- Waiting for COMMODITY_SEARCH_RESULTS_UPDATED

---------------------------------------------------------------------------
-- Print — send a prefixed message to the default chat frame
---------------------------------------------------------------------------
-- @param msg (string) The message to display, may include WoW color codes
---------------------------------------------------------------------------
function ns.Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(ns.ADDON_PREFIX .. tostring(msg))
    end
end

---------------------------------------------------------------------------
-- SetStatus — update the in-panel status bar text
---------------------------------------------------------------------------
-- Also echoes to chat when the user has verbose mode enabled.
-- @param msg (string) Status text (supports WoW color escape sequences)
---------------------------------------------------------------------------
function ns.SetStatus(msg)
    if ns.statusText then
        ns.statusText:SetText(msg)
    end
    if ns.db and ns.db.verbose then
        ns.Print(msg)
    end
end

---------------------------------------------------------------------------
-- FormatMoney — convert copper into a human-readable gold/silver string
---------------------------------------------------------------------------
-- Formats a copper amount as gold and silver only (no copper shown).
-- Uses inline texture escapes for the gold/silver coin icons so they
-- render correctly on buttons and font strings alike.
-- Returns "0[gold icon]" for nil/zero values.
-- @param  copper (number|nil) Amount in copper
-- @return (string) Formatted gold/silver string with coin icons
---------------------------------------------------------------------------
local ICON_GOLD   = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local ICON_SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"

function ns.FormatMoney(copper)
    if not copper or copper == 0 then
        return "0" .. ICON_GOLD
    end
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    if gold > 0 then
        return gold .. ICON_GOLD .. " " .. silver .. ICON_SILVER
    elseif silver > 0 then
        return silver .. ICON_SILVER
    else
        return "0" .. ICON_SILVER
    end
end

--- Shorthand alias for FormatMoney (used heavily in UI strings)
function ns.MC(copper)
    return ns.FormatMoney(copper)
end

--- Gold-only format — shows just the gold amount rounded, no silver/copper
function ns.GoldOnly(copper)
    if not copper or copper == 0 then return "0g" end
    local gold = math.floor(copper / 10000)
    return gold .. "g"
end

--- FormatGold — gold-only with coin icon (for compact display)
function ns.FormatGold(copper)
    if not copper or copper == 0 then return "0" .. ICON_GOLD end
    local gold = math.floor(copper / 10000)
    return gold .. ICON_GOLD
end

---------------------------------------------------------------------------
-- ParseSearchTerm — extract a clean item name from a search string
---------------------------------------------------------------------------
-- List entries may be quoted ("Rousing Fire") or contain semicolons for
-- advanced filters.  This strips quotes and trailing filter syntax so we
-- get a plain item name suitable for browse queries.
--
-- @param  term (string) Raw search string from the shopping list
-- @return (string) Cleaned item name
---------------------------------------------------------------------------
function ns.ParseSearchTerm(term)
    -- Strip surrounding double quotes if present
    local quoted = term:match('^"(.-)"')
    if quoted then return quoted end
    -- Take everything before the first semicolon, trimmed
    local plain = term:match("^([^;]+)")
    return plain and plain:match("^%s*(.-)%s*$") or term
end
