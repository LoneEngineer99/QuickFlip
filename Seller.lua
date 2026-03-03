---------------------------------------------------------------------------
-- Seller.lua — Quick-sell logic: scan, price, post, and cancel
---------------------------------------------------------------------------
-- Implements the "Quick Sell" flow:
--   1. Scan a shopping list for current AH prices (floor calculation).
--   2. Count matching items in the player's bags.
--   3. Check owned auctions for each item.
--   4. Queue posts (if below caps) and cancellations (if out of valid
--      sell range).
--   5. Present each action to the user one at a time; user clicks to
--      execute (C_AuctionHouse.PostCommodity and CancelAuction both
--      require hardware events).
--
-- Three sell caps control posting behaviour:
--   sellPostCap          — total units allowed for sale in valid range
--   sellPostCapPerStack  — max units per auction this cycle
--   sellPostCapListingAmt — max separate auction listings per item
--
-- Shares the two-phase browse → commodity scan with Scanner.lua but
-- routes events via the ns.isSellScanning flag.
---------------------------------------------------------------------------

--- `ns` = addon-private namespace table shared across all .lua files.
--- See Core.lua header for full explanation of the namespace pattern.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Sell-scan state — kept on the shared namespace so Core/UI can inspect.
---------------------------------------------------------------------------
ns.isSellScanning     = false
ns.sellState          = 0       -- reuses STATE_IDLE / STATE_BROWSE / STATE_COMMODITY
ns.sellQueue          = {}      -- search-term strings from the shopping list
ns.sellQueueIdx       = 0
ns.sellResults        = {}      -- scan-result rows for the results scroll
ns.sellScanCount      = 0
ns.sellCurrentItemKey = nil
ns.sellRescanIter     = 0

-- Action queues populated after scan
ns.sellPostQueue      = {}      -- { itemID, itemKey, name, qty, unitPrice, bagSlot }
ns.sellCancelQueue    = {}      -- { auctionID, itemID, name, unitPrice, quantity }
ns.sellPendingPost    = nil     -- current item being posted (shown on sell card)
ns.sellPendingCancel  = nil     -- current auction being cancelled (shown on sell card)
ns.sellPostIdx        = 0       -- index into sellPostQueue
ns.sellCancelIdx      = 0       -- index into sellCancelQueue
ns.sellActionPhase    = "idle"  -- "idle" | "cancel" | "post"

-- Owned-auctions cache (refreshed at start of each sell scan)
ns.ownedAuctions      = {}

-- Bag inventory by lowercase item name (refreshed at start of each sell scan)
ns.sellBagInventory   = {}      -- { ["item name"] = count }

-- Session sell tracking
ns.sellSessionPosts   = 0
ns.sellSessionCancels = 0

---------------------------------------------------------------------------
-- Sell duration constants (C_AuctionHouse enum: 1=12h, 2=24h, 3=48h)
---------------------------------------------------------------------------
local VALID_DURATIONS = { [1] = true, [2] = true, [3] = true }

---------------------------------------------------------------------------
-- BuildBagInventory — snapshot all bag contents keyed by lowercase name
---------------------------------------------------------------------------
-- Called once at the start of each sell scan so we can skip items that
-- the player has none of without burning an AH query.
-- @return table { ["lowercase name"] = totalCount }
---------------------------------------------------------------------------
--- Snapshot all bag contents into a table keyed by lowercase item name.
--- Called once at the start of each sell scan so items not in bags can be
--- skipped without burning an AH query.
--- @return inv (table) mapping of lowercase item name to total stack count
function ns.BuildBagInventory()
    -- Accumulator table: { ["lowercase name"] = totalCount }
    local inv = {}
    -- Iterate over all bag containers (0 = backpack, 1-4 = bags, 5 = reagent bag)
    for bag = 0, 5 do
        -- Query the number of slots available in this bag
        local numSlots = C_Container.GetContainerNumSlots(bag)
        -- Iterate over every slot in the current bag
        for slot = 1, numSlots do
            -- Retrieve item info for this bag/slot position
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- If a valid item occupies this slot
            if info and info.itemID then
                -- Resolve the item ID to its localised display name
                local name = GetItemInfo(info.itemID)
                -- Guard against cache misses (name can be nil on first call)
                if name then
                    -- Normalise to lowercase for case-insensitive matching
                    local key = name:lower()
                    -- Accumulate the stack count for this item name
                    inv[key] = (inv[key] or 0) + info.stackCount
                end
            end
        end
    end
    -- Return the complete bag inventory snapshot
    return inv
end

---------------------------------------------------------------------------
-- CountInBags — count how many of `itemID` the player has in bags 0-4
---------------------------------------------------------------------------
-- @param  itemID (number)
-- @return total  (number) total quantity across all bags
-- @return slots  (table)  array of { bag, slot, count }
---------------------------------------------------------------------------
--- Count how many of a specific item the player has across all bags.
--- Returns both the total quantity and a list of individual bag/slot
--- locations so the caller can build an ItemLocation for posting.
--- @param  itemID (number) the commodity item ID to search for
--- @return total  (number) total quantity across all bags
--- @return slots  (table)  array of { bag, slot, count } entries
function ns.CountInBags(itemID)
    -- Table to collect individual bag/slot hits
    local slots = {}
    -- Running total of matching item quantity
    local total = 0
    -- Iterate over all bag containers (0 = backpack, 1-4 = bags, 5 = reagent bag)
    for bag = 0, 5 do
        -- Query slot count for this bag
        local numSlots = C_Container.GetContainerNumSlots(bag)
        -- Check every slot in the bag
        for slot = 1, numSlots do
            -- Retrieve the item info for this position
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- If the slot contains the item we are looking for
            if info and info.itemID == itemID then
                -- Record this slot's location and stack size
                table.insert(slots, { bag = bag, slot = slot, count = info.stackCount })
                -- Add this stack's count to the running total
                total = total + info.stackCount
            end
        end
    end
    -- Return aggregated count and per-slot details
    return total, slots
end

---------------------------------------------------------------------------
-- CacheOwnedAuctions — snapshot of all our active commodity auctions
---------------------------------------------------------------------------
--- Snapshot all of the player's active commodity auctions into ns.ownedAuctions.
--- Called at the start of each sell scan so we can analyse which items are
--- already listed and at what price, without repeated API calls.
--- @return nil (results stored in ns.ownedAuctions)
function ns.CacheOwnedAuctions()
    -- Reset the cache to start fresh
    ns.ownedAuctions = {}
    -- Query the total number of owned auctions from the AH API
    local count = C_AuctionHouse.GetNumOwnedAuctions()
    -- Iterate over every owned auction
    for i = 1, count do
        -- Fetch metadata for auction at index i
        local info = C_AuctionHouse.GetOwnedAuctionInfo(i)
        -- Only cache active auctions (status 0); skip sold/cancelled
        if info and info.status == 0 then          -- 0 = active
            -- Append to the namespace-level cache for later analysis
            table.insert(ns.ownedAuctions, info)
        end
    end
end

---------------------------------------------------------------------------
-- CountOwnedForItem — analyse our active auctions for a given itemID
---------------------------------------------------------------------------
-- Uses the floor price as the boundary for "valid sell range".  Auctions
-- priced within the valid range count towards the caps; auctions priced
-- well above floor are flagged for cancellation.
--
-- @param  itemID      (number) commodity item ID
-- @param  floorPrice  (number) calculated floor price in copper
-- @param  sellPrice   (number|nil) current optimal sell price in copper
-- @return inRangeQty  (number) total units posted at or near sell price
-- @return inRangeListings (number) count of separate listings in range
-- @return overpriced  (table)  auctions above floor (candidates for cancel)
-- @return undercut    (table)  auctions below floor but behind a wall
---------------------------------------------------------------------------
--- Analyse the player's active auctions for a given item, classifying
--- each as in-range, overpriced (above floor), or undercut (behind wall).
--- @param  itemID      (number)     commodity item ID
--- @param  floorPrice  (number)     calculated floor price in copper
--- @param  sellPrice   (number|nil) current optimal sell price in copper
--- @return inRangeQty      (number) total units posted at or near sell price
--- @return inRangeListings (number) count of separate listings in range
--- @return overpriced      (table)  auctions priced above floor
--- @return undercut        (table)  auctions behind a wall (below floor but above sell)
function ns.CountOwnedForItem(itemID, floorPrice, sellPrice)
    -- Counters for auctions within the acceptable sell-price window
    local inRangeQty      = 0
    local inRangeListings = 0
    local overpriced      = {}
    -- Tables for auctions that should be cancelled
    local undercut        = {}

    -- Tolerance: listings within one undercut step of sellPrice are still valid
    local undercutCopper = math.max((ns.db.sellUndercutSilver or 1), 1) * 100

    -- Iterate through all cached owned auctions
    for _, info in ipairs(ns.ownedAuctions) do
        -- Only process auctions matching the target item ID
        if info.itemKey and info.itemKey.itemID == itemID then
            -- Calculate per-unit price from total buyout / quantity
            local qty  = info.quantity or 0
            local unit = qty > 0 and math.floor((info.buyoutAmount or 0) / qty) or 0
            -- If unit price exceeds floor, flag for cancellation as overpriced
            if floorPrice > 0 and unit > floorPrice then
                -- Above floor → overpriced
                table.insert(overpriced, {
                    auctionID = info.auctionID,
                    itemID    = itemID,
                    unitPrice = unit,
                    quantity  = qty,
                })
            -- If below floor but significantly above the new sell price, it is undercut by a wall
            elseif sellPrice and sellPrice > 0 and unit > sellPrice + undercutCopper then
                -- Below floor but significantly above the new sell price → undercut by wall
                table.insert(undercut, {
                    auctionID = info.auctionID,
                    itemID    = itemID,
                    unitPrice = unit,
                    quantity  = qty,
                })
            -- Otherwise the listing is within the acceptable sell range
            else
                inRangeQty      = inRangeQty + qty
                inRangeListings = inRangeListings + 1
            end
        end
    end
    -- Return classification results to the caller
    return inRangeQty, inRangeListings, overpriced, undercut
end

---------------------------------------------------------------------------
-- CalcSellPrice — determine optimal sell price for FAST selling
---------------------------------------------------------------------------
-- Scenario: we bought a large qty at a discount and want to flip it as
-- quickly as possible.  Speed of sale trumps maximising per-unit profit.
--
-- Key principles (aggressive mode):
--   • Undercut the cheapest listing to be first in the buy queue.
--   • Wall detection uses market volume, NOT our stack cap.  A tier
--     is a "wall" when its cumulative quantity exceeds `sellWallPct`%
--     of total listed volume below floor.  Walls block us; we jump in
--     front so we sell before the wall does.
--   • If the qty ahead of us is a small fraction of the market we can
--     tolerate sitting behind it — it'll get bought up quickly.
--   • Never price below the break-even point after the 5% AH fee.
--   • Never price below `floor * (1 − sellMaxUndercutPct/100)` so we
--     don't sacrifice too much profit just to jump a wall.
--   • Never price above floor.
--
-- Algorithm:
--   1. Compute the break-even and max-undercut price floors.
--   2. Group at-or-below-floor listings into price tiers and sum total
--      volume below floor.
--   3. Walk tiers cheapest→floor; if cumulative qty exceeds
--      `sellWallPct`% of that total volume, the tier is a wall →
--      post at wall − undercut.
--   4. If no wall, undercut the cheapest listing price directly.
--   5. Clamp the result into the allowed range.
--   6. Round to whole silver.
--
-- @param  itemID     (number)
-- @param  floorPrice (number) weighted-average floor in copper
-- @return sellPrice  (number) recommended sell price in copper
---------------------------------------------------------------------------
--- Determine the optimal sell price for fast commodity flipping.
--- Uses wall detection and aggressive undercutting to ensure our listing
--- sells before competing stock. Clamps result to stay above break-even
--- and below floor price.
--- @param  itemID     (number) commodity item ID
--- @param  floorPrice (number) weighted-average floor price in copper
--- @return sellPrice  (number) recommended sell price in copper (silver-rounded)
function ns.CalcSellPrice(itemID, floorPrice)
    -- No valid floor means we cannot determine a sell price
    if floorPrice <= 0 then return 0 end

    -- Query the number of commodity search results currently cached
    local numResults = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    -- If no results are available, default to floor price as sell price
    if not numResults or numResults == 0 then
        return math.max(floorPrice, 1)
    end

    -- Undercut in copper (convert silver setting); minimum 1 silver (100c)
    local undercut = math.max((ns.db.sellUndercutSilver or 1), 1) * 100

    -- Compute break-even: worst-case buy price after AH fee and min profit.
    -- Worst case: we bought at cutoff = floor × (1 − fee) / (1 + minProfitPct/100).
    -- We must sell above that to cover our cost after the 5% AH cut.
    local minProfitPct = ns.db.minProfitPct or 10
    local worstBuy = math.floor(
        floorPrice * (1 - ns.AH_FEE_RATE) / (1 + minProfitPct / 100))
    local breakEven = math.ceil(worstBuy / (1 - ns.AH_FEE_RATE))
    breakEven = math.ceil(breakEven / 100) * 100

    -- Compute the maximum undercut floor: don't sacrifice more than sellMaxUndercutPct below floor
    local maxUndercutFloor = math.floor(
        floorPrice * (1 - (ns.db.sellMaxUndercutPct or 10) / 100))
    maxUndercutFloor = math.floor(maxUndercutFloor / 100) * 100

    -- Step 1: Group all listings into price tiers (cheapest-first)
    -- and compute total volume below floor.
    local tiers    = {}   -- { price, qty }
    local belowFloorQty = 0
    -- Walk all commodity results, grouping by price tier
    for i = 1, numResults do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        -- If the result is valid, process it
        if info then
            -- Stop once we pass the floor price threshold
            if info.unitPrice > floorPrice then break end
            -- Add this listing's quantity to the below-floor total
            belowFloorQty = belowFloorQty + info.quantity
            -- Merge into existing tier if same price, else create new tier
            local last = tiers[#tiers]
            if last and last.price == info.unitPrice then
                last.qty = last.qty + info.quantity
            else
                table.insert(tiers, { price = info.unitPrice, qty = info.quantity })
            end
        end
    end

    -- Clamp helper: round to silver, enforce break-even and floor bounds.
    local function clamp(copper)
        local p = math.floor(copper / 100) * 100
        p = math.max(p, breakEven)
        p = math.max(p, maxUndercutFloor)
        p = math.min(p, floorPrice)
        return math.max(p, 100)
    end

    -- If there are no listings below floor, post at floor − undercut
    if #tiers == 0 then
        return clamp(floorPrice - undercut)
    end

    -- Step 2: Walk tiers cheapest→floor, detect wall.
    -- A wall = cumulative qty > sellWallPct% of total below-floor volume.
    local wallPct      = (ns.db.sellWallPct or 10) / 100
    local tolerableQty = math.max(math.floor(belowFloorQty * wallPct), 1)
    local runningQty   = 0

    -- Iterate over each price tier checking cumulative volume
    for idx = 1, #tiers do
        local tier = tiers[idx]
        runningQty = runningQty + tier.qty

        -- If cumulative volume exceeds the wall threshold, undercut the wall
        if runningQty > tolerableQty then
            -- Wall detected — post just in front of it.
            return clamp(tier.price - undercut)
        end
    end

    -- Step 3: No wall — aggressively undercut the cheapest listing.
    local cheapest = tiers[1].price
    return clamp(cheapest - undercut)
end

---------------------------------------------------------------------------
-- StartSellScan — kick off the quick-sell cycle
---------------------------------------------------------------------------
--- Kick off the quick-sell cycle.
--- Validates that the AH is open and a shopping list is selected, stops
--- any active buy-scan, then queries owned auctions to begin the sell flow.
function ns.StartSellScan()
    -- Guard: AH must be open to interact with the auction API
    if not ns.isAHOpen then
        ns.Print("|cffff0000AH must be open.|r")
        return
    end
    -- Guard: a shopping list must be selected for scanning
    if not ns.db.sellSelectedList or ns.db.sellSelectedList == "" then
        ns.Print("|cffff8000Select a shopping list first.|r")
        return
    end

    -- Halt any active buy-scan to avoid conflicting AH queries
    if ns.isScanning then ns.StopScan() end

    -- Initialise sell-scan state flags
    ns.isSellScanning = true
    ns.sellScanCount  = 0
    ns.sellState      = ns.STATE_IDLE

    -- Update the toggle button text to indicate scanning is active
    if ns.sellToggleButton then
        ns.sellToggleButton:SetText("|cffff4444Stop Selling|r")
    end

    -- Request owned auction data from the server; the response event
    -- (OWNED_AUCTIONS_UPDATED) will trigger SellOnOwnedAuctions
    ns.sellState = ns.STATE_IDLE
    C_AuctionHouse.QueryOwnedAuctions({})
    ns.SetSellStatus("|cff88ccffQuerying owned auctions...|r")
end

---------------------------------------------------------------------------
-- SellOnOwnedAuctions — called when owned auctions data arrives
---------------------------------------------------------------------------
--- Event handler invoked when owned auction data arrives from the server.
--- Caches the auction snapshot and bag inventory, then starts the scan.
function ns.SellOnOwnedAuctions()
    -- Ignore stale events if we are no longer in sell-scan mode
    if not ns.isSellScanning then return end
    -- Build a fresh cache of all our active auctions
    ns.CacheOwnedAuctions()
    -- Snapshot bag contents so we know what we can post
    ns.sellBagInventory = ns.BuildBagInventory()
    -- Begin the item-by-item sell scan pass
    ns.SellDoScan()
end

---------------------------------------------------------------------------
-- StopSellScan — halt all sell scanning
---------------------------------------------------------------------------
--- Halt all sell scanning and reset associated state.
--- Clears queues, pending actions, and updates UI elements.
function ns.StopSellScan()
    -- Disable the sell-scan flag so event handlers exit early
    ns.isSellScanning     = false
    -- Reset scan state machine to idle
    ns.sellState          = ns.STATE_IDLE
    -- Clear the current item key being scanned
    ns.sellCurrentItemKey = nil
    -- Flush post and cancel action queues
    ns.sellPostQueue      = {}
    ns.sellCancelQueue    = {}
    -- Clear any pending single-action items
    ns.sellPendingPost    = nil
    ns.sellPendingCancel  = nil
    -- Reset the action phase to idle
    ns.sellActionPhase    = "idle"

    -- Restore the toggle button text to the start state
    if ns.sellToggleButton then
        ns.sellToggleButton:SetText("|cff00ff00Start Selling|r")
    end
    -- Clear progress text if the widget exists
    if ns.sellProgressText then
        ns.sellProgressText:SetText("")
    end
    -- Update the status bar and refresh all sell-tab UI widgets
    ns.SetSellStatus("|cff888888Stopped|r")
    ns.RefreshSellUI()
end

---------------------------------------------------------------------------
-- SellDoScan — start a full pass over the shopping list
---------------------------------------------------------------------------
--- Start a full pass over the selected shopping list for sell analysis.
--- Retrieves list items, resets all queues and counters, then kicks off
--- processing of the first item.
function ns.SellDoScan()
    -- Bail out if sell scanning was stopped or AH closed mid-scan
    if not ns.isSellScanning or not ns.isAHOpen then return end
    -- If no list is selected, stop the scan gracefully
    if not ns.db.sellSelectedList or ns.db.sellSelectedList == "" then
        ns.StopSellScan()
        return
    end

    -- Load the shopping list items from the built-in list manager
    local items = ns.GetListItems(ns.db.sellSelectedList)
    -- If the list is empty or does not exist, abort
    if not items or #items == 0 then
        ns.Print("|cffff8000List empty or missing.|r")
        ns.StopSellScan()
        return
    end

    -- Store the item queue and reset all indices/counters
    ns.sellQueue       = items
    ns.sellQueueIdx    = 0
    ns.sellResults     = {}
    ns.sellScanCount   = ns.sellScanCount + 1
    ns.sellRescanIter  = 0
    ns.sellPostQueue   = {}
    ns.sellCancelQueue = {}
    ns.sellPostIdx     = 0
    ns.sellCancelIdx   = 0
    ns.sellPendingPost   = nil
    ns.sellPendingCancel = nil
    ns.sellActionPhase   = "idle"

    -- Update UI: status bar, deal card, results list, and sell panel
    ns.SetSellStatus("|cff88ccffSell scan #" .. ns.sellScanCount .. "|r")
    ns.UpdateSellDeal(nil)
    ns.UpdateSellResultsDisplay()
    ns.RefreshSellUI()

    -- Begin processing items one by one
    ns.SellProcessNextItem()
end

---------------------------------------------------------------------------
-- SellProcessNextItem — advance to the next item in the sell queue
---------------------------------------------------------------------------
--- Advance to the next item in the sell queue.
--- Skips items not present in bags, records skip results, and transitions
--- to the action phase (post/cancel) once all items have been scanned.
function ns.SellProcessNextItem()
    -- Guard: stop if sell scan was cancelled or AH closed
    if not ns.isSellScanning or not ns.isAHOpen then return end

    -- Move to the next item index in the queue
    ns.sellQueueIdx = ns.sellQueueIdx + 1

    -- Skip loop: advance past items not found in bags to save AH queries
    while ns.sellQueueIdx <= #ns.sellQueue do
        local term = ns.sellQueue[ns.sellQueueIdx]
        local name = ns.ParseSearchTerm(term):lower()
        if (ns.sellBagInventory[name] or 0) > 0 then
            break  -- we have stock, proceed with AH query
        end
        -- Record a placeholder result so the UI shows this item was considered
        local parsedName = ns.ParseSearchTerm(term)
        table.insert(ns.sellResults, {
            term     = parsedName,
            name     = parsedName,
            itemID   = ns.GetCachedItemID(parsedName),
            minPrice = 0, floorPrice = 0, totalQty = 0,
            bagCount = 0, postedQty = 0, listingCount = 0,
            statusStr = "|cff888888skip (not in bags)|r",
        })
        ns.UpdateSellResultsDisplay()
        -- Move to the next item in the queue
        ns.sellQueueIdx = ns.sellQueueIdx + 1
    end

    -- If we have exhausted all items, transition to the action phase
    if ns.sellQueueIdx > #ns.sellQueue then
        ns.sellState          = ns.STATE_IDLE
        ns.sellCurrentItemKey = nil

        -- Determine which action phase to enter based on queued actions
        if #ns.sellPostQueue > 0 then
            ns.sellActionPhase = "post"
            ns.sellPostIdx = 1
            ns.PresentNextSellPost()
            ns.SetSellStatus(string.format(
                "|cff88ccffScan done — %d to post, %d to cancel. Click buttons.|r",
                #ns.sellPostQueue, #ns.sellCancelQueue))
        elseif #ns.sellCancelQueue > 0 then
            ns.sellActionPhase = "cancel"
            ns.sellCancelIdx = 1
            ns.PresentNextSellCancel()
            ns.SetSellStatus(string.format(
                "|cff88ccffScan done — %d to cancel. Click Cancel.|r",
                #ns.sellCancelQueue))
        else
            ns.sellActionPhase = "idle"
            ns.SetSellStatus(string.format(
                "|cff888888Scan #%d done — %d items, nothing to do.|r",
                ns.sellScanCount, #ns.sellResults))
            -- Auto-loop after a short delay
            C_Timer.After(2.0, function()
                if ns.isSellScanning and ns.isAHOpen then
                    -- Re-query owned auctions before next pass
                    C_AuctionHouse.QueryOwnedAuctions({})
                end
            end)
        end
        -- Update the scan progress indicator
        ns.UpdateSellScanProgress()
        return
    end

    -- Still have items remaining — update progress and scan the next one
    ns.UpdateSellScanProgress()
    ns.SellBeginBrowseQuery()
end

---------------------------------------------------------------------------
-- SellBeginBrowseQuery — Phase 1: resolve item name → ItemKey
---------------------------------------------------------------------------
--- Phase 1 of the sell scan: send a browse query to resolve item name
--- to an ItemKey. Results arrive via AUCTION_HOUSE_BROWSE_RESULTS_UPDATED.
function ns.SellBeginBrowseQuery()
    -- Guard: abort if not scanning or AH closed
    if not ns.isSellScanning or not ns.isAHOpen then return end

    -- Check AH throttle before sending; if throttled, wait for ready event
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        ns.sellState = ns.STATE_IDLE
        ns.SetSellStatus("|cffff8800Throttled — waiting...|r")
        return
    end

    -- Extract the search name from the raw shopping-list term
    local rawTerm    = ns.sellQueue[ns.sellQueueIdx]
    local searchName = ns.ParseSearchTerm(rawTerm)

    -- Transition state to BROWSE and send the AH browse query
    ns.sellState = ns.STATE_BROWSE
    C_AuctionHouse.SendBrowseQuery({
        searchString     = searchName,
        sorts            = {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }},
        filters          = {},
        itemClassFilters  = {},
    })
end

---------------------------------------------------------------------------
-- SellOnBrowseResults — handle Phase 1 response for selling
---------------------------------------------------------------------------
--- Handle Phase 1 browse response for the sell scan.
--- Matches browse results to the current search term, skipping high-quality
--- reagents if configured. On match, caches the ItemKey and proceeds to
--- Phase 2 commodity query. On miss, records an error and advances.
function ns.SellOnBrowseResults()
    -- Only process if we are expecting browse results in sell mode
    if ns.sellState ~= ns.STATE_BROWSE or not ns.isSellScanning then return end

    -- Retrieve the current search term and fetch browse results
    local rawTerm    = ns.sellQueue[ns.sellQueueIdx]
    local searchName = ns.ParseSearchTerm(rawTerm)
    local results    = C_AuctionHouse.GetBrowseResults()

    -- First pass: exact name match with optional quality filter
    local match = nil
    -- Iterate browse results looking for an exact name match
    for _, r in ipairs(results) do
        local name = GetItemInfo(r.itemKey.itemID)
        -- Resolve the item ID to its display name, then check for exact match
        if name and name:lower() == searchName:lower() then
            -- If skipHighQuality is on, skip tier 2+ reagents
            if ns.db.skipHighQuality then
                local tier = C_TradeSkillUI.GetItemReagentQualityByItemInfo(r.itemKey.itemID)
                if tier and tier > 1 then
                    -- skip
                else
                    match = r; break
                end
            else
                match = r; break
            end
        end
    end

    -- Fallback: if no exact match, try the first valid result
    if not match and #results > 0 then
        if ns.db.skipHighQuality then
            for _, r in ipairs(results) do
                local tier = C_TradeSkillUI.GetItemReagentQualityByItemInfo(r.itemKey.itemID)
                if not tier or tier <= 1 then
                    match = r; break
                end
            end
            -- If still no match, all results are tier 2+ — skip item entirely
        else
            match = results[1]
        end
    end

    -- No usable match found — record an error result and advance
    if not match then
        table.insert(ns.sellResults, {
            term = searchName, name = searchName,
            minPrice = 0, floorPrice = 0, totalQty = 0,
            error = true,
        })
        ns.UpdateSellResultsDisplay()
        ns.sellState = ns.STATE_IDLE
        C_Timer.After(0.15, ns.SellProcessNextItem)
        return
    end

    -- Match found: store the ItemKey and cache the item ID for icons
    ns.sellCurrentItemKey = match.itemKey
    local matchName = GetItemInfo(match.itemKey.itemID)
    if matchName then
        ns.CacheItemID(matchName, match.itemKey.itemID)
    end
    -- Proceed to Phase 2: full commodity query for this item
    ns.SellBeginCommodityQuery()
end

---------------------------------------------------------------------------
-- SellBeginCommodityQuery — Phase 2: fetch full commodity listings
---------------------------------------------------------------------------
--- Phase 2 of the sell scan: fetch full commodity listings for the
--- matched ItemKey. Results arrive via COMMODITY_SEARCH_RESULTS_UPDATED.
function ns.SellBeginCommodityQuery()
    -- Guard: abort if not scanning, AH closed, or no current item key
    if not ns.isSellScanning or not ns.isAHOpen or not ns.sellCurrentItemKey then return end

    -- Check AH throttle before sending the commodity query
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        ns.sellState = ns.STATE_IDLE
        ns.SetSellStatus("|cffff8800Throttled — waiting...|r")
        return
    end

    -- Transition state to COMMODITY and send the search query
    ns.sellState = ns.STATE_COMMODITY
    C_AuctionHouse.SendSearchQuery(
        ns.sellCurrentItemKey,
        {{ sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }},
        true
    )
end

---------------------------------------------------------------------------
-- SellOnCommodityResults — handle Phase 2, decide sell actions
---------------------------------------------------------------------------
--- Handle Phase 2 commodity results for the sell scan.
--- Calculates floor and sell prices, checks bag inventory and owned
--- auctions against posting caps, then queues post and cancel actions.
--- @param itemID (number) the commodity item ID whose results arrived
function ns.SellOnCommodityResults(itemID)
    -- Only process if we are in COMMODITY state during a sell scan
    if ns.sellState ~= ns.STATE_COMMODITY or not ns.isSellScanning then return end
    -- Verify the results match the item we are currently scanning
    if not ns.sellCurrentItemKey or ns.sellCurrentItemKey.itemID ~= itemID then return end

    -- Retrieve the search term and resolve the display name
    local rawTerm    = ns.sellQueue[ns.sellQueueIdx]
    local searchName = ns.ParseSearchTerm(rawTerm)
    local name       = GetItemInfo(itemID) or searchName

    -- Calculate the floor price using the shared Scanner.lua algorithm
    local floorPrice, minPrice, totalQty = ns.CalcFloorPrice(itemID)

    -- Count how many of this item the player has in bags
    local bagCount, bagSlots = ns.CountInBags(itemID)

    -- Determine the optimal sell price via wall detection / undercutting
    local sellPrice = ns.CalcSellPrice(itemID, floorPrice)

    -- Classify owned auctions as in-range, overpriced, or undercut.
    -- Pass sellPrice so auctions behind a wall are classified as "undercut"
    -- rather than "in range" — they won't count towards caps.
    local inRangeQty, inRangeListings, overpriced, undercutAuctions =
        ns.CountOwnedForItem(itemID, floorPrice, sellPrice)
    -- Load the three sell caps from saved settings
    local unitCap    = ns.db.sellPostCap or 200
    local stackCap   = ns.db.sellPostCapPerStack or 50
    local listingCap = ns.db.sellPostCapListingAmt or 5

    -- Determine whether we should post and how many units
    local action   = "none"
    local postQty  = 0
    local cancelCount = #overpriced + #undercutAuctions

    -- Check if there is room under all three caps to post more units
    if bagCount > 0 and sellPrice > 0
    and inRangeQty < unitCap
    and inRangeListings < listingCap then
        -- Calculate how many units we can still list without exceeding caps
        local roomByUnits = unitCap - inRangeQty
        postQty = math.min(bagCount, roomByUnits, stackCap)
        if postQty > 0 then
            action = "post"
        end
    end

    -- Queue a post action if we have units to list and bag slots available
    if action == "post" and postQty > 0 and #bagSlots > 0 then
        table.insert(ns.sellPostQueue, {
            itemID     = itemID,
            itemKey    = ns.sellCurrentItemKey,
            name       = name,
            quantity   = postQty,
            unitPrice  = sellPrice,
            floorPrice = floorPrice,
            bagSlot    = bagSlots[1],   -- first bag location
        })
    end

    -- Queue cancel actions for auctions priced above floor
    for _, oa in ipairs(overpriced) do
        table.insert(ns.sellCancelQueue, {
            auctionID = oa.auctionID,
            itemID    = oa.itemID,
            name      = name,
            unitPrice = oa.unitPrice,
            quantity  = oa.quantity,
        })
    end

    -- Queue cancel actions for wall-undercut auctions (below floor but behind wall)
    for _, ua in ipairs(undercutAuctions) do
        table.insert(ns.sellCancelQueue, {
            auctionID = ua.auctionID,
            itemID    = ua.itemID,
            name      = name,
            unitPrice = ua.unitPrice,
            quantity  = ua.quantity,
        })
    end

    -- Build a human-readable status string for the results display
    local statusStr
    if action == "post" then
        if cancelCount > 0 then
            statusStr = string.format("|cff00ff00POST %d|r @ %s  |cffff8800CANCEL %d|r",
                postQty, ns.MC(sellPrice), cancelCount)
        else
            statusStr = string.format("|cff00ff00POST %d|r @ %s", postQty, ns.MC(sellPrice))
        end
    elseif cancelCount > 0 then
        statusStr = string.format("|cffff8800CANCEL %d|r", cancelCount)
    elseif bagCount == 0 then
        statusStr = "|cff888888no stock|r"
    elseif inRangeQty >= unitCap then
        statusStr = "|cff888888at unit cap|r"
    elseif inRangeListings >= listingCap then
        statusStr = "|cff888888at listing cap|r"
    else
        statusStr = "|cff888888—|r"
    end

    -- Record the full result row for the sell results scroll list
    table.insert(ns.sellResults, {
        term        = searchName,
        name        = name,
        itemID      = itemID,
        minPrice    = minPrice,
        floorPrice  = floorPrice,
        totalQty    = totalQty,
        bagCount    = bagCount,
        postedQty   = inRangeQty,
        listingCount = inRangeListings,
        postQty     = postQty,
        sellPrice   = sellPrice,
        cancelCount = cancelCount,
        action      = action,
        statusStr   = statusStr,
    })
    -- Refresh the results display to show the new entry
    ns.UpdateSellResultsDisplay()

    -- Reset state and schedule processing of the next item
    ns.sellState = ns.STATE_IDLE
    ns.sellCurrentItemKey = nil
    ns.sellRescanIter     = 0
    C_Timer.After(0.1, ns.SellProcessNextItem)
end

---------------------------------------------------------------------------
-- PresentNextSellCancel — show the next cancel action on the sell card
---------------------------------------------------------------------------
-- CancelAuction requires a hardware event, so we present each cancel
-- one at a time for the user to click.
---------------------------------------------------------------------------
--- Present the next cancel action on the sell card for user confirmation.
--- CancelAuction requires a hardware event (click), so each cancel is
--- shown individually for the user to approve.
function ns.PresentNextSellCancel()
    -- If we have exhausted the cancel queue, all cancels are done
    if ns.sellCancelIdx > #ns.sellCancelQueue then
        -- Cancels done — all actions complete, rescan
        ns.sellPendingCancel = nil
        ns.sellActionPhase = "idle"
        ns.UpdateSellDeal(nil)
        ns.SetSellStatus("|cff00ff00All done! Rescanning...|r")
        C_Timer.After(2.0, function()
            if ns.isSellScanning and ns.isAHOpen then
                C_AuctionHouse.QueryOwnedAuctions({})
            end
        end)
        return
    -- Load the next cancel entry and display it on the sell card
    end

    local cancel = ns.sellCancelQueue[ns.sellCancelIdx]
    ns.sellPendingCancel = cancel
    ns.UpdateSellCancel(cancel)

    -- Play an alert sound if the user has sound notifications enabled
    if ns.db.soundOnDeal then PlaySoundFile(ns.SOUND_DEAL, "Master") end
end

---------------------------------------------------------------------------
-- OnSellCancelClicked — user clicked Cancel button (hardware event)
---------------------------------------------------------------------------
--- Handler for the Cancel button click (hardware event).
--- Sends the CancelAuction API call for the pending auction, logs the
--- action, and advances to the next cancel in the queue.
function ns.OnSellCancelClicked()
    -- Retrieve the pending cancel entry
    local cancel = ns.sellPendingCancel
    -- Guard: nothing to cancel or AH closed
    if not cancel or not ns.isAHOpen then return end

    -- Attempt to cancel the auction via the AH API (pcall for safety)
    pcall(C_AuctionHouse.CancelAuction, cancel.auctionID)
    -- Increment the session cancel counter for tracking
    ns.sellSessionCancels = ns.sellSessionCancels + 1
    -- Log the cancellation to chat for user visibility
    ns.Print(string.format(
        "|cffff8800Cancelled|r %s x%d @ %s (above floor)",
        cancel.name, cancel.quantity or 0, ns.MC(cancel.unitPrice)))

    -- Clear the pending cancel and advance to the next one
    ns.sellPendingCancel = nil
    ns.sellCancelIdx = ns.sellCancelIdx + 1
    C_Timer.After(0.3, ns.PresentNextSellCancel)
end

---------------------------------------------------------------------------
-- SkipSellCancel — skip current cancel, move to next
---------------------------------------------------------------------------
--- Skip the current cancel action without executing it.
--- Advances to the next cancel in the queue.
function ns.SkipSellCancel()
    -- Clear the current pending cancel entry
    ns.sellPendingCancel = nil
    -- Move the cancel index forward
    ns.sellCancelIdx = ns.sellCancelIdx + 1
    -- Present the next cancel (or finish if queue exhausted)
    ns.PresentNextSellCancel()
end

---------------------------------------------------------------------------
-- PresentNextSellPost — show the next post action on the sell card
---------------------------------------------------------------------------
--- Present the next post action on the sell card for user confirmation.
--- PostCommodity requires a hardware event (click), so each post is
--- shown individually. After all posts, transitions to the cancel phase.
function ns.PresentNextSellPost()
    -- If we have exhausted the post queue, move to the next phase
    if ns.sellPostIdx > #ns.sellPostQueue then
        -- Posts done — move to cancels if any
        ns.sellPendingPost = nil
        if #ns.sellCancelQueue > 0 then
            ns.sellActionPhase = "cancel"
            ns.sellCancelIdx = 1
            ns.PresentNextSellCancel()
        else
            ns.sellActionPhase = "idle"
            ns.UpdateSellDeal(nil)
            ns.SetSellStatus("|cff00ff00All posts done! Rescanning...|r")
            C_Timer.After(2.0, function()
                if ns.isSellScanning and ns.isAHOpen then
                    C_AuctionHouse.QueryOwnedAuctions({})
                end
            end)
        end
        return
    end

    -- Load the next post entry and display it on the sell deal card
    local post = ns.sellPostQueue[ns.sellPostIdx]
    ns.sellPendingPost = post
    ns.UpdateSellDeal(post)

    -- Play an alert sound if sound notifications are enabled
    if ns.db.soundOnDeal then PlaySoundFile(ns.SOUND_DEAL, "Master") end
end

---------------------------------------------------------------------------
-- OnSellPostClicked — user clicked Post (hardware event)
---------------------------------------------------------------------------
--- Handler for the Post button click (hardware event).
--- Constructs an ItemLocation from the bag slot, validates the item
--- still exists, rounds the price to silver, and posts the commodity.
function ns.OnSellPostClicked()
    -- Retrieve the pending post entry
    local post = ns.sellPendingPost
    -- Guard: nothing to post or AH closed
    if not post or not ns.isAHOpen then return end

    -- Locate the item in the player's bags for posting
    local bagSlot = post.bagSlot
    if not bagSlot then
        ns.Print("|cffff0000No bag slot for posting.|r")
        ns.SkipSellPost()
        return
    end

    -- Build an ItemLocation from the bag and slot indices
    local itemLocation = ItemLocation:CreateFromBagAndSlot(bagSlot.bag, bagSlot.slot)
    -- Verify the item still exists (may have been moved or consumed)
    if not C_Item.DoesItemExist(itemLocation) then
        ns.Print("|cffff0000Item no longer in bag.|r")
        ns.SkipSellPost()
        return
    end

    -- Validate and default the auction duration setting
    local duration = VALID_DURATIONS[ns.db.sellDuration] and ns.db.sellDuration or 2

    -- Round the unit price to whole silver (copper causes posting failures)
    local postPrice = math.floor(post.unitPrice / 100) * 100
    postPrice = math.max(postPrice, 100) -- minimum 1 silver

    -- Attempt to post the commodity via the AH API (pcall for safety)
    pcall(C_AuctionHouse.PostCommodity,
        itemLocation, duration, post.quantity, postPrice)

    -- Increment the session post counter for tracking
    ns.sellSessionPosts = ns.sellSessionPosts + 1
    -- Log the successful post to chat for user visibility
    ns.Print(string.format(
        "|cff00ff00Posted|r %s x%d @ %s ea",
        post.name, post.quantity, ns.MC(postPrice)))

    -- Play a confirmation sound if enabled
    if ns.db.soundOnDeal then PlaySoundFile(ns.SOUND_DEAL, "Master") end

    -- Clear the pending post and advance to the next one
    ns.sellPendingPost = nil
    ns.sellPostIdx = ns.sellPostIdx + 1
    C_Timer.After(0.5, ns.PresentNextSellPost)
end

---------------------------------------------------------------------------
-- SkipSellPost — skip current post, move to next
---------------------------------------------------------------------------
--- Skip the current post action without executing it.
--- Advances to the next post in the queue.
function ns.SkipSellPost()
    -- Clear the current pending post entry
    ns.sellPendingPost = nil
    -- Move the post index forward
    ns.sellPostIdx = ns.sellPostIdx + 1
    -- Present the next post (or transition to cancel phase if done)
    ns.PresentNextSellPost()
end

---------------------------------------------------------------------------
-- SetSellStatus — update the sell panel status text
---------------------------------------------------------------------------
--- Update the sell panel status text and optionally echo to chat.
--- @param msg (string) the status message (may contain colour codes)
function ns.SetSellStatus(msg)
    -- Update the UI widget if it has been created
    if ns.sellStatusText then
        ns.sellStatusText:SetText(msg)
    end
    -- Echo to chat when verbose mode is enabled in settings
    if ns.db and ns.db.verbose then
        ns.Print(msg)
    end
end

---------------------------------------------------------------------------
-- InitSellFrame — create the hidden frame for sell-related events
---------------------------------------------------------------------------
--- Create the hidden event frame used to listen for sell-related events.
--- Idempotent: does nothing if the frame already exists.
function ns.InitSellFrame()
    -- Guard: only create the frame once
    if ns.sellFrame then return end
    -- Create a hidden frame parented to UIParent for event listening
    ns.sellFrame = CreateFrame("Frame", "QuickFlipSellFrame", UIParent)
    -- Register for the owned auctions data event
    ns.sellFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
    -- Route OWNED_AUCTIONS_UPDATED events to SellOnOwnedAuctions
    ns.sellFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "OWNED_AUCTIONS_UPDATED" then
            ns.SellOnOwnedAuctions()
        end
    end)
end
