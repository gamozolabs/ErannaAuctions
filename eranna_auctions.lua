local GOLD_TEXT = '|cffffd70ag|r'
local SILVER_TEXT = '|cffc7c7cfs|r'
local COPPER_TEXT = '|cffeda55fc|r'

local COPPER_PER_GOLD = 10000
local COPPER_PER_SILVER = 100

function round(x)
	return floor(x + .5)
end

function to_gsc(money)
	local gold = floor(money / COPPER_PER_GOLD)
	local silver = floor(mod(money, COPPER_PER_GOLD) / COPPER_PER_SILVER)
	local copper = mod(money, COPPER_PER_SILVER)
	return gold, silver, copper
end

function money_to_string(money)
	color = FONT_COLOR_CODE_CLOSE

	local TEXT_NONE = '0'

	local GOLD = 'ffd100'
	local SILVER = 'e6e6e6'
	local COPPER = 'c8602c'
	local START = '|cff%s%d' .. FONT_COLOR_CODE_CLOSE
	local PART = color .. '.|cff%s%02d' .. FONT_COLOR_CODE_CLOSE
	local NONE = '|cffa0a0a0' .. TEXT_NONE .. FONT_COLOR_CODE_CLOSE

	local g, s, c = to_gsc(money)

	local str = ''

	local fmt = START
	if g > 0 then
		str = str .. format(fmt, GOLD, g)
		fmt = PART
	end
	if s > 0 or c > 0 then
		str = str .. format(fmt, SILVER, s)
		fmt = PART
	end
	if c > 0 then
		str = str .. format(fmt, COPPER, c)
	end
	if str == '' then
		str = NONE
	end
	return str
end

local ITEM_ID_SCAN_START = 1
local ITEM_ID_SCAN_END   = 100000

-- Create a new frame
local frame = CreateFrame("FRAME")

-- Register events we want to track in the frame
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")

-- Track whether or not the auction house is currently open
local auction_house_open = false

-- Number of timer events which have occurred
local frames = 0

-- If auto market scanning is enabled
local autoscan = false

-- On frame events we will check this to get the page identifier of a scan to
-- start. If this is `nil` then we will not start a scan
local start_scan = nil

-- Current item scan ID
local item_scan_id = nil

-- Scan state.
-- nil means no scan in progress
-- 1 means that a scan was dispatched
-- 2 means we're processing a scan result
local scan_state = nil

-- Time the last scan occurred
local last_scan_time = nil

-- Auction house snapshot
local last_ah_snapshot = {}

-- Temporary AH snapshot
local ah_snapshot = {}

-- Query index
local ah_query_index = nil

-- Time when the item tooltip scan started
local item_tooltip_start = nil

-- Number of frames since the tooltip was no longer observed as retrieving
local item_tooltip_frames_since_complete = nil

-- Current item being scanned
local item_scan = nil

-- Event handler for `OnUpdate` events
function frame:OnUpdate(event, arg1)
	-- Track number of frames which have been rendered
	frames = frames + 1

    if item_scan then
        local tooltip = {}
        for ii = 1, EAUCMyScanningTooltip:NumLines() do
            local mytext = _G["EAUCMyScanningTooltipTextLeft" .. ii]
            local text   = mytext:GetText()
            table.insert(tooltip, text)
        end

        if item_tooltip_frames_since_complete == nil and tooltip[1] ~= "Retrieving item information" then
            item_tooltip_frames_since_complete = 0
        end
        
        if item_tooltip_frames_since_complete == 1 then
            ItemTooltips["item_" .. item_scan[1] .. "_enchant_" .. item_scan[2]] = tooltip
            ItemScanLast = ItemScanLast + 1
            next_tooltip_scan()
        end

        if item_tooltip_frames_since_complete then
            item_tooltip_frames_since_complete = item_tooltip_frames_since_complete + 1
        end

        if item_tooltip_start and (GetTime() - item_tooltip_start) > 0.25 then
            print("Tooltip timeout")
            table.foreach(item_scan, print)
            ItemScanLast = ItemScanLast + 1
            next_tooltip_scan()
        end
    end

	-- Auction house auto scanning
	if autoscan and auction_house_open then
		-- If we're not doing any active scan
		if scan_state == nil then
			-- Check if we can do a scanall
			local canQuery, canQueryAll = CanSendAuctionQuery()

			if canQuery then
				print("Starting getAll scan @ " .. time())

				ah_snapshot = {}
				ah_query_index = 1

				-- Set that we performed a query
				scan_state = 1
				last_scan_time = time()

				-- Alert the player that they're AFK
				if UnitIsAFK("player") then
					print("WARNING: Character is AFK!!!")
					PlaySound(1026, "Master")
				end

				-- Perform an all query with no filtering
				QueryAuctionItems("", nil, nil, 0, false, 0, true, false, nil)
				--QueryAuctionItems("Linen Cloth", nil, nil, 0, false, 0, false, false, nil)
			end
		end

		if scan_state == 2 then
			-- Get information about the auction listings
			local batch_count, total_count = GetNumAuctionItems("list")

			-- Save the scan start value
			local initial_id = ah_query_index
			
            -- Issue queries for all auctions to get caches loaded ASAP
            local tmp = ah_query_index;
			while true do
				-- Only query 1000 at a time
				if (tmp - initial_id) >= 1000 or tmp > batch_count then
					break
				end

                GetAuctionItemInfo("list", tmp);
                GetAuctionItemLink("list", tmp);
                GetAuctionItemTimeLeft("list", tmp);
                tmp = tmp + 1
            end

			-- Scan all auctions in the listing
			while true do
				-- Only query 1000 at a time
				if (ah_query_index - initial_id) >= 1000 or ah_query_index > batch_count then
					break
				end

				-- Query the auction listing information for our own auctions
				local name, texture, count, quality, canUse, level,
					levelColHeader, minBid, minIncrement, buyoutPrice,
					bidAmount, highBidder, highBidderFullName, owner,
					ownerFullName, saleStatus, itemId, hasAllInfo =
						GetAuctionItemInfo("list", ah_query_index);

                -- Query the item link
                local link = GetAuctionItemLink("list", ah_query_index);
                if link == nil or owner == nil then
                    return
                end

				-- Get the time left for an auction
				local time_left = GetAuctionItemTimeLeft("list", ah_query_index)

				-- Check that everything looks good
				if type(itemId) ~= "number" or type(count) ~= "number" or
						type(minBid) ~= "number" or
						type(bidAmount) ~= "number" or
						type(buyoutPrice) ~= "number" or
						type(time_left) ~= "number" or
                        link == nil or
                        owner == nil or
						count <= 0 or itemId <= 0 then
					print("Whoa, bad data")
					scan_state = nil
					return
				end

				-- Generate a unique key for this auction house entry
				local keyboi = table.concat({
					link, count, minBid, bidAmount, buyoutPrice, time_left, owner
				}, "^")

				local old_count = ah_snapshot[keyboi]
				if old_count ~= nil then
					-- AH snapshot already has this key, increment the count
					ah_snapshot[keyboi] = old_count + 1
				else
					-- Start a new count at 1
					ah_snapshot[keyboi] = 1
				end

				ah_query_index = ah_query_index + 1
			end

			if ah_query_index <= batch_count then
				return
			end

			-- Make sure `last_ah_snapshot` has keys for all values in `ah_snapshot`
			for item_key, count in pairs(ah_snapshot) do
				if last_ah_snapshot[item_key] == nil then
					last_ah_snapshot[item_key] = 0
				end
			end

			-- Make sure `ah_snapshot` has keys for all values in `last_ah_snapshot`
			for item_key, count in pairs(last_ah_snapshot) do
				if ah_snapshot[item_key] == nil then
					ah_snapshot[item_key] = 0
				end
			end

			-- Track all the deltas
			local deltas = {}

			-- Search for changes from the last snapshot
			for item_key, count in pairs(ah_snapshot) do
				-- Compute the delta from the last snapshot state
				local diff = count - last_ah_snapshot[item_key]
				if diff ~= 0 then
					print("Delta of " .. diff .. " auction " .. item_key)

					local deltakey = table.concat({ diff, item_key }, ",")
					table.insert(deltas, deltakey)
				end
			end

			-- Add a new diff listing to the auction data
			table.insert(AuctionData, "AHSCANDIFF!" .. last_scan_time .. "!" .. table.concat(deltas, "~"))

			print("Snapshot of " .. batch_count .. " auctions complete at " .. time() .. "... diffing data")

			-- Save off the auction house snapshot
			last_ah_snapshot = ah_snapshot

			-- Scan done, delete the scan state
			scan_state = nil
		end
	end
end

-- Scan items forever until we run into one which requires a server query
function scan_items_until_non_cached()
	-- Get all item info
	while item_scan_id < ITEM_ID_SCAN_END do
        if ea_item_enchant_database["" .. item_scan_id] == nil then
            item_scan_id = item_scan_id + 1
        else 
            -- Get the item info
            local itemName, itemLink, itemRarity, itemLevel, itemMinLevel, itemType,
                itemSubType, itemStackCount, itemEquipLoc, itemIcon,
                itemSellPrice, itemClassID, itemSubClassID, bindType, expacID,
                itemSetID, isCraftingReagent = GetItemInfo(item_scan_id)

            local iidstr = "" .. item_scan_id

            if itemName == nil then
                -- Result was invalid, we must wait for a response from the server
                ItemCache[iidstr] = {}
                break
            else

                for ii = 1, 100 do
                    local enchant_table = ea_item_enchant_database[iidstr]
                    for _, enchant in pairs(enchant_table) do
                        EAUCMyScanningTooltip:SetOwner(UIParent, "ANCHOR_NONE")
                        EAUCMyScanningTooltip:ClearLines()
                        EAUCMyScanningTooltip:SetHyperlink("item:" .. iidstr .. ":0:0:0:0:0:" .. enchant .. ":0")
                        local tooltip = {}
                        for ii = 1, EAUCMyScanningTooltip:NumLines() do
                            local mytext = _G["EAUCMyScanningTooltipTextLeft" .. ii]
                            local text   = mytext:GetText()
                            table.insert(tooltip, text)
                        end
                        ItemTooltips["item_" .. iidstr .. "_enchant_" .. enchant] = tooltip
                    end
                end

                -- Got a valid entry!
                ItemCache[iidstr] = table.concat({
                    tostring(itemName),
                    tostring(itemLink),
                    tostring(itemRarity),
                    tostring(itemLevel),
                    tostring(itemMinLevel),
                    tostring(itemType),
                    tostring(itemSubType),
                    tostring(itemStackCount),
                    tostring(itemEquipLoc),
                    tostring(itemIcon),
                    tostring(itemSellPrice),
                    tostring(itemClassID),
                    tostring(itemSubClassID),
                    tostring(bindType),
                    tostring(expacID),
                    tostring(itemSetID),
                    tostring(isCraftingReagent)
                }, "~~ESEP~~")

                print("Logged " .. iidstr)

                ItemScanLast = item_scan_id + 1

                -- Item probe was success, go to the next item!
                item_scan_id = item_scan_id + 1
            end
        end
	end

    if item_scan_id == ITEM_ID_SCAN_END then
        -- Save the item cache out to the SavedVariable
        print("Item scan complete")
        print("Items + random enchants " .. tablelength(ItemTooltips))
    end
end

-- Event handler for `OnEvent` events
function frame:OnEvent(event, arg1, arg2)
	-- `event` contains the string registered with `RegisterEvent`, such as
	-- "AUCTION_HOUSE_SHOW"
	if event == "GET_ITEM_INFO_RECEIVED" then
		local item_id = arg1
		local success = arg2

		if item_scan_id ~= nil and item_id == item_scan_id then
			-- Item was unqueryable or something failed, skip this item
			if success == nil or success == false then
				print("Invalid item " .. item_id)
				item_scan_id = item_scan_id + 1
			end

			-- Scan items until we run into one which requires a response from
			-- the server
			scan_items_until_non_cached()
		end
	end

	if event == "AUCTION_HOUSE_SHOW" then
		-- Track state of the AH window
		auction_house_open = true
	end
	
	if event == "AUCTION_HOUSE_CLOSED" then
		-- Track state of the AH window
		auction_house_open = false
	end

	if event == "AUCTION_ITEM_LIST_UPDATE" and scan_state == 1 then
		-- Processing a list update
		scan_state = 2
	end
end

-- Register the OnEvent function as the event handler for `frame`
frame:SetScript("OnEvent", frame.OnEvent)
frame:SetScript("OnUpdate", frame.OnUpdate)

SLASH_EA1 = "/ea"
SLASH_EASCAN1 = "/eascan"
SLASH_EAITEMS1 = "/eaitems"
SLASH_EACLEAR1 = "/eaclear"
SLASH_EASKILL1 = "/easkill"
SLASH_EASKILLSAVE1 = "/easkillsave"
SLASH_EASKILLCLEAR1 = "/easkillclear"
SLASH_EASAVE1 = "/easave"
SLASH_EATEST1 = "/eatest"
SLASH_EAITEMSRESET1 = "/eaitemsreset"

SlashCmdList["EATEST"] = function(msg)
    next_tooltip_scan()
end

function next_tooltip_scan()
    item_scan = ItemScan[ItemScanLast]
    if item_scan == nil then
        print("Scan complete")
        return
    end

    print(ItemScanLast)

    -- Perform a tooltip request
    EAUCMyScanningTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    EAUCMyScanningTooltip:ClearLines()
    EAUCMyScanningTooltip:SetHyperlink("item:" .. item_scan[1] .. ":0:0:0:0:0:" .. item_scan[2] .. ":0")

    -- Log when we started the request
    item_tooltip_start = GetTime()
    item_tooltip_frames_since_complete = nil
end

SlashCmdList["EA"] = function(msg)
	local num_items    = 0
	local num_auctions = 0
	local item_value   = 0

	for ii = 1, 1000000 do
		local name, texture, count, quality, canUse, level,
			levelColHeader, minBid, minIncrement, buyoutPrice,
			bidAmount, highBidder, highBidderFullName, owner,
			ownerFullName, saleStatus, itemId, hasAllInfo =
				GetAuctionItemInfo("owner", ii);
		if name == nil then
			break
		end

		num_auctions = num_auctions + 1
		num_items    = num_items + count
		item_value   = item_value + buyoutPrice
	end

	DEFAULT_CHAT_FRAME:AddMessage("Eranna Auctions: You have " ..
		num_auctions .. " auctions, totalling " .. num_items .. " items.")
	DEFAULT_CHAT_FRAME:AddMessage("Eranna Auctions: This totals " ..
		money_to_string(item_value) .. "!")
end 

-- Cache all the item information in the game
SlashCmdList["EAITEMSRESET"] = function(msg)
	-- Delete the old SavedVariables entirely
	ItemCache = {}
    ItemTooltips = {}
    ItemScan = {}
    ItemScanLast = 1

    for item_id, enchants in pairs(ea_item_enchant_database) do
        for _, enchant in pairs(enchants) do
            table.insert(ItemScan, { item_id, enchant })
        end
    end

    print("Reset item scan " .. tablelength(ItemScan))
end

-- Cache all the item information in the game
SlashCmdList["EAITEMS"] = function(msg)
	-- Set the current item scan ID
	item_scan_id = ItemScanLast

	print("Starting item cache query from " .. item_scan_id)

	-- Scan items until we run into one which requires a response from the
	-- server
	scan_items_until_non_cached()
end

function tablelength(T)
	local count = 0
	for _ in pairs(T) do count = count + 1 end
	return count
end

SlashCmdList["EASKILL"] = function(msg)
	if Craftables == nil then
		Craftables = {}
	end

	local new_skills = 0

	-- Go through each skill in the window
	for skill_id = 1, GetNumTradeSkills() do
		-- Get some info about it
		name, type, _, _, _, _ = GetTradeSkillInfo(skill_id)

		-- Check if it's an actual craftable
		if name and type ~= "header" and type ~= "subheader" then
			-- Get the item link and number of items made
			local crafted_item = GetTradeSkillItemLink(skill_id)
			local min_made, max_made = GetTradeSkillNumMade(skill_id)

			-- Create a local to track the reagents
			local reagents = {}

			-- Query reagent information (number and link)
			for reagent_id = 1, GetTradeSkillNumReagents(skill_id) do
				local reagentName, reagentTexture,
					reagentCount, playerReagentCount =
					GetTradeSkillReagentInfo(skill_id, reagent_id)
				local reagentLink =
					GetTradeSkillReagentItemLink(skill_id, reagent_id)

				reagents[reagent_id] = table.concat({
					tostring(reagentLink),
					tostring(reagentCount),
				}, "~~ESEP~~")
			end

			new_skills = new_skills + 1
			table.insert(Craftables, table.concat({
				tostring(crafted_item),
				tostring(min_made),
				tostring(max_made),
				table.concat(reagents, "~~RSEP~~"),
			}, "~~ISEP~~"))
		end
	end

	--print("Scanned " .. new_skills .. " new skills (" .. tablelength(Craftables) .. " total)")
end

SlashCmdList["EASKILLSAVE"] = function(msg)
	print("Scanned " .. tablelength(Craftables) .. " skills")

	Craftables = "CRAFTABLESSTART" ..
		table.concat(Craftables, "~~CRSEP~~") .. "CRAFTABLESEND"	
end

SlashCmdList["EASKILLCLEAR"] = function(msg)
	-- Delete the old SavedVariable entirely
	Craftables = {}

	print("Cleared skills database")
end

SlashCmdList["EASCAN"] = function(msg)
	-- Toggle autoscanning
	if autoscan == false then
		-- Enable autoscanning
		clear_ah_data()
		autoscan = true
	else
		autoscan = false
	end

	-- Print current autoscan state
	print("Eranna Auctions: Autoscanning " .. tostring(autoscan))
end

SlashCmdList["EACLEAR"] = function(msg)
    ItemCache = nil
    Craftables = nil
    ItemTooltips = nil
    ItemScan = nil
    ItemScanLast = nil
	clear_ah_data()
end

function clear_ah_data()
	-- Delete the old SavedVariable entirely
	AuctionData = {}

	-- Print that we were able to successfully delete the saved variables
	DEFAULT_CHAT_FRAME:AddMessage("Eranna Auctions: AuctionData deleted!")
end
