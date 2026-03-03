---------------------------------------------------------------------------
-- Config.lua — SavedVariables defaults and initialization
---------------------------------------------------------------------------
-- Defines the default settings for QuickFlip and provides a helper to
-- merge defaults into the per-character saved table on first load.
-- All settings are stored in the global `QuickFlipDB` table which WoW
-- persists between sessions via the SavedVariables system declared in
-- the .toc file.  Shopping lists are also stored here under the `lists`
-- key, managed by ListManager.lua.
---------------------------------------------------------------------------

--- `ns` = addon-private namespace table shared across all .lua files.
--- See Core.lua header for full explanation of the namespace pattern.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Default configuration values
---------------------------------------------------------------------------
-- These defaults are merged into QuickFlipDB on first load.  Each key
-- maps to a user-configurable setting exposed via the options panel
-- and/or slash commands.
ns.defaults = {
    minProfitPct    = 10,       -- Minimum % profit after 5% AH fee to trigger a deal
    samplePct       = 10,       -- Floor = average of bottom 10% of listings by qty
    maxBuyPrice     = 0,        -- Absolute cap in copper (0 = no limit)
    autoConfirm     = true,     -- Automatically confirm purchases after price quote
    soundOnDeal     = true,     -- Play sound when a deal is detected
    excludedSellers = {},       -- Names of sellers whose listings we ignore
    enabled         = true,     -- Master on/off toggle
    skipHighQuality = true,     -- Skip rank 2+ crafting reagents (tier > 1)
    selectedList    = "",       -- Name of the shopping list to scan
    rescanCount     = 3,        -- Check each item N times before moving on
    buyPct          = 50,       -- Buy this % of the deal quantity (1-100)
    maxBuyQty       = 200,      -- Cap on units to buy per deal
    verbose         = false,    -- Mirror status bar messages to chat

    -- Shopping lists (built-in list management)
    lists             = {},     -- { ["listName"] = { "item1", "item2", ... }, ... }
    listIcons         = {},     -- { ["listName"] = iconFileID, ... }
    itemIDCache       = {},     -- { ["lowercase name"] = itemID } for icon loading

    -- Quick Sell defaults
    sellSelectedList      = "",     -- Shopping list for selling
    sellPostCap           = 200,    -- Max total units for sale in valid price range per item
    sellPostCapPerStack   = 50,     -- Max units to post per auction this cycle
    sellPostCapListingAmt = 5,      -- Max number of separate auction listings per item
    sellDuration          = 2,      -- 1=12h, 2=24h, 3=48h (24h is most common)
    sellUndercutSilver    = 1,      -- Silver to undercut by (min 1, never copper)
    sellWallPct           = 10,     -- % of total AH volume that constitutes a wall
    sellMaxUndercutPct    = 10,     -- Max % below floor we'll price (profit protection)

    -- Auction notification sounds
    soundOnAuctionSold    = true,   -- Play order-filled sound when an auction sells
    soundOnAuctionExpired = true,   -- Play notice sound when an auction expires/cancelled
}

---------------------------------------------------------------------------
-- InitDB — merge defaults into the live saved-variables table
---------------------------------------------------------------------------
-- Called once from Core.lua when ADDON_LOADED fires.  Ensures every key
-- from `ns.defaults` exists in the player's QuickFlipDB so the rest of
-- the addon can safely read `db.someKey` without nil checks.
--
-- @param  saved  (table) Reference to QuickFlipDB (created by WoW if nil)
-- @return (table) The same reference, now populated with any missing keys
---------------------------------------------------------------------------
function ns.InitDB(saved)
    for key, default in pairs(ns.defaults) do
        if saved[key] == nil then
            -- Deep-copy table defaults so each character gets their own copy
            if type(default) == "table" then
                saved[key] = {}
            else
                saved[key] = default
            end
        end
    end
    -- Safety: selectedList must always be a string
    if type(saved.selectedList) ~= "string" then
        saved.selectedList = ""
    end
    if type(saved.sellSelectedList) ~= "string" then
        saved.sellSelectedList = ""
    end
    -- Safety: lists must always be a table
    if type(saved.lists) ~= "table" then
        saved.lists = {}
    end
    if type(saved.listIcons) ~= "table" then
        saved.listIcons = {}
    end
    if type(saved.itemIDCache) ~= "table" then
        saved.itemIDCache = {}
    end
    -- Clean up legacy keys that are no longer used
    if saved.scanItems then
        saved.scanItems = nil
    end
    -- Remove legacy probe keys (feature removed)
    saved.probeQty     = nil
    saved.probeEnabled = nil
    -- Migrate sellUndercutCopper → sellUndercutSilver
    if saved.sellUndercutCopper then
        -- Old value was in copper; convert to silver (min 1)
        saved.sellUndercutSilver = math.max(math.floor(saved.sellUndercutCopper / 100), 1)
        saved.sellUndercutCopper = nil
    end
    return saved
end
