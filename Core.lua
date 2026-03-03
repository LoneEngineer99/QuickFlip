---------------------------------------------------------------------------
-- Core.lua — Main entry point, event hub, slash commands, tab creation
---------------------------------------------------------------------------
-- This is the orchestrator file for QuickFlip.  It wires together the
-- modules defined in the other files:
--
--   Config.lua      — SavedVariables defaults and initialization
--   Utils.lua       — Shared utilities (Print, FormatMoney, SetStatus, etc.)
--   ListManager.lua — Built-in shopping list management
--   Scanner.lua     — Two-phase commodity scan engine
--   Buyer.lua       — Purchase logic, session tracking
--   Seller.lua      — Quick-sell logic: scan, price, post, and cancel
--   UI.lua          — Panel construction and visual updates
--
-- Core.lua handles:
--   • ADDON_LOADED — initialise saved variables, create the buy frame
--                    and options panel.
--   • AH open/close — create the custom Flip tab, start/stop scanning.
--   • Event routing — forward AH events to the correct module.
--   • Slash commands — /qf and /quickflip command processing.
--
-- Namespace pattern ("ns"):
--   Every .lua file listed in the .toc receives the same two values from
--   WoW's addon loader: ADDON_NAME (string, "QuickFlip") and `ns`, a
--   private table shared exclusively among this addon's files.  We use
--   `ns` as a namespace to store shared state (ns.db, ns.isScanning …),
--   functions (ns.StartScan, ns.FormatMoney …), and UI widget references
--   (ns.buyButton, ns.statusText …) so every module can read and write
--   them without circular require/import dependencies.  Nothing on `ns`
--   is visible to other addons — it acts as our internal API surface.
---------------------------------------------------------------------------

--- WoW addon loader injects (ADDON_NAME, ns) into every .lua file listed
--- in the .toc.  `ns` is the addon-private namespace table shared across
--- all modules.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Shared mutable state lives on the namespace table so every module can
-- read and write it without circular dependencies.
---------------------------------------------------------------------------
ns.db               = nil      -- Reference to QuickFlipDB (set on ADDON_LOADED)
ns.isAHOpen         = false    -- True while the Auction House frame is open
ns.isScanning       = false    -- True while the scan loop is running
ns.state            = 0        -- Current scan state-machine state (STATE_*)
ns.scanQueue        = {}       -- Array of search-term strings for this pass
ns.scanQueueIdx     = 0        -- Index into scanQueue
ns.scanResults      = {}       -- Array of result tables for display
ns.scanCount        = 0        -- Total number of scan passes completed
ns.currentItemKey   = nil      -- ItemKey currently being commodity-queried
ns.rescanIter       = 0        -- Current rescan iteration for current item
ns.pendingDeal      = nil      -- Deal table awaiting user Buy action
ns.isWaitingForPrice = false   -- True while waiting for COMMODITY_PRICE_UPDATED

-- UI widget references (set by BuildPanel in UI.lua)
ns.panelBuilt       = false
ns.panel            = nil
ns.statusText       = nil
ns.progressText     = nil
ns.dealCard         = nil
ns.dealIcon         = nil
ns.dealNameText     = nil
ns.dealPctText      = nil
ns.dealPriceText    = nil
ns.dealFloorText    = nil
ns.dealQtyText      = nil
ns.dealCostText     = nil
ns.dealProfitText   = nil
ns.buyButton        = nil
ns.skipButton       = nil
ns.toggleButton     = nil
ns.scanCountText    = nil
ns.settingsText     = nil
ns.resultsScroll    = nil
ns.progressBarFill  = nil
ns.profitText       = nil
ns.buyFrame         = nil

-- Sell UI widget references (set by BuildSellPanel in UI.lua)
ns.sellPanelBuilt   = false
ns.sellPanel        = nil
ns.sellStatusText   = nil
ns.sellProgressText = nil
ns.sellCard         = nil
ns.sellItemIcon     = nil
ns.sellItemNameText = nil
ns.sellPriceText    = nil
ns.sellQtyText      = nil
ns.sellActionText   = nil
ns.sellPostButton   = nil
ns.sellSkipButton   = nil
ns.sellToggleButton = nil
ns.sellScanCountText = nil
ns.sellSettingsText = nil
ns.sellResultsScroll = nil
ns.sellProgressBarFill = nil
ns.sellProfitText   = nil
ns.sellFrame        = nil

-- Lists UI widget references (set by BuildListsPanel in UI.lua)
ns.listsPanelBuilt  = false
ns.listsPanel       = nil

-- Tab state
local _tabCreated = false
local _sellTabCreated = false
local _listsTabCreated = false

---------------------------------------------------------------------------
-- CreateFlipTab — inject the custom "Flip" tab into the AH frame
---------------------------------------------------------------------------
local function CreateFlipTab()
    if _tabCreated then return end
    local LibAHTab = LibStub("LibAHTab-1-0")
    if not LibAHTab then
        ns.Print("|cffff0000LibAHTab missing.|r")
        return
    end
    local panel = ns.BuildPanel()
    LibAHTab:CreateTab("QuickFlip", panel, "Flip", "QuickFlip — Buy Deals")
    _tabCreated = true
    ns.RefreshUI()
end

---------------------------------------------------------------------------
-- CreateSellTab — inject the "Quick Sell" tab into the AH frame
---------------------------------------------------------------------------
local function CreateSellTab()
    if _sellTabCreated then return end
    local LibAHTab = LibStub("LibAHTab-1-0")
    if not LibAHTab then return end
    local panel = ns.BuildSellPanel()
    LibAHTab:CreateTab("QuickFlipSell", panel, "Quick Sell", "QuickFlip — Quick Sell")
    _sellTabCreated = true
    ns.RefreshSellUI()
end

---------------------------------------------------------------------------
-- CreateListsTab — inject the "Lists" management tab into the AH frame
---------------------------------------------------------------------------
local function CreateListsTab()
    if _listsTabCreated then return end
    local LibAHTab = LibStub("LibAHTab-1-0")
    if not LibAHTab then return end
    local panel = ns.BuildListsPanel()
    LibAHTab:CreateTab("QuickFlipLists", panel, "Lists", "QuickFlip — List Manager")
    _listsTabCreated = true
    ns.RefreshListsUI()
end

---------------------------------------------------------------------------
-- Event hub — single frame that routes all WoW events to the right module
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION")

eventFrame:SetScript("OnEvent", function(self, event, ...)

    -------------------------------------------------------------------
    -- ADDON_LOADED — one-time initialisation
    -------------------------------------------------------------------
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            -- Initialise saved variables with defaults
            if not QuickFlipDB then QuickFlipDB = {} end
            ns.db = ns.InitDB(QuickFlipDB)

            -- Create the purchase-event listener frame and sell frame
            ns.InitBuyFrame()
            ns.InitSellFrame()

            -- Register the Interface > Addons settings panel
            ns.CreateOptionsPanel()

            ns.Print(ns.VERSION .. " loaded. /qf config for settings.")
            self:UnregisterEvent("ADDON_LOADED")
        end

    -------------------------------------------------------------------
    -- AH opened — create tab, refresh UI
    -------------------------------------------------------------------
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local interactionType = ...
        if interactionType == Enum.PlayerInteractionType.Auctioneer then
            ns.isAHOpen = true
            C_Timer.After(0.2, function()
                if AuctionHouseFrame then
                    CreateFlipTab()
                    CreateSellTab()
                    CreateListsTab()
                    ns.RefreshUI()
                    ns.RefreshSellUI()
                    ns.RefreshListsUI()
                end
            end)
        end

    -------------------------------------------------------------------
    -- AH closed — stop everything, cancel pending purchases
    -------------------------------------------------------------------
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local interactionType = ...
        if interactionType == Enum.PlayerInteractionType.Auctioneer then
            ns.isAHOpen = false
            ns.StopScan()
            ns.StopSellScan()
            ns.CancelPendingPurchase()
            ns.UpdateDeal(nil)
        end

    -------------------------------------------------------------------
    -- Browse results ready — forward to Scanner
    -------------------------------------------------------------------
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        if ns.isSellScanning then
            ns.SellOnBrowseResults()
        else
            ns.OnBrowseResults()
        end

    -------------------------------------------------------------------
    -- Commodity search results ready — forward to Scanner or Seller
    -------------------------------------------------------------------
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local itemID = ...
        if ns.isSellScanning then
            ns.SellOnCommodityResults(itemID)
        else
            ns.OnCommodityResults(itemID)
        end

    -------------------------------------------------------------------
    -- AH error (code 10 = throttled) — pause and wait for ready signal
    -------------------------------------------------------------------
    elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
        if (ns.state == ns.STATE_BROWSE or ns.state == ns.STATE_COMMODITY)
           and ns.isScanning then
            ns.state = ns.STATE_IDLE
            ns.SetStatus("|cffff8800Throttled — retrying...|r")
        end
        if (ns.sellState == ns.STATE_BROWSE or ns.sellState == ns.STATE_COMMODITY)
           and ns.isSellScanning then
            ns.sellState = ns.STATE_IDLE
            ns.SetSellStatus("|cffff8800Throttled — retrying...|r")
        end

    -------------------------------------------------------------------
    -- Throttle cooldown complete — resume interrupted scan step
    -------------------------------------------------------------------
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if ns.isSellScanning and ns.sellState == ns.STATE_IDLE then
            if ns.sellCurrentItemKey and ns.sellQueueIdx <= #ns.sellQueue then
                ns.SellBeginCommodityQuery()
            elseif ns.sellQueueIdx <= #ns.sellQueue then
                ns.SellBeginBrowseQuery()
            end
        elseif ns.isScanning and ns.state == ns.STATE_IDLE and not ns.pendingDeal then
            if ns.currentItemKey and ns.scanQueueIdx <= #ns.scanQueue then
                -- Had an itemKey — retry the commodity query
                ns.BeginCommodityQuery()
            elseif ns.scanQueueIdx <= #ns.scanQueue then
                -- Retry the browse query
                ns.BeginBrowseQuery()
            end
        end

    -------------------------------------------------------------------
    -- Auction notification — sold, expired, won, outbid
    -------------------------------------------------------------------
    elseif event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" then
        local notification = ...
        if notification == Enum.AuctionHouseNotification.AuctionSold
        or notification == Enum.AuctionHouseNotification.AuctionWon then
            if ns.db and ns.db.soundOnAuctionSold then
                PlaySoundFile(ns.SOUND_PURCHASED, "Master")
            end
        elseif notification == Enum.AuctionHouseNotification.AuctionExpired then
            if ns.db and ns.db.soundOnAuctionExpired then
                PlaySoundFile(ns.SOUND_DEAL, "Master")
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Slash commands — /qf and /quickflip
---------------------------------------------------------------------------
SLASH_QUICKFLIP1 = "/qf"
SLASH_QUICKFLIP2 = "/quickflip"

SlashCmdList["QUICKFLIP"] = function(input)
    if not ns.db then
        ns.Print("|cffff0000Not initialized.|r")
        return
    end
    local cmd, rest = input:match("^(%S+)%s*(.*)")
    cmd = cmd and cmd:lower() or ""

    -------------------------------------------------------------------
    -- /qf help (or no subcommand) — print usage
    -------------------------------------------------------------------
    if cmd == "" or cmd == "help" then
        ns.Print("--- " .. ADDON_NAME .. " v" .. ns.VERSION .. " ---")
        ns.Print("/qf uselist <name> — Select shopping list")
        ns.Print("/qf lists — Show available lists")
        ns.Print("/qf newlist <name> — Create a new list")
        ns.Print("/qf dellist <name> — Delete a list")
        ns.Print("/qf add <item> — Add item to active list")
        ns.Print("/qf remove <item> — Remove item from active list")
        ns.Print("/qf scan — Start scanning")
        ns.Print("/qf stop — Stop scanning")
        ns.Print("/qf enable|disable — Master toggle")
        ns.Print("/qf profit <1-50> — Min profit % after AH fee")
        ns.Print("/qf sample <1-50> — Bottom % of listings for floor calc")
        ns.Print("/qf maxprice <copper> — Max buy price (0=none)")
        ns.Print("/qf autoconfirm — Toggle auto-confirm")
        ns.Print("/qf sound — Toggle sound alerts")
        ns.Print("/qf quality — Toggle skip rank 2+ reagents")
        ns.Print("/qf exclude <name> — Toggle seller exclusion")
        ns.Print("/qf verbose — Mirror status bar to chat")
        ns.Print("/qf config — Open settings panel")

    -------------------------------------------------------------------
    -- /qf uselist <name> — select a shopping list
    -------------------------------------------------------------------
    elseif cmd == "uselist" then
        if not rest or rest == "" then
            ns.Print("Current: " .. (ns.db.selectedList ~= "" and ns.db.selectedList or "(none)"))
            return
        end
        if ns.GetListItems(rest) then
            ns.db.selectedList = rest
            ns.Print("List: |cff00ff00" .. rest .. "|r")
        else
            ns.Print("|cffff0000Not found: " .. rest .. "|r")
        end
        ns.RefreshUI()

    -------------------------------------------------------------------
    -- /qf lists — enumerate available shopping lists
    -------------------------------------------------------------------
    elseif cmd == "lists" then
        local names = ns.GetListNames()
        if #names == 0 then ns.Print("No lists. Use /qf newlist <name> to create one."); return end
        ns.Print("--- Shopping Lists ---")
        for i, n in ipairs(names) do
            local items = ns.GetListItems(n)
            local active = (ns.db.selectedList == n)
                and " |cff00ff00<< ACTIVE|r" or ""
            ns.Print(string.format("  %d. %s (%d)%s",
                i, n, items and #items or 0, active))
        end

    -------------------------------------------------------------------
    -- /qf newlist <name> — create a new list
    -------------------------------------------------------------------
    elseif cmd == "newlist" then
        if not rest or rest == "" then
            ns.Print("Usage: /qf newlist <name>")
            return
        end
        if ns.CreateList(rest) then
            ns.Print("Created list: |cff00ff00" .. rest .. "|r")
        else
            ns.Print("|cffff0000List already exists or invalid name.|r")
        end
        ns.RefreshUI()
        ns.RefreshListsUI()

    -------------------------------------------------------------------
    -- /qf dellist <name> — delete a list
    -------------------------------------------------------------------
    elseif cmd == "dellist" then
        if not rest or rest == "" then
            ns.Print("Usage: /qf dellist <name>")
            return
        end
        if ns.DeleteList(rest) then
            ns.Print("Deleted list: |cffff8800" .. rest .. "|r")
        else
            ns.Print("|cffff0000List not found: " .. rest .. "|r")
        end
        ns.RefreshUI()
        ns.RefreshListsUI()

    -------------------------------------------------------------------
    -- /qf add <item> — add an item to the active list
    -------------------------------------------------------------------
    elseif cmd == "add" then
        if not rest or rest == "" then
            ns.Print("Usage: /qf add <item name>")
            return
        end
        if ns.db.selectedList == "" then
            ns.Print("|cffff0000No list selected. Use /qf uselist <name> first.|r")
            return
        end
        if ns.AddItemToList(ns.db.selectedList, rest) then
            ns.Print("Added |cff00ff00" .. rest .. "|r to " .. ns.db.selectedList)
        else
            ns.Print("|cffff0000Already in list or error.|r")
        end
        ns.RefreshListsUI()

    -------------------------------------------------------------------
    -- /qf remove <item> — remove an item from the active list
    -------------------------------------------------------------------
    elseif cmd == "remove" then
        if not rest or rest == "" then
            ns.Print("Usage: /qf remove <item name>")
            return
        end
        if ns.db.selectedList == "" then
            ns.Print("|cffff0000No list selected.|r")
            return
        end
        if ns.RemoveItemFromList(ns.db.selectedList, rest) then
            ns.Print("Removed |cffff8800" .. rest .. "|r from " .. ns.db.selectedList)
        else
            ns.Print("|cffff0000Not found in list.|r")
        end
        ns.RefreshListsUI()

    -------------------------------------------------------------------
    -- Simple toggle/action commands
    -------------------------------------------------------------------
    elseif cmd == "scan"   then ns.StartScan()
    elseif cmd == "stop"   then ns.StopScan()

    elseif cmd == "config" or cmd == "options" or cmd == "settings" then
        if Settings and Settings.OpenToCategory then
            Settings.OpenToCategory(ADDON_NAME)
        elseif InterfaceOptionsFrame_OpenToCategory then
            InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)
            InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)  -- WoW quirk: needs two calls
        end

    elseif cmd == "enable" then
        ns.db.enabled = true
        ns.Print("|cff00ff00Enabled.|r")
        ns.RefreshUI()

    elseif cmd == "disable" then
        ns.db.enabled = false
        ns.StopScan()
        ns.CancelPendingPurchase()
        ns.UpdateDeal(nil)
        ns.Print("|cffff0000Disabled.|r")
        ns.RefreshUI()

    -------------------------------------------------------------------
    -- /qf profit <1-50>
    -------------------------------------------------------------------
    elseif cmd == "profit" then
        local pct = tonumber(rest)
        if pct and pct >= 1 and pct <= 50 then
            ns.db.minProfitPct = pct
            ns.Print(string.format(
                "Min profit: %d%% — deals must yield ≥%d%% after 5%% AH fee", pct, pct))
        else
            ns.Print("Current: " .. ns.db.minProfitPct
                .. "% (usage: /qf profit 10)")
        end
        ns.RefreshUI()

    -------------------------------------------------------------------
    -- /qf sample <1-50>
    -------------------------------------------------------------------
    elseif cmd == "sample" then
        local pct = tonumber(rest)
        if pct and pct >= 1 and pct <= 50 then
            ns.db.samplePct = pct
            ns.Print(string.format(
                "Sample: bottom %d%% of listings used for floor", pct))
        else
            ns.Print("Current: " .. ns.db.samplePct
                .. "% (usage: /qf sample 10)")
        end
        ns.RefreshUI()

    -------------------------------------------------------------------
    -- /qf maxprice <copper>
    -------------------------------------------------------------------
    elseif cmd == "maxprice" then
        local c = tonumber(rest)
        if c and c >= 0 then
            ns.db.maxBuyPrice = c
            ns.Print("Max: " .. (c > 0 and ns.FormatMoney(c) or "none"))
        else
            ns.Print("Usage: /qf maxprice <copper>")
        end
        ns.RefreshUI()

    -------------------------------------------------------------------
    -- Boolean toggles
    -------------------------------------------------------------------
    elseif cmd == "autoconfirm" then
        ns.db.autoConfirm = not ns.db.autoConfirm
        ns.Print("Auto-confirm: " .. (ns.db.autoConfirm
            and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        ns.RefreshUI()

    elseif cmd == "sound" then
        ns.db.soundOnDeal = not ns.db.soundOnDeal
        ns.Print("Sound: " .. (ns.db.soundOnDeal
            and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        ns.RefreshUI()

    elseif cmd == "quality" then
        ns.db.skipHighQuality = not ns.db.skipHighQuality
        ns.Print("Skip rank 2+: " .. (ns.db.skipHighQuality
            and "|cff00ff00ON|r (tier 1 only)" or "|cffff0000OFF|r (all tiers)"))
        ns.RefreshUI()

    -------------------------------------------------------------------
    -- /qf exclude <name> — toggle seller exclusion
    -------------------------------------------------------------------
    elseif cmd == "exclude" then
        if not rest or rest == "" then
            ns.Print("Excluded: " .. (#ns.db.excludedSellers > 0
                and table.concat(ns.db.excludedSellers, ", ") or "none"))
            return
        end
        -- If already excluded, remove; otherwise add
        for i, n in ipairs(ns.db.excludedSellers) do
            if n:lower() == rest:lower() then
                table.remove(ns.db.excludedSellers, i)
                ns.Print("Removed: " .. rest)
                return
            end
        end
        table.insert(ns.db.excludedSellers, rest)
        ns.Print("Excluded: " .. rest)

    -------------------------------------------------------------------
    -- /qf verbose — toggle status → chat mirroring
    -------------------------------------------------------------------
    elseif cmd == "verbose" then
        ns.db.verbose = not ns.db.verbose
        ns.Print("Verbose: " .. (ns.db.verbose
            and "|cff00ff00ON|r (status → chat)" or "|cffff0000OFF|r"))

    -------------------------------------------------------------------
    -- Unknown command
    -------------------------------------------------------------------
    else
        ns.Print("Unknown: " .. cmd .. " — /qf help")
    end
end
