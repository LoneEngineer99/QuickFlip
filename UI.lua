---------------------------------------------------------------------------
-- UI.lua — All user-interface code
---------------------------------------------------------------------------
-- Builds the custom AH tab panel, deal card, scan-results list, status
-- bar, options panel, and handles visual updates.
--
-- Layout overview:
--   ┌──────────────────────────────────────────────────────────────────┐
--   │ Header (addon name + version)                                   │
--   │ List dropdown  |  Start/Stop button  |  Scan count              │
--   │ Progress text                                                   │
--   ├──────────────────────────────┬───────────────────────────────────┤
--   │ Scan Results (scrollable)    │ Deal Card (icon, name, prices,   │
--   │                              │   qty, profit, buy/skip buttons) │
--   │                              │                                  │
--   │                              │ Session profit text              │
--   ├──────────────────────────────┴───────────────────────────────────┤
--   │ Settings text (live config display)                             │
--   │ [AH gold bar] ──── Status bar / progress fill ──────────────── │
--   └──────────────────────────────────────────────────────────────────┘
---------------------------------------------------------------------------

--- `ns` = addon-private namespace table shared across all .lua files.
--- See Core.lua header for full explanation of the namespace pattern.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
--- UpdateDeal — populate or clear the deal card
---------------------------------------------------------------------------
--- Receives a deal table from the Scanner (or nil) and refreshes every
--- element in the deal card: icon, name, price labels, profit estimate,
--- buy/skip buttons, and backdrop colours.
---
--- @param deal table|nil  Deal info from Scanner, or nil to clear.
---   Fields: deal.itemID, deal.unitPrice, deal.floorPrice, deal.quantity,
---   deal.availableQty, deal.name, deal.totalDealCost, deal.projectedSellPrice
---------------------------------------------------------------------------
function ns.UpdateDeal(deal)
    -- Guard: bail out if the UI panel hasn't been created yet
    if not ns.panelBuilt then return end

    if deal then
        -- Store deal so the Buy button can act on it
        ns.pendingDeal = deal

        ---------------------------------------------------------------
        -- Calculations — derive display values from raw deal data
        ---------------------------------------------------------------
        local pct       = deal.floorPrice > 0                           -- unit price as a % of floor (0 if floor unknown)
            and math.floor(deal.unitPrice / deal.floorPrice * 100) or 0
        local totalCost  = deal.unitPrice * deal.quantity               -- total copper cost for the buy qty
        local sellPrice  = deal.projectedSellPrice or deal.floorPrice   -- best estimate of resale price per unit
        local estRevenue = sellPrice * deal.quantity                    -- gross revenue if every unit sells
        local ahFee      = math.floor(estRevenue * ns.AH_FEE_RATE)     -- Blizzard's 5 % auction house cut
        local estProfit  = estRevenue - ahFee - totalCost               -- net profit after AH fee and purchase cost

        ---------------------------------------------------------------
        -- Icon — load item texture (async-capable via Item mixin)
        ---------------------------------------------------------------
        local icon = C_Item.GetItemIconByID(deal.itemID)                -- returns cached icon or nil
        if icon then
            -- Icon already in client cache — show it immediately
            ns.dealIcon:SetTexture(icon); ns.dealIcon:Show()
        else
            -- Not cached yet — show placeholder while we request from server
            ns.dealIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); ns.dealIcon:Show()
            local item = Item:CreateFromItemID(deal.itemID)             -- create async Item handle
            item:ContinueOnItemLoad(function()                          -- fires once item data arrives
                local loadedIcon = C_Item.GetItemIconByID(deal.itemID)
                -- Only apply if we're still looking at the same deal
                if loadedIcon and ns.pendingDeal and ns.pendingDeal.itemID == deal.itemID then
                    ns.dealIcon:SetTexture(loadedIcon)
                end
            end)
        end

        ---------------------------------------------------------------
        -- Text fields — populate every label on the deal card
        ---------------------------------------------------------------
        -- Item name in green
        ns.dealNameText:SetText("|cff00ff00" .. (deal.name or "?") .. "|r")
        -- Price as a percentage of the floor price
        ns.dealPctText:SetText(string.format("|cff00ff00%d%% of floor|r", pct))
        -- Per-unit prices: current / floor / projected sell
        ns.dealPriceText:SetText(string.format(
            "|cffffd100Price:|r %s ea  |cffffd100Floor:|r %s ea  |cffffd100Sell:|r %s ea",
            ns.MC(deal.unitPrice), ns.MC(deal.floorPrice), ns.MC(sellPrice)))
        -- Quantity breakdown: buying / available / full deal size
        ns.dealQtyText:SetText(string.format(
            "|cffffd100Qty:|r |cffffffff%d|r buy  /  |cff888888%d avail|r",
            deal.quantity, deal.availableQty or deal.quantity))
        -- Total purchase cost formatted as gold/silver/copper
        ns.dealCostText:SetText(string.format(
            "|cffffd100Cost:|r %s", ns.FormatMoney(totalCost)))

        -- Estimated profit (green if positive, red if negative)
        local profitColor = estProfit >= 0 and "|cff00ff00" or "|cffff0000"  -- colour code by sign
        local profitSign  = estProfit >= 0 and "+" or "-"                    -- explicit sign prefix
        -- Profit line with AH fee disclaimer
        ns.dealProfitText:SetText(string.format(
            "|cffffd100Est Profit:|r %s%s%s|r |cff888888(after 5%% AH fee)|r",
            profitColor, profitSign, ns.FormatMoney(math.abs(estProfit))))
        -- Full deal info: total units and cost of all deal-priced stock
        ns.dealFloorText:SetText(string.format(
            "|cffffd100Full Deal:|r %d units @ %s",
            deal.availableQty or 0,
            ns.FormatMoney(deal.totalDealCost or 0)))

        ---------------------------------------------------------------
        -- Buttons — enable Buy/Skip and update Buy label with cost
        ---------------------------------------------------------------
        ns.buyButton:Enable()                                           -- allow user to click Buy
        ns.buyButton:SetText("|cff00ff00▶ BUY|r  " .. ns.FormatMoney(totalCost))  -- label includes total cost
        ns.skipButton:Enable(); ns.skipButton:Show()                    -- reveal the Skip option

        -- Visual feedback: green-tinted border + background on deal card
        ns.dealCard:SetBackdropBorderColor(0.2, 0.85, 0.4, 0.9)       -- bright green border
        ns.dealCard:SetBackdropColor(0.05, 0.08, 0.05, 1)             -- dark green background

        -- Show the card now that we have a deal
        ns.dealCard:Show()

        -- Update the status bar with a "deal found" prompt
        ns.SetStatus("|cff00ccff⚡ DEAL FOUND|r |cffffffff— Buy or Skip.|r")
    else
        ---------------------------------------------------------------
        -- No deal — reset the card to its empty / idle state
        ---------------------------------------------------------------
        ns.pendingDeal = nil                                            -- clear stored deal reference
        ns.dealIcon:SetTexture(nil); ns.dealIcon:Hide()                 -- remove icon
        ns.dealNameText:SetText("|cff666666No deal|r")                  -- grey placeholder text
        ns.dealPctText:SetText("")                                      -- clear pct label
        ns.dealPriceText:SetText("")                                    -- clear price row
        ns.dealFloorText:SetText("")                                    -- clear full-reset row
        ns.dealQtyText:SetText("")                                      -- clear qty row
        ns.dealCostText:SetText("")                                     -- clear cost row
        ns.dealProfitText:SetText("")                                   -- clear profit row
        ns.buyButton:Disable()                                          -- grey-out Buy button
        ns.buyButton:SetText("Buy Deal")                                -- reset Buy label to default
        ns.skipButton:Disable(); ns.skipButton:Hide()                   -- hide Skip button
        -- Hide the card entirely when no deal is active
        ns.dealCard:Hide()
    end
end

---------------------------------------------------------------------------
-- UpdateResultsDisplay — refresh the scrollable scan-results list
---------------------------------------------------------------------------
--- Rebuilds the results scroll frame from `ns.scanResults`.
--- Each item gets a multi-line block: header line with icon + name + status,
--- detail line with price / floor / cutoff / margin / projected sell,
--- followed by a blank separator line.
---------------------------------------------------------------------------
function ns.UpdateResultsDisplay()
    -- Guard: bail if the panel hasn't been built or the scroll frame is missing
    if not ns.panelBuilt or not ns.resultsScroll then return end

    -- ── Build result lines ──
    ns.resultsScroll:Clear()
    for i = 1, #ns.scanResults do
        local r = ns.scanResults[i]
        if r.error then
            ns.resultsScroll:AddMessage(string.format(
                "|cffff4444%d.  %s — not found|r", i, r.term))
        else
            -- Resolve itemID: use result field, or fall back to name cache
            local itemID = r.itemID or ns.GetCachedItemID(r.name)

            -- Item icon via inline texture escape (14×14 px)
            local iconTex = ""
            if itemID then
                local texPath = C_Item.GetItemIconByID(itemID)
                if texPath then
                    iconTex = string.format("|T%s:14:14:0:0|t ", tostring(texPath))
                end
            end

            -- Status tag
            local tag
            if r.isDeal then
                tag = "|cff00ff00DEAL|r"
            else
                tag = ""
            end

            -- Line 1: index + icon + name + status
            ns.resultsScroll:AddMessage(string.format(
                "|cff999999%d.|r  %s%s  %s",
                i, iconTex, r.name, tag))

            -- Line 2: price details
            local pct = r.floorPrice > 0
                and math.floor(r.minPrice / r.floorPrice * 100) or 0
            local marginStr = r.margin
                and string.format("%.1f%%", r.margin) or "—"
            local projStr   = r.projSellPrice and r.projSellPrice > 0
                and ns.FormatGold(r.projSellPrice) or "—"
            local cutoffStr = r.cutoffPrice and r.cutoffPrice > 0
                and ns.FormatGold(r.cutoffPrice) or "—"

            ns.resultsScroll:AddMessage(string.format(
                "      price %s |cff888888(%d%%)|r  floor %s  cutoff %s  margin %s  proj %s",
                ns.FormatGold(r.minPrice), pct,
                ns.FormatGold(r.floorPrice),
                cutoffStr, marginStr, projStr))
        end
        -- Blank separator line between items
        ns.resultsScroll:AddMessage(" ")
    end
    -- Auto-scroll so the most recent result is always visible
    ns.resultsScroll:ScrollToBottom()
end

---------------------------------------------------------------------------
-- UpdateScanProgress — update the progress text and bar during scanning
---------------------------------------------------------------------------
--- Sets the progress label to show "idx/total itemName (pass N/M)" while
--- scanning, a green "complete" message when finished, or blank when idle.
--- Also triggers `ns.UpdateProgressBar()` to sync the fill bar.
---------------------------------------------------------------------------
function ns.UpdateScanProgress()
    -- Guard: nothing to update if panel or text widget doesn't exist yet
    if not ns.panelBuilt or not ns.progressText then return end
    if ns.isScanning and #ns.scanQueue > 0 and ns.scanQueueIdx <= #ns.scanQueue then
        -- ── Scanning in progress ──
        -- Clamp idx so it never exceeds the queue length (defensive)
        local idx = math.min(ns.scanQueueIdx, #ns.scanQueue)
        -- Build optional "(pass N/M)" suffix when multiple rescan passes
        -- are configured; hide it on the first pass (rescanIter == 0)
        local rescanInfo = ""
        if ns.db.rescanCount > 1 and ns.rescanIter > 0 then
            rescanInfo = string.format(
                "  |cff666666(pass %d/%d)|r", ns.rescanIter, ns.db.rescanCount)
        end
        -- Display: "3/12 Dreamleaf  (pass 2/3)"
        ns.progressText:SetText(string.format(
            "|cff88ccff%d/%d|r |cff999999%s|r%s",
            idx, #ns.scanQueue,
            ns.ParseSearchTerm(ns.scanQueue[idx]),
            rescanInfo))
    elseif ns.isScanning and #ns.scanQueue > 0
           and ns.scanQueueIdx > #ns.scanQueue then
        -- ── Scan complete — all items processed ──
        ns.progressText:SetText(string.format(
            "|cff00ff00%d/%d complete|r", #ns.scanQueue, #ns.scanQueue))
    else
        -- ── Idle / reset — clear the label ──
        ns.progressText:SetText("")
    end
    -- Keep the progress bar in sync with the text
    ns.UpdateProgressBar()
end

---------------------------------------------------------------------------
-- UpdateProgressBar — fill the status-bar background proportionally
---------------------------------------------------------------------------
--- Sizes and colours the progress-bar fill texture to reflect how far
--- through the scan queue (including rescan passes) we have progressed.
--- Hides the bar entirely when not scanning.
---------------------------------------------------------------------------
function ns.UpdateProgressBar()
    -- Guard: fill texture must exist
    if not ns.progressBarFill then return end
    -- Guard: the status panel frame (named global) must be available
    local statusPanel = _G["QuickFlipStatusPanel"]
    if not statusPanel then return end

    if ns.isScanning and #ns.scanQueue > 0 then
        -- ── Scanning — compute and display progress ──
        -- Total work units = items × rescan passes (at least 1 pass)
        local total = #ns.scanQueue * math.max(ns.db.rescanCount, 1)
        -- Completed work units so far
        local done
        if ns.scanQueueIdx > #ns.scanQueue then
            done = total  -- 100% — all items processed
        else
            -- Each fully-scanned item accounts for rescanCount units;
            -- add the current pass index within the current item
            local idx = math.min(ns.scanQueueIdx, #ns.scanQueue)
            done = (idx - 1) * math.max(ns.db.rescanCount, 1) + ns.rescanIter
        end
        -- Normalise to 0-1 and clamp to avoid overshooting
        local pct      = total > 0 and (done / total) or 0
        pct = math.min(pct, 1)
        -- Subtract 2px for the panel's 1px border on each side
        local barWidth = statusPanel:GetWidth() - 2  -- account for border insets
        -- Ensure at least 1px width so the texture is always renderable
        ns.progressBarFill:SetWidth(math.max(barWidth * pct, 1))
        -- Dark green tint for the filled portion
        ns.progressBarFill:SetColorTexture(0.15, 0.25, 0.15, 1)
        ns.progressBarFill:Show()
    else
        -- ── Not scanning — hide the bar ──
        ns.progressBarFill:Hide()
    end
end

---------------------------------------------------------------------------
-- RefreshUI — update the settings display and list dropdown
---------------------------------------------------------------------------
--- Synchronises the on-screen settings summary, list dropdown label,
--- and scan-count badge with the current values in `ns.db`.
--- Called after any option change, list selection, or scan completion.
---------------------------------------------------------------------------
function ns.RefreshUI()
    -- Guard: skip everything if the panel hasn't been constructed yet
    if not ns.panelBuilt then return end

    -- ── Settings text ──
    -- Pipe-separated summary of key config values displayed at the top
    -- of the Flip tab so the user can see active settings at a glance.
    -- Format: "Min Profit 10% | Sample 10% | Confirm Auto | Sound ON | R2+ Skip | Max none"
    if ns.settingsText then
        ns.settingsText:SetText(string.format(
            "Min Profit |cffffffff%d%%|r  |  Sample |cffffffff%d%%|r  |  "
            .. "Confirm %s  |  Sound %s  |  R2+ %s  |  Max |cffffffff%s|r",
            ns.db.minProfitPct,
            ns.db.samplePct,
            -- Green "Auto" when auto-confirm is on, red "Manual" otherwise
            ns.db.autoConfirm and "|cff00ff00Auto|r" or "|cffff0000Manual|r",
            -- Green "ON" / red "OFF" for deal-found sound effect
            ns.db.soundOnDeal and "|cff00ff00ON|r" or "|cffff0000OFF|r",
            -- R2+ (tier 2+ reagents): "Skip" means ignore them, "Buy" means include
            ns.db.skipHighQuality and "|cffff0000Skip|r" or "|cff00ff00Buy|r",
            -- Max buy price cap — show formatted gold or "none" if unlimited
            ns.db.maxBuyPrice > 0 and ns.FormatMoney(ns.db.maxBuyPrice) or "none"
        ))
    end

    -- ── List dropdown ──
    -- Show the selected list name; if none selected, show a placeholder
    -- hint only when no lists exist at all (otherwise leave blank)
    local dd = _G["QuickFlipListDD"]
    if dd then
        local hasLists = #ns.GetListNames() > 0
        UIDropDownMenu_SetText(dd,
            ns.db.selectedList ~= "" and ns.db.selectedList
            or (hasLists and "" or "-- Pick a shopping list --"))
    end

    -- ── Scan count badge ──
    -- Grey "#N" counter next to the scan button; hidden when zero
    if ns.scanCountText then
        ns.scanCountText:SetText(
            ns.scanCount > 0 and ("|cff999999#" .. ns.scanCount .. "|r") or "")
    end
end

---------------------------------------------------------------------------
--- BuildPanel — construct the main addon panel inside AuctionHouseFrame
---------------------------------------------------------------------------
--- Creates all UI elements: header, list dropdown, scan buttons, results
--- scroll frame, deal card with buy/skip, session profit, settings text,
--- status bar with progress fill, and the hidden K-key buy frame.
---
--- Called once from Core.lua when the AH is first opened. All subsequent
--- opens reuse the already-built panel.
---
--- @return Frame panel  The root panel frame anchored to AuctionHouseFrame
---------------------------------------------------------------------------
function ns.BuildPanel()
    -- Guard: only build once; subsequent calls return the existing panel
    if ns.panelBuilt then return ns.panel end

    -- Root frame — parented to AuctionHouseFrame so it inherits show/hide
    ns.panel = CreateFrame("Frame", "QuickFlipPanel", AuctionHouseFrame)
    ns.panel:SetAllPoints()   -- fill the entire AH window
    ns.panel:Hide()           -- hidden until the QuickFlip tab is selected

    -- Solid dark background behind all content (inset slightly for the AH border)
    local bg = ns.panel:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 3, -31)       -- 3px from left, 31px below top (under AH title bar)
    bg:SetPoint("BOTTOMRIGHT", -3, 2)    -- 3px inset from right, 2px above bottom
    bg:SetColorTexture(0.02, 0.02, 0.02, 1)  -- near-black

    -- Layout constants — shared spacing values used by all child elements
    local PAD = 10           -- general padding between elements and edges
    local L   = PAD + 5     -- left anchor inset (15px from panel left)
    local T   = -68          -- Y offset for top content row (below AH tabs)
    local R   = -PAD - 5    -- right anchor inset (negative for right-side offsets)

    -- Vertical split: left pane ≈65% (results list), right pane ≈35% (deal card)
    local panelWidth = AuctionHouseFrame:GetWidth() or 890  -- fallback width
    local SPLIT_X    = math.floor(panelWidth * 0.65)        -- pixel X where deal card begins

    -----------------------------------------------------------------------
    -- HEADER — addon name and version
    -----------------------------------------------------------------------
    -- FontString overlay at top-left showing "QuickFlip vX.Y.Z"
    local header = ns.panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", L, T)
    header:SetText("|cff33ff99QuickFlip|r  |cff555555v" .. ns.VERSION .. "|r")

    -----------------------------------------------------------------------
    -- ROW 1 — Shopping list dropdown
    -----------------------------------------------------------------------
    local row1Y     = T - 28  -- 28px below header
    -- Label for the dropdown
    local listLabel = ns.panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", L, row1Y)
    listLabel:SetText("|cffffd100List:|r")  -- gold-coloured label

    -- UIDropDownMenu frame — WoW standard dropdown using the global template
    local dd = CreateFrame("Frame", "QuickFlipListDD", ns.panel, "UIDropDownMenuTemplate")
    dd:SetPoint("LEFT", listLabel, "RIGHT", -8, -3)  -- nudge left/down to align with label
    UIDropDownMenu_SetWidth(dd, 220)  -- fixed width to accommodate long list names

    -- Populate the dropdown with available shopping lists.
    -- This callback is invoked by the dropdown framework each time it opens.
    UIDropDownMenu_Initialize(dd, function(self, level)
        local names = ns.GetListNames()  -- returns sorted list names from ListManager

        -- Show placeholder only when no lists exist
        if #names == 0 then
            local info  = UIDropDownMenu_CreateInfo()  -- new empty info table
            info.text   = "-- Pick a shopping list --"  -- display text
            info.value  = ""                             -- empty value = no selection
            info.checked = (ns.db.selectedList == "")    -- check-mark if nothing selected
            info.notCheckable = true                     -- hide the check-mark radio button
            -- OnClick: clear selection and reset dropdown text
            info.func   = function()
                ns.db.selectedList = ""
                UIDropDownMenu_SetText(dd, "-- Pick a shopping list --")
                ns.StopScan(); ns.RefreshUI()
            end
            UIDropDownMenu_AddButton(info, level)  -- add this entry to the menu
        end

        -- List entries from our built-in list manager
        for _, n in ipairs(names) do
            local items = ns.GetListItems(n)  -- items in this list (for count display)
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = n .. "  |cff888888(" .. (items and #items or 0) .. ")|r"  -- "ListName  (N)"
            info.value    = n                                  -- stored value = list name
            info.checked  = (ns.db.selectedList == n)          -- highlight currently selected
            -- OnClick: save selection, update dropdown label, refresh UI
            info.func     = function()
                ns.db.selectedList = n
                UIDropDownMenu_SetText(dd, n); ns.RefreshUI()
            end
            UIDropDownMenu_AddButton(info, level)  -- add this entry to the menu
        end
    end)
    -- Set initial dropdown text based on saved selection
    local hasLists = #ns.GetListNames() > 0
    UIDropDownMenu_SetText(dd,
        ns.db.selectedList ~= "" and ns.db.selectedList
        or (hasLists and "" or "-- Pick a shopping list --"))

    -----------------------------------------------------------------------
    -- ROW 2 — Start/Stop toggle + scan count badge
    -----------------------------------------------------------------------
    local row2Y = row1Y - 36  -- 36px below the dropdown row

    -- Toggle button — starts or stops the scanning loop
    ns.toggleButton = CreateFrame("Button", nil, ns.panel, "UIPanelButtonTemplate")
    ns.toggleButton:SetSize(150, 24)
    ns.toggleButton:SetPoint("TOPLEFT", L, row2Y)
    ns.toggleButton:SetText("|cff00ff00Start Scanning|r")
    -- OnClick: toggle between scanning and idle; StopScan/StartScan update button text
    ns.toggleButton:SetScript("OnClick", function()
        if ns.isScanning then ns.StopScan() else ns.StartScan() end
    end)

    -- Grey "#N" badge showing how many full scan cycles have completed this session
    ns.scanCountText = ns.panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.scanCountText:SetPoint("LEFT", ns.toggleButton, "RIGHT", 10, 0)

    -----------------------------------------------------------------------
    -- ROW 3 — Progress text
    -----------------------------------------------------------------------
    local row3Y = row2Y - 26  -- 26px below toggle button row

    -- Single-line status text (e.g. "Scanning [3/12] — Linen Cloth")
    ns.progressText = ns.panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.progressText:SetPoint("TOPLEFT", L, row3Y)

    -----------------------------------------------------------------------
    -- RESULTS SCROLL — scrollable list of scan results (left pane)
    -----------------------------------------------------------------------
    local resultsY = row3Y - 16  -- small gap below progress text
    -- Section heading for the results list
    local rh = ns.panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rh:SetPoint("TOPLEFT", L, resultsY)
    rh:SetText("|cffffd100Scan Results:|r")

    -- ScrollingMessageFrame — WoW's built-in scrollable text log widget.
    -- Appended to via :AddMessage(); ideal for streaming scan output.
    ns.resultsScroll = CreateFrame("ScrollingMessageFrame", nil, ns.panel)
    ns.resultsScroll:SetPoint("TOPLEFT", rh, "BOTTOMLEFT", 0, -4)        -- just below heading
    ns.resultsScroll:SetPoint("BOTTOMLEFT", ns.panel, "BOTTOMLEFT", L + 4, 55)  -- above status bar
    ns.resultsScroll:SetWidth(SPLIT_X - L - 20)          -- fill left pane minus padding
    ns.resultsScroll:SetFontObject(GameFontHighlightSmall) -- small white text
    ns.resultsScroll:SetMaxLines(500)                     -- keep up to 500 lines in the buffer
    ns.resultsScroll:SetFading(false)                     -- disable auto-fade of old lines
    ns.resultsScroll:SetInsertMode(BOTTOM)                -- newest messages appear at the bottom
    ns.resultsScroll:SetJustifyH("LEFT")                  -- left-align all text
    ns.resultsScroll:SetClipsChildren(true)               -- clip text that overflows the frame
    ns.resultsScroll:EnableMouseWheel(true)                -- allow scroll wheel input
    -- OnMouseWheel: scroll the message buffer up or down
    ns.resultsScroll:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    ns.resultsScroll:SetIndentedWordWrap(false)            -- no hanging indent on wrapped lines

    -----------------------------------------------------------------------
    -- DEAL CARD — right split pane showing the current best deal
    -----------------------------------------------------------------------
    -- BackdropTemplate frame — bordered card container for deal details
    ns.dealCard = CreateFrame("Frame", nil, ns.panel, "BackdropTemplate")
    ns.dealCard:SetPoint("TOPLEFT", ns.panel, "TOPLEFT", SPLIT_X, -32)   -- right of the split
    ns.dealCard:SetPoint("BOTTOMRIGHT", ns.panel, "BOTTOMRIGHT", -4, 75) -- above status area
    -- Backdrop: dark fill + thin 1px border (WoW standard flat style)
    ns.dealCard:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",                        -- solid colour texture
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,          -- 1px solid border
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },         -- border inset from edges
    })
    ns.dealCard:SetBackdropColor(0.06, 0.06, 0.06, 1)        -- very dark grey fill
    ns.dealCard:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)  -- subtle grey border

    -- Decorative top edge highlight — thin bright line across card top
    local cardTopEdge = ns.dealCard:CreateTexture(nil, "BORDER", nil, 1)
    cardTopEdge:SetHeight(1)                                   -- 1px tall
    cardTopEdge:SetPoint("TOPLEFT", ns.dealCard, "TOPLEFT", 1, -1)    -- inset 1px from corners
    cardTopEdge:SetPoint("TOPRIGHT", ns.dealCard, "TOPRIGHT", -1, -1)
    cardTopEdge:SetColorTexture(0.35, 0.35, 0.35, 0.4)        -- semi-transparent light grey

    -- Subtle inner glow at the top of the card (gradient-like effect)
    local cardGlow = ns.dealCard:CreateTexture(nil, "BACKGROUND", nil, 2)
    cardGlow:SetHeight(40)                                     -- 40px tall glow area
    cardGlow:SetPoint("TOPLEFT", ns.dealCard, "TOPLEFT", 2, -2)
    cardGlow:SetPoint("TOPRIGHT", ns.dealCard, "TOPRIGHT", -2, -2)
    cardGlow:SetColorTexture(0.10, 0.10, 0.10, 0.4)           -- slightly lighter than card bg

    -- "Best Deal" title
    local dt = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dt:SetPoint("TOPLEFT", PAD, -PAD)
    dt:SetText("|cff88bbffBest Deal|r")

    -- Card starts hidden — shown only when a deal is pending
    ns.dealCard:Hide()

    -- Item icon — 36×36 texture showing the deal item's inventory icon
    ns.dealIcon = ns.dealCard:CreateTexture(nil, "ARTWORK")
    ns.dealIcon:SetSize(36, 36)
    ns.dealIcon:SetPoint("TOPLEFT", PAD, -32)  -- below the title
    ns.dealIcon:Hide()                          -- hidden until a deal is found

    -- Item name — wraps to fit; anchored right of the icon
    ns.dealNameText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.dealNameText:SetPoint("TOPLEFT", ns.dealIcon, "TOPRIGHT", 8, -2)
    ns.dealNameText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)  -- constrain to card width
    ns.dealNameText:SetJustifyH("LEFT")
    ns.dealNameText:SetText("|cff666666No deal|r")  -- placeholder when idle

    -- Percentage of floor — large text showing how far below floor the deal is
    ns.dealPctText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ns.dealPctText:SetPoint("TOPLEFT", ns.dealNameText, "BOTTOMLEFT", 0, -2)

    -- Separator line — thin horizontal rule between header area and detail rows
    local dealSep = ns.dealCard:CreateTexture(nil, "ARTWORK")
    dealSep:SetHeight(1)  -- 1px line
    dealSep:SetPoint("TOPLEFT", ns.dealIcon, "BOTTOMLEFT", 0, -6)
    dealSep:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    dealSep:SetColorTexture(0.25, 0.25, 0.25, 0.5)  -- semi-transparent grey

    -- Price per unit + floor price — detail row showing unit economics
    ns.dealPriceText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.dealPriceText:SetPoint("TOPLEFT", ns.dealIcon, "BOTTOMLEFT", 0, -10)
    ns.dealPriceText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    ns.dealPriceText:SetJustifyH("LEFT")

    -- Quantity text — "Buy X / Y available" detail row
    ns.dealQtyText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.dealQtyText:SetPoint("TOPLEFT", ns.dealPriceText, "BOTTOMLEFT", 0, -3)
    ns.dealQtyText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    ns.dealQtyText:SetJustifyH("LEFT")

    -- Total cost — the full copper cost of the proposed purchase
    ns.dealCostText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.dealCostText:SetPoint("TOPLEFT", ns.dealQtyText, "BOTTOMLEFT", 0, -3)
    ns.dealCostText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    ns.dealCostText:SetJustifyH("LEFT")

    -- Estimated profit — projected gain after AH cut, coloured green/red
    ns.dealProfitText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.dealProfitText:SetPoint("TOPLEFT", ns.dealCostText, "BOTTOMLEFT", 0, -3)
    ns.dealProfitText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    ns.dealProfitText:SetJustifyH("LEFT")

    -- Total reset cost — what it would cost to buy out all stock below floor
    ns.dealFloorText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.dealFloorText:SetPoint("TOPLEFT", ns.dealProfitText, "BOTTOMLEFT", 0, -2)
    ns.dealFloorText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    ns.dealFloorText:SetJustifyH("LEFT")

    -----------------------------------------------------------------------
    -- BUY / SKIP buttons
    -----------------------------------------------------------------------
    -- Buy button — global name required for keyboard shortcut click-through.
    -- IMPORTANT: StartCommoditiesPurchase is a PROTECTED API that requires
    -- a hardware event (direct mouse click or keypress). This button's
    -- OnClick handler satisfies that requirement because WoW propagates
    -- the hardware event through UIPanelButtonTemplate clicks.
    ns.buyButton = CreateFrame("Button", "QuickFlipBuyBtn", ns.dealCard, "UIPanelButtonTemplate")
    ns.buyButton:SetSize(170, 28)
    ns.buyButton:SetPoint("BOTTOMLEFT", ns.dealCard, "BOTTOMLEFT", PAD, PAD)
    ns.buyButton:SetText("Buy Deal")
    ns.buyButton:Disable()  -- disabled until a valid deal is detected
    -- OnClick: begin the commodity purchase flow (hardware event context)
    ns.buyButton:SetScript("OnClick", function()
        if not ns.pendingDeal or not ns.isAHOpen then return end  -- safety guard
        ns.isWaitingForPrice = true               -- flag: waiting for COMMODITY_PRICE_UPDATED
        ns.skipButton:Disable(); ns.skipButton:Hide()  -- prevent skip while purchasing
        -- This call requires the hardware event from the click
        C_AuctionHouse.StartCommoditiesPurchase(
            ns.pendingDeal.itemID, ns.pendingDeal.quantity)
        ns.SetStatus("|cffffd100Purchasing — waiting for price...|r")
        ns.buyButton:Disable()  -- prevent double-clicks
    end)

    -- Skip button — allows the user to pass on the current deal
    ns.skipButton = CreateFrame("Button", "QuickFlipSkipBtn", ns.dealCard, "UIPanelButtonTemplate")
    ns.skipButton:SetSize(60, 28)
    ns.skipButton:SetPoint("BOTTOMRIGHT", ns.dealCard, "BOTTOMRIGHT", -PAD, PAD)
    ns.skipButton:SetText("|cffff8800Skip|r")  -- orange text for visual distinction
    ns.skipButton:Disable(); ns.skipButton:Hide()  -- hidden until a deal is pending
    -- OnClick: cancel any pending purchase, clear the deal, and resume scanning
    ns.skipButton:SetScript("OnClick", function()
        if not ns.isScanning then return end  -- only skip while actively scanning
        ns.CancelPendingPurchase()            -- abort any in-progress AH purchase
        ns.UpdateDeal(nil)                    -- clear deal card display
        ns.currentItemKey = nil               -- reset item tracking
        ns.rescanIter     = 0                 -- reset rescan counter for next item
        ns.SetStatus("|cff888888Deal skipped — continuing scan...|r")
        C_Timer.After(0.15, ns.ProcessNextItem)  -- brief delay then advance to next item
    end)

    -----------------------------------------------------------------------
    -- SESSION PROFIT — displayed inside deal card above buttons
    -----------------------------------------------------------------------
    -- Running total of estimated profit from purchases made this session
    ns.profitText = ns.dealCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.profitText:SetPoint("BOTTOMLEFT", ns.buyButton, "TOPLEFT", 0, 8)  -- above Buy button
    ns.profitText:SetPoint("RIGHT", ns.dealCard, "RIGHT", -PAD, 0)
    ns.profitText:SetJustifyH("LEFT")
    ns.profitText:SetText("")  -- empty until a purchase completes

    -----------------------------------------------------------------------
    -- SETTINGS TEXT — live config summary (above status bar, full width)
    -----------------------------------------------------------------------
    -- Single-line FontString showing current config at a glance, updated by RefreshUI()
    ns.settingsText = ns.panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.settingsText:SetPoint("BOTTOMLEFT", ns.panel, "BOTTOMLEFT", PAD, 30)  -- above status bar
    ns.settingsText:SetPoint("RIGHT", ns.panel, "RIGHT", -PAD, 0)
    ns.settingsText:SetJustifyH("LEFT")

    -----------------------------------------------------------------------
    -- STATUS BAR — single-line text with background progress fill
    -----------------------------------------------------------------------
    -- BackdropTemplate frame acting as a thin status bar at the bottom of the panel.
    -- Contains a progress fill texture and an overlay text FontString.
    local statusPanel = CreateFrame("Frame", "QuickFlipStatusPanel", ns.panel, "BackdropTemplate")
    statusPanel:SetHeight(21)  -- fixed 21px tall
    statusPanel:SetPoint("BOTTOMLEFT", ns.panel, "BOTTOMLEFT", 170, 4)  -- right of AH nav buttons
    statusPanel:SetPoint("RIGHT", ns.panel, "RIGHT", -PAD, 0)
    -- Same flat backdrop style as the deal card
    statusPanel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",                        -- solid colour fill
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,          -- 1px border
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    statusPanel:SetBackdropColor(0.06, 0.06, 0.06, 1)        -- dark fill
    statusPanel:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)  -- subtle border
    -- Raise above other elements so progress bar renders on top of background
    statusPanel:SetFrameLevel(ns.panel:GetFrameLevel() + 5)

    -- Progress fill texture inside the status bar — width is set by UpdateProgressBar()
    ns.progressBarFill = statusPanel:CreateTexture(nil, "BACKGROUND", nil, 1)
    ns.progressBarFill:SetPoint("TOPLEFT", statusPanel, "TOPLEFT", 1, -1)      -- 1px inset (border)
    ns.progressBarFill:SetPoint("BOTTOMLEFT", statusPanel, "BOTTOMLEFT", 1, 1) -- 1px inset (border)
    ns.progressBarFill:SetWidth(1)                             -- initial 1px (hidden anyway)
    ns.progressBarFill:SetColorTexture(0.15, 0.25, 0.15, 1)   -- dark green
    ns.progressBarFill:Hide()                                  -- hidden when not scanning

    -- Status text overlaid on the bar — shows current action / idle state
    ns.statusText = statusPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.statusText:SetPoint("LEFT", statusPanel, "LEFT", 8, 0)    -- 8px left padding
    ns.statusText:SetPoint("RIGHT", statusPanel, "RIGHT", -8, 0) -- 8px right padding
    ns.statusText:SetJustifyH("LEFT")
    ns.statusText:SetText("|cff888888Idle|r")  -- default idle state

    -----------------------------------------------------------------------
    -- K-KEY BUY FRAME — invisible frame that intercepts the K key
    -----------------------------------------------------------------------
    -- This 1×1 invisible frame captures keyboard input globally.
    -- It enables the K key as a quick-action hotkey to click the Buy
    -- button (needs hardware event for protected API).
    -- SetPropagateKeyboardInput controls whether the key event passes
    -- through to WoW's default keybindings after we handle it.
    local keyFrame = CreateFrame("Frame", "QuickFlipKeyFrame", ns.panel)
    keyFrame:SetSize(1, 1)       -- invisible; no visual footprint
    keyFrame:SetPoint("CENTER")
    keyFrame:EnableKeyboard(true)              -- receive keyboard events
    keyFrame:SetPropagateKeyboardInput(true)   -- default: let keys pass through
    -- OnKeyDown: intercept K presses when the AH is open
    keyFrame:SetScript("OnKeyDown", function(self, key)
        if key == "K" and ns.isAHOpen then
            -- A deal is pending and buy button is ready.
            -- Consume the key (propagate=false) and simulate a Buy button click.
            -- The click inherits this hardware event, satisfying the protected API.
            if ns.pendingDeal
               and not ns.isWaitingForPrice
               and ns.buyButton and ns.buyButton:IsEnabled() then
                self:SetPropagateKeyboardInput(false)  -- consume the key event
                ns.buyButton:Click()  -- triggers OnClick with hardware event context
            -- K pressed but nothing to act on.
            -- Let the key propagate to WoW's normal key handler.
            else
                self:SetPropagateKeyboardInput(true)   -- pass key to WoW
            end
        else
            -- Non-K key or AH not open — always pass through
            self:SetPropagateKeyboardInput(true)
        end
    end)

    ns.panelBuilt = true
    return ns.panel
end

---------------------------------------------------------------------------
-- CreateOptionsPanel — Interface > Addons > QuickFlip settings
---------------------------------------------------------------------------
-- Two-column layout: left column has sliders (buy then sell), right column
-- has General/Audio checkboxes then Excluded Sellers editor.  Content is
-- inside a ScrollFrame so nothing gets clipped.  Registered with the WoW
-- settings system so /qf config or Interface > Addons opens it.
---------------------------------------------------------------------------
--- Builds and registers the QuickFlip settings panel shown under
--- Interface → Addons → QuickFlip.  Creates a scrollable two-column
--- layout (left = sliders, right = checkboxes + excluded-sellers editor)
--- and registers the panel with the modern Settings API or the legacy
--- InterfaceOptions system depending on WoW client version.
function ns.CreateOptionsPanel()
    -- Create the top-level frame that WoW's settings system will parent into
    -- the Interface → Addons panel.  panel.name tells the system the category.
    local panel = CreateFrame("Frame", "QuickFlipOptionsPanel")
    panel.name = ADDON_NAME

    -- Title stays on the outer panel (non-scrolling) so it is always visible
    -- even when the user scrolls the settings content below.
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cff33ff99QuickFlip|r  v" .. ns.VERSION)

    ---------------------------------------------------------------
    -- Scrollable container for all settings content
    ---------------------------------------------------------------
    -- A UIPanelScrollFrameTemplate provides the scrollbar; we anchor it
    -- just below the title and inset 26px on the right for the scrollbar.
    local scrollFrame = CreateFrame("ScrollFrame", "QuickFlipOptionsScroll",
        panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -40)   -- leave room for the title
    scrollFrame:SetPoint("BOTTOMRIGHT", -26, 8) -- 26px right inset = scrollbar

    -- The content child is where all widgets live.  Width is fixed to 640px
    -- (enough for two columns); height is set to 1 initially and updated at
    -- the end of the function once all widgets are placed, so the scrollbar
    -- range covers the full content.
    local content = CreateFrame("Frame", "QuickFlipOptionsContent")
    content:SetSize(640, 1)  -- width fixed, height set dynamically at end
    scrollFrame:SetScrollChild(content)

    -- Two-column layout cursors -----------------------------------------
    -- COL1_X / COL2_X are the left-edge x offsets for column 1 and 2.
    -- yOff1 / yOff2 track how far down each column has been filled (negative
    -- values = downward from TOPLEFT).  activeCol selects which column the
    -- helper functions (MakeHeader, MakeSlider, MakeCheckbox) operate on.
    local COL1_X    = 20      -- left column x offset (px from content left)
    local COL2_X    = 340     -- right column x offset
    local yOff1     = -10     -- left column y cursor  (grows negative)
    local yOff2     = -10     -- right column y cursor (grows negative)
    local activeCol = 1       -- which column helpers target (1 = left, 2 = right)

    -- Convenience accessors for the active column's position
    local function getX() return activeCol == 1 and COL1_X or COL2_X end
    local function getY() return activeCol == 1 and yOff1  or yOff2  end
    -- Advance the active column's y cursor downward by |dy| pixels
    local function advanceY(dy)
        if activeCol == 1 then yOff1 = yOff1 - dy else yOff2 = yOff2 - dy end
    end

    -------------------------------------------------------------------
    -- Helper: create a section header label
    -------------------------------------------------------------------
    --- Creates a bold section header in the active column and advances
    --- the y cursor past it.
    --- @param parent Frame  Parent frame to attach the font string to.
    --- @param text   string Display text for the header (may contain color codes).
    --- @return FontString    The created header font string.
    local function MakeHeader(parent, text)
        local x, y = getX(), getY()
        advanceY(6)  -- small top-padding before the header text
        local hdr = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        hdr:SetPoint("TOPLEFT", x, getY())
        hdr:SetText(text)
        advanceY(22) -- advance past the header line height
        return hdr
    end

    -------------------------------------------------------------------
    -- Helper: create a labeled slider (with optional tooltip)
    -------------------------------------------------------------------
    --- Creates a slider control with a label that shows the current value,
    --- wired to a getter/setter pair on ns.db.  The slider snaps to the
    --- nearest step on drag and refreshes the main UI on every change.
    --- @param parent  Frame    Parent frame for the slider widgets.
    --- @param label   string   Display name shown above the slider track.
    --- @param minVal  number   Minimum slider value.
    --- @param maxVal  number   Maximum slider value.
    --- @param step    number   Discrete step increment for snapping.
    --- @param getter  function Returns the current setting value.
    --- @param setter  function Called with the new value on change.
    --- @param tooltip string|nil Optional long description for the hover tooltip.
    --- @return Slider  The created WoW Slider widget.
    local function MakeSlider(parent, label, minVal, maxVal, step, getter, setter, tooltip)
        local x, y = getX(), getY()
        -- Wrapper frame holds both the label text and the slider track
        local frame = CreateFrame("Frame", nil, parent)
        frame:SetSize(290, 50)
        frame:SetPoint("TOPLEFT", x, y)
        advanceY(54) -- advance cursor past the slider (50px + 4px spacing)

        -- Label font string: updated on every value change to show "Name: value"
        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetPoint("TOPLEFT", 0, 0)

        -- Create the slider using Blizzard's OptionsSliderTemplate
        local slider = CreateFrame("Slider", nil, frame, "OptionsSliderTemplate")
        slider:SetSize(250, 16)
        slider:SetPoint("TOPLEFT", 0, -18) -- below the label text
        slider:SetMinMaxValues(minVal, maxVal)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true) -- enforce step increments while dragging
        slider.Low:SetText(tostring(minVal))   -- left-end label
        slider.High:SetText(tostring(maxVal))  -- right-end label
        slider:SetValue(getter())              -- initialise from saved setting
        text:SetText(label .. ": |cffffffff" .. getter() .. "|r")

        -- OnValueChanged: snap value to nearest step, persist, refresh UI
        slider:SetScript("OnValueChanged", function(self, value)
            value = math.floor(value / step + 0.5) * step  -- snap to step grid
            setter(value)
            text:SetText(label .. ": |cffffffff" .. value .. "|r")
            ns.RefreshUI()
            ns.RefreshSellUI()
        end)

        -- Optional tooltip shown on hover (title = label, body = tooltip text)
        if tooltip then
            slider.tooltipText = tooltip
            slider:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(label, 1, 0.82, 0)       -- gold title
                GameTooltip:AddLine(tooltip, 1, 1, 1, true)   -- white body, word-wrap
                GameTooltip:Show()
            end)
            slider:SetScript("OnLeave", GameTooltip_Hide)
        end
        return slider
    end

    -------------------------------------------------------------------
    -- Helper: create a labeled checkbox (with optional tooltip)
    -------------------------------------------------------------------
    --- Creates a checkbox control using the standard Blizzard template,
    --- wired to a boolean getter/setter pair on ns.db.
    --- @param parent  Frame    Parent frame for the checkbox.
    --- @param label   string   Text shown to the right of the checkbox.
    --- @param getter  function Returns the current boolean value.
    --- @param setter  function Called with true/false on toggle.
    --- @param tooltip string|nil Optional hover description.
    --- @return CheckButton  The created checkbox widget.
    local function MakeCheckbox(parent, label, getter, setter, tooltip)
        local x, y = getX(), getY()
        -- InterfaceOptionsCheckButtonTemplate provides the standard look & feel
        local cb = CreateFrame("CheckButton", nil, parent,
            "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        advanceY(28) -- checkbox height + spacing
        cb.Text:SetText(label)     -- label to the right of the box
        cb:SetChecked(getter())    -- initialise from saved setting
        -- OnClick: persist the new boolean state and refresh the UI
        cb:SetScript("OnClick", function(self)
            setter(self:GetChecked())
            ns.RefreshUI()
        end)

        -- Optional tooltip shown on hover
        if tooltip then
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(label, 1, 0.82, 0)
                GameTooltip:AddLine(tooltip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", GameTooltip_Hide)
        end
        return cb
    end

    -------------------------------------------------------------------
    -- LEFT COLUMN — Buy Sliders
    -------------------------------------------------------------------
    activeCol = 1

    MakeHeader(content, "|cff33ff99Buy Settings|r")

    -- minProfitPct: minimum % margin after AH cut to flag a deal
    MakeSlider(content, "Min Profit (%)", 1, 50, 1,
        function() return ns.db.minProfitPct end,
        function(v) ns.db.minProfitPct = v end,
        "Minimum profit margin required after the 5% AH fee. A deal is only triggered if buying at the listed price and selling at the projected post-purchase price yields at least this % profit.")

    -- samplePct: bottom N% of listings used to compute floor price
    MakeSlider(content, "Sample Size (%)", 1, 50, 1,
        function() return ns.db.samplePct end,
        function(v) ns.db.samplePct = v end,
        "Percentage of total listed quantity (by volume) used to calculate the floor price. A larger sample averages over more listings for a more stable floor.")

    -- rescanCount: how many consecutive scans per item before moving on
    MakeSlider(content, "Rescan Count", 1, 10, 1,
        function() return ns.db.rescanCount end,
        function(v) ns.db.rescanCount = v end,
        "Number of times to re-check each item before moving to the next one. Higher values catch deals that appear between scans.")

    -- maxBuyPrice: absolute gold cap per unit (stored in copper, displayed in gold)
    MakeSlider(content, "Max Buy Price (gold, 0=none)", 0, 50000, 100,
        function() return math.floor(ns.db.maxBuyPrice / 10000) end,
        function(v) ns.db.maxBuyPrice = v * 10000 end,
        "Absolute maximum price in gold you are willing to pay per unit, regardless of floor. Set to 0 for no limit.")

    -- buyPct: what fraction of the deal stock to purchase
    MakeSlider(content, "Buy % of Deal", 1, 100, 1,
        function() return ns.db.buyPct end,
        function(v) ns.db.buyPct = v end,
        "Percentage of the available deal quantity to buy. For example, 50 means buy half the deal stock. Lower values reduce risk; higher values capture more of the deal.")

    -- maxBuyQty: hard unit cap per deal (overrides buyPct)
    MakeSlider(content, "Max Buy Qty", 1, 1000, 10,
        function() return ns.db.maxBuyQty end,
        function(v) ns.db.maxBuyQty = v end,
        "Maximum number of units to buy per deal, regardless of the Buy % setting. Acts as an absolute cap to limit exposure on any single purchase.")

    -------------------------------------------------------------------
    -- LEFT COLUMN — Sell Sliders
    -------------------------------------------------------------------
    MakeHeader(content, "|cffff8800Sell Settings|r")

    -- Save Y position so right column sections start at the same height
    local sellStartY = yOff1

    -- sellPostCap: max total units listed per item across all your auctions
    MakeSlider(content, "Unit Cap", 1, 1000, 10,
        function() return ns.db.sellPostCap end,
        function(v) ns.db.sellPostCap = v end,
        "Maximum total units you want listed on the AH per item across all your auctions. Once this many units are already posted in the valid price range, no more will be listed.")

    -- sellPostCapPerStack: units per single auction listing
    MakeSlider(content, "Per Stack", 1, 200, 1,
        function() return ns.db.sellPostCapPerStack end,
        function(v) ns.db.sellPostCapPerStack = v end,
        "Maximum number of units to post in a single auction listing each scan cycle. Splitting into smaller stacks can help sell faster.")

    -- sellPostCapListingAmt: how many separate listings per item
    MakeSlider(content, "Max Listings", 1, 20, 1,
        function() return ns.db.sellPostCapListingAmt end,
        function(v) ns.db.sellPostCapListingAmt = v end,
        "Maximum number of separate auction listings allowed per item. Prevents flooding the AH with too many rows.")

    -- sellUndercutSilver: undercut in whole silver (copper causes PostCommodity to fail)
    MakeSlider(content, "Undercut (silver)", 1, 100, 1,
        function() return ns.db.sellUndercutSilver end,
        function(v) ns.db.sellUndercutSilver = v end,
        "Amount in silver to undercut the computed sell price by. PostCommodity silently fails if the final price has a non-zero copper component, so undercut is in whole silver.")

    -- sellWallPct: volume threshold that defines a "wall" to undercut
    MakeSlider(content, "Wall Threshold (%)", 1, 50, 1,
        function() return ns.db.sellWallPct end,
        function(v) ns.db.sellWallPct = v end,
        "Percentage of total listed volume (below floor) that constitutes a wall. If cumulative qty at a price tier exceeds this % of volume, we undercut it instead of sitting behind it. Lower = more aggressive.")

    -- sellMaxUndercutPct: safety floor on how far below floor we'll price
    MakeSlider(content, "Max Undercut (%)", 1, 25, 1,
        function() return ns.db.sellMaxUndercutPct end,
        function(v) ns.db.sellMaxUndercutPct = v end,
        "Maximum percentage below floor price we are willing to post at. Prevents sacrificing too much profit to jump in front of a wall. E.g. 10 means never price below 90% of floor.")

    -- sellDuration: auction length (1=12h, 2=24h, 3=48h)
    MakeSlider(content, "Duration", 1, 3, 1,
        function() return ns.db.sellDuration end,
        function(v) ns.db.sellDuration = v end,
        "Auction duration: 1 = 12 hours, 2 = 24 hours, 3 = 48 hours. Longer durations cost a higher deposit but give more time to sell.")

    -------------------------------------------------------------------
    -- RIGHT COLUMN — General (above Excluded Sellers)
    -------------------------------------------------------------------
    activeCol = 2
    yOff2 = -10  -- start at top of content

    MakeHeader(content, "|cff33ff99General|r")

    -- enabled: master on/off switch for the entire addon
    MakeCheckbox(content, "Enabled (master toggle)",
        function() return ns.db.enabled end,
        function(v) ns.db.enabled = v end,
        "Master on/off switch for QuickFlip. When disabled, scanning and buying are completely stopped.")

    -- autoConfirm: skip manual confirmation after price quote
    MakeCheckbox(content, "Auto-confirm purchases",
        function() return ns.db.autoConfirm end,
        function(v) ns.db.autoConfirm = v end,
        "Automatically confirm the purchase after the AH returns a price quote, without requiring a second click.")

    -- skipHighQuality: ignore tier 2+ crafting reagents while scanning
    MakeCheckbox(content, "Skip rank 2+ reagents",
        function() return ns.db.skipHighQuality end,
        function(v) ns.db.skipHighQuality = v end,
        "Ignore higher-quality (tier 2+) crafting reagents during scanning. Useful to avoid overpaying for premium-rank materials.")

    -- verbose: echo status bar messages to chat for debugging
    MakeCheckbox(content, "Verbose (status -> chat)",
        function() return ns.db.verbose end,
        function(v) ns.db.verbose = v end,
        "Mirror status bar messages to the chat window for easier debugging and monitoring.")

    -------------------------------------------------------------------
    -- RIGHT COLUMN — Audio Settings
    -------------------------------------------------------------------
    MakeHeader(content, "|cff88bbffAudio Settings|r")

    -- soundOnDeal: play alert sound when a profitable deal is detected
    MakeCheckbox(content, "Sound on deal",
        function() return ns.db.soundOnDeal end,
        function(v) ns.db.soundOnDeal = v end,
        "Play an audio alert when a deal is detected that meets your threshold.")

    -- soundOnAuctionSold: play sound when one of your auctions sells
    MakeCheckbox(content, "Sound on auction sold",
        function() return ns.db.soundOnAuctionSold end,
        function(v) ns.db.soundOnAuctionSold = v end,
        "Play the order-filled sound when one of your auctions sells. Works even when the AH is closed.")

    -- soundOnAuctionExpired: play sound when an auction expires or is cancelled
    MakeCheckbox(content, "Sound on auction expired",
        function() return ns.db.soundOnAuctionExpired end,
        function(v) ns.db.soundOnAuctionExpired = v end,
        "Play the notice sound when one of your auctions expires or is cancelled.")

    -------------------------------------------------------------------
    -- RIGHT COLUMN — Excluded Sellers editor
    -------------------------------------------------------------------
    yOff2 = yOff2 - 8  -- extra spacing before the section

    -- Section label
    local exLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    exLabel:SetPoint("TOPLEFT", COL2_X, yOff2)
    exLabel:SetText("Excluded Sellers:")
    yOff2 = yOff2 - 16

    -- Display area: comma-separated list of excluded seller names (word-wrapped)
    local exListText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    exListText:SetPoint("TOPLEFT", COL2_X, yOff2)
    exListText:SetWidth(260)
    exListText:SetJustifyH("LEFT")
    exListText:SetWordWrap(true)

    --- Refreshes the excluded-sellers display text from ns.db.excludedSellers.
    --- Shows "(none)" in grey when the list is empty.
    local function UpdateExcludedDisplay()
        if #ns.db.excludedSellers > 0 then
            exListText:SetText("|cffffffff" .. table.concat(ns.db.excludedSellers, ", ") .. "|r")
        else
            exListText:SetText("|cff888888(none)|r")
        end
    end
    UpdateExcludedDisplay()  -- populate on panel creation
    yOff2 = yOff2 - 20

    -- Input box for typing a seller name (Character-Realm format)
    local exBox = CreateFrame("EditBox", "QuickFlipExcludeBox", content, "InputBoxTemplate")
    exBox:SetSize(150, 22)
    exBox:SetPoint("TOPLEFT", COL2_X, yOff2)
    exBox:SetAutoFocus(false)
    exBox:SetMaxLetters(60)

    -- "Add" button: trims whitespace, checks for duplicates (case-insensitive),
    -- then appends to the excluded list and refreshes the display.
    local exAddBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    exAddBtn:SetSize(50, 22)
    exAddBtn:SetPoint("LEFT", exBox, "RIGHT", 4, 0)
    exAddBtn:SetText("Add")
    exAddBtn:SetScript("OnClick", function()
        local name = exBox:GetText():match("^%s*(.-)%s*$") -- trim whitespace
        if name == "" then return end
        -- Prevent duplicate entries (case-insensitive comparison)
        for _, v in ipairs(ns.db.excludedSellers) do
            if v:lower() == name:lower() then
                exBox:SetText(""); return
            end
        end
        table.insert(ns.db.excludedSellers, name)
        exBox:SetText("")
        UpdateExcludedDisplay()
    end)

    -- "Del" button: finds and removes the matching name (case-insensitive),
    -- then refreshes the display.
    local exRemBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    exRemBtn:SetSize(55, 22)
    exRemBtn:SetPoint("LEFT", exAddBtn, "RIGHT", 2, 0)
    exRemBtn:SetText("Del")
    exRemBtn:SetScript("OnClick", function()
        local name = exBox:GetText():match("^%s*(.-)%s*$") -- trim whitespace
        if name == "" then return end
        for i, v in ipairs(ns.db.excludedSellers) do
            if v:lower() == name:lower() then
                table.remove(ns.db.excludedSellers, i)
                break  -- only remove first match
            end
        end
        exBox:SetText("")
        UpdateExcludedDisplay()
    end)

    -- Pressing Enter in the edit box triggers Add; Escape clears focus
    exBox:SetScript("OnEnterPressed", function(self)
        exAddBtn:Click()
    end)
    exBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -------------------------------------------------------------------
    -- Set scroll-child height to the taller of the two columns
    -------------------------------------------------------------------
    -- yOff1 and yOff2 are negative; take the absolute value of whichever
    -- column grew further, then add 30px bottom padding so the last
    -- widget isn't flush against the scrollframe edge.
    local totalHeight = math.max(math.abs(yOff1), math.abs(yOff2)) + 30
    content:SetHeight(totalHeight)

    -------------------------------------------------------------------
    -- Register with the WoW settings system
    -------------------------------------------------------------------
    -- Modern path (Dragonflight 10.x+): use the new Settings API which
    -- provides RegisterCanvasLayoutCategory for custom panel frames.
    -- Legacy path (Classic / older retail): fall back to the deprecated
    -- InterfaceOptions_AddCategory which still works in older clients.
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, ADDON_NAME)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

---------------------------------------------------------------------------
-- =====================  SPAM SELL TAB UI  ================================
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- UpdateSellDeal — populate or clear the sell action card (post mode)
---------------------------------------------------------------------------
-- @param post (table|nil) Post info from Seller, or nil to clear
---------------------------------------------------------------------------
--- Populate or clear the sell card with a pending post action.
--- When a post table is provided the card shows the item icon, pricing
--- details, quantity, and enables the Post/Skip buttons with a green
--- border.  When nil, all fields are reset to the empty/disabled state.
--- Mirrors UpdateDeal but for the Quick Sell workflow.
--- @param post table|nil  Post descriptor { itemID, name, unitPrice, floorPrice, quantity } or nil to clear
function ns.UpdateSellDeal(post)
    if not ns.sellPanelBuilt then return end  -- guard: panel not yet constructed

    if post then
        -- Try to load the item icon synchronously
        local icon = C_Item.GetItemIconByID(post.itemID)
        if icon then
            ns.sellItemIcon:SetTexture(icon); ns.sellItemIcon:Show()
        else
            -- Show placeholder question-mark while the real icon loads
            ns.sellItemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); ns.sellItemIcon:Show()
            -- Queue async item-data load so the icon updates once available
            local item = Item:CreateFromItemID(post.itemID)
            item:ContinueOnItemLoad(function()
                local loadedIcon = C_Item.GetItemIconByID(post.itemID)
                if loadedIcon then
                    ns.sellItemIcon:SetTexture(loadedIcon)
                end
            end)
        end

        -- Fill card text fields: name (green), sell/floor prices, quantity, total
        ns.sellItemNameText:SetText("|cff00ff00" .. (post.name or "?") .. "|r")
        ns.sellPriceText:SetText(string.format(
            "|cffffd100Sell:|r %s ea  |cffffd100Floor:|r %s ea",
            ns.MC(post.unitPrice), ns.MC(post.floorPrice or 0)))
        ns.sellQtyText:SetText(string.format(
            "|cffffd100Qty:|r |cffffffff%d|r to post", post.quantity))
        ns.sellActionText:SetText(string.format(
            "|cffffd100Total:|r %s",
            ns.FormatMoney((post.unitPrice or 0) * (post.quantity or 0))))

        -- Enable action buttons so the user can post or skip
        ns.sellPostButton:Enable()
        ns.sellPostButton:SetText("|cff00ff00▶ POST|r  " ..
            ns.FormatMoney((post.unitPrice or 0) * (post.quantity or 0)))
        ns.sellSkipButton:Enable(); ns.sellSkipButton:Show()

        -- Green-tinted card border and background to indicate a ready deal
        ns.sellCard:SetBackdropBorderColor(0.2, 0.85, 0.4, 0.9)
        ns.sellCard:SetBackdropColor(0.05, 0.08, 0.05, 1)

        -- Show the card now that we have an action
        ns.sellCard:Show()

        ns.SetSellStatus("|cff00ccff⚡ READY TO POST|r |cffffffff— Post or Skip.|r")
    else
        -- Clear branch: reset every card element to its idle/disabled state
        ns.sellPendingPost = nil
        ns.sellItemIcon:SetTexture(nil); ns.sellItemIcon:Hide()
        ns.sellItemNameText:SetText("|cff666666No sell action|r")
        ns.sellPriceText:SetText("")
        ns.sellQtyText:SetText("")
        ns.sellActionText:SetText("")
        ns.sellPostButton:Disable()
        ns.sellPostButton:SetText("Post")
        ns.sellSkipButton:Disable(); ns.sellSkipButton:Hide()
        -- Hide the card entirely when no sell action is active
        ns.sellCard:Hide()
    end
end

---------------------------------------------------------------------------
-- UpdateSellCancel — populate the sell card in cancel mode
---------------------------------------------------------------------------
-- @param cancel (table) { auctionID, itemID, name, unitPrice, quantity }
---------------------------------------------------------------------------
--- Populate the sell card in cancel mode for an overpriced auction.
--- Displays the item icon, "listed at" price, and a cancel button with
--- an orange card tint.  The user can cancel the auction or skip to the
--- next one in the cancel queue.
--- @param cancel table  Cancel descriptor { auctionID, itemID, name, unitPrice, quantity }
function ns.UpdateSellCancel(cancel)
    if not ns.sellPanelBuilt then return end  -- guard: panel not yet constructed

    if cancel then
        -- Load item icon, falling back to a placeholder while async loads
        local icon = C_Item.GetItemIconByID(cancel.itemID)
        if icon then
            ns.sellItemIcon:SetTexture(icon); ns.sellItemIcon:Show()
        else
            -- Show question-mark placeholder until the real icon resolves
            ns.sellItemIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); ns.sellItemIcon:Show()
            local item = Item:CreateFromItemID(cancel.itemID)
            item:ContinueOnItemLoad(function()
                local loadedIcon = C_Item.GetItemIconByID(cancel.itemID)
                if loadedIcon then
                    ns.sellItemIcon:SetTexture(loadedIcon)
                end
            end)
        end

        -- Orange name to visually distinguish cancel actions from posts
        ns.sellItemNameText:SetText("|cffff8800" .. (cancel.name or "?") .. "|r")
        -- Show the listed unit price with a red "above floor" warning
        ns.sellPriceText:SetText(string.format(
            "|cffffd100Listed at:|r %s ea  |cffff4444(above floor)|r",
            ns.MC(cancel.unitPrice)))
        ns.sellQtyText:SetText(string.format(
            "|cffffd100Qty:|r |cffffffff%d|r listed", cancel.quantity or 0))
        ns.sellActionText:SetText("|cffff8800Cancel this overpriced auction|r")

        -- Enable cancel and skip buttons
        ns.sellPostButton:Enable()
        ns.sellPostButton:SetText("|cffff4444✗ CANCEL|r")
        ns.sellSkipButton:Enable(); ns.sellSkipButton:Show()

        -- Orange-tinted card border and background to signal a cancel action
        ns.sellCard:SetBackdropBorderColor(0.85, 0.4, 0.2, 0.9)
        ns.sellCard:SetBackdropColor(0.08, 0.05, 0.03, 1)

        -- Show the card now that we have a cancel action
        ns.sellCard:Show()

        -- Status bar: show cancel index out of total queue size
        ns.SetSellStatus(string.format(
            "|cffff8800⚠ CANCEL %d/%d|r |cffffffff— Click Cancel or Skip.|r",
            ns.sellCancelIdx, #ns.sellCancelQueue))
    end
end

---------------------------------------------------------------------------
-- UpdateSellResultsDisplay — refresh the scrollable sell-results list
---------------------------------------------------------------------------
--- Refresh the scrollable sell-results list from ns.sellResults.
--- Each entry is either an error line (item not found) or a normal
--- line showing bag count, listed quantity, status, and sell price.
function ns.UpdateSellResultsDisplay()
    if not ns.sellPanelBuilt or not ns.sellResultsScroll then return end  -- guard

    ns.sellResultsScroll:Clear()  -- wipe previous messages before rebuilding
    for i = 1, #ns.sellResults do
        local r = ns.sellResults[i]
        if r.error then
            ns.sellResultsScroll:AddMessage(string.format(
                "|cffff4444%d.  %s — not found|r", i, r.term))
        else
            -- Resolve itemID: use result field, or fall back to name cache
            local itemID = r.itemID or ns.GetCachedItemID(r.name)

            -- Item icon via inline texture escape (14×14 px)
            local iconTex = ""
            if itemID then
                local texPath = C_Item.GetItemIconByID(itemID)
                if texPath then
                    iconTex = string.format("|T%s:14:14:0:0|t ", tostring(texPath))
                end
            end

            -- Line 1: index + icon + name + status
            ns.sellResultsScroll:AddMessage(string.format(
                "|cff999999%d.|r  %s%s  %s",
                i, iconTex, r.name, r.statusStr or ""))

            -- Line 2: price details
            local sellStr = (r.sellPrice and r.sellPrice > 0)
                and ns.FormatGold(r.sellPrice) or "—"
            ns.sellResultsScroll:AddMessage(string.format(
                "      price %s  floor %s  sell %s  bag:%d  listed:%d",
                ns.FormatGold(r.minPrice),
                ns.FormatGold(r.floorPrice),
                sellStr,
                r.bagCount or 0, r.postedQty or 0))
        end
        -- Blank separator line between items
        ns.sellResultsScroll:AddMessage(" ")
    end
    ns.sellResultsScroll:ScrollToBottom()  -- auto-scroll to show latest entries
end

---------------------------------------------------------------------------
-- UpdateSellScanProgress — update progress text and bar during sell scan
---------------------------------------------------------------------------
--- Update the progress text label during a sell scan.
--- Three states are handled:
---   1. Scanning in progress  — "idx/total  itemName"
---   2. Scan complete         — "N/N complete" in green
---   3. Idle / no queue       — empty string
--- Also triggers UpdateSellProgressBar to keep the bar in sync.
function ns.UpdateSellScanProgress()
    if not ns.sellPanelBuilt or not ns.sellProgressText then return end  -- guard
    if ns.isSellScanning and #ns.sellQueue > 0 and ns.sellQueueIdx <= #ns.sellQueue then
        -- State 1: actively scanning — show current index and item name
        local idx = math.min(ns.sellQueueIdx, #ns.sellQueue)
        ns.sellProgressText:SetText(string.format(
            "|cff88ccff%d/%d|r |cff999999%s|r",
            idx, #ns.sellQueue,
            ns.ParseSearchTerm(ns.sellQueue[idx])))
    elseif ns.isSellScanning and #ns.sellQueue > 0
           and ns.sellQueueIdx > #ns.sellQueue then
        -- State 2: queue exhausted — all items scanned
        ns.sellProgressText:SetText(string.format(
            "|cff00ff00%d/%d complete|r", #ns.sellQueue, #ns.sellQueue))
    else
        -- State 3: idle or empty queue — clear the label
        ns.sellProgressText:SetText("")
    end
    ns.UpdateSellProgressBar()  -- keep the progress bar width in sync
end

---------------------------------------------------------------------------
-- UpdateSellProgressBar — fill the sell status-bar proportionally
---------------------------------------------------------------------------
--- Fill the sell status-bar proportionally based on scan progress.
--- Simpler than the buy-side bar — no rescan passes to account for;
--- progress is simply (items processed / total items).
function ns.UpdateSellProgressBar()
    if not ns.sellProgressBarFill then return end  -- guard: fill texture missing
    local statusPanel = _G["QuickFlipSellStatusPanel"]
    if not statusPanel then return end  -- guard: status panel not created yet

    if ns.isSellScanning and #ns.sellQueue > 0 then
        -- Calculate progress percentage (done / total), capped at 1.0
        local total = #ns.sellQueue
        local done  = math.min(ns.sellQueueIdx, total)
        local pct   = total > 0 and (done / total) or 0
        pct = math.min(pct, 1)
        -- Size the fill texture; subtract 2px for the 1px inset on each side
        local barWidth = statusPanel:GetWidth() - 2
        ns.sellProgressBarFill:SetWidth(math.max(barWidth * pct, 1))
        ns.sellProgressBarFill:SetColorTexture(0.15, 0.15, 0.25, 1)
        ns.sellProgressBarFill:Show()
    else
        -- Not scanning — hide the progress fill entirely
        ns.sellProgressBarFill:Hide()
    end
end

---------------------------------------------------------------------------
-- RefreshSellUI — update the sell settings display and list dropdown
---------------------------------------------------------------------------
--- Refresh the sell panel's dynamic display elements:
---   • Settings summary text (unit cap, per-stack cap, listings, undercut)
---   • Shopping-list dropdown label
---   • Scan-count badge next to the Start Selling button
function ns.RefreshSellUI()
    if not ns.sellPanelBuilt then return end  -- guard: panel not built

    -- Update the settings summary string from current SavedVariables
    if ns.sellSettingsText then
        ns.sellSettingsText:SetText(string.format(
            "Unit Cap |cffffffff%d|r  |  Per Stack |cffffffff%d|r  |  "
            .. "Listings |cffffffff%d|r  |  Undercut |cffffffff%ds|r",
            ns.db.sellPostCap or 200,
            ns.db.sellPostCapPerStack or 50,
            ns.db.sellPostCapListingAmt or 5,
            ns.db.sellUndercutSilver or 1
        ))
    end

    -- Sync the dropdown label with the currently selected sell list
    local dd = _G["QuickFlipSellListDD"]
    if dd then
        local hasLists = #ns.GetListNames() > 0
        UIDropDownMenu_SetText(dd,
            ns.db.sellSelectedList ~= "" and ns.db.sellSelectedList
            or (hasLists and "" or "-- Pick a shopping list --"))
    end

    -- Update the scan-count badge (e.g. "#3") beside the toggle button
    if ns.sellScanCountText then
        ns.sellScanCountText:SetText(
            ns.sellScanCount > 0 and ("|cff999999#" .. ns.sellScanCount .. "|r") or "")
    end
end

---------------------------------------------------------------------------
-- BuildSellPanel — construct the Quick Sell panel (mirrors BuildPanel)
---------------------------------------------------------------------------
--- Construct the Quick Sell panel (mirrors BuildPanel for the buy side).
--- Creates all child frames, textures, font strings, and buttons that make
--- up the sell tab.  Called once on first tab selection; subsequent calls
--- short-circuit via the sellPanelBuilt flag and return the cached panel.
--- @return Frame  The fully constructed sell panel frame
function ns.BuildSellPanel()
    if ns.sellPanelBuilt then return ns.sellPanel end  -- idempotent guard

    -- Create the root panel frame parented to the AH window
    ns.sellPanel = CreateFrame("Frame", "QuickFlipSellPanel", AuctionHouseFrame)
    ns.sellPanel:SetAllPoints()
    ns.sellPanel:Hide()

    -- Dark background texture filling the usable interior of the AH frame
    local bg = ns.sellPanel:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 3, -31)
    bg:SetPoint("BOTTOMRIGHT", -3, 2)
    bg:SetColorTexture(0.02, 0.02, 0.02, 1)

    -- Layout constants shared by child elements
    local PAD = 10            -- general padding in pixels
    local L   = PAD + 5       -- left-edge inset for most elements
    local T   = -68            -- top-edge offset below AH title area
    local panelWidth = AuctionHouseFrame:GetWidth() or 890
    local SPLIT_X    = math.floor(panelWidth * 0.65)  -- left/right pane split point

    -----------------------------------------------------------------------
    -- HEADER — addon name, tab title, and version string
    -----------------------------------------------------------------------
    local header = ns.sellPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", L, T)
    header:SetText("|cff33ff99QuickFlip|r  |cffff8800Quick Sell|r  |cff555555v" .. ns.VERSION .. "|r")

    -----------------------------------------------------------------------
    -- ROW 1 — Shopping list dropdown for choosing which list to sell from
    -----------------------------------------------------------------------
    local row1Y     = T - 28
    local listLabel = ns.sellPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listLabel:SetPoint("TOPLEFT", L, row1Y)
    listLabel:SetText("|cffffd100List:|r")

    -- Standard Blizzard dropdown template for shopping list selection
    local dd = CreateFrame("Frame", "QuickFlipSellListDD", ns.sellPanel, "UIDropDownMenuTemplate")
    dd:SetPoint("LEFT", listLabel, "RIGHT", -8, -3)
    UIDropDownMenu_SetWidth(dd, 220)

    -- Populate dropdown entries from the built-in list manager
    UIDropDownMenu_Initialize(dd, function(self, level)
        local names = ns.GetListNames()

        -- Show placeholder only when no lists exist
        if #names == 0 then
            local info  = UIDropDownMenu_CreateInfo()
            info.text   = "-- Pick a shopping list --"
            info.value  = ""
            info.checked = (ns.db.sellSelectedList == "")
            info.notCheckable = true
            info.func   = function()
                ns.db.sellSelectedList = ""
                UIDropDownMenu_SetText(dd, "-- Pick a shopping list --")
                ns.StopSellScan(); ns.RefreshSellUI()
            end
            UIDropDownMenu_AddButton(info, level)
        end

        -- List entries from our built-in list manager (with item count)
        for _, n in ipairs(names) do
            local items = ns.GetListItems(n)
            local info    = UIDropDownMenu_CreateInfo()
            info.text     = n .. "  |cff888888(" .. (items and #items or 0) .. ")|r"
            info.value    = n
            info.checked  = (ns.db.sellSelectedList == n)
            info.func     = function()
                ns.db.sellSelectedList = n
                UIDropDownMenu_SetText(dd, n); ns.RefreshSellUI()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    -- Set initial dropdown text from saved selection or placeholder
    local hasLists = #ns.GetListNames() > 0
    UIDropDownMenu_SetText(dd,
        ns.db.sellSelectedList ~= "" and ns.db.sellSelectedList
        or (hasLists and "" or "-- Pick a shopping list --"))

    -----------------------------------------------------------------------
    -- ROW 2 — Start/Stop toggle button + scan count badge
    -----------------------------------------------------------------------
    local row2Y = row1Y - 36

    -- Toggle button: starts or stops the sell scan depending on state
    ns.sellToggleButton = CreateFrame("Button", nil, ns.sellPanel, "UIPanelButtonTemplate")
    ns.sellToggleButton:SetSize(150, 24)
    ns.sellToggleButton:SetPoint("TOPLEFT", L, row2Y)
    ns.sellToggleButton:SetText("|cff00ff00Start Selling|r")
    ns.sellToggleButton:SetScript("OnClick", function()
        if ns.isSellScanning then ns.StopSellScan() else ns.StartSellScan() end
    end)

    -- Scan count badge (e.g. "#3") shown to the right of the toggle button
    ns.sellScanCountText = ns.sellPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.sellScanCountText:SetPoint("LEFT", ns.sellToggleButton, "RIGHT", 10, 0)

    -----------------------------------------------------------------------
    -- ROW 3 — Progress text showing current scan index and item name
    -----------------------------------------------------------------------
    local row3Y = row2Y - 26

    ns.sellProgressText = ns.sellPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.sellProgressText:SetPoint("TOPLEFT", L, row3Y)

    -----------------------------------------------------------------------
    -- RESULTS SCROLL — scrollable message list of sell results (left pane)
    -----------------------------------------------------------------------
    local resultsY = row3Y - 16
    local rh = ns.sellPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rh:SetPoint("TOPLEFT", L, resultsY)
    rh:SetText("|cffffd100Sell Results:|r")

    -- ScrollingMessageFrame behaves like a chat window — append-only messages
    ns.sellResultsScroll = CreateFrame("ScrollingMessageFrame", nil, ns.sellPanel)
    ns.sellResultsScroll:SetPoint("TOPLEFT", rh, "BOTTOMLEFT", 0, -4)
    ns.sellResultsScroll:SetPoint("BOTTOMLEFT", ns.sellPanel, "BOTTOMLEFT", L + 4, 55)
    ns.sellResultsScroll:SetWidth(SPLIT_X - L - 20)  -- left pane width
    ns.sellResultsScroll:SetFontObject(GameFontHighlightSmall)
    ns.sellResultsScroll:SetMaxLines(500)  -- keep up to 500 result lines
    ns.sellResultsScroll:SetFading(false)
    ns.sellResultsScroll:SetInsertMode(BOTTOM)
    ns.sellResultsScroll:SetJustifyH("LEFT")
    ns.sellResultsScroll:SetClipsChildren(true)
    -- Enable mouse-wheel scrolling through the results
    ns.sellResultsScroll:EnableMouseWheel(true)
    ns.sellResultsScroll:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    ns.sellResultsScroll:SetIndentedWordWrap(false)

    -----------------------------------------------------------------------
    -- SELL CARD — right-pane card showing the current sell/cancel action
    -----------------------------------------------------------------------
    -- BackdropTemplate provides border + background via SetBackdrop
    ns.sellCard = CreateFrame("Frame", nil, ns.sellPanel, "BackdropTemplate")
    ns.sellCard:SetPoint("TOPLEFT", ns.sellPanel, "TOPLEFT", SPLIT_X, -32)
    ns.sellCard:SetPoint("BOTTOMRIGHT", ns.sellPanel, "BOTTOMRIGHT", -4, 75)
    ns.sellCard:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    ns.sellCard:SetBackdropColor(0.06, 0.06, 0.06, 1)
    ns.sellCard:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)

    -- Subtle 1px highlight line at the top of the card
    local cardTopEdge = ns.sellCard:CreateTexture(nil, "BORDER", nil, 1)
    cardTopEdge:SetHeight(1)
    cardTopEdge:SetPoint("TOPLEFT", ns.sellCard, "TOPLEFT", 1, -1)
    cardTopEdge:SetPoint("TOPRIGHT", ns.sellCard, "TOPRIGHT", -1, -1)
    cardTopEdge:SetColorTexture(0.35, 0.35, 0.35, 0.4)

    -- Gradient glow band at the top for visual depth
    local cardGlow = ns.sellCard:CreateTexture(nil, "BACKGROUND", nil, 2)
    cardGlow:SetHeight(40)
    cardGlow:SetPoint("TOPLEFT", ns.sellCard, "TOPLEFT", 2, -2)
    cardGlow:SetPoint("TOPRIGHT", ns.sellCard, "TOPRIGHT", -2, -2)
    cardGlow:SetColorTexture(0.10, 0.10, 0.10, 0.4)

    -- "Sell Action" title
    local dt = ns.sellCard:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dt:SetPoint("TOPLEFT", PAD, -PAD)
    dt:SetText("|cffff8800Sell Action|r")

    -- Card starts hidden — shown only when a post/cancel action is pending
    ns.sellCard:Hide()

    -- Item icon (36x36), hidden until a sell action is active
    ns.sellItemIcon = ns.sellCard:CreateTexture(nil, "ARTWORK")
    ns.sellItemIcon:SetSize(36, 36)
    ns.sellItemIcon:SetPoint("TOPLEFT", PAD, -32)
    ns.sellItemIcon:Hide()

    -- Item name text, positioned to the right of the icon
    ns.sellItemNameText = ns.sellCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.sellItemNameText:SetPoint("TOPLEFT", ns.sellItemIcon, "TOPRIGHT", 8, -2)
    ns.sellItemNameText:SetPoint("RIGHT", ns.sellCard, "RIGHT", -PAD, 0)
    ns.sellItemNameText:SetJustifyH("LEFT")
    ns.sellItemNameText:SetText("|cff666666No sell action|r")

    -- Horizontal separator line below the icon
    local sellSep = ns.sellCard:CreateTexture(nil, "ARTWORK")
    sellSep:SetHeight(1)
    sellSep:SetPoint("TOPLEFT", ns.sellItemIcon, "BOTTOMLEFT", 0, -6)
    sellSep:SetPoint("RIGHT", ns.sellCard, "RIGHT", -PAD, 0)
    sellSep:SetColorTexture(0.25, 0.25, 0.25, 0.5)

    -- Price text: shows sell price and floor price (or listed-at for cancel)
    ns.sellPriceText = ns.sellCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.sellPriceText:SetPoint("TOPLEFT", ns.sellItemIcon, "BOTTOMLEFT", 0, -10)
    ns.sellPriceText:SetPoint("RIGHT", ns.sellCard, "RIGHT", -PAD, 0)
    ns.sellPriceText:SetJustifyH("LEFT")

    -- Quantity text: number of items to post or listed
    ns.sellQtyText = ns.sellCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.sellQtyText:SetPoint("TOPLEFT", ns.sellPriceText, "BOTTOMLEFT", 0, -3)
    ns.sellQtyText:SetPoint("RIGHT", ns.sellCard, "RIGHT", -PAD, 0)
    ns.sellQtyText:SetJustifyH("LEFT")

    -- Total / action description text (e.g. total revenue or cancel prompt)
    ns.sellActionText = ns.sellCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.sellActionText:SetPoint("TOPLEFT", ns.sellQtyText, "BOTTOMLEFT", 0, -3)
    ns.sellActionText:SetPoint("RIGHT", ns.sellCard, "RIGHT", -PAD, 0)
    ns.sellActionText:SetJustifyH("LEFT")

    -----------------------------------------------------------------------
    -- POST / SKIP buttons — dual-purpose for post and cancel actions
    -----------------------------------------------------------------------
    -- Post button: dispatches to cancel or post handler depending on phase
    ns.sellPostButton = CreateFrame("Button", "QuickFlipSellPostBtn", ns.sellCard, "UIPanelButtonTemplate")
    ns.sellPostButton:SetSize(170, 28)
    ns.sellPostButton:SetPoint("BOTTOMLEFT", ns.sellCard, "BOTTOMLEFT", PAD, PAD)
    ns.sellPostButton:SetText("Post")
    ns.sellPostButton:Disable()  -- disabled until a sell action is ready
    ns.sellPostButton:SetScript("OnClick", function()
        -- Branch on action phase: "cancel" removes an overpriced auction,
        -- anything else posts the pending commodities to the AH
        if ns.sellActionPhase == "cancel" then
            ns.OnSellCancelClicked()
        else
            ns.OnSellPostClicked()
        end
    end)

    -- Skip button: advances past the current action without executing it
    ns.sellSkipButton = CreateFrame("Button", "QuickFlipSellSkipBtn", ns.sellCard, "UIPanelButtonTemplate")
    ns.sellSkipButton:SetSize(60, 28)
    ns.sellSkipButton:SetPoint("BOTTOMRIGHT", ns.sellCard, "BOTTOMRIGHT", -PAD, PAD)
    ns.sellSkipButton:SetText("|cffff8800Skip|r")
    ns.sellSkipButton:Disable(); ns.sellSkipButton:Hide()  -- hidden until action ready
    ns.sellSkipButton:SetScript("OnClick", function()
        -- Mirror the post button's branching: skip cancel vs skip post
        if ns.sellActionPhase == "cancel" then
            ns.SkipSellCancel()
        else
            ns.SkipSellPost()
        end
    end)

    -----------------------------------------------------------------------
    -- SESSION SELL STATS — running totals displayed inside the card
    -----------------------------------------------------------------------
    -- Positioned above the Post button so stats are always visible
    ns.sellProfitText = ns.sellCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.sellProfitText:SetPoint("BOTTOMLEFT", ns.sellPostButton, "TOPLEFT", 0, 8)
    ns.sellProfitText:SetPoint("RIGHT", ns.sellCard, "RIGHT", -PAD, 0)
    ns.sellProfitText:SetJustifyH("LEFT")
    ns.sellProfitText:SetText("")

    -----------------------------------------------------------------------
    -- SETTINGS TEXT — live config summary shown above the status bar
    -----------------------------------------------------------------------
    ns.sellSettingsText = ns.sellPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ns.sellSettingsText:SetPoint("BOTTOMLEFT", ns.sellPanel, "BOTTOMLEFT", PAD, 30)
    ns.sellSettingsText:SetPoint("RIGHT", ns.sellPanel, "RIGHT", -PAD, 0)
    ns.sellSettingsText:SetJustifyH("LEFT")

    -----------------------------------------------------------------------
    -- STATUS BAR — single-line status text with a background progress fill
    -----------------------------------------------------------------------
    -- Positioned at the bottom of the panel; offset left to avoid the AH tabs
    local statusPanel = CreateFrame("Frame", "QuickFlipSellStatusPanel", ns.sellPanel, "BackdropTemplate")
    statusPanel:SetHeight(21)
    statusPanel:SetPoint("BOTTOMLEFT", ns.sellPanel, "BOTTOMLEFT", 170, 4)
    statusPanel:SetPoint("RIGHT", ns.sellPanel, "RIGHT", -PAD, 0)
    statusPanel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    statusPanel:SetBackdropColor(0.06, 0.06, 0.06, 1)
    statusPanel:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)
    statusPanel:SetFrameLevel(ns.sellPanel:GetFrameLevel() + 5)  -- above other elements

    -- Progress bar fill texture — stretches from the left edge proportionally
    ns.sellProgressBarFill = statusPanel:CreateTexture(nil, "BACKGROUND", nil, 1)
    ns.sellProgressBarFill:SetPoint("TOPLEFT", statusPanel, "TOPLEFT", 1, -1)
    ns.sellProgressBarFill:SetPoint("BOTTOMLEFT", statusPanel, "BOTTOMLEFT", 1, 1)
    ns.sellProgressBarFill:SetWidth(1)
    ns.sellProgressBarFill:SetColorTexture(0.15, 0.15, 0.25, 1)
    ns.sellProgressBarFill:Hide()  -- hidden until a scan is in progress

    -- Status text label overlaid on top of the progress bar
    ns.sellStatusText = statusPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ns.sellStatusText:SetPoint("LEFT", statusPanel, "LEFT", 8, 0)
    ns.sellStatusText:SetPoint("RIGHT", statusPanel, "RIGHT", -8, 0)
    ns.sellStatusText:SetJustifyH("LEFT")
    ns.sellStatusText:SetText("|cff888888Idle|r")

    -- Mark the panel as built so subsequent calls return the cached frame
    ns.sellPanelBuilt = true
    return ns.sellPanel
end

---------------------------------------------------------------------------
-- =====================  LISTS MANAGEMENT TAB UI  =========================
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Internal state for the Lists panel
---------------------------------------------------------------------------
local _listsSelectedList    = ""    -- currently selected list name
local _listRows             = {}    -- recycled Button frames for list names
local _itemRows             = {}    -- recycled Button frames for items
local _invRows              = {}    -- recycled Button frames for inventory
local _listsAddBox          = nil   -- EditBox for adding items (manual tab)
local _listsStatusText      = nil   -- status text at bottom
local _listsSelectedLabel   = nil   -- label showing selected list name + count
local _listsListContent     = nil   -- content child of lists ScrollFrame
local _listsItemContent     = nil   -- content child of items ScrollFrame
local _listsInvContent      = nil   -- content child of inventory ScrollFrame
local _listsEmptyListMsg    = nil   -- "no lists" placeholder
local _listsEmptyItemMsg    = nil   -- "select a list" / "empty" placeholder
local _listsEmptyInvMsg     = nil   -- "no inventory items" placeholder
local _importDialog         = nil   -- modal import/export dialog
local _listsActiveTab       = "items"  -- "items" or "inventory"
local _listsItemsTabBtn     = nil   -- tab button reference
local _listsInvTabBtn       = nil   -- tab button reference
local _listsItemsTabFrame   = nil   -- container for items tab content
local _listsInvTabFrame     = nil   -- container for inventory tab content
local _listsContextMenu     = nil   -- context dropdown for list rows
local _listsInvSearchBox    = nil   -- search box for inventory tab
local _listsInvSearchText   = ""    -- current inventory search filter
local _iconPickerFrame      = nil   -- icon picker popup
local _iconPickerCallback   = nil   -- function(iconID) called when icon selected
local _iconPickerIcons      = nil   -- cached icon list

-- Layout constants for list rows
local LIST_ROW_HEIGHT = 28
local ITEM_ROW_HEIGHT = 26
local INV_ROW_HEIGHT  = 28

local DEFAULT_LIST_ICON = "Interface\\Icons\\INV_Misc_Bag_10_Blue"

---------------------------------------------------------------------------
-- Rarity color helper — returns "|cAARRGGBB" prefix for a quality int
---------------------------------------------------------------------------
local RARITY_COLORS = {
    [0] = "|cff9d9d9d",  -- Poor (grey)
    [1] = "|cffffffff",  -- Common (white)
    [2] = "|cff1eff00",  -- Uncommon (green)
    [3] = "|cff0070dd",  -- Rare (blue)
    [4] = "|cffa335ee",  -- Epic (purple)
    [5] = "|cffff8000",  -- Legendary (orange)
    [6] = "|cffe6cc80",  -- Artifact
    [7] = "|cffe6cc80",  -- Heirloom
    [8] = "|cff00ccff",  -- WoW Token
}

--- Return the WoW colour escape string for a given item quality tier.
--- @param quality number  Item quality enum (0 = Poor … 5 = Legendary)
--- @return string         WoW colour escape code, defaults to white if unknown
local function GetRarityColor(quality)
    return RARITY_COLORS[quality] or "|cffffffff"
end

---------------------------------------------------------------------------
-- GetItemInfoCached — resolve a search term to name, icon, quality
---------------------------------------------------------------------------
-- Uses GetItemInfo which may return nil on first call (server query).
-- Falls back to the persisted itemIDCache and triggers async loading via
-- Item:CreateFromItemID() so icons appear even for items not in bags.
-- Returns: name, iconID, quality  (all may be nil on first call)
---------------------------------------------------------------------------
--- Dedup table for in-flight async Item:ContinueOnItemLoad requests.
--- Keys are itemIDs; prevents multiple callbacks for the same item.
local _pendingItemLoads = {}  -- track in-flight async loads to avoid duplicates

--- Resolve a search term (item name string) to its display name, icon, and quality.
---
--- Uses a three-stage fallback strategy:
---   1. Exact name lookup via GetItemInfo (succeeds when the client already cached the item).
---   2. Persisted itemID cache (ns.GetCachedItemID) + GetItemInfoInstant for a fast icon,
---      then GetItemInfo by ID for full data (may trigger a server round-trip).
---   3. Async load via Item:CreateFromItemID — enqueues a callback that refreshes
---      the list UI once the server responds, so icons appear lazily.
---
--- @param searchTerm string  Item name to look up
--- @return string|nil name      Localised item name (nil if not yet loaded)
--- @return number|nil icon      Icon fileID
--- @return number|nil quality   Item quality enum
local function GetItemInfoCached(searchTerm)
    -------------------------------------------------------------------
    -- Stage 1: exact name match (works when item is already in client cache)
    -------------------------------------------------------------------
    -- Try exact name match first (works when item is already cached)
    local name, link, quality, _, _, _, _, _, _, icon = GetItemInfo(searchTerm)
    if name and icon then
        -- Cache the ID for future sessions while we have the data
        if link then
            -- Extract numeric itemID from the hyperlink for cross-session persistence
            local itemID = link:match("item:(%d+)")
            if itemID then ns.CacheItemID(name, tonumber(itemID)) end
        end
        return name, icon, quality
    end

    -------------------------------------------------------------------
    -- Stage 2: persisted itemID cache → GetItemInfoInstant + GetItemInfo
    -------------------------------------------------------------------
    -- Name lookup failed — try the persisted itemID cache
    local cachedID = ns.GetCachedItemID(searchTerm)
    if cachedID then
        -- Try instant info (uses static item sparse DB, no server needed)
        local _, _, _, _, iconFromInstant, _, _ = GetItemInfoInstant(cachedID)
        -- Try full info (may trigger a server query)
        name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(cachedID)
        if name and icon then
            return name, icon, quality
        end
        -- Use instant icon as fallback while full data loads
        if iconFromInstant then
            icon = iconFromInstant
        end
        -----------------------------------------------------------
        -- Stage 3: async load — only one request per itemID at a time
        -----------------------------------------------------------
        -- Trigger async load if not already pending
        -- Check _pendingItemLoads to avoid queuing duplicate callbacks
        if not _pendingItemLoads[cachedID] then
            _pendingItemLoads[cachedID] = true
            local item = Item:CreateFromItemID(cachedID)
            -- ContinueOnItemLoad fires once the server returns item data
            item:ContinueOnItemLoad(function()
                _pendingItemLoads[cachedID] = nil  -- allow future re-requests
                -- Refresh list UI so icons/names appear once loaded
                if ns.RefreshListsUI then
                    ns.RefreshListsUI()
                end
            end)
        end
        -- Return what we have (icon from instant, name may still be nil)
        return name, icon, quality
    end

    -- All stages failed — item is completely unknown to the client
    return nil, nil, nil
end

---------------------------------------------------------------------------
-- CreateImportDialog — modal popup for import / export
---------------------------------------------------------------------------
--- Create (or return cached) the shared import/export modal dialog.
--- The same frame is re-used by ShowImportDialog and ShowExportDialog;
--- callers swap the title, instructions, edit text, and action button.
--- @return Frame  The reusable dialog frame
local function CreateImportDialog()
    if _importDialog then return _importDialog end  -- singleton guard

    -- Main dialog frame — DIALOG strata + high level so it sits above the AH
    local d = CreateFrame("Frame", "QuickFlipImportDialog", UIParent, "BackdropTemplate")
    d:SetSize(520, 320)
    d:SetPoint("CENTER")
    d:SetFrameStrata("DIALOG")  -- above all normal UI
    d:SetFrameLevel(200)        -- high level within strata for guaranteed visibility
    d:SetMovable(true)          -- user can drag the dialog around
    d:EnableMouse(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2,
        insets   = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    d:SetBackdropColor(0.06, 0.06, 0.08, 0.97)   -- near-black background
    d:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)  -- subtle grey border
    d:Hide()  -- hidden by default; Show() called by the Show*Dialog helpers

    -- Title label — text is set dynamically by Show*Dialog callers
    d._title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d._title:SetPoint("TOPLEFT", 16, -12)

    -- Close [X] button in the top-right corner
    local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() d:Hide() end)

    -- Instructions text — describes usage; set dynamically by callers
    d._instructions = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d._instructions:SetPoint("TOPLEFT", 16, -38)
    d._instructions:SetPoint("RIGHT", d, "RIGHT", -16, 0)
    d._instructions:SetJustifyH("LEFT")
    d._instructions:SetWordWrap(true)

    -- Multi-line edit area inside a scroll frame
    -- Dark inner container that visually separates the editable area
    local editBg = CreateFrame("Frame", nil, d, "BackdropTemplate")
    editBg:SetPoint("TOPLEFT", 12, -70)
    editBg:SetPoint("BOTTOMRIGHT", -14, 50)  -- leave room for action buttons
    editBg:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    editBg:SetBackdropColor(0.04, 0.04, 0.04, 1)
    editBg:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)

    -- Scroll frame wrapping the editbox so long lists can scroll
    local sf = CreateFrame("ScrollFrame", "QuickFlipImportScroll", editBg, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -24, 6)  -- offset for scrollbar thumb

    -- Multi-line EditBox — child of the scroll frame
    local eb = CreateFrame("EditBox", "QuickFlipImportEditBox", sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)          -- don't steal focus on show
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(440)                -- initial width; corrected OnShow below
    eb:EnableMouse(true)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Auto-resize height as text grows so the scroll frame has correct content bounds
    eb:SetScript("OnTextChanged", function(self)
        local _, fontH = self:GetFont()
        if not fontH then fontH = 14 end
        local text = self:GetText() or ""
        local _, newlines = text:gsub("\n", "")     -- count newlines
        local lines = (newlines or 0) + 2           -- +2 for padding/cursor
        self:SetHeight(math.max(lines * (fontH + 2), sf:GetHeight()))
    end)
    eb:SetScript("OnMouseDown", function(self) self:SetFocus() end)
    sf:SetScrollChild(eb)
    d._editBox = eb

    -- Click anywhere in the background or scroll area to focus the editbox
    editBg:EnableMouse(true)
    editBg:SetScript("OnMouseDown", function() eb:SetFocus() end)
    sf:EnableMouse(true)
    sf:SetScript("OnMouseDown", function() eb:SetFocus() end)

    -- Fix editbox width after layout — deferred by one frame via C_Timer so
    -- the scroll frame has been fully laid out and GetWidth returns the real value
    d:SetScript("OnShow", function(self)
        C_Timer.After(0, function()
            local w = sf:GetWidth()
            if w and w > 10 then
                eb:SetWidth(w)
            end
        end)
    end)

    -- Action button (Import / Close) — text and OnClick set by callers
    d._actionBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d._actionBtn:SetSize(100, 24)
    d._actionBtn:SetPoint("BOTTOMRIGHT", -16, 14)

    -- Cancel button — always just hides the dialog
    local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("RIGHT", d._actionBtn, "LEFT", -8, 0)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() d:Hide() end)

    _importDialog = d  -- cache for singleton reuse
    return d
end

---------------------------------------------------------------------------
-- ShowImportDialog — open the import dialog for a list
---------------------------------------------------------------------------
--- Open the import dialog pre-configured for pasting items into a list.
--- @param listName string  The target shopping list name
local function ShowImportDialog(listName)
    local d = CreateImportDialog()
    d._title:SetText("Import into: |cff00ff00" .. listName .. "|r")
    d._instructions:SetText(
        "Paste items below, separated by semicolons (;) or one per line.\n"
        .. "Example: |cffffffffRousing Fire; Awakened Fire; Hochenblume|r")
    d._editBox:SetText("")
    d._editBox:SetFocus()
    d._actionBtn:SetText("|cff00ff00Import|r")
    d._actionBtn:SetScript("OnClick", function()
        local raw = d._editBox:GetText()
        if not raw or raw == "" then return end
        -- Normalise newlines to semicolons so ns.ImportList receives a
        -- single-line, semicolon-delimited string regardless of paste format
        local data = raw:gsub("\n", ";")
        local added = ns.ImportList(listName, data)
        ns.Print(string.format(
            "Imported |cff00ff00%d|r item(s) into |cff88bbff%s|r.", added, listName))
        d:Hide()
        ns.RefreshListsUI()
    end)
    d:Show()
end

---------------------------------------------------------------------------
-- ShowExportDialog — open the export dialog showing list contents
---------------------------------------------------------------------------
--- Open the export dialog showing the semicolon-delimited contents of a list.
--- The text is auto-highlighted so the user can immediately Ctrl+C to copy.
--- @param listName string  The shopping list to export
local function ShowExportDialog(listName)
    local d = CreateImportDialog()  -- reuses the same singleton frame
    d._title:SetText("Export: |cff00ff00" .. listName .. "|r")
    d._instructions:SetText(
        "Select all (Ctrl+A) and copy (Ctrl+C) the text below.")
    local data = ns.ExportList(listName) or ""
    d._editBox:SetText(data)
    d._actionBtn:SetText("Close")                           -- no import action; just close
    d._actionBtn:SetScript("OnClick", function() d:Hide() end)
    d:Show()
    d._editBox:SetFocus()
    d._editBox:HighlightText()  -- pre-select all text for quick copy
end

---------------------------------------------------------------------------
-- ShowRenameDialog — Blizzard StaticPopup with text input
---------------------------------------------------------------------------
--- Blizzard StaticPopup template for renaming a shopping list.
--- `data` carries the original list name through the popup lifecycle.
StaticPopupDialogs["AHSCALPER_RENAME_LIST"] = {
    text         = "Enter new name for list:|n|cff00ff00%s|r",  -- %s filled by StaticPopup_Show arg2
    button1      = "Rename",       -- accept button label
    button2      = "Cancel",       -- cancel button label
    hasEditBox   = true,           -- shows an inline text input
    editBoxWidth = 260,
    timeout      = 0,              -- no auto-dismiss timer
    whileDead    = true,           -- popup works even when the player is dead
    hideOnEscape = true,           -- pressing Escape closes the popup
    preferredIndex = 3,            -- avoids taint by using a high popup slot
    --- Pre-fill the editbox with the current list name and highlight it.
    OnShow = function(self, data)
        -- Blizzard names child EditBox with parent frame name + "EditBox"
        local eb = _G[self:GetName() .. "EditBox"]
        eb:SetText(data or "")
        eb:HighlightText()  -- select all so typing replaces the old name
        eb:SetFocus()
    end,
    --- Attempt the rename when the user clicks "Rename".
    OnAccept = function(self, data)
        local eb = _G[self:GetName() .. "EditBox"]
        local newName = eb:GetText():match("^%s*(.-)%s*$")  -- trim whitespace
        if not newName or newName == "" then return end
        local oldName = data  -- original name passed via StaticPopup_Show arg4
        if ns.RenameList(oldName, newName) then
            _listsSelectedList = newName  -- update selection to follow the rename
            ns.Print("Renamed to: |cff00ff00" .. newName .. "|r")
        else
            ns.Print("|cffff0000Rename failed (name taken or invalid).|r")
        end
        -- Refresh all three panels that may reference the list by name
        ns.RefreshListsUI(); ns.RefreshUI(); ns.RefreshSellUI()
    end,
    --- Allow Enter to confirm the rename (mirrors click on button1)
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        StaticPopup_OnClick(parent, 1)
    end,
    --- Allow Escape inside the editbox to dismiss the popup
    EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
    end,
}

--- Show the Blizzard rename popup for a given list.
--- @param listName string  Current name of the list to rename
local function ShowRenameDialog(listName)
    -- arg1 = popup key, arg2 = %s substitution for text, arg3 = unused, arg4 = data payload
    StaticPopup_Show("AHSCALPER_RENAME_LIST", listName, nil, listName)
end

---------------------------------------------------------------------------
-- GetIconPool — build cached list of icon file IDs for the picker
---------------------------------------------------------------------------
--- Build and cache a merged pool of all available icon file IDs.
--- Combines the macro icon set (spells, abilities, UI art) with the
--- macro item icon set (equipment, consumables, trade goods) into one
--- flat array used by the icon picker grid.
--- @return table  Numerically-indexed array of icon fileIDs
local function GetIconPool()
    if _iconPickerIcons then return _iconPickerIcons end  -- return cached pool
    _iconPickerIcons = {}
    -- GetMacroIcons and GetMacroItemIcons return arrays of icon file IDs
    -- Merge macro/spell icons into the pool
    local macroIcons = GetMacroIcons()
    -- Merge item/equipment icons into the pool
    local itemIcons  = GetMacroItemIcons()
    if macroIcons then
        for _, id in ipairs(macroIcons) do
            table.insert(_iconPickerIcons, id)
        end
    end
    if itemIcons then
        for _, id in ipairs(itemIcons) do
            table.insert(_iconPickerIcons, id)
        end
    end
    return _iconPickerIcons
end

---------------------------------------------------------------------------
-- CreateIconPicker — scrollable icon grid popup (guild-bank-tab style)
---------------------------------------------------------------------------
-- Grid dimensions — determines how many icons are visible at once
local PICKER_COLS     = 10   -- columns per row in the icon grid
local PICKER_ROWS     = 9    -- visible rows before scrolling
local PICKER_BTN_SIZE = 36   -- px width/height of each icon button
local PICKER_PAD      = 4    -- px gap between buttons
-- Derive total frame size from grid constants
local PICKER_WIDTH    = PICKER_COLS * (PICKER_BTN_SIZE + PICKER_PAD) + 40
local PICKER_HEIGHT   = PICKER_ROWS * (PICKER_BTN_SIZE + PICKER_PAD) + 90

--- Create (or return cached) the scrollable icon-picker popup.
--- Modelled after the WoW guild-bank tab icon chooser: a grid of icon
--- buttons backed by a FauxScrollFrame for paging through thousands of icons.
--- @return Frame  The icon-picker frame (singleton)
local function CreateIconPicker()
    if _iconPickerFrame then return _iconPickerFrame end  -- singleton guard

    -- Main frame — DIALOG strata so it floats above the AH and other UI
    local f = CreateFrame("Frame", "QuickFlipIconPicker", UIParent, "BackdropTemplate")
    f:SetSize(PICKER_WIDTH, PICKER_HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(200)
    f:SetMovable(true)           -- user-draggable
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
    f:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    f:Hide()

    -- Title label — always "Choose Icon"
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("Choose Icon")
    f._title = title

    -- Close button — top-right corner
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Search box — filters icons by numeric ID
    local searchBox = CreateFrame("EditBox", "QuickFlipIconSearchBox", f, "SearchBoxTemplate")
    searchBox:SetSize(PICKER_WIDTH - 40, 20)
    searchBox:SetPoint("TOPLEFT", 16, -36)
    searchBox:SetAutoFocus(false)
    f._searchBox = searchBox

    -- FauxScrollFrame — provides a scrollbar for paging through the icon grid
    local scrollFrame = CreateFrame("ScrollFrame", "QuickFlipIconPickerScroll",
        f, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 12, -62)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 12)
    f._scrollFrame = scrollFrame

    -- Icon buttons grid (PICKER_COLS x PICKER_ROWS)
    -- Pre-create one button per visible grid cell; content is assigned in RefreshGrid
    local buttons = {}
    for row = 1, PICKER_ROWS do
        for col = 1, PICKER_COLS do
            local idx = (row - 1) * PICKER_COLS + col  -- 1-based linear index into the grid
            local btn = CreateFrame("Button", nil, f)
            btn:SetSize(PICKER_BTN_SIZE, PICKER_BTN_SIZE)
            -- Position relative to the scroll frame's top-left, offset by grid coords
            btn:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT",
                (col - 1) * (PICKER_BTN_SIZE + PICKER_PAD),
                -((row - 1) * (PICKER_BTN_SIZE + PICKER_PAD)))

            -- Icon texture fills the button face
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            btn._icon = tex

            -- Gold border for highlight / selection feedback
            local border = btn:CreateTexture(nil, "OVERLAY")
            border:SetPoint("TOPLEFT", -2, 2)
            border:SetPoint("BOTTOMRIGHT", 2, -2)
            border:SetColorTexture(1, 0.82, 0, 0.8)  -- gold tint
            border:Hide()
            btn._border = border

            -- Semi-transparent white highlight on mouse-over
            local hl = btn:CreateTexture(nil, "HIGHLIGHT")
            hl:SetPoint("TOPLEFT", -1, 1)
            hl:SetPoint("BOTTOMRIGHT", 1, -1)
            hl:SetColorTexture(1, 1, 1, 0.25)

            -- On click: invoke the stored callback with the chosen icon, then close
            btn:SetScript("OnClick", function(self)
                if self._iconID and _iconPickerCallback then
                    _iconPickerCallback(self._iconID)
                end
                f:Hide()
            end)
            -- Tooltip showing the numeric icon fileID on hover
            btn:SetScript("OnEnter", function(self)
                if self._iconID then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText("Icon ID: " .. self._iconID, 1, 1, 1)
                    GameTooltip:Show()
                end
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            buttons[idx] = btn
        end
    end
    f._buttons = buttons

    -- Filtered icon list (after search) — subset of the full icon pool
    f._filteredIcons = {}

    --- Refresh the visible grid buttons for the current scroll offset.
    --- Called whenever the scroll position changes or the filter updates.
    local function RefreshGrid()
        local icons = f._filteredIcons
        local numIcons = #icons
        local perPage = PICKER_COLS * PICKER_ROWS      -- total visible cells
        local offset = FauxScrollFrame_GetOffset(scrollFrame)  -- row offset from scrollbar
        local startIdx = offset * PICKER_COLS + 1       -- first icon index for this page

        for i = 1, perPage do
            local btn = buttons[i]
            local iconIdx = startIdx + i - 1  -- map grid cell to icon pool index
            if iconIdx <= numIcons then
                -- Assign icon data and show the button
                local iconID = icons[iconIdx]
                btn._iconID = iconID
                btn._icon:SetTexture(iconID)
                btn:Show()
            else
                -- Past end of pool — hide unused buttons
                btn._iconID = nil
                btn._icon:SetTexture(nil)
                btn:Hide()
            end
        end
    end
    f._RefreshGrid = RefreshGrid

    --- Apply the current search-box text as a filter and re-scroll to the top.
    --- Supports numeric search (matches icon IDs containing the query digits).
    --- Non-numeric or empty queries fall back to showing the full icon pool.
    local function ApplyFilter()
        local query = (f._searchBox:GetText() or ""):lower():match("^%s*(.-)%s*$")
        local pool = GetIconPool()
        if not query or query == "" then
            -- No filter — show everything
            f._filteredIcons = pool
        else
            -- Numeric search: match icon IDs starting with the query
            local filtered = {}
            local numQuery = tonumber(query)  -- nil if query isn't numeric
            for _, id in ipairs(pool) do
                if numQuery then
                    -- Plain-text find (not pattern) for numeric substring matching
                    if tostring(id):find(query, 1, true) then
                        table.insert(filtered, id)
                    end
                end
            end
            -- If no numeric match or not a number, just show all
            -- (non-numeric text can't match icon file IDs)
            if #filtered == 0 and not numQuery then
                filtered = pool
            end
            f._filteredIcons = (#filtered > 0) and filtered or pool
        end
        -- Update scrollbar range: total rows = ceil(icons / columns)
        local totalRows = math.ceil(#f._filteredIcons / PICKER_COLS)
        FauxScrollFrame_Update(scrollFrame, totalRows, PICKER_ROWS,
            PICKER_BTN_SIZE + PICKER_PAD)
        RefreshGrid()
    end
    f._ApplyFilter = ApplyFilter

    -- Re-filter whenever the user types in the search box
    searchBox:SetScript("OnTextChanged", function(self, userInput)
        SearchBoxTemplate_OnTextChanged(self)  -- standard Blizzard clear-button logic
        if userInput then ApplyFilter() end    -- only re-filter on real keystrokes
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- Scroll handler — FauxScrollFrame drives offset, RefreshGrid redraws
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset,
            PICKER_BTN_SIZE + PICKER_PAD, RefreshGrid)
    end)

    _iconPickerFrame = f  -- cache singleton
    return f
end

---------------------------------------------------------------------------
-- ShowIconPicker — open the icon picker, call onSelect(iconID) on pick
---------------------------------------------------------------------------
--- Open the icon picker and invoke a callback when the user selects an icon.
--- Uses the callback pattern: the caller passes a function that receives the
--- chosen iconID, decoupling the picker from any specific consumer.
--- @param onSelect function  Callback receiving (iconID) when an icon is clicked
local function ShowIconPicker(onSelect)
    local f = CreateIconPicker()
    _iconPickerCallback = onSelect        -- store callback for button OnClick handlers
    f._searchBox:SetText("")              -- clear previous search
    f._filteredIcons = GetIconPool()      -- reset to full icon pool
    f:Show()
    f._ApplyFilter()                      -- populate grid with unfiltered icons
end

---------------------------------------------------------------------------
-- New List Dialog — modal with name input + icon picker button
---------------------------------------------------------------------------
local _newListDialog        = nil
local _newListSelectedIcon  = nil  -- chosen icon file ID (nil = default)

--- Create (or return cached) the "Create New List" modal dialog.
--- Contains a name input, icon preview with a "Choose…" picker button,
--- and Create / Cancel action buttons.
--- @return Frame  The new-list dialog frame (singleton)
local function CreateNewListDialog()
    if _newListDialog then return _newListDialog end  -- singleton guard

    -- Dialog frame — level 210 so it sits above the icon picker (200)
    local d = CreateFrame("Frame", "QuickFlipNewListDialog", UIParent, "BackdropTemplate")
    d:SetSize(340, 160)
    d:SetPoint("CENTER")
    d:SetFrameStrata("DIALOG")
    d:SetFrameLevel(210)     -- higher than icon picker so it stays on top
    d:SetMovable(true)
    d:EnableMouse(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets   = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    d:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
    d:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    d:Hide()

    -- Title label
    local title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("Create New List")

    -- Close [X] button
    local closeBtn = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() d:Hide() end)

    -- Name label + editbox — the user types the new list name here
    local nameLabel = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameLabel:SetPoint("TOPLEFT", 16, -40)
    nameLabel:SetText("List Name:")

    local nameBox = CreateFrame("EditBox", "QuickFlipNewListNameBox", d, "InputBoxTemplate")
    nameBox:SetSize(200, 22)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetMaxLetters(50)  -- cap list name length
    nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    d._nameBox = nameBox

    -- Icon row: label + 32×32 preview thumbnail + "Choose…" button
    local iconLabel = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    iconLabel:SetPoint("TOPLEFT", 16, -72)
    iconLabel:SetText("Icon:")

    -- Preview button showing the currently selected icon
    local iconPreview = CreateFrame("Button", nil, d)
    iconPreview:SetSize(32, 32)
    iconPreview:SetPoint("LEFT", iconLabel, "RIGHT", 8, 0)
    local iconTex = iconPreview:CreateTexture(nil, "ARTWORK")
    iconTex:SetAllPoints()
    iconTex:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")  -- default bag icon
    d._iconTex = iconTex

    -- Opens the icon picker; selected icon updates the preview and _newListSelectedIcon
    local changeIconBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    changeIconBtn:SetSize(80, 22)
    changeIconBtn:SetPoint("LEFT", iconPreview, "RIGHT", 8, 0)
    changeIconBtn:SetText("Choose...")
    changeIconBtn:SetScript("OnClick", function()
        ShowIconPicker(function(iconID)
            _newListSelectedIcon = iconID   -- store for use when Create is clicked
            iconTex:SetTexture(iconID)      -- update the preview thumbnail
        end)
    end)

    -- Create button — validates name, creates the list, optionally sets icon
    local createBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    createBtn:SetSize(90, 24)
    createBtn:SetPoint("BOTTOMRIGHT", -16, 12)
    createBtn:SetText("|cff00ff00Create|r")
    createBtn:SetScript("OnClick", function()
        local name = nameBox:GetText():match("^%s*(.-)%s*$")  -- trim whitespace
        if not name or name == "" then return end               -- reject blank names
        if ns.CreateList(name) then
            _listsSelectedList = name  -- auto-select the newly created list
            -- Apply chosen icon if the user picked one via the icon picker
            if _newListSelectedIcon then
                ns.SetListIcon(name, _newListSelectedIcon)
            end
            ns.Print("Created list: |cff00ff00" .. name .. "|r")
        else
            ns.Print("|cffff0000List already exists.|r")
        end
        d:Hide()
        -- Refresh all panels that display list names / dropdowns
        ns.RefreshListsUI(); ns.RefreshUI(); ns.RefreshSellUI()
    end)

    -- Cancel button — just closes the dialog
    local cancelBtn = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    cancelBtn:SetSize(80, 24)
    cancelBtn:SetPoint("RIGHT", createBtn, "LEFT", -8, 0)
    cancelBtn:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function() d:Hide() end)

    -- Pressing Enter in the name box acts as clicking Create
    nameBox:SetScript("OnEnterPressed", function() createBtn:Click() end)

    _newListDialog = d  -- cache singleton
    return d
end

--- Show the "Create New List" dialog with a blank name and default icon.
local function ShowNewListDialog()
    local d = CreateNewListDialog()
    d._nameBox:SetText("")                                       -- clear previous input
    _newListSelectedIcon = nil                                   -- reset icon selection
    d._iconTex:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")  -- default preview
    d:Show()
    d._nameBox:SetFocus()  -- auto-focus the name field for immediate typing
end

---------------------------------------------------------------------------
-- ShowListContextMenu — right-click context menu on a list row
---------------------------------------------------------------------------
--- Show a right-click context menu on a shopping list row.
--- Entries: Rename, Change Icon, Export, Import, Delete, Cancel.
--- @param listName    string  The list this menu operates on
--- @param anchorFrame Frame   The UI element to anchor the dropdown to
local function ShowListContextMenu(listName, anchorFrame)
    -- Create the dropdown frame once, reuse on subsequent calls
    if not _listsContextMenu then
        _listsContextMenu = CreateFrame("Frame", "QuickFlipListContextMenu",
            UIParent, "UIDropDownMenuTemplate")
    end

    -- UIDropDownMenu_Initialize rebuilds the menu items each time it opens
    UIDropDownMenu_Initialize(_listsContextMenu, function(self, level)
        local info

        -- Header — non-interactive title showing the list name
        info = UIDropDownMenu_CreateInfo()
        info.text       = listName
        info.isTitle     = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Rename — opens the Blizzard StaticPopup rename dialog
        info = UIDropDownMenu_CreateInfo()
        info.text       = "Rename"
        info.notCheckable = true
        info.func       = function()
            ShowRenameDialog(listName)
        end
        UIDropDownMenu_AddButton(info, level)

        -- Change Icon — opens the icon picker, persists choice via ns.SetListIcon
        info = UIDropDownMenu_CreateInfo()
        info.text       = "Change Icon"
        info.notCheckable = true
        info.func       = function()
            ShowIconPicker(function(iconID)
                ns.SetListIcon(listName, iconID)
                ns.RefreshListsUI()
            end)
        end
        UIDropDownMenu_AddButton(info, level)

        -- Export — opens the shared dialog in read-only export mode
        info = UIDropDownMenu_CreateInfo()
        info.text       = "Export"
        info.notCheckable = true
        info.func       = function()
            ShowExportDialog(listName)
        end
        UIDropDownMenu_AddButton(info, level)

        -- Import — opens the shared dialog in writable import mode
        info = UIDropDownMenu_CreateInfo()
        info.text       = "Import"
        info.notCheckable = true
        info.func       = function()
            ShowImportDialog(listName)
        end
        UIDropDownMenu_AddButton(info, level)

        -- Separator — visual divider before destructive action
        info = UIDropDownMenu_CreateInfo()
        info.text = ""
        info.disabled = true
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)

        -- Delete (red) — permanently removes the list and refreshes all panels
        info = UIDropDownMenu_CreateInfo()
        info.text       = "|cffff4444Delete|r"
        info.notCheckable = true
        info.func       = function()
            ns.DeleteList(listName)
            -- Clear selection if the deleted list was selected
            if _listsSelectedList == listName then _listsSelectedList = "" end
            ns.Print("Deleted: |cffff8800" .. listName .. "|r")
            ns.RefreshListsUI(); ns.RefreshUI(); ns.RefreshSellUI()
        end
        UIDropDownMenu_AddButton(info, level)

        -- Cancel — no-op entry; closing the menu without choosing an action
        info = UIDropDownMenu_CreateInfo()
        info.text       = "Cancel"
        info.notCheckable = true
        UIDropDownMenu_AddButton(info, level)
    end, "MENU")  -- "MENU" type: no persistent selection, just a command menu

    -- Display the dropdown anchored to the clicked list row
    ToggleDropDownMenu(1, nil, _listsContextMenu, anchorFrame, 0, 0)
end

---------------------------------------------------------------------------
-- CreateListRow — a single clickable shopping-list row with context menu
---------------------------------------------------------------------------
--- Create a single clickable shopping-list row for the left pane.
--- Each row displays a list icon, the list name, and an item-count badge.
--- Supports left-click (select) and right-click (context menu) via RegisterForClicks.
--- @param parent Frame  The scroll content frame that will contain this row
--- @return Frame row  The configured, initially hidden row frame
local function CreateListRow(parent)
    -- Create a Button frame so we receive OnClick; height matches the shared constant
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(LIST_ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp") -- enable both mouse buttons

    -- Selection bg (green tint) — shown only when this row is the active list;
    -- draw layer 1 so it renders above the hover bg (layer 0)
    local sel = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    sel:SetAllPoints()
    sel:SetColorTexture(0.08, 0.28, 0.12, 0.55)
    sel:Hide()
    row._sel = sel

    -- Hover bg — subtle highlight shown on mouse-over (layer 0, behind selection)
    local hl = row:CreateTexture(nil, "BACKGROUND", nil, 0)
    hl:SetAllPoints()
    hl:SetColorTexture(0.14, 0.14, 0.20, 0.40)
    hl:Hide()
    row._hl = hl

    -- List icon (folder-like) — default blue bag; swapped at refresh time
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 8, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")
    row._icon = icon

    -- List name — truncated by right anchor to leave room for the count badge
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -42, 0)
    name:SetJustifyH("LEFT")
    row._name = name

    -- Item count badge — right-aligned "(N)" showing how many items the list contains
    local count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    count:SetJustifyH("RIGHT")
    row._count = count

    -- Bottom separator — thin horizontal line dividing rows visually
    local sep = row:CreateTexture(nil, "OVERLAY")
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", 6, 0)
    sep:SetPoint("BOTTOMRIGHT", -6, 0)
    sep:SetColorTexture(0.15, 0.15, 0.15, 0.45)

    -- Hover scripts — show highlight on enter (unless row is already selected),
    -- display a tooltip with the list name and usage hint
    row:SetScript("OnEnter", function(self)
        if not self._isSelected then self._hl:Show() end -- don't overwrite green selection bg
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self._listName or "", 1, 1, 1)
        GameTooltip:AddLine("Left-click to select, Right-click for options", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function(self)
        self._hl:Hide()
        GameTooltip:Hide()
    end)

    row:Hide()  -- hidden by default; shown during RefreshListsUI when populated
    return row
end

---------------------------------------------------------------------------
-- CreateItemRow — a single list-item row with icon, rarity, delete btn
---------------------------------------------------------------------------
--- Create a single item row for the Items tab on the right pane.
--- Displays an icon with rarity-colored border, a numbered label, the item
--- name, and a delete [x] button to remove the item from the list.
--- @param parent Frame  The scroll content frame for the Items tab
--- @return Frame row  The configured, initially hidden item row frame
local function CreateItemRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ITEM_ROW_HEIGHT)

    -- Hover bg — subtle purple-grey tint on mouse-over
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(0.14, 0.14, 0.20, 0.30)
    hl:Hide()
    row._hl = hl

    -- Item icon — defaults to question mark; replaced with real icon during refresh
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    row._icon = icon

    -- Icon border (rarity color) — white frame overlay tinted by item quality
    -- Slightly larger than the icon to create a visible border effect
    local iconBorder = row:CreateTexture(nil, "OVERLAY")
    iconBorder:SetSize(22, 22)
    iconBorder:SetPoint("CENTER", icon, "CENTER", 0, 0)
    iconBorder:SetTexture("Interface\\Common\\WhiteIconFrame")
    iconBorder:SetVertexColor(1, 1, 1, 0.3) -- default: faint white for common items
    row._iconBorder = iconBorder

    -- Number label — right-justified ordinal ("1.", "2.", etc.) next to the icon
    local num = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    num:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    num:SetWidth(22)
    num:SetJustifyH("RIGHT")
    row._num = num

    -- Item name — stretches from number label to just before the delete button
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", num, "RIGHT", 4, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -28, 0)
    name:SetJustifyH("LEFT")
    row._name = name

    -- Delete [X] — small button to remove the item from the current list
    local del = CreateFrame("Button", nil, row)
    del:SetSize(20, 20)
    del:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    del._label = del:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    del._label:SetPoint("CENTER")
    del._label:SetText("|cffff4444x|r") -- muted red by default
    -- Hover turns the "x" brighter red and shows a removal tooltip
    del:SetScript("OnEnter", function(self)
        self._label:SetText("|cffff0000x|r") -- bright red on hover
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove from list", 1, 0.3, 0.3)
        GameTooltip:Show()
    end)
    del:SetScript("OnLeave", function(self)
        self._label:SetText("|cffff4444x|r") -- revert to muted red
        GameTooltip:Hide()
    end)
    row._del = del

    -- Separator — thin line at the bottom of each row
    local sep = row:CreateTexture(nil, "OVERLAY")
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", 4, 0)
    sep:SetPoint("BOTTOMRIGHT", -4, 0)
    sep:SetColorTexture(0.12, 0.12, 0.12, 0.35)

    -- Row hover — show highlight bg and an item-level tooltip via SetItemByID
    row:SetScript("OnEnter", function(self)
        self._hl:Show()
        -- Show item tooltip if we have an itemID (set during RefreshListsUI)
        if self._itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self._itemID) -- full Blizzard item tooltip
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self._hl:Hide()
        GameTooltip:Hide()
    end)

    row:Hide()  -- hidden by default; shown when populated by RefreshListsUI
    return row
end

---------------------------------------------------------------------------
-- CreateInventoryRow — a single bag-item row with icon, qty, add btn
---------------------------------------------------------------------------
--- Create a single inventory row for the Inventory tab on the right pane.
--- Similar to CreateItemRow but designed for bag items: shows a quantity badge
--- and an [+] add button instead of a delete button, allowing the user to add
--- a bag item directly to the selected shopping list.
--- @param parent Frame  The scroll content frame for the Inventory tab
--- @return Frame row  The configured, initially hidden inventory row frame
local function CreateInventoryRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(INV_ROW_HEIGHT)

    -- Hover bg — greenish tint to visually distinguish from Items-tab rows
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetAllPoints()
    hl:SetColorTexture(0.12, 0.18, 0.12, 0.30)
    hl:Hide()
    row._hl = hl

    -- Item icon — placeholder; replaced with the real bag item icon during refresh
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", 6, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
    row._icon = icon

    -- Icon border (rarity color) — slightly larger than the icon for a border effect
    local iconBorder = row:CreateTexture(nil, "OVERLAY")
    iconBorder:SetSize(24, 24)
    iconBorder:SetPoint("CENTER", icon, "CENTER", 0, 0)
    iconBorder:SetTexture("Interface\\Common\\WhiteIconFrame")
    iconBorder:SetVertexColor(1, 1, 1, 0.3) -- default: faint white
    row._iconBorder = iconBorder

    -- Item name — truncated to leave room for qty badge + add button on the right
    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetPoint("RIGHT", row, "RIGHT", -80, 0)
    name:SetJustifyH("LEFT")
    row._name = name

    -- Quantity badge — displays total stack count across all bags (e.g. "x42")
    local qty = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    qty:SetPoint("RIGHT", row, "RIGHT", -46, 0)
    qty:SetWidth(30)
    qty:SetJustifyH("RIGHT")
    row._qty = qty

    -- Add [+] button — clicking adds this bag item to the currently selected list
    local addBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    addBtn:SetSize(36, 20)
    addBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    addBtn:SetText("|cff00ff00+|r")
    row._addBtn = addBtn

    -- Separator — thin bottom border between inventory rows
    local sep = row:CreateTexture(nil, "OVERLAY")
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", 4, 0)
    sep:SetPoint("BOTTOMRIGHT", -4, 0)
    sep:SetColorTexture(0.12, 0.12, 0.12, 0.35)

    -- Row hover — show highlight and display a full item tooltip via SetItemByID
    row:SetScript("OnEnter", function(self)
        self._hl:Show()
        if self._itemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self._itemID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        self._hl:Hide()
        GameTooltip:Hide()
    end)

    row:Hide()  -- hidden by default; shown when populated by RefreshListsUI
    return row
end

---------------------------------------------------------------------------
-- GetBagItems — scan player bags, return sorted unique items
---------------------------------------------------------------------------
-- Returns: array of { itemID, name, icon, quality, count }
---------------------------------------------------------------------------
--- Scan all player bags and return a de-duplicated, sorted list of unbound items.
--- Stacks of the same item across multiple bag slots are merged into one entry.
--- Soulbound / account-bound items are excluded since they cannot be listed on the AH.
--- @return table list  Array of { itemID, name, icon, quality, count } sorted by quality desc then name asc
local function GetBagItems()
    local seen = {}  -- itemID -> entry  (dedup table: merges stack counts for the same item)
    local list = {}

    -- Bags 0-4 = backpack + equipped bags, bag 5 = reagent bag
    for bag = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bag)
        for slot = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            -- Only consider non-nil, non-bound items (bound items can't be auctioned)
            if info and info.itemID and not info.isBound then
                if seen[info.itemID] then
                    -- Already encountered this item — accumulate the stack count
                    seen[info.itemID].count = seen[info.itemID].count + info.stackCount
                else
                    -- First occurrence — fetch item metadata from the client cache
                    local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(info.itemID)
                    if name then
                        local entry = {
                            itemID  = info.itemID,
                            name    = name,
                            icon    = icon or info.iconFileID, -- fallback to container icon if cache misses
                            quality = quality or 1,            -- default to Common if unknown
                            count   = info.stackCount,
                        }
                        seen[info.itemID] = entry
                        table.insert(list, entry)
                    end
                end
            end
        end
    end

    -- Sort by quality desc (rarer items first), then name asc for a readable list
    table.sort(list, function(a, b)
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.name < b.name
    end)

    return list
end

---------------------------------------------------------------------------
-- SetTabActive — visually toggle between Items and Inventory tabs
---------------------------------------------------------------------------
--- Visually toggle between the Items and Inventory tabs on the right pane.
--- Updates button backdrop colours (green tint for Items, blue for Inventory)
--- and shows/hides the corresponding tab content frames.
--- @param tabName string  Either "items" or "inventory"
local function SetTabActive(tabName)
    _listsActiveTab = tabName  -- persist current tab state for RefreshListsUI

    -- Apply colour theming to tab buttons when both exist
    if _listsItemsTabBtn and _listsInvTabBtn then
        if tabName == "items" then
            -- Active Items tab: green-tinted bg + green border
            _listsItemsTabBtn:SetBackdropColor(0.12, 0.20, 0.12, 1)
            _listsItemsTabBtn:SetBackdropBorderColor(0.2, 0.6, 0.3, 0.8)
            -- Inactive Inventory tab: dark neutral bg
            _listsInvTabBtn:SetBackdropColor(0.06, 0.06, 0.06, 1)
            _listsInvTabBtn:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)
        else
            -- Active Inventory tab: blue-tinted bg + blue border
            _listsInvTabBtn:SetBackdropColor(0.12, 0.15, 0.22, 1)
            _listsInvTabBtn:SetBackdropBorderColor(0.3, 0.45, 0.7, 0.8)
            -- Inactive Items tab: dark neutral bg
            _listsItemsTabBtn:SetBackdropColor(0.06, 0.06, 0.06, 1)
            _listsItemsTabBtn:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)
        end
    end

    -- Toggle frame visibility — only the active tab's frame is shown
    if _listsItemsTabFrame then
        _listsItemsTabFrame:SetShown(tabName == "items")
    end
    if _listsInvTabFrame then
        _listsInvTabFrame:SetShown(tabName == "inventory")
    end
end

---------------------------------------------------------------------------
-- RefreshListsUI — update the Lists panel display
---------------------------------------------------------------------------
--- Refresh the entire Lists panel display: left pane (list rows), right pane
--- (Items tab + Inventory tab), selected-list label, add-box state, and status bar.
--- Called after any mutation (add/remove/rename/import) and on tab switches.
--- Safe to call at any time — early-returns if the panel hasn't been built yet.
function ns.RefreshListsUI()
    if not ns.listsPanelBuilt then return end  -- guard: panel not yet constructed

    local names = ns.GetListNames()

    -- Validate selection still exists (list may have been deleted externally)
    if _listsSelectedList ~= "" and not ns.GetListItems(_listsSelectedList) then
        _listsSelectedList = ""
    end

    -------------------------------------------------------------------
    -- Left pane: list rows
    -------------------------------------------------------------------
    if _listsListContent then
        -- Ensure enough row frames exist (recycle previously created ones)
        for i = #_listRows + 1, #names do
            _listRows[i] = CreateListRow(_listsListContent)
        end

        -- Populate or hide each row frame
        for i = 1, math.max(#_listRows, #names) do
            local row = _listRows[i]
            if i <= #names then
                local n      = names[i]
                local items  = ns.GetListItems(n)
                local cnt    = items and #items or 0
                local active = (n == _listsSelectedList)

                row._listName = n
                -- Highlight the selected list name in green; others in white
                row._name:SetText(active
                    and ("|cff00ff00" .. n .. "|r")
                    or  ("|cffffffff" .. n .. "|r"))
                row._count:SetText("|cff888888(" .. cnt .. ")|r")

                -- List icon — use custom icon if set, else default
                -- Active lists without a custom icon get a green bag icon
                local customIcon = ns.GetListIcon(n)
                if customIcon then
                    row._icon:SetTexture(customIcon)
                elseif active then
                    row._icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Green")
                else
                    row._icon:SetTexture(DEFAULT_LIST_ICON)
                end

                row._isSelected = active
                if active then row._sel:Show() else row._sel:Hide() end

                -- Left click = select list, Right click = open context menu (rename/delete/etc.)
                row:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        ShowListContextMenu(n, self)
                    else
                        _listsSelectedList = n
                        ns.RefreshListsUI()  -- re-render with new selection
                    end
                end)

                -- Position rows vertically within the scroll content
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", _listsListContent, "TOPLEFT", 0,
                    -(i - 1) * LIST_ROW_HEIGHT)
                row:SetPoint("RIGHT", _listsListContent, "RIGHT", 0, 0)
                row:Show()
            elseif row then
                row:Hide()  -- surplus row frame from a previous larger list
            end
        end
        -- Resize scroll content to fit all rows (min 1px to keep ScrollFrame happy)
        _listsListContent:SetHeight(math.max(#names * LIST_ROW_HEIGHT, 1))
    end

    -- Empty-list placeholder — shown when no shopping lists exist
    if _listsEmptyListMsg then
        _listsEmptyListMsg:SetShown(#names == 0)
    end

    -------------------------------------------------------------------
    -- Right pane: Items tab — item rows with icons
    -------------------------------------------------------------------
    if _listsItemContent then
        -- Fetch items for the selected list (empty table if none selected)
        local items = (_listsSelectedList ~= "")
            and ns.GetListItems(_listsSelectedList) or {}
        items = items or {}

        -- Grow the row pool if the list has more items than existing frames
        for i = #_itemRows + 1, #items do
            _itemRows[i] = CreateItemRow(_listsItemContent)
        end

        for i = 1, math.max(#_itemRows, #items) do
            local row = _itemRows[i]
            if i <= #items then
                local itemTerm = items[i]
                local cleanName = ns.ParseSearchTerm(itemTerm) -- strip any search modifiers
                -- Resolve item metadata from the client cache (name, icon, quality)
                local resolvedName, iconID, quality = GetItemInfoCached(cleanName)

                -- Set icon — use cached icon or fall back to question mark
                if iconID then
                    row._icon:SetTexture(iconID)
                else
                    row._icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                end

                -- Set rarity border color — colour the icon frame by item quality
                -- Quality >= 2 (Uncommon+) gets the standard Blizzard rarity colour
                if quality and quality >= 2 then
                    local c = ITEM_QUALITY_COLORS[quality]
                    if c then
                        row._iconBorder:SetVertexColor(c.r, c.g, c.b, 0.8)
                    else
                        row._iconBorder:SetVertexColor(1, 1, 1, 0.3)
                    end
                else
                    row._iconBorder:SetVertexColor(1, 1, 1, 0.3) -- Common/unknown: faint white
                end

                -- Ordinal label ("1.", "2.", …)
                row._num:SetText("|cff666666" .. i .. ".|r")
                -- Colour the item name by its rarity
                local colorCode = GetRarityColor(quality or 1)
                row._name:SetText(colorCode .. (resolvedName or cleanName) .. "|r")
                -- Cache itemID for tooltip display on hover
                row._itemID = resolvedName and select(1, GetItemInfoInstant(cleanName)) or nil

                -- Wire up the delete button to remove this item and refresh
                row._del:SetScript("OnClick", function()
                    ns.RemoveItemFromList(_listsSelectedList, itemTerm)
                    ns.Print("Removed: |cffff8800" .. cleanName .. "|r")
                    ns.RefreshListsUI()
                end)

                -- Position row vertically in the scroll content
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", _listsItemContent, "TOPLEFT", 0,
                    -(i - 1) * ITEM_ROW_HEIGHT)
                row:SetPoint("RIGHT", _listsItemContent, "RIGHT", 0, 0)
                row:Show()
            elseif row then
                row:Hide()
            end
        end
        _listsItemContent:SetHeight(math.max(#items * ITEM_ROW_HEIGHT, 1))

        -- Placeholder text — three states:
        -- 1. No list selected  2. List selected but empty  3. List has items (hide msg)
        if _listsEmptyItemMsg then
            if _listsSelectedList == "" then
                _listsEmptyItemMsg:SetText("|cff666666Select a list from the left panel|r")
                _listsEmptyItemMsg:Show()
            elseif #items == 0 then
                _listsEmptyItemMsg:SetText("|cff666666This list is empty\nAdd items using the box below\nor switch to the Inventory tab|r")
                _listsEmptyItemMsg:Show()
            else
                _listsEmptyItemMsg:Hide()
            end
        end
    end

    -------------------------------------------------------------------
    -- Right pane: Inventory tab — bag items not already in list
    -------------------------------------------------------------------
    if _listsInvContent then
        local bagItems = {}
        if _listsSelectedList ~= "" then
            local allBag = GetBagItems()  -- full bag scan (deduped + sorted)
            -- Build set of existing items (lowercase) for fast lookup
            -- so we can exclude items that are already in the selected list
            local existing = {}
            local listItems = ns.GetListItems(_listsSelectedList) or {}
            for _, term in ipairs(listItems) do
                existing[ns.ParseSearchTerm(term):lower()] = true
            end
            -- Filter: exclude items already in list, then apply search-box filter
            local searchQuery = _listsInvSearchText:lower()
            for _, entry in ipairs(allBag) do
                if not existing[entry.name:lower()] then
                    if searchQuery == "" or entry.name:lower():find(searchQuery, 1, true) then
                        table.insert(bagItems, entry)
                    end
                end
            end
        end

        -- Grow the inventory row pool as needed
        for i = #_invRows + 1, #bagItems do
            _invRows[i] = CreateInventoryRow(_listsInvContent)
        end

        for i = 1, math.max(#_invRows, #bagItems) do
            local row = _invRows[i]
            if i <= #bagItems then
                local entry = bagItems[i]
                row._icon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                row._itemID = entry.itemID  -- stored for tooltip on hover

                -- Rarity border — colour the icon frame by item quality
                if entry.quality and entry.quality >= 2 then
                    local c = ITEM_QUALITY_COLORS[entry.quality]
                    if c then
                        row._iconBorder:SetVertexColor(c.r, c.g, c.b, 0.8)
                    else
                        row._iconBorder:SetVertexColor(1, 1, 1, 0.3)
                    end
                else
                    row._iconBorder:SetVertexColor(1, 1, 1, 0.3)
                end

                local colorCode = GetRarityColor(entry.quality)
                row._name:SetText(colorCode .. entry.name .. "|r")
                row._qty:SetText("|cffccccccx" .. entry.count .. "|r") -- e.g. "x42"

                -- [+] button: add this bag item to the selected shopping list
                row._addBtn:SetScript("OnClick", function()
                    if _listsSelectedList == "" then return end  -- safety check
                    if ns.AddItemToList(_listsSelectedList, entry.name) then
                        ns.CacheItemID(entry.name, entry.itemID)
                        ns.Print("Added: |cff00ff00" .. entry.name .. "|r")
                        ns.RefreshListsUI()  -- re-render so item moves from inventory to list
                    else
                        ns.Print("|cffff0000Already in list.|r")
                    end
                end)

                -- Position row in the scroll content
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", _listsInvContent, "TOPLEFT", 0,
                    -(i - 1) * INV_ROW_HEIGHT)
                row:SetPoint("RIGHT", _listsInvContent, "RIGHT", 0, 0)
                row:Show()
            elseif row then
                row:Hide()
            end
        end
        _listsInvContent:SetHeight(math.max(#bagItems * INV_ROW_HEIGHT, 1))

        -- Empty-inventory placeholder — two states:
        -- 1. No list selected  2. All bag items already in list / bags empty
        if _listsEmptyInvMsg then
            if _listsSelectedList == "" then
                _listsEmptyInvMsg:SetText("|cff666666Select a list first|r")
                _listsEmptyInvMsg:Show()
            elseif #bagItems == 0 then
                _listsEmptyInvMsg:SetText("|cff666666All bag items are already in this list\nor your bags are empty|r")
                _listsEmptyInvMsg:Show()
            else
                _listsEmptyInvMsg:Hide()
            end
        end
    end

    -------------------------------------------------------------------
    -- Selected label with icon — shows "<ListName> (N items)" or placeholder
    -------------------------------------------------------------------
    if _listsSelectedLabel then
        if _listsSelectedList ~= "" then
            local items = ns.GetListItems(_listsSelectedList)
            _listsSelectedLabel:SetText(string.format(
                "|cff00ff00%s|r  |cff888888(%d items)|r",
                _listsSelectedList, items and #items or 0))
        else
            _listsSelectedLabel:SetText("|cff888888No list selected|r")
        end
    end

    -- Add-item box enable/disable — disabled when no list is selected
    if _listsAddBox then
        if _listsSelectedList ~= "" then
            _listsAddBox:Enable()
            _listsAddBox:SetAlpha(1)
        else
            _listsAddBox:Disable()
            _listsAddBox:SetAlpha(0.4)  -- visually dim when disabled
        end
    end

    -------------------------------------------------------------------
    -- Status bar — summary text at the bottom of the panel
    -------------------------------------------------------------------
    if _listsStatusText then
        local listCount = ns.GetListCount()
        local itemCount = 0
        if _listsSelectedList ~= "" then
            local its = ns.GetListItems(_listsSelectedList)
            itemCount = its and #its or 0
        end
        _listsStatusText:SetText(string.format(
            "|cff888888%d list(s)  |  %d item(s) in selected list  |  Right-click a list for options|r",
            listCount, itemCount))
    end
end

---------------------------------------------------------------------------
-- BuildListsPanel — construct the Lists management panel
---------------------------------------------------------------------------
-- Layout:
--   +--------------------------------------------------------------------+
--   | Header: QuickFlip Lists                                          |
--   +-------------------------+-----------------------------------------+
--   | Shopping Lists          | [Items] [Inventory]  <- tab buttons     |
--   | +---------------------+ | +-------------------------------------+ |
--   | | [bag] MyList  (5)   | | | [icon] 1. Rousing Fire          x  | |
--   | | [bag] Herbs   (3)   | | | [icon] 2. Awakened Fire         x  | |
--   | | [bag] Gems   (12)   | | | [icon] 3. Hochenblume           x  | |
--   | +---------------------+ | +-------------------------------------+ |
--   | [_________] [+ New]     | [___________] [+ Add]  [Import][Export]|
--   +-------------------------+-----------------------------------------+
--   | Status: 3 lists | 5 items | Right-click for options               |
--   +--------------------------------------------------------------------+
---------------------------------------------------------------------------
--- Construct the entire Lists management panel UI from scratch.
--- This is a one-shot builder: once created, the panel is reused via show/hide.
--- Layout is a two-pane design (see ASCII diagram above): left pane for shopping
--- list selection, right pane with Items/Inventory tabs, plus a bottom action bar.
--- @return Frame  The fully constructed lists panel frame
function ns.BuildListsPanel()
    if ns.listsPanelBuilt then return ns.listsPanel end  -- guard: only build once

    -- Create the main panel frame, parented to the AH window
    ns.listsPanel = CreateFrame("Frame", "QuickFlipListsPanel", AuctionHouseFrame)
    ns.listsPanel:SetAllPoints()
    ns.listsPanel:Hide()  -- hidden until the Lists tab is clicked

    -- Solid dark background covering the AH content area (inset from AH borders)
    local bg = ns.listsPanel:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 3, -31)
    bg:SetPoint("BOTTOMRIGHT", -3, 2)
    bg:SetColorTexture(0.02, 0.02, 0.02, 1)

    -- Layout constants — padding, left offset, top offset, and left/right pane split
    local PAD = 10
    local L   = PAD + 5               -- left margin
    local T   = -68                    -- top offset below AH title bar
    local panelWidth = AuctionHouseFrame:GetWidth() or 890
    local SPLIT_X    = math.floor(panelWidth * 0.35)  -- 35% for left pane

    -----------------------------------------------------------------------
    -- HEADER — addon icon + title with version number
    -----------------------------------------------------------------------
    local headerIcon = ns.listsPanel:CreateTexture(nil, "ARTWORK")
    headerIcon:SetSize(22, 22)
    headerIcon:SetPoint("TOPLEFT", L, T + 2)
    headerIcon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")

    local header = ns.listsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("LEFT", headerIcon, "RIGHT", 6, 0)
    header:SetText("|cff33ff99QuickFlip|r  |cff88bbffLists|r  |cff555555v" .. ns.VERSION .. "|r")

    -----------------------------------------------------------------------
    -- LEFT PANE — Shopping Lists (clickable scroll list)
    -----------------------------------------------------------------------
    local leftHeaderY = T - 28  -- vertical position for the "Shopping Lists" sub-header

    -- Small bag icon before the "Shopping Lists" label
    local lhIcon = ns.listsPanel:CreateTexture(nil, "ARTWORK")
    lhIcon:SetSize(14, 14)
    lhIcon:SetPoint("TOPLEFT", L, leftHeaderY + 1)
    lhIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_10_Blue")

    local lh = ns.listsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lh:SetPoint("LEFT", lhIcon, "RIGHT", 4, 0)
    lh:SetText("|cffffd100Shopping Lists|r")

    -- "+ New" button in header (right-aligned) — opens the new-list dialog
    local newListBtn = CreateFrame("Button", nil, ns.listsPanel)
    newListBtn:SetSize(18, 18)
    newListBtn:SetPoint("RIGHT", ns.listsPanel, "TOPLEFT", SPLIT_X - 10, leftHeaderY + 1)
    local newListIcon = newListBtn:CreateTexture(nil, "ARTWORK")
    newListIcon:SetAllPoints()
    newListIcon:SetAtlas("communities-icon-addgroupplus")  -- green "+" atlas icon
    local newListHl = newListBtn:CreateTexture(nil, "HIGHLIGHT")
    newListHl:SetAllPoints()
    newListHl:SetAtlas("communities-icon-addgroupplus")
    newListHl:SetAlpha(0.4)  -- subtle highlight effect on hover
    newListBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Create New List", 1, 1, 1)
        GameTooltip:Show()
    end)
    newListBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    newListBtn:SetScript("OnClick", function()
        ShowNewListDialog()
    end)

    -- Container background — dark bordered box holding the scrollable list rows
    local listBg = CreateFrame("Frame", nil, ns.listsPanel, "BackdropTemplate")
    listBg:SetPoint("TOPLEFT", L - 4, leftHeaderY - 17)
    listBg:SetPoint("BOTTOMLEFT", ns.listsPanel, "BOTTOMLEFT", L - 4, 30)
    listBg:SetWidth(SPLIT_X - L - 2)
    listBg:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    listBg:SetBackdropColor(0.04, 0.04, 0.04, 1)
    listBg:SetBackdropBorderColor(0.16, 0.16, 0.16, 1)

    -- Scroll frame for lists — uses the standard Blizzard scroll template
    local listScroll = CreateFrame("ScrollFrame", "QuickFlipListScroll",
        listBg, "UIPanelScrollFrameTemplate")
    listScroll:SetPoint("TOPLEFT", 2, -2)
    listScroll:SetPoint("BOTTOMRIGHT", -22, 2)  -- -22 leaves room for the scrollbar

    -- Scroll content frame — rows are parented here; height grows with content
    _listsListContent = CreateFrame("Frame", nil, listScroll)
    _listsListContent:SetWidth(listScroll:GetWidth() or (SPLIT_X - L - 48))
    _listsListContent:SetHeight(1)  -- initial height; updated by RefreshListsUI
    listScroll:SetScrollChild(_listsListContent)

    -- "No lists" placeholder — centered text shown when the list database is empty
    _listsEmptyListMsg = listBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _listsEmptyListMsg:SetPoint("CENTER")
    _listsEmptyListMsg:SetText("|cff666666No lists yet\nClick + to create one|r")
    _listsEmptyListMsg:Hide()

    -----------------------------------------------------------------------
    -- RIGHT PANE — Tab buttons: Items | Inventory
    -----------------------------------------------------------------------
    -- Shared backdrop definition for both tab buttons
    local TAB_BD = {
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    }

    -- Items tab button — shows the list of items in the selected shopping list
    _listsItemsTabBtn = CreateFrame("Button", nil, ns.listsPanel, "BackdropTemplate")
    _listsItemsTabBtn:SetSize(90, 22)
    _listsItemsTabBtn:SetPoint("TOPLEFT", ns.listsPanel, "TOPLEFT", SPLIT_X + PAD, leftHeaderY + 1)
    _listsItemsTabBtn:SetBackdrop(TAB_BD)

    -- Scroll icon inside the Items tab button
    local itemsTabIcon = _listsItemsTabBtn:CreateTexture(nil, "ARTWORK")
    itemsTabIcon:SetSize(14, 14)
    itemsTabIcon:SetPoint("LEFT", 6, 0)
    itemsTabIcon:SetTexture("Interface\\Icons\\INV_Scroll_02")

    local itemsTabText = _listsItemsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    itemsTabText:SetPoint("LEFT", itemsTabIcon, "RIGHT", 4, 0)
    itemsTabText:SetText("|cffffd100Items|r")

    -- Clicking the Items tab activates it and refreshes the UI
    _listsItemsTabBtn:SetScript("OnClick", function()
        SetTabActive("items")
        ns.RefreshListsUI()
    end)

    -- Inventory tab button — shows unbound bag items that can be added to the list
    _listsInvTabBtn = CreateFrame("Button", nil, ns.listsPanel, "BackdropTemplate")
    _listsInvTabBtn:SetSize(110, 22)
    _listsInvTabBtn:SetPoint("LEFT", _listsItemsTabBtn, "RIGHT", 4, 0)
    _listsInvTabBtn:SetBackdrop(TAB_BD)

    -- Bag icon inside the Inventory tab button
    local invTabIcon = _listsInvTabBtn:CreateTexture(nil, "ARTWORK")
    invTabIcon:SetSize(14, 14)
    invTabIcon:SetPoint("LEFT", 6, 0)
    invTabIcon:SetTexture("Interface\\Icons\\INV_Misc_Bag_07")

    local invTabText = _listsInvTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    invTabText:SetPoint("LEFT", invTabIcon, "RIGHT", 4, 0)
    invTabText:SetText("|cffffd100Inventory|r")

    -- Clicking the Inventory tab activates it and refreshes the UI
    _listsInvTabBtn:SetScript("OnClick", function()
        SetTabActive("inventory")
        ns.RefreshListsUI()
    end)

    -- Selected list label (to the right of tabs) — shows currently active list name
    _listsSelectedLabel = ns.listsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _listsSelectedLabel:SetPoint("LEFT", _listsInvTabBtn, "RIGHT", 12, 0)
    _listsSelectedLabel:SetText("|cff888888No list selected|r")

    -----------------------------------------------------------------------
    -- RIGHT PANE — Items tab frame (scrollable item list)
    -----------------------------------------------------------------------
    -- Container frame for the Items tab content area
    _listsItemsTabFrame = CreateFrame("Frame", nil, ns.listsPanel)
    _listsItemsTabFrame:SetPoint("TOPLEFT", ns.listsPanel, "TOPLEFT", SPLIT_X + PAD - 4, leftHeaderY - 17)
    _listsItemsTabFrame:SetPoint("BOTTOMRIGHT", ns.listsPanel, "BOTTOMRIGHT", -PAD, 58)

    -- Dark bordered background for the item list area
    local itemBg = CreateFrame("Frame", nil, _listsItemsTabFrame, "BackdropTemplate")
    itemBg:SetAllPoints()
    itemBg:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    itemBg:SetBackdropColor(0.04, 0.04, 0.04, 1)
    itemBg:SetBackdropBorderColor(0.16, 0.16, 0.16, 1)

    -- Scroll frame for item rows
    local itemScroll = CreateFrame("ScrollFrame", "QuickFlipItemScroll",
        itemBg, "UIPanelScrollFrameTemplate")
    itemScroll:SetPoint("TOPLEFT", 2, -2)
    itemScroll:SetPoint("BOTTOMRIGHT", -22, 2)

    -- Scroll content frame — item rows are parented here
    _listsItemContent = CreateFrame("Frame", nil, itemScroll)
    _listsItemContent:SetWidth(itemScroll:GetWidth() or 400)
    _listsItemContent:SetHeight(1)
    itemScroll:SetScrollChild(_listsItemContent)

    -- Empty-item placeholder — centered in the item list area
    _listsEmptyItemMsg = itemBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _listsEmptyItemMsg:SetPoint("CENTER")
    _listsEmptyItemMsg:SetText("|cff666666Select a list from the left panel|r")

    -----------------------------------------------------------------------
    -- RIGHT PANE — Inventory tab frame (bag contents, filtered)
    -----------------------------------------------------------------------
    -- Container frame for the Inventory tab content area (hidden by default)
    _listsInvTabFrame = CreateFrame("Frame", nil, ns.listsPanel)
    _listsInvTabFrame:SetPoint("TOPLEFT", ns.listsPanel, "TOPLEFT", SPLIT_X + PAD - 4, leftHeaderY - 17)
    _listsInvTabFrame:SetPoint("BOTTOMRIGHT", ns.listsPanel, "BOTTOMRIGHT", -PAD, 58)
    _listsInvTabFrame:Hide()  -- Inventory tab starts hidden; Items tab is default

    -- Search box for inventory tab (above the scroll area) — filters bag items by name
    _listsInvSearchBox = CreateFrame("EditBox", "QuickFlipInvSearchBox",
        _listsInvTabFrame, "SearchBoxTemplate")
    _listsInvSearchBox:SetSize(150, 20)
    _listsInvSearchBox:SetPoint("TOPLEFT", _listsInvTabFrame, "TOPLEFT", 4, 0)
    _listsInvSearchBox:SetAutoFocus(false)
    _listsInvSearchBox:SetFrameLevel(_listsInvTabFrame:GetFrameLevel() + 10) -- above backdrop
    -- Real-time filtering: refresh on each keystroke (only for user-initiated changes)
    _listsInvSearchBox:SetScript("OnTextChanged", function(self, userInput)
        SearchBoxTemplate_OnTextChanged(self)
        if userInput then
            _listsInvSearchText = self:GetText() or ""
            ns.RefreshListsUI()
        end
    end)
    _listsInvSearchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Refresh inventory button — re-scans bags and updates the inventory list
    local refreshInvBtn = CreateFrame("Button", nil, _listsInvTabFrame, "UIPanelButtonTemplate")
    refreshInvBtn:SetSize(70, 20)
    refreshInvBtn:SetPoint("TOPRIGHT", _listsInvTabFrame, "TOPRIGHT", -24, 0)
    refreshInvBtn:SetText("Refresh")
    refreshInvBtn:SetFrameLevel(_listsInvTabFrame:GetFrameLevel() + 10)
    refreshInvBtn:SetScript("OnClick", function()
        ns.RefreshListsUI()
    end)

    -- Dark bordered background for the inventory scroll area (below search box)
    local invBg = CreateFrame("Frame", nil, _listsInvTabFrame, "BackdropTemplate")
    invBg:SetPoint("TOPLEFT", _listsInvTabFrame, "TOPLEFT", 0, -24)
    invBg:SetPoint("BOTTOMRIGHT", _listsInvTabFrame, "BOTTOMRIGHT")
    invBg:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    invBg:SetBackdropColor(0.04, 0.04, 0.04, 1)
    invBg:SetBackdropBorderColor(0.16, 0.16, 0.16, 1)

    -- Scroll frame for inventory rows
    local invScroll = CreateFrame("ScrollFrame", "QuickFlipInvScroll",
        invBg, "UIPanelScrollFrameTemplate")
    invScroll:SetPoint("TOPLEFT", 2, -2)
    invScroll:SetPoint("BOTTOMRIGHT", -22, 2)

    -- Scroll content frame — inventory rows are parented here
    _listsInvContent = CreateFrame("Frame", nil, invScroll)
    _listsInvContent:SetWidth(invScroll:GetWidth() or 400)
    _listsInvContent:SetHeight(1)
    invScroll:SetScrollChild(_listsInvContent)

    -- Empty-inventory placeholder
    _listsEmptyInvMsg = invBg:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _listsEmptyInvMsg:SetPoint("CENTER")
    _listsEmptyInvMsg:SetText("|cff666666Select a list first|r")

    -----------------------------------------------------------------------
    -- Items tab bottom bar: [____________] [+ Add]  [Import] [Export]
    -----------------------------------------------------------------------
    -- Add-item text box — type an item name to add to the selected list
    _listsAddBox = CreateFrame("EditBox", "QuickFlipAddItemBox", ns.listsPanel, "InputBoxTemplate")
    _listsAddBox:SetSize(260, 22)
    _listsAddBox:SetPoint("BOTTOMLEFT", ns.listsPanel, "BOTTOMLEFT", SPLIT_X + PAD, 30)
    _listsAddBox:SetAutoFocus(false)
    _listsAddBox:SetMaxLetters(80)
    _listsAddBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- "+ Add" button — validates input, adds item to selected list, clears the box
    local addBtn = CreateFrame("Button", nil, ns.listsPanel, "UIPanelButtonTemplate")
    addBtn:SetSize(48, 22)
    addBtn:SetPoint("LEFT", _listsAddBox, "RIGHT", 4, 0)
    addBtn:SetText("|cff00ff00+ Add|r")
    addBtn:SetScript("OnClick", function()
        if _listsSelectedList == "" then
            ns.Print("|cffff0000Select a list first.|r"); return
        end
        local item = _listsAddBox:GetText():match("^%s*(.-)%s*$") -- trim whitespace
        if not item or item == "" then return end
        if ns.AddItemToList(_listsSelectedList, item) then
            ns.Print("Added: |cff00ff00" .. item .. "|r")
        else
            ns.Print("|cffff0000Already in list or error.|r")
        end
        _listsAddBox:SetText("")  -- clear the input after adding
        ns.RefreshListsUI()
    end)
    -- Pressing Enter in the add-box triggers the add button
    _listsAddBox:SetScript("OnEnterPressed", function() addBtn:Click() end)

    -- Export button — opens an export dialog for the selected list
    local exportBtn = CreateFrame("Button", nil, ns.listsPanel, "UIPanelButtonTemplate")
    exportBtn:SetSize(55, 22)
    exportBtn:SetPoint("BOTTOMRIGHT", ns.listsPanel, "BOTTOMRIGHT", -PAD, 30)
    exportBtn:SetText("Export")
    exportBtn:SetScript("OnClick", function()
        if _listsSelectedList == "" then
            ns.Print("|cffff0000Select a list first.|r"); return
        end
        ShowExportDialog(_listsSelectedList)
    end)

    -- Import button — opens an import dialog for the selected list
    local importBtn = CreateFrame("Button", nil, ns.listsPanel, "UIPanelButtonTemplate")
    importBtn:SetSize(55, 22)
    importBtn:SetPoint("RIGHT", exportBtn, "LEFT", -4, 0)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        if _listsSelectedList == "" then
            ns.Print("|cffff0000Select a list first.|r"); return
        end
        ShowImportDialog(_listsSelectedList)
    end)

    -- Refresh button (icon-only) — re-renders icons and item data
    local refreshBtn = CreateFrame("Button", nil, ns.listsPanel)
    refreshBtn:SetSize(22, 22)
    refreshBtn:SetPoint("RIGHT", importBtn, "LEFT", -4, 0)
    local refreshIcon = refreshBtn:CreateTexture(nil, "ARTWORK")
    refreshIcon:SetSize(16, 16)
    refreshIcon:SetPoint("CENTER")
    refreshIcon:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    local refreshHl = refreshBtn:CreateTexture(nil, "HIGHLIGHT")
    refreshHl:SetSize(16, 16)
    refreshHl:SetPoint("CENTER")
    refreshHl:SetTexture("Interface\\Buttons\\UI-RefreshButton")
    refreshHl:SetAlpha(0.4)
    refreshBtn:SetScript("OnClick", function()
        ns.RefreshListsUI()
    end)
    refreshBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Refresh icons", 1, 1, 1)
        GameTooltip:Show()
    end)
    refreshBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -----------------------------------------------------------------------
    -- STATUS BAR — full width at the very bottom, shows summary stats
    -----------------------------------------------------------------------
    local statusPanel = CreateFrame("Frame", "QuickFlipListsStatusPanel",
        ns.listsPanel, "BackdropTemplate")
    statusPanel:SetHeight(21)
    statusPanel:SetPoint("BOTTOMLEFT", ns.listsPanel, "BOTTOMLEFT", L, 4)
    statusPanel:SetPoint("RIGHT", ns.listsPanel, "RIGHT", -PAD, 0)
    statusPanel:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    statusPanel:SetBackdropColor(0.06, 0.06, 0.06, 1)
    statusPanel:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)
    statusPanel:SetFrameLevel(ns.listsPanel:GetFrameLevel() + 5) -- above other elements

    -- Status text — left-justified summary: list count, item count, usage hint
    _listsStatusText = statusPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _listsStatusText:SetPoint("LEFT", statusPanel, "LEFT", 8, 0)
    _listsStatusText:SetPoint("RIGHT", statusPanel, "RIGHT", -8, 0)
    _listsStatusText:SetJustifyH("LEFT")
    _listsStatusText:SetText("|cff888888List Manager|r")

    -- Initialize tab state — Items tab is active by default
    SetTabActive("items")

    ns.listsPanelBuilt = true  -- prevent future re-builds
    return ns.listsPanel
end
