---------------------------------------------------------------------------
-- ListManager.lua — Built-in shopping list management
---------------------------------------------------------------------------
-- Provides a self-contained list system that stores lists inside
-- QuickFlipDB.lists, removing the need for Auctionator's shopping
-- lists entirely.
--
-- Each list is a simple table of search-term strings keyed by the
-- list name.  The module exposes functions for CRUD operations on
-- lists and their items, plus helpers the Scanner and Seller modules
-- use to retrieve list contents.
--
-- SavedVariables schema addition:
--   QuickFlipDB.lists = {
--       ["My List"]   = { "Rousing Fire", "Awakened Fire", ... },
--       ["Herbs"]     = { "Hochenblume", "Bubble Poppy", ... },
--   }
---------------------------------------------------------------------------

--- `ns` = addon-private namespace table shared across all .lua files.
--- See Core.lua header for full explanation of the namespace pattern.
local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- CacheItemID — store a name→itemID mapping for icon loading
---------------------------------------------------------------------------
-- Allows icons to load for items not currently in bags by persisting the
-- itemID so we can use Item:CreateFromItemID() for async loading.
--
-- @param  name   (string) Item name (will be lowercased for storage)
-- @param  itemID (number) The item's numeric ID
---------------------------------------------------------------------------
function ns.CacheItemID(name, itemID)
    if not name or not itemID or not ns.db then return end
    if not ns.db.itemIDCache then ns.db.itemIDCache = {} end
    ns.db.itemIDCache[name:lower()] = itemID
end

---------------------------------------------------------------------------
-- GetCachedItemID — look up a cached itemID by name
---------------------------------------------------------------------------
-- @param  name (string) Item name (case-insensitive)
-- @return (number|nil) Cached itemID or nil
---------------------------------------------------------------------------
function ns.GetCachedItemID(name)
    if not name or not ns.db or not ns.db.itemIDCache then return nil end
    return ns.db.itemIDCache[name:lower()]
end

---------------------------------------------------------------------------
-- GetListNames — return a sorted array of all list names
---------------------------------------------------------------------------
-- @return (table) Array of list name strings, sorted alphabetically
---------------------------------------------------------------------------
function ns.GetListNames()
    local names = {}
    if ns.db and ns.db.lists then
        for name in pairs(ns.db.lists) do
            table.insert(names, name)
        end
        table.sort(names)
    end
    return names
end

---------------------------------------------------------------------------
-- GetListItems — return the items array for a given list
---------------------------------------------------------------------------
-- @param  listName (string) Name of the list
-- @return (table|nil) Array of search-term strings, or nil if not found
---------------------------------------------------------------------------
function ns.GetListItems(listName)
    if not ns.db or not ns.db.lists then return nil end
    return ns.db.lists[listName]
end

---------------------------------------------------------------------------
-- CreateList — create a new empty list
---------------------------------------------------------------------------
-- @param  name (string) Desired list name
-- @return (boolean) true if created, false if name already exists or invalid
---------------------------------------------------------------------------
function ns.CreateList(name)
    if not name or name == "" then return false end
    if not ns.db or not ns.db.lists then return false end
    if ns.db.lists[name] then return false end  -- already exists
    ns.db.lists[name] = {}
    return true
end

---------------------------------------------------------------------------
-- DeleteList — remove a list entirely
---------------------------------------------------------------------------
-- @param  name (string) List name to delete
-- @return (boolean) true if deleted, false if not found
---------------------------------------------------------------------------
function ns.DeleteList(name)
    if not name or not ns.db or not ns.db.lists then return false end
    if not ns.db.lists[name] then return false end
    ns.db.lists[name] = nil
    -- Remove associated icon
    if ns.db.listIcons then
        ns.db.listIcons[name] = nil
    end
    -- Clear selection if the deleted list was active
    if ns.db.selectedList == name then
        ns.db.selectedList = ""
    end
    if ns.db.sellSelectedList == name then
        ns.db.sellSelectedList = ""
    end
    return true
end

---------------------------------------------------------------------------
-- RenameList — change a list's name
---------------------------------------------------------------------------
-- @param  oldName (string) Current list name
-- @param  newName (string) Desired new name
-- @return (boolean) true if renamed, false on error
---------------------------------------------------------------------------
function ns.RenameList(oldName, newName)
    if not oldName or not newName or newName == "" then return false end
    if not ns.db or not ns.db.lists then return false end
    if not ns.db.lists[oldName] then return false end
    if ns.db.lists[newName] then return false end  -- target name taken
    ns.db.lists[newName] = ns.db.lists[oldName]
    ns.db.lists[oldName] = nil
    -- Carry over icon
    if ns.db.listIcons then
        ns.db.listIcons[newName] = ns.db.listIcons[oldName]
        ns.db.listIcons[oldName] = nil
    end
    -- Update selections to follow the rename
    if ns.db.selectedList == oldName then
        ns.db.selectedList = newName
    end
    if ns.db.sellSelectedList == oldName then
        ns.db.sellSelectedList = newName
    end
    return true
end

---------------------------------------------------------------------------
-- AddItemToList — append a search term to a list (no duplicates)
---------------------------------------------------------------------------
-- @param  listName (string) Target list name
-- @param  item     (string) Search term to add
-- @return (boolean) true if added, false if duplicate or error
---------------------------------------------------------------------------
function ns.AddItemToList(listName, item)
    if not listName or not item or item == "" then return false end
    if not ns.db or not ns.db.lists then return false end
    local list = ns.db.lists[listName]
    if not list then return false end
    -- Check for duplicate (case-insensitive)
    local lower = item:lower()
    for _, existing in ipairs(list) do
        if existing:lower() == lower then return false end
    end
    table.insert(list, item)
    return true
end

---------------------------------------------------------------------------
-- RemoveItemFromList — remove a search term from a list
---------------------------------------------------------------------------
-- @param  listName (string) Target list name
-- @param  item     (string) Search term to remove (case-insensitive match)
-- @return (boolean) true if removed, false if not found
---------------------------------------------------------------------------
function ns.RemoveItemFromList(listName, item)
    if not listName or not item then return false end
    if not ns.db or not ns.db.lists then return false end
    local list = ns.db.lists[listName]
    if not list then return false end
    local lower = item:lower()
    for i, existing in ipairs(list) do
        if existing:lower() == lower then
            table.remove(list, i)
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- GetListCount — return the number of lists
---------------------------------------------------------------------------
-- @return (number) Count of lists
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- SetListIcon — assign a custom icon to a list
---------------------------------------------------------------------------
-- @param  name   (string) List name
-- @param  iconID (number) Icon file ID (from GetMacroIcons etc.)
---------------------------------------------------------------------------
function ns.SetListIcon(name, iconID)
    if not name or not ns.db then return end
    if not ns.db.listIcons then ns.db.listIcons = {} end
    ns.db.listIcons[name] = iconID
end

---------------------------------------------------------------------------
-- GetListIcon — get the custom icon for a list (nil = default)
---------------------------------------------------------------------------
-- @param  name (string) List name
-- @return (number|nil) Icon file ID or nil
---------------------------------------------------------------------------
function ns.GetListIcon(name)
    if not name or not ns.db or not ns.db.listIcons then return nil end
    return ns.db.listIcons[name]
end

---------------------------------------------------------------------------
function ns.GetListCount()
    local count = 0
    if ns.db and ns.db.lists then
        for _ in pairs(ns.db.lists) do
            count = count + 1
        end
    end
    return count
end

---------------------------------------------------------------------------
-- ExportList — serialise a list to a semicolon-delimited string
---------------------------------------------------------------------------
-- Format: "item1;item2;item3"
-- @param  listName (string) List to export
-- @return (string|nil) Serialised string, or nil if list not found
---------------------------------------------------------------------------
function ns.ExportList(listName)
    local list = ns.GetListItems(listName)
    if not list then return nil end
    return table.concat(list, ";")
end

---------------------------------------------------------------------------
-- ImportList — deserialise a semicolon-delimited string into a list
---------------------------------------------------------------------------
-- Creates the list if it doesn't exist; merges items (no duplicates).
-- @param  listName (string) Target list name
-- @param  data     (string) Semicolon-delimited items
-- @return (number) Count of items added
---------------------------------------------------------------------------
function ns.ImportList(listName, data)
    if not listName or not data or data == "" then return 0 end
    if not ns.db or not ns.db.lists then return 0 end
    if not ns.db.lists[listName] then
        ns.db.lists[listName] = {}
    end
    local added = 0
    for item in data:gmatch("[^;]+") do
        item = item:match("^%s*(.-)%s*$")  -- trim whitespace
        if item and item ~= "" then
            if ns.AddItemToList(listName, item) then
                added = added + 1
            end
        end
    end
    return added
end
