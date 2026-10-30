if not C_EquipmentSet then
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_LOGIN")
  f:SetScript("OnEvent", function()
	DEFAULT_CHAT_FRAME:AddMessage(
	  "|cffff2020Equipment Manager:|r ClassicAPI is not installed. "
	  .. "The addon will not function without it. Please install ClassicAPI and restart the game.")
  end)
  return
end

if not C_EquipmentSet.CanUseEquipmentSets then return end

local addonName = "EquipmentManager"
local addonpath = "Interface\\AddOns\\" .. addonName
local imgpath   = addonpath .. "\\assets\\"

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function()
  if event ~= "PLAYER_LOGIN" then return end
  if not C_EquipmentSet.CanUseEquipmentSets() then return end

  local DIALOG_BACKDROP = {
	bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
	edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
	tile = true, tileSize = 32, edgeSize = 32,
	insets = { left = 11, right = 12, top = 12, bottom = 11 },
  }
  -- Inset panel
  local INSET_BACKDROP = {
	bgFile   = "Interface\\FrameGeneral\\UI-Background-Rock",
	edgeFile = "Interface\\FrameGeneral\\UI-Background-Rock",
	tile = true, tileSize = 64, edgeSize = 1,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
  }

  local function ApplyDialogBackdrop(frame)
	frame:SetBackdrop(DIALOG_BACKDROP)
  end

  local function ApplyInsetBackdrop(frame)
	frame:SetBackdrop(INSET_BACKDROP)
  end

  -- Location-bitfield helpers
  local LOC_PLAYER = 1048576
  local LOC_BAGS   = 2097152
  local LOC_BANK   = 4194304

  local function UnpackLocation(location)
	local r    = {}
	r.isPlayer = (math.mod(math.floor(location / LOC_PLAYER), 2) == 1)
	r.isBags   = (math.mod(math.floor(location / LOC_BAGS),   2) == 1)
	r.isBank   = (math.mod(math.floor(location / LOC_BANK),   2) == 1)
	r.slot	   = math.mod(location, 256)
	r.bag	   = math.mod(math.floor(location / 256), 256)
	if r.isBank and r.isBags then
	  r.bag = r.bag + 4
	end
	return r
  end

  EquipmentManagerDB = EquipmentManagerDB or {}
  local db = EquipmentManagerDB
  db.triggers = db.triggers or {}
  db.nextID	  = db.nextID or 1
  db.bank	  = db.bank or {}
  db.config	  = db.config or {}
  if db.config.autoswitch == nil then db.config.autoswitch = true end
  if db.config.announce == nil then db.config.announce = true end
  if db.config.unusedquality == nil then db.config.unusedquality = 0 end
  if db.config.unusedbank == nil then db.config.unusedbank = true end
  if not db.ignore then
	-- Ignored items; can be unignored.
	db.ignore = {
	  [2901]  = true,  -- Mining Pick
	  [5956]  = true,  -- Blacksmith Hammer
	  [6219]  = true,  -- Arclight Spanner
	  [7005]  = true,  -- Skinning Knife
	  [7297]  = true,  -- Morbent's Bane
	  [10696] = true,  -- Enchanted Azsharite Felbane Sword
	  [10697] = true,  -- Enchanted Azsharite Felbane Dagger
	  [10698] = true,  -- Enchanted Azsharite Felbane Staff
	  [20406] = true,  -- Twilight Cultist Mantle
	  [20407] = true,  -- Twilight Cultist Robe
	  [20408] = true,  -- Twilight Cultist Cowl
	}
  end

  local RESTORE_SET_NAME = "EM Auto-Restore"

  local function IsRestoreSet(setID)
	return setID and C_EquipmentSet.GetEquipmentSetInfo(setID) == RESTORE_SET_NAME
  end

  local function GetVisibleSetIDs()
	local result = {}
	for _, id in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
	  if not IsRestoreSet(id) then table.insert(result, id) end
	end
	return result
  end

  local function PlayerEquipLocation(invSlot)
	return LOC_PLAYER + invSlot
  end

  local WEAPON_SLOTS = { [16] = true, [17] = true, [18] = true }

  -- State - reset on every login so character switching works correctly.
  local SET_ROW_HEIGHT	  = 34
  local LIST_VISIBLE_ROWS = 8
  local LIST_ROW_STRIDE   = SET_ROW_HEIGHT + 1

  local selectedSetID			= nil
  local pendingAction			= nil
  local slotOverlays			= {}
  local slotHighlights			= {}
  local popoutButtons			= {}
  local pendingIgnoredToggles	= {}

  local setRows = {}

  local loginReset = CreateFrame("Frame")
  loginReset:RegisterEvent("PLAYER_ENTERING_WORLD")
  loginReset:SetScript("OnEvent", function()
	if not frame or not flyout or not namePopup or not listFrame then return end
	local newName = UnitName("player")
	if loginReset.charName == newName then return end
	loginReset.charName = newName
	selectedSetID		  = nil
	pendingIgnoredToggles = {}
	for _, row in ipairs(setRows) do
	  row:Hide()
	  row.setID = nil
	end
	listFrame.offset = 0
	flyout:Hide()
	namePopup:Hide()
	frame:Hide()
  end)

  local function GetEffectiveIgnored(setID)
	local result = {}
	if not setID then return result end
	local persistent = C_EquipmentSet.GetIgnoredSlots(setID) or {}
	for _, s in ipairs(persistent) do result[s] = true end
	local pending = pendingIgnoredToggles[setID]
	if pending then
	  for slotID in pairs(pending) do
		if result[slotID] then result[slotID] = nil else result[slotID] = true end
	  end
	end
	return result
  end

  local function ToggleIgnoredForSet(setID, slotID)
	if not setID then return end
	pendingIgnoredToggles[setID] = pendingIgnoredToggles[setID] or {}
	if pendingIgnoredToggles[setID][slotID] then
	  pendingIgnoredToggles[setID][slotID] = nil
	else
	  pendingIgnoredToggles[setID][slotID] = true
	end
  end

  local function EquipSet(setID)
	if not setID then return end
	if C_EquipmentSet.EquipmentSetContainsLockedItems(setID) then
	  UIErrorsFrame:AddMessage(ERR_CLIENT_LOCKED_OUT or "You are locked out", 1, .1, .1, 1)
	  return
	end
	PlaySound("INTERFACESOUND_CHARWINDOWTAB")
	ClearCursor()
	C_EquipmentSet.UseEquipmentSet(setID)
  end

  -- Icon picker data
  local QUESTION_MARK	 = "INTERFACE\\ICONS\\INV_MISC_QUESTIONMARK"
  local selectedIconPath = QUESTION_MARK
  local iconFilterMode   = "all"

  local spellIconList = nil
  local itemIconList  = nil
  local iconList	  = nil

  local function BuildRawIconLists()
	if spellIconList then return end
	spellIconList = {}
	itemIconList  = {}
	local spells, items = {}, {}
	if GetLooseMacroIcons	  then GetLooseMacroIcons(spells)	 end
	if GetLooseMacroItemIcons then GetLooseMacroItemIcons(items) end
	if GetMacroIcons		  then GetMacroIcons(spells)		 end
	if GetMacroItemIcons	  then GetMacroItemIcons(items)		 end
	local seen = {}
	for _, name in ipairs(spells) do
	  local u = strupper(name)
	  if not seen[u] then seen[u] = true
		spellIconList[table.getn(spellIconList) + 1] = "INTERFACE\\ICONS\\" .. u
	  end
	end
	for _, name in ipairs(items) do
	  local u = strupper(name)
	  if not seen[u] then seen[u] = true
		itemIconList[table.getn(itemIconList) + 1] = "INTERFACE\\ICONS\\" .. u
	  end
	end
  end

  local function BuildBagIconList()
	local bagIcons = {}
	local seen = {}
	-- Equipped gear
	for slot = 1, 19 do
	  local itemID = GetInventoryItemID("player", slot)
	  if itemID then
		local _, _, _, equipLoc, tex = C_Item.GetItemInfoInstant(itemID)
		if equipLoc and equipLoc ~= "" and tex then
		  local u = strupper(tex)
		  u = string.gsub(u, ".*\\", "")
		  local full = "INTERFACE\\ICONS\\" .. u
		  if not seen[full] then
			seen[full] = true
			bagIcons[table.getn(bagIcons) + 1] = full
		  end
		end
	  end
	end
	-- Bag gear
	for bag = 0, NUM_BAG_SLOTS do
	  for slot = 1, GetContainerNumSlots(bag) do
		local tex = GetContainerItemInfo(bag, slot)
		if tex then
		  local link = GetContainerItemLink(bag, slot)
		  if link and C_Item.IsEquippableItem(link) then
			local u = strupper(tex)
			u = string.gsub(u, ".*\\", "")
			local full = "INTERFACE\\ICONS\\" .. u
			if not seen[full] then
			  seen[full] = true
			  bagIcons[table.getn(bagIcons) + 1] = full
			end
		  end
		end
	  end
	end
	return bagIcons
  end

  local iconSearchText   = ""

  local function BuildIconList()
	BuildRawIconLists()
	if iconList then return end
	local base = {}
	-- Always first: the question mark placeholder
	base[1] = QUESTION_MARK
	-- Second: unique icons from items currently in bags (only for item/all filter)
	local bagSeen = { [QUESTION_MARK] = true }
	if iconFilterMode ~= "spells" then
	  local bagIcons = BuildBagIconList()
	  for _, v in ipairs(bagIcons) do
		if not bagSeen[v] then
		  bagSeen[v] = true
		  base[table.getn(base) + 1] = v
		end
	  end
	end
	-- Then the regular spell/item lists per filter
	local pool
	if iconFilterMode == "spells" then
	  pool = spellIconList
	elseif iconFilterMode == "items" then
	  pool = itemIconList
	else
	  pool = {}
	  for _, v in ipairs(spellIconList) do pool[table.getn(pool) + 1] = v end
	  for _, v in ipairs(itemIconList)  do pool[table.getn(pool) + 1] = v end
	end
	for _, v in ipairs(pool) do
	  if not bagSeen[v] then base[table.getn(base) + 1] = v end
	end
	local search = iconSearchText and strupper(iconSearchText) or ""
	if search == "" then
	  iconList = base
	else
	  iconList = {}
	  for _, v in ipairs(base) do
		if strfind(strupper(v), search) then
		  iconList[table.getn(iconList) + 1] = v
		end
	  end
	end
  end

  local function GetNumIcons()	   BuildIconList(); return table.getn(iconList) end
  local function GetIconByIndex(i) return iconList and iconList[i] end

  -- Map from inventory slot ID to the paperdoll empty-slot texture for that slot.
  -- Populated lazily on first ShowFlyout call, after the player has logged in.
  local EMPTY_SLOT_TEXTURES = nil
  local function GetEmptySlotTexture(invSlotID)
	if not EMPTY_SLOT_TEXTURES then
	  EMPTY_SLOT_TEXTURES = {}
	  local slotNames = {
		"HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
		"ShirtSlot", "TabardSlot", "WristSlot", "HandsSlot", "WaistSlot",
		"LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
		"Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot",
		"RangedSlot",
	  }
	  for _, name in ipairs(slotNames) do
		local id, tex = GetInventorySlotInfo(name)
		if id and tex then
		  EMPTY_SLOT_TEXTURES[id] = tex
		end
	  end
	end
	return EMPTY_SLOT_TEXTURES[invSlotID]
  end
  local OpenNamePopup
  local eqmgr = {}

  -- Main sidecar frame
  local frame = CreateFrame("Frame", "STEquipmentManagerFrame", UIParent)
  frame:SetWidth(232)
  frame:SetHeight(380)
  frame:SetFrameStrata("HIGH")
  ApplyDialogBackdrop(frame)
  frame:Hide()

  frame:SetScript("OnShow", function()
	this:ClearAllPoints()
	this:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", -33, -12)
	for _, b in ipairs(popoutButtons) do b:Show() end
	-- Delay by one frame to give ClassicAPI time to finish loading the
	-- per-character ClassicAPI_EquipmentSets.txt file before we query it.
	-- Without this delay, GetEquipmentSetIDs() may return the previous
	-- character's cached data on the first call after a character switch.
	C_Timer.After(0, function() eqmgr.Refresh() end)
  end)

  frame.titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.titleText:SetPoint("TOP", frame, "TOP", 0, -14)
  frame.titleText:SetText(EQUIPMENT_MANAGER)

  local closeBtn = CreateFrame("Button", "STEqMgrClose", frame, "UIPanelCloseButton")
  closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 4, 4)
  closeBtn:SetScript("OnClick", function()
	PlaySound("INTERFACESOUND_BACKPACKCLOSE")
	frame:Hide()
  end)

  -- Toggle button on the paperdoll
  local toggleBtn = CreateFrame("Button", "STEqMgrToggleButton", PaperDollFrame)
  toggleBtn:SetWidth(28)
  toggleBtn:SetHeight(28)
  toggleBtn:SetPoint("BOTTOM", CharacterHandsSlot, "TOP", 0, 4)
  toggleBtn:SetNormalTexture(imgpath .. "UI-GearManager-Button")
  toggleBtn:SetPushedTexture(imgpath .. "UI-GearManager-Button-Pushed")
  toggleBtn:SetHighlightTexture("Interface\\Buttons\\UI-MicroButton-Hilight", "ADD")
  toggleBtn:GetHighlightTexture():SetTexCoord(0, 1, 0.390625, 0.96875)
  toggleBtn:SetScript("OnEnter", function()
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	GameTooltip:SetText(EQUIPMENT_MANAGER, 1, 1, 1)
	GameTooltip:Show()
  end)
  toggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  toggleBtn:SetScript("OnClick", function()
	if frame:IsShown() then
	  PlaySound("INTERFACESOUND_BACKPACKOPEN")
	  frame:Hide()
	else
	  PlaySound("INTERFACESOUND_BACKPACKCLOSE")
	  frame:Show()
	end
  end)

  -- New Set, Equip, Save buttons
  local btnNewSet = CreateFrame("Button", "STEqMgrNewSet", frame, "UIPanelButtonTemplate")
  btnNewSet:SetWidth(68); btnNewSet:SetHeight(22)
  btnNewSet:SetText(PAPERDOLL_NEWEQUIPMENTSET)
  btnNewSet:SetPoint("CENTER", frame, "TOP", -68, -40)

  local btnEquip = CreateFrame("Button", "STEqMgrEquip", frame, "UIPanelButtonTemplate")
  btnEquip:SetWidth(68); btnEquip:SetHeight(22)
  btnEquip:SetText(EQUIPSET_EQUIP)
  btnEquip:SetPoint("CENTER", frame, "TOP", 0, -40)
  btnEquip:SetScript("OnClick", function() EquipSet(selectedSetID) end)

  local btnSave = CreateFrame("Button", "STEqMgrSave", frame, "UIPanelButtonTemplate")
  btnSave:SetWidth(68); btnSave:SetHeight(22)
  btnSave:SetText(SAVE)
  btnSave:SetPoint("CENTER", frame, "TOP", 68, -40)
  btnSave:SetScript("OnClick", function()
	if not selectedSetID then return end
	local name, icon = C_EquipmentSet.GetEquipmentSetInfo(selectedSetID)
	if not name then return end
	local targetID = selectedSetID
	StaticPopupDialogs["STEQMGR_SAVE_CONFIRM"] = {
	  text = string.format(CONFIRM_SAVE_EQUIPMENT_SET, name),
	  button1 = YES, button2 = NO,
	  OnAccept = function()
		C_EquipmentSet.ClearIgnoredSlotsForSave()
		local effective = GetEffectiveIgnored(targetID)
		for slotID in pairs(effective) do C_EquipmentSet.IgnoreSlotForSave(slotID) end
		C_EquipmentSet.SaveEquipmentSet(targetID, icon)
		C_EquipmentSet.ClearIgnoredSlotsForSave()
		pendingIgnoredToggles[targetID] = nil
		eqmgr.Refresh()
	  end,
	  timeout = 0, whileDead = 1, hideOnEscape = 1, exclusive = 1,
	}
	StaticPopup_Show("STEQMGR_SAVE_CONFIRM")
  end)

  -- Set list
  local listFrame = CreateFrame("Frame", nil, frame)
  listFrame:SetPoint("TOPLEFT",		frame, "TOPLEFT",	  14, -52)
  listFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 44)
  ApplyInsetBackdrop(listFrame)

  listFrame.offset = 0
  listFrame:EnableMouseWheel(true)
  listFrame:SetScript("OnMouseWheel", function()
	listFrame.offset = listFrame.offset - (arg1 or 0)
	eqmgr.Refresh()
  end)

  local rowMenu = CreateFrame("Frame", "STEqMgrRowMenu", UIParent)
  rowMenu:SetFrameStrata("DIALOG")
  rowMenu:SetWidth(155); rowMenu:SetHeight(70)
  rowMenu:Hide()
  ApplyDialogBackdrop(rowMenu)
  rowMenu:EnableMouse(true)
  rowMenu:RegisterEvent("GLOBAL_MOUSE_DOWN")
  rowMenu:SetScript("OnEvent", function()
	if not this:IsShown() then return end
	if MouseIsOver(this) then return end
	if this.anchorBtn and MouseIsOver(this.anchorBtn) then return end
	PlaySound("igMainMenuOptionFaerTab")
	this:Hide()
  end)
  tinsert(UISpecialFrames, "STEqMgrRowMenu")

  rowMenu.changeBtn = CreateFrame("Button", nil, rowMenu, "UIPanelButtonTemplate")
  rowMenu.changeBtn:SetWidth(136); rowMenu.changeBtn:SetHeight(22)
  rowMenu.changeBtn:SetPoint("TOP", rowMenu, "TOP", 0, -12)
  rowMenu.changeBtn:SetText(EQUIPMENT_SET_EDIT)
  rowMenu.changeBtn:SetScript("OnClick", function()
	rowMenu:Hide()
	if not rowMenu.targetSetID then return end
	local name, icon = C_EquipmentSet.GetEquipmentSetInfo(rowMenu.targetSetID)
	selectedSetID = rowMenu.targetSetID
	OpenNamePopup("save", name, icon)
  end)

  rowMenu.deleteBtn = CreateFrame("Button", nil, rowMenu, "UIPanelButtonTemplate")
  rowMenu.deleteBtn:SetWidth(136); rowMenu.deleteBtn:SetHeight(22)
  rowMenu.deleteBtn:SetPoint("TOP", rowMenu.changeBtn, "BOTTOM", 0, -2)
  rowMenu.deleteBtn:SetText(DELETE)
  rowMenu.deleteBtn:SetScript("OnClick", function()
	rowMenu:Hide()
	if not rowMenu.targetSetID then return end
	local targetID = rowMenu.targetSetID
	local name = C_EquipmentSet.GetEquipmentSetInfo(targetID)
	StaticPopupDialogs["STEQMGR_DELETE"] = {
	  text = string.format(CONFIRM_DELETE_EQUIPMENT_SET, name or "?"),
	  button1 = YES, button2 = NO,
	  OnAccept = function()
		pendingIgnoredToggles[targetID] = nil
		C_EquipmentSet.DeleteEquipmentSet(targetID)
		if selectedSetID == targetID then selectedSetID = nil end
		eqmgr.Refresh()
	  end,
	  timeout = 0, whileDead = 1, hideOnEscape = 1, exclusive = 1,
	}
	StaticPopup_Show("STEQMGR_DELETE")
  end)

  local setRowIconCount = 0
  local function CreateSetRow()
	local row = CreateFrame("Button", nil, listFrame)
	row:SetHeight(SET_ROW_HEIGHT)

	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.selTex = row:CreateTexture(nil, "BACKGROUND")
	row.selTex:SetAllPoints(row)
	row.selTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	row.selTex:SetBlendMode("ADD")
	row.selTex:SetVertexColor(0.4, 0.35, 0.1, 0.9)
	row.selTex:Hide()

	setRowIconCount = setRowIconCount + 1
	row.iconBtn = CreateFrame("Button", "STEqMgrRowIcon" .. setRowIconCount, row, "ActionButtonTemplate")
	row.iconBtn:SetWidth(32); row.iconBtn:SetHeight(32)
	row.iconBtn:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.iconBtn:SetNormalTexture("")
	row.icon = _G["STEqMgrRowIcon" .. setRowIconCount .. "Icon"]

	if C_EquipmentSet.PickupEquipmentSet then
	  row.iconBtn:RegisterForDrag("LeftButton")
	  row.iconBtn:SetScript("OnDragStart", function()
		if not row.setID then return end
		C_EquipmentSet.PickupEquipmentSet(row.setID)
	  end)
	end
	row.iconBtn:SetScript("OnEnter", function()
	  if not row.setID then return end
	  local name = C_EquipmentSet.GetEquipmentSetInfo(row.setID)
	  if not name then return end
	  GameTooltip_SetDefaultAnchor(GameTooltip, this)
	  GameTooltip:SetEquipmentSet(name)
	  GameTooltip:Show()
	  row.gear:Show()
	end)
	row.iconBtn:SetScript("OnLeave", function()
	  if not MouseIsOver(row.gear) then
		GameTooltip:Hide()
		row.gear:Hide()
	  end
	end)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.text:SetPoint("LEFT",  row.iconBtn, "RIGHT", 6,   0)
	row.text:SetPoint("RIGHT", row,			"RIGHT", -22, 0)
	row.text:SetJustifyH("LEFT")

	row.gear = CreateFrame("Button", nil, row)
	row.gear:SetWidth(16); row.gear:SetHeight(16)
	row.gear:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.gear.tex = row.gear:CreateTexture(nil, "ARTWORK")
	row.gear.tex:SetAllPoints(row.gear)
	row.gear.tex:SetTexture(imgpath .. "Gear_64Grey")
	row.gear:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	row.gear:Hide()

	row.gear:SetScript("OnClick", function()
	  if not row.setID then return end
	  if rowMenu:IsShown() and rowMenu.targetSetID == row.setID then
		PlaySound("igMainMenuOptionFaerTab")
		rowMenu:Hide(); return
	  end
	  rowMenu.targetSetID = row.setID
	  rowMenu.anchorBtn   = row.gear
	  rowMenu:ClearAllPoints()
	  rowMenu:SetPoint("TOPRIGHT", row.gear, "BOTTOMRIGHT", 0, 0)
	  rowMenu:Show()
	  PlaySound("igMainMenuOptionFaerTab")
	end)

	row.gear:SetScript("OnLeave", function()
	  if not MouseIsOver(row) then
		GameTooltip:Hide()
		row.gear:Hide()
	  end
	end)

	row:SetScript("OnClick", function()
	  selectedSetID = row.setID
	  PlaySound("igMainMenuOptionFaerTab")
	  local now = GetTime()
	  if row.lastClick and (now - row.lastClick) < 0.4 then
		row.lastClick = nil
		EquipSet(row.setID)
	  else
		row.lastClick = now
	  end
	  eqmgr.Refresh()
	end)

	row:SetScript("OnEnter", function()
	  if not this.setID then return end
	  local name = C_EquipmentSet.GetEquipmentSetInfo(this.setID)
	  if not name then return end
	  GameTooltip_SetDefaultAnchor(GameTooltip, this)
	  GameTooltip:SetEquipmentSet(name)
	  GameTooltip:Show()
	  row.gear:Show()
	end)

	row:SetScript("OnLeave", function()
	  if not MouseIsOver(row.gear) then
		GameTooltip:Hide()
		row.gear:Hide()
	  end
	end)

	return row
  end

  btnNewSet:SetScript("OnClick", function()
	PlaySound("igCharacterInfoOpen")
	OpenNamePopup("new")
  end)


  -- Name/Icon popup
  local ICON_GRID_COLS = 11
  local ICON_GRID_ROWS = 9
  local ICON_BTN_SIZE  = 34
  local ICON_BTN_PAD   = 4

  local namePopup = CreateFrame("Frame", "STEqMgrNamePopup", UIParent)
  namePopup:SetFrameStrata("DIALOG")
  namePopup:SetWidth(476)
  namePopup:SetHeight(510)
  namePopup:SetPoint("CENTER", UIParent, "CENTER")
  namePopup:Hide()
  ApplyDialogBackdrop(namePopup)
  namePopup:EnableMouse(true)
  namePopup:SetMovable(true)
  namePopup:RegisterForDrag("LeftButton")
  namePopup:SetScript("OnDragStart", function() this:StartMoving() end)
  namePopup:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
  tinsert(UISpecialFrames, "STEqMgrNamePopup")
  tinsert(UISpecialFrames, "STEquipmentManagerFrame")
  tinsert(UISpecialFrames, "STEqMgrFlyout")

  namePopup.title = namePopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  namePopup.title:SetPoint("TOP", namePopup, "TOP", 0, -14)
  namePopup.title:SetText(SAVE)

  local npClose = CreateFrame("Button", "STEqMgrNamePopupClose", namePopup, "UIPanelCloseButton")
  npClose:SetPoint("TOPRIGHT", namePopup, "TOPRIGHT", 4, 4)
  npClose:SetScript("OnClick", function()
	PlaySound("gsTitleOptionOK")
	namePopup:Hide()
  end)

  namePopup.nameLabel = namePopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  namePopup.nameLabel:SetPoint("TOPLEFT", namePopup, "TOPLEFT", 24, -36)
  namePopup.nameLabel:SetText(GEARSETS_POPUP_TEXT)

  namePopup.editbox = CreateFrame("EditBox", "STEqMgrNameEdit", namePopup, "InputBoxTemplate")
  namePopup.editbox:SetWidth(290)
  namePopup.editbox:SetHeight(22)
  namePopup.editbox:SetPoint("TOPLEFT", namePopup, "TOPLEFT", 24, -56)
  namePopup.editbox:SetAutoFocus(false)
  namePopup.editbox:SetMaxLetters(16)

  namePopup.selectedLabel = namePopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  namePopup.selectedLabel:SetPoint("TOPRIGHT", namePopup, "TOPRIGHT", -21, -36)
  namePopup.selectedLabel:SetText(ICON_SELECTION_TITLE_CURRENT)
  namePopup.selectedLabel:SetTextColor(1, 0.82, 0)

  namePopup.selectedPreview = CreateFrame("Button", "STEqMgrSelectedPreview", namePopup, "ActionButtonTemplate")
  namePopup.selectedPreview:SetWidth(44); namePopup.selectedPreview:SetHeight(44)
  namePopup.selectedPreview:SetPoint("TOPRIGHT", namePopup, "TOPRIGHT", -55, -54)
  namePopup.selectedPreview:EnableMouse(false)
  namePopup.selectedPreview:SetNormalTexture("")
  namePopup.selectedPreview.tex = _G["STEqMgrSelectedPreviewIcon"]

  namePopup.iconLabel = namePopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  namePopup.iconLabel:SetPoint("TOPLEFT", namePopup, "TOPLEFT", 24, -100)
  namePopup.iconLabel:SetText(GEARSETS_POPUP_ICON_TEXT or "Choose an Icon:")

  -- Icon grid inset and scroll frame declared before SetFilterMode so
  -- iconScroll is a valid upvalue inside that closure (Lua 5.0 rule).
  local iconInset = CreateFrame("Frame", nil, namePopup)
  iconInset:SetPoint("TOPLEFT",		namePopup, "TOPLEFT",	  14, -118)
  iconInset:SetPoint("BOTTOMRIGHT", namePopup, "BOTTOMRIGHT", -14,  42)
  ApplyInsetBackdrop(iconInset)

  local iconScroll = CreateFrame("ScrollFrame", "STEqMgrIconScroll", iconInset, "FauxScrollFrameTemplate")
  iconScroll:SetPoint("TOPLEFT",	 iconInset, "TOPLEFT",		6, -6)
  iconScroll:SetPoint("BOTTOMRIGHT", iconInset, "BOTTOMRIGHT", -22,  6)

  local searchBox = CreateFrame("EditBox", "STEqMgrSearchBox", namePopup, "InputBoxTemplate")
  searchBox:SetWidth(120); searchBox:SetHeight(20)
  searchBox:SetPoint("BOTTOMLEFT", namePopup, "BOTTOMLEFT", 115, 15)
  searchBox:SetAutoFocus(false)
  searchBox:SetMaxLetters(32)

  local searchIcon = searchBox:CreateTexture(nil, "OVERLAY")
  searchIcon:SetTexture(imgpath .. "Search")
  searchIcon:SetWidth(10); searchIcon:SetHeight(10)
  searchIcon:SetPoint("LEFT", searchBox, "LEFT", 4, 0)
  searchIcon:SetVertexColor(0.5, 0.5, 0.5, 1)

  local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  searchPlaceholder:SetPoint("LEFT", searchBox, "LEFT", 20, 0)
  searchPlaceholder:SetText("Search")

  local searchHasFocus = false

  local function UpdateSearchPlaceholder()
	if searchBox:GetText() ~= "" or searchHasFocus then
	  searchPlaceholder:Hide()
	  searchIcon:Hide()
	else
	  searchPlaceholder:Show()
	  searchIcon:Show()
	end
  end

  searchBox:SetScript("OnTextChanged", function()
	iconSearchText = this:GetText()
	UpdateSearchPlaceholder()
	iconList = nil
	iconScroll.offset = 0
	eqmgr.RefreshIconGrid()
  end)
  searchBox:SetScript("OnEditFocusGained", function()
	searchHasFocus = true
	UpdateSearchPlaceholder()
  end)
  searchBox:SetScript("OnEditFocusLost", function()
	searchHasFocus = false
	UpdateSearchPlaceholder()
  end)
  searchBox:SetScript("OnEscapePressed", function()
	this:ClearFocus()
  end)

  local scrollbar = _G["STEqMgrIconScrollScrollBar"]
  if scrollbar then
	scrollbar:ClearAllPoints()
	scrollbar:SetPoint("TOPLEFT",	 iconInset, "TOPRIGHT",    -18, -16)
	scrollbar:SetPoint("BOTTOMLEFT", iconInset, "BOTTOMRIGHT", -18,  16)
  end

  -- Icon type filter dropdown (All Icons/Spells/Items)
  local filterModes  = { "all", "spells", "items" }
  local filterLabels = {
	all    = ICON_FILTER_ALL,
	spells = ICON_FILTER_SPELL,
	items  = ICON_FILTER_ITEM,
  }

  local function SetFilterMode(mode)
	iconFilterMode	  = mode
	iconList		  = nil
	iconScroll.offset = 0
	eqmgr.RefreshIconGrid()
  end

  local filterDropdown = CreateFrame("Frame", "STEqMgrFilterDropdown", namePopup, "UIDropDownMenuTemplate")
  filterDropdown:SetPoint("BOTTOMRIGHT", namePopup, "BOTTOMRIGHT", -93, 7)
  UIDropDownMenu_SetWidth(80, filterDropdown)
  UIDropDownMenu_SetText(filterLabels[iconFilterMode], filterDropdown)
  UIDropDownMenu_Initialize(filterDropdown, function()
	for _, mode in ipairs(filterModes) do
	  local info = {}
	  info.text    = filterLabels[mode]
	  info.value   = mode
	  info.checked = (iconFilterMode == mode)
	  info.func    = function()
		SetFilterMode(this.value)
		UIDropDownMenu_SetText(filterLabels[this.value], filterDropdown)
	  end
	  UIDropDownMenu_AddButton(info)
	end
  end)

  local iconButtons = {}
  local iconBtnCount = 0
  for r = 1, ICON_GRID_ROWS do
	for c = 1, ICON_GRID_COLS do
	  local i = (r - 1) * ICON_GRID_COLS + c
	  iconBtnCount = iconBtnCount + 1
	  local bname = "STEqMgrIconBtn" .. iconBtnCount
	  local btn = CreateFrame("Button", bname, iconScroll, "ActionButtonTemplate")
	  btn:SetWidth(ICON_BTN_SIZE); btn:SetHeight(ICON_BTN_SIZE)
	  btn:SetPoint("TOPLEFT", iconScroll, "TOPLEFT",
		(c - 1) * (ICON_BTN_SIZE + ICON_BTN_PAD),
		-(r - 1) * (ICON_BTN_SIZE + ICON_BTN_PAD))
	  btn.icon = _G[bname .. "Icon"]
	  -- Selection highlight overlay (shown when this icon is selected)
	  btn.selectedTex = btn:CreateTexture(nil, "OVERLAY")
	  btn.selectedTex:SetTexture("Interface\\Buttons\\CheckButtonHilight")
	  btn.selectedTex:SetBlendMode("ADD")
	  btn.selectedTex:SetAllPoints(btn)
	  btn.selectedTex:Hide()
	  btn.selectedBorder = btn:CreateTexture(nil, "OVERLAY")
	  btn.selectedBorder:SetTexture("Interface\\Buttons\\UI-SlotFrame")
	  btn.selectedBorder:SetAllPoints(btn)
	  btn.selectedBorder:Hide()
	  btn.gridIndex = i

	  btn:SetScript("OnClick", function()
		if this.iconIndex then
		  local path = GetIconByIndex(this.iconIndex)
		  if path then selectedIconPath = path end
		  eqmgr.RefreshIconGrid()
		end
	  end)
	  btn:SetScript("OnEnter", function()
		if not this.iconIndex then return end
		local path = GetIconByIndex(this.iconIndex)
		if type(path) == "string" then
		  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		  GameTooltip:SetText(string.gsub(path, "INTERFACE\\ICONS\\", ""), 1, 1, 1)
		  GameTooltip:Show()
		end
	  end)
	  btn:SetScript("OnLeave", GameTooltip_Hide)
	  iconButtons[i] = btn
	end
  end

  function eqmgr.RefreshIconGrid()
	BuildIconList()
	local numIcons = GetNumIcons()
	local numRows  = math.ceil(numIcons / ICON_GRID_COLS)
	FauxScrollFrame_Update(iconScroll, numRows, ICON_GRID_ROWS, ICON_BTN_SIZE + ICON_BTN_PAD)
	iconScroll:Show()
	local offset = FauxScrollFrame_GetOffset(iconScroll)
	for i = 1, ICON_GRID_ROWS * ICON_GRID_COLS do
	  local listIdx = i + offset * ICON_GRID_COLS
	  local btn = iconButtons[i]
	  if listIdx <= numIcons then
		btn:Show()
		btn.iconIndex = listIdx
		local path = GetIconByIndex(listIdx)
		btn.icon:SetTexture(path)
		if path == selectedIconPath then btn.selectedTex:Show(); btn.selectedBorder:Show() else btn.selectedTex:Hide(); btn.selectedBorder:Hide() end
	  else
		btn:Hide()
		btn.iconIndex = nil
	  end
	end
	namePopup.selectedPreview.tex:SetTexture(selectedIconPath)
  end

  iconScroll:SetScript("OnVerticalScroll", function()
	FauxScrollFrame_OnVerticalScroll(ICON_BTN_SIZE + ICON_BTN_PAD, eqmgr.RefreshIconGrid)
  end)

  local btnPopupOK = CreateFrame("Button", "STEqMgrPopupOK", namePopup, "UIPanelButtonTemplate")
  btnPopupOK:SetWidth(80); btnPopupOK:SetHeight(22)
  btnPopupOK:SetPoint("BOTTOMLEFT", namePopup, "BOTTOMLEFT", 16, 14)
  btnPopupOK:SetText(OKAY)

  namePopup.editbox:SetScript("OnTextChanged", function()
	local txt = namePopup.editbox:GetText()
	if txt and txt ~= "" then btnPopupOK:Enable() else btnPopupOK:Disable() end
  end)

  btnPopupOK:SetScript("OnClick", function()
	local name = namePopup.editbox:GetText()
	if not name or name == "" then return end
	local iconForSave = string.gsub(selectedIconPath, "INTERFACE\\ICONS\\", "")
	if pendingAction == "new" then
	  C_EquipmentSet.CreateEquipmentSet(name, iconForSave)
	  PlaySound("igMainMenuOptionFaerTab")
	  C_EquipmentSet.ClearIgnoredSlotsForSave()
	  selectedSetID = C_EquipmentSet.GetEquipmentSetID(name)
	elseif pendingAction == "save" and selectedSetID then
	  C_EquipmentSet.ModifyEquipmentSet(selectedSetID, name)
	  C_EquipmentSet.ClearIgnoredSlotsForSave()
	  local effective = GetEffectiveIgnored(selectedSetID)
	  for slotID in pairs(effective) do C_EquipmentSet.IgnoreSlotForSave(slotID) end
	  C_EquipmentSet.SaveEquipmentSet(selectedSetID, iconForSave)
	  C_EquipmentSet.ClearIgnoredSlotsForSave()
	  pendingIgnoredToggles[selectedSetID] = nil
	elseif pendingAction == "rename" and selectedSetID then
	  C_EquipmentSet.ModifyEquipmentSet(selectedSetID, name)
	end
	namePopup:Hide()
	eqmgr.Refresh()
  end)

  local btnPopupCancel = CreateFrame("Button", "STEqMgrPopupCancel", namePopup, "UIPanelButtonTemplate")
  btnPopupCancel:SetWidth(80); btnPopupCancel:SetHeight(22)
  btnPopupCancel:SetPoint("BOTTOMRIGHT", namePopup, "BOTTOMRIGHT", -16, 14)
  btnPopupCancel:SetText(CANCEL)
  btnPopupCancel:SetScript("OnClick", function()
	PlaySound("gsTitleOptionOK")
	namePopup:Hide()
  end)

  function OpenNamePopup(action, prefillName, prefillIcon)
	pendingAction = action
	iconList	  = nil
	iconSearchText = ""
	searchBox:SetText("")
	searchPlaceholder:Show()
	searchIcon:Show()
	searchBox:ClearFocus()
	namePopup.editbox:SetText(prefillName or "")
	if prefillIcon then
	  selectedIconPath = "INTERFACE\\ICONS\\" .. strupper(string.gsub(prefillIcon, "INTERFACE\\ICONS\\", ""))
	else
	  selectedIconPath = QUESTION_MARK
	end
	if action == "rename" then
	  namePopup.title:SetText("Rename Set")
	  iconInset:Hide()
	  namePopup.iconLabel:Hide()
	  namePopup.selectedLabel:Hide()
	  namePopup.selectedPreview:Hide()
	  filterDropdown:Hide()
	  searchBox:Hide()
	  namePopup:SetHeight(120)
	else
	  namePopup.title:SetText(
		(action == "new") and "Name Set" or "Save Set")
	  iconInset:Show()
	  namePopup.iconLabel:Show()
	  namePopup.selectedLabel:Show()
	  namePopup.selectedPreview:Show()
	  filterDropdown:Show()
	  searchBox:Show()
	  namePopup:SetHeight(510)
	end
	local txt = namePopup.editbox:GetText()
	if txt and txt ~= "" then btnPopupOK:Enable() else btnPopupOK:Disable() end
	namePopup:Show()
	if action ~= "rename" then eqmgr.RefreshIconGrid() end
	namePopup.editbox:SetFocus()
  end

  -- Equipment slot flyout
  local flyout = CreateFrame("Frame", "STEqMgrFlyout", UIParent)
  flyout:SetFrameStrata("DIALOG")
  flyout:SetWidth(43); flyout:SetHeight(43)
  flyout:Hide()
  flyout.buttons	= {}
  local allFlyoutButtons = {}  -- every button ever created, for reliable hide-all

  local FLYOUT_COLS		   = 5
  local FLYOUT_BORDERWIDTH = 3
  local FLYOUT_ITEM_WIDTH  = 37
  local FLYOUT_ITEM_HEIGHT = 37
  local FLYOUT_ITEM_XOFF   = 4
  local FLYOUT_ITEM_YOFF   = -5   -- buttons in successive rows overlap by 5px
  local FLYOUT_ROW_HEIGHT  = 54   -- one-row bg height
  local FLYOUT_ATLAS	   = imgpath .. "UI-GearManager-Flyout"

  -- TexCoord sets for the atlas (left/right = U, top/bottom = V)
  local TC_ONESLOT_LEFT   = { 0,		  0.09765625, 0.5546875, 0.77734375 }
  local TC_ONESLOT_RIGHT  = { 0.41796875, 0.51171875, 0.5546875, 0.77734375 }
  local TC_ONEROW_LEFT	  = { 0,		  0.16796875, 0.5546875, 0.77734375 }
  local TC_ONEROW_CENTER  = { 0.16796875, 0.328125,   0.5546875, 0.77734375 }
  local TC_ONEROW_RIGHT   = { 0.328125,   0.51171875, 0.5546875, 0.77734375 }
  local TC_MULTIROW_TOP   = { 0,		  0.8359375,  0,		 0.19140625 }
  local TC_MULTIROW_MID   = { 0,		  0.8359375,  0.19140625,0.35546875 }
  local TC_MULTIROW_BOT   = { 0,		  0.8359375,  0.35546875,0.546875   }
  -- Width/height of each atlas section
  local W_ONESLOT_LEFT	= 25;  local W_ONESLOT_RIGHT = 24
  local W_ONEROW_LEFT	= 43;  local W_ONEROW_CENTER = 41;  local W_ONEROW_RIGHT  = 47
  local H_ONEROW		= 54
  local W_MULTIROW		= 214
  local H_MULTIROW_TOP	= 49;  local H_MULTIROW_MID  = 42;  local H_MULTIROW_BOT  = 49

  -- buttonAnchor: child frame that holds both bg textures and buttons
  local buttonAnchor = CreateFrame("Frame", nil, flyout)
  buttonAnchor:SetFrameStrata("DIALOG")
  buttonAnchor.numBGs = 1
  buttonAnchor.bg1 = buttonAnchor:CreateTexture(nil, "BACKGROUND")
  buttonAnchor.bg1:SetTexture(FLYOUT_ATLAS)

  local function CreateFlyoutBG()
	buttonAnchor.numBGs = buttonAnchor.numBGs + 1
	local t = buttonAnchor:CreateTexture(nil, "BACKGROUND")
	t:SetTexture(FLYOUT_ATLAS)
	buttonAnchor["bg" .. buttonAnchor.numBGs] = t
	return t
  end

  local flyoutNumItems = 0  -- track last layout so we only rebuild bg when needed

  local function UpdateFlyoutBG(numItems)
	if flyoutNumItems == numItems then return end
	flyoutNumItems = numItems
	local used = 0
	local last

	if numItems == 1 then
	  -- Special case: one item uses narrow single-slot caps with no center
	  local bg = buttonAnchor.bg1
	  bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_ONESLOT_LEFT))
	  bg:SetWidth(W_ONESLOT_LEFT); bg:SetHeight(H_ONEROW)
	  bg:SetPoint("TOPLEFT", buttonAnchor, "TOPLEFT", -5, 4); bg:Show()
	  used = used + 1; last = bg
	  bg = buttonAnchor.bg2 or CreateFlyoutBG()
	  bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_ONESLOT_RIGHT))
	  bg:SetWidth(W_ONESLOT_RIGHT); bg:SetHeight(H_ONEROW)
	  bg:SetPoint("TOPLEFT", last, "TOPRIGHT"); bg:Show()
	  used = used + 1
	elseif numItems <= FLYOUT_COLS then
	  -- Single row: left cap, N-2 centers, right cap
	  local bg = buttonAnchor.bg1
	  bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_ONEROW_LEFT))
	  bg:SetWidth(W_ONEROW_LEFT); bg:SetHeight(H_ONEROW)
	  bg:SetPoint("TOPLEFT", buttonAnchor, "TOPLEFT", -5, 4); bg:Show()
	  used = used + 1; last = bg
	  for i = 2, numItems - 1 do
		bg = buttonAnchor["bg"..i] or CreateFlyoutBG()
		bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_ONEROW_CENTER))
		bg:SetWidth(W_ONEROW_CENTER); bg:SetHeight(H_ONEROW)
		bg:SetPoint("TOPLEFT", last, "TOPRIGHT"); bg:Show()
		used = used + 1; last = bg
	  end
	  bg = buttonAnchor["bg"..numItems] or CreateFlyoutBG()
	  bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_ONEROW_RIGHT))
	  bg:SetWidth(W_ONEROW_RIGHT); bg:SetHeight(H_ONEROW)
	  bg:SetPoint("TOPLEFT", last, "TOPRIGHT"); bg:Show()
	  used = used + 1
	else
	  -- Multi-row
	  local numRows = math.ceil(numItems / FLYOUT_COLS)
	  local bg = buttonAnchor.bg1
	  bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_MULTIROW_TOP))
	  bg:SetWidth(W_MULTIROW); bg:SetHeight(H_MULTIROW_TOP)
	  bg:SetPoint("TOPLEFT", buttonAnchor, "TOPLEFT", -5, 4); bg:Show()
	  used = used + 1; last = bg
	  for i = 2, numRows - 1 do
		bg = buttonAnchor["bg"..i] or CreateFlyoutBG()
		bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_MULTIROW_MID))
		bg:SetWidth(W_MULTIROW); bg:SetHeight(H_MULTIROW_MID)
		bg:SetPoint("TOPLEFT", last, "BOTTOMLEFT"); bg:Show()
		used = used + 1; last = bg
	  end
	  bg = buttonAnchor["bg"..numRows] or CreateFlyoutBG()
	  bg:ClearAllPoints(); bg:SetTexCoord(unpack(TC_MULTIROW_BOT))
	  bg:SetWidth(W_MULTIROW); bg:SetHeight(H_MULTIROW_BOT)
	  bg:SetPoint("TOPLEFT", last, "BOTTOMLEFT"); bg:Show()
	  used = used + 1
	end
	for i = used + 1, buttonAnchor.numBGs do
	  buttonAnchor["bg"..i]:Hide()
	end
  end

  local PLACEINBAGS_LOC  = -1
  local IGNORESLOT_LOC	 = -2
  local UNIGNORESLOT_LOC = -3

  local function UnequipToBags(invSlot)
	if not GetInventoryItemID("player", invSlot) then return end
	ClearCursor()
	PickupInventoryItem(invSlot)
	if not CursorHasItem() then return end
	for bag = 0, 4 do
	  local nslots = GetContainerNumSlots(bag) or 0
	  for slot = 1, nslots do
		if not C_Container.GetContainerItemID(bag, slot) then
		  PickupContainerItem(bag, slot); return
		end
	  end
	end
	ClearCursor()
	UIErrorsFrame:AddMessage(ERR_EQUIPMENT_MANAGER_BAGS_FULL, 1, .1, .1, 1)
  end

  local function SetPopoutReversed(popout, reversed)
	if not popout then return end
	local nc = reversed and popout.coordReversed   or popout.coordNormal
	local hc = reversed and popout.coordReversedHi or popout.coordNormalHi
	popout.normalTex:SetTexCoord(unpack(nc))
	popout.highlightTex:SetTexCoord(unpack(hc))
  end

  -- Rarity-coloured borders on flyout items (oGlow-style glow).
  -- If oGlow is loaded it already hooks STEqMgrFlyout, so we defer to it.
  local function UpdateFlyoutGlow(b)
	local glow = b.emGlow
	if not glow then
	  glow = b:CreateTexture(nil, "OVERLAY")
	  glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	  glow:SetBlendMode("ADD")
	  glow:SetAlpha(0.8)
	  glow:SetWidth(70); glow:SetHeight(70)
	  glow:SetPoint("CENTER", b, "CENTER", 0, 0)
	  b.emGlow = glow
	end
	glow:Hide()
	if oGlow or IsAddOnLoaded("oGlow") then return end
	local link
	if b.bag then
	  link = GetContainerItemLink(b.bag, b.slot)
	elseif b.invSlot then
	  link = GetInventoryItemLink("player", b.invSlot)
	end
	if not link then return end
	local _, _, hex = string.find(link, "|c(%x%x%x%x%x%x%x%x)|")
	if not hex then return end
	hex = string.lower(string.sub(hex, 3))
	if hex == "9d9d9d" or hex == "ffffff" then return end
	local r = tonumber(string.sub(hex, 1, 2), 16) / 255
	local g = tonumber(string.sub(hex, 3, 4), 16) / 255
	local bl = tonumber(string.sub(hex, 5, 6), 16) / 255
	glow:SetVertexColor(r, g, bl)
	glow:Show()
  end

  local flyoutBtnCount = 0
  local function MakeFlyoutButton()
	flyoutBtnCount = flyoutBtnCount + 1
	local bname = "STEqMgrFlyoutBtn" .. flyoutBtnCount
	local b = CreateFrame("Button", bname, buttonAnchor, "ActionButtonTemplate")
	b:SetWidth(FLYOUT_ITEM_WIDTH); b:SetHeight(FLYOUT_ITEM_HEIGHT)
	b.icon  = _G[bname .. "Icon"]
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)

	b:SetScript("OnEnter", function()
	  if this.specialAction == "placeInBags" then
		GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
		GameTooltip:SetText(EQUIPMENT_MANAGER_PLACE_IN_BAGS, 1, 1, 1)
		GameTooltip:Show()
	  elseif this.specialAction == "ignore" then
		GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
		GameTooltip:SetText(EQUIPMENT_MANAGER_IGNORE_SLOT, 1, 1, 1)
		GameTooltip:Show()
	  elseif this.specialAction == "unignore" then
		GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
		GameTooltip:SetText(EQUIPMENT_MANAGER_UNIGNORE_SLOT, 1, 1, 1)
		GameTooltip:Show()
	  elseif this.bag then
		GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
		if this.bag == -1 then
		  local link = GetContainerItemLink(-1, this.slot)
		  if link then GameTooltip:SetHyperlink(link) end
		else
		  GameTooltip:SetBagItem(this.bag, this.slot)
		end
		GameTooltip:Show()
	  elseif this.invSlot then
		GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
		GameTooltip:SetInventoryItem("player", this.invSlot)
		GameTooltip:Show()
	  end
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:SetScript("OnClick", function()
	  if this.specialAction == "placeInBags" then
		UnequipToBags(flyout.targetInvSlot); flyout:Hide(); return
	  elseif this.specialAction == "ignore" or this.specialAction == "unignore" then
		ToggleIgnoredForSet(selectedSetID, flyout.targetInvSlot)
		flyout:Hide(); eqmgr.Refresh(); return
	  end
	  ClearCursor()
	  if this.bag then PickupContainerItem(this.bag, this.slot)
	  elseif this.invSlot then PickupInventoryItem(this.invSlot)
	  else return end  -- empty slot button, do nothing
	  if CursorHasItem() then PickupInventoryItem(flyout.targetInvSlot) end
	  flyout:Hide()
	end)
	return b
  end

  function eqmgr.ShowFlyout(slotBtn)
	local invSlot = slotBtn.slotID or slotBtn:GetID()

	local items = {}
	GetInventoryItemsForSlot(invSlot, items)
	items[PlayerEquipLocation(invSlot)] = nil

	if BankFrame and BankFrame:IsVisible() then
	  local SLOT_EQUIPLOCS = {
		[1]  = { INVTYPE_HEAD=true },
		[2]  = { INVTYPE_NECK=true },
		[3]  = { INVTYPE_SHOULDER=true },
		[4]  = { INVTYPE_BODY=true },
		[5]  = { INVTYPE_CHEST=true, INVTYPE_ROBE=true },
		[6]  = { INVTYPE_WAIST=true },
		[7]  = { INVTYPE_LEGS=true },
		[8]  = { INVTYPE_FEET=true },
		[9]  = { INVTYPE_WRIST=true },
		[10] = { INVTYPE_HAND=true },
		[11] = { INVTYPE_FINGER=true },
		[12] = { INVTYPE_FINGER=true },
		[13] = { INVTYPE_TRINKET=true },
		[14] = { INVTYPE_TRINKET=true },
		[15] = { INVTYPE_CLOAK=true },
		[16] = { INVTYPE_WEAPON=true, INVTYPE_2HWEAPON=true, INVTYPE_WEAPONMAINHAND=true },
		[17] = { INVTYPE_WEAPON=true, INVTYPE_SHIELD=true, INVTYPE_WEAPONOFFHAND=true, INVTYPE_HOLDABLE=true },
		[18] = { INVTYPE_RANGED=true, INVTYPE_THROWN=true, INVTYPE_RANGEDRIGHT=true },
		[19] = { INVTYPE_TABARD=true },
	  }
	  local eligibleLocs = SLOT_EQUIPLOCS[invSlot]
	  if eligibleLocs then
		local function tryAddBank(bag, slot, location)
		  local link = GetContainerItemLink(bag, slot)
		  if not link then return end
		  local _, _, _, equipLoc = C_Item.GetItemInfoInstant(link)
		  if equipLoc and eligibleLocs[equipLoc] then
			items[location] = true
		  end
		end
		-- Main bank: bag ID -1, slots 1..24
		for slot = 1, 24 do
		  tryAddBank(-1, slot, LOC_BANK + slot)
		end
		-- Bank bags: IDs 5..10; stored in bitfield as bag-4
		for bag = 5, 10 do
		  for slot = 1, GetContainerNumSlots(bag) do
			tryAddBank(bag, slot, LOC_BANK + LOC_BAGS + ((bag - 4) * 256) + slot)
		  end
		end
	  end
	end

	local ordered = {}
	if GetInventoryItemID("player", invSlot) then
	  table.insert(ordered, PLACEINBAGS_LOC)
	end
	if selectedSetID and frame:IsShown() then
	  local effective = GetEffectiveIgnored(selectedSetID)
	  table.insert(ordered, effective[invSlot] and UNIGNORESLOT_LOC or IGNORESLOT_LOC)
	end
	local itemLocations = {}
	for location in pairs(items) do
	  local loc = UnpackLocation(location)
	  local itemID, tex
	  if loc.isBank then
		local bag = loc.isBags and loc.bag or -1
		itemID = C_Container.GetContainerItemID(bag, loc.slot)
		tex = GetContainerItemInfo(bag, loc.slot)
	  elseif loc.isBags then
		itemID = C_Container.GetContainerItemID(loc.bag, loc.slot)
		tex = GetContainerItemInfo(loc.bag, loc.slot)
	  else
		itemID = GetInventoryItemID("player", loc.slot)
		tex = GetInventoryItemTexture("player", loc.slot)
	  end
	  -- Skip locations with no item texture
	  if tex then
		local canUse = true
		if itemID then
		  if invSlot == 17 then
			local _,_,_,equipLoc = C_Item.GetItemInfoInstant(itemID)
			if equipLoc == "INVTYPE_WEAPON" and not CanDualWield() then
			  canUse = false
			end
		  end
		  if canUse and not C_PlayerInfo.CanUseItem(itemID) then
			canUse = false
		  end
		end
		if canUse then table.insert(itemLocations, location) end
	  end
	end
	table.sort(itemLocations)
	for _, loc in ipairs(itemLocations) do table.insert(ordered, loc) end

	flyout.targetInvSlot = invSlot
	local num = table.getn(ordered)

	-- Hide all buttons first so stale buttons from a previous larger flyout
	-- are never left visible.
	for _, b in ipairs(flyout.buttons) do b:Hide() end

	if num == 0 then
	  flyout:Hide()
	  return
	end

	while table.getn(flyout.buttons) < num do
	  table.insert(flyout.buttons, MakeFlyoutButton())
	  table.insert(allFlyoutButtons, flyout.buttons[table.getn(flyout.buttons)])
	end

	for i, b in ipairs(flyout.buttons) do
	  if i <= num then
		local location = ordered[i]
		b.specialAction = nil; b.bag = nil; b.slot = nil; b.invSlot = nil; b.bankSlot = nil

		if location == PLACEINBAGS_LOC then
		  b.specialAction = "placeInBags"
		  b.icon:SetTexture(imgpath .. "UI-GearManager-ItemIntoBag")
		  b.count:SetText("")
		elseif location == IGNORESLOT_LOC then
		  b.specialAction = "ignore"
		  b.icon:SetTexture(imgpath .. "UI-GearManager-LeaveItem-Opaque")
		  b.count:SetText("")
		elseif location == UNIGNORESLOT_LOC then
		  b.specialAction = "unignore"
		  b.icon:SetTexture(imgpath .. "UI-GearManager-Undo")
		  b.count:SetText("")
		else
		  local loc = UnpackLocation(location)
		  if loc.isBank then
			local bag = loc.isBags and loc.bag or -1
			b.bag = bag; b.slot = loc.slot
			local tex, count = GetContainerItemInfo(bag, loc.slot)
			b.icon:SetTexture(tex)
			b.count:SetText((count and count > 1) and count or "")
		  elseif loc.isBags then
			b.bag = loc.bag; b.slot = loc.slot
			local tex, count = GetContainerItemInfo(loc.bag, loc.slot)
			b.icon:SetTexture(tex)
			b.count:SetText((count and count > 1) and count or "")
		  else
			b.invSlot = loc.slot
			b.icon:SetTexture(GetInventoryItemTexture("player", loc.slot))
			b.count:SetText("")
		  end
		end

		UpdateFlyoutGlow(b)

		local col = math.mod(i - 1, FLYOUT_COLS)
		local row = math.floor((i - 1) / FLYOUT_COLS)
		b:ClearAllPoints()
		if col == 0 then
		  -- First in row: anchor to buttonAnchor TOPLEFT
		  b:SetPoint("TOPLEFT", buttonAnchor, "TOPLEFT",
			FLYOUT_BORDERWIDTH,
			-FLYOUT_BORDERWIDTH - (FLYOUT_ITEM_HEIGHT - FLYOUT_ITEM_YOFF) * row)
		else
		  -- Subsequent in row: anchor to left neighbour TOPRIGHT
		  b:SetPoint("TOPLEFT", flyout.buttons[i - 1], "TOPRIGHT", FLYOUT_ITEM_XOFF, 0)
		end
		b:Show()
	  end
	end

	local cols = math.min(num, FLYOUT_COLS)
	local rows = math.ceil(num / FLYOUT_COLS)

	-- Size the buttonAnchor to fit all buttons
	buttonAnchor:SetWidth(cols * FLYOUT_ITEM_WIDTH + (cols - 1) * FLYOUT_ITEM_XOFF + FLYOUT_BORDERWIDTH)
	buttonAnchor:SetHeight(FLYOUT_ROW_HEIGHT + math.floor((num - 1) / FLYOUT_COLS) * (FLYOUT_ITEM_HEIGHT - FLYOUT_ITEM_YOFF))

	-- Update atlas background textures
	UpdateFlyoutBG(num)

	flyout:ClearAllPoints()
	local anchorBtn = slotBtn.popout or slotBtn
	if WEAPON_SLOTS[invSlot] then
	  flyout:SetPoint("TOPLEFT", slotBtn, "TOPLEFT", -FLYOUT_BORDERWIDTH, FLYOUT_BORDERWIDTH)
	  buttonAnchor:SetPoint("TOPLEFT", anchorBtn, "BOTTOMLEFT", 0, -FLYOUT_BORDERWIDTH)
	else
	  flyout:SetPoint("TOPLEFT", slotBtn, "TOPLEFT", -FLYOUT_BORDERWIDTH, FLYOUT_BORDERWIDTH)
	  buttonAnchor:SetPoint("TOPLEFT", anchorBtn, "TOPRIGHT", 0, 0)
	end

	if flyout.currentPopout and flyout.currentPopout ~= slotBtn.popout then
	  SetPopoutReversed(flyout.currentPopout, false)
	end
	flyout.currentPopout = slotBtn.popout

	for sid, hl in pairs(slotHighlights) do
	  if sid == invSlot then hl:Show() else hl:Hide() end
	end

	SetPopoutReversed(slotBtn.popout, true)
	flyout:Show()

	if slotBtn:IsMouseOver() and GetInventoryItemID("player", invSlot) then
	  GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
	  GameTooltip:SetInventoryItem("player", invSlot)
	  GameTooltip:Show()
	end
  end

  flyout:SetScript("OnHide", function()
	this.targetInvSlot = nil
	if this.currentPopout then
	  SetPopoutReversed(this.currentPopout, false)
	  this.currentPopout = nil
	end
	for _, hl in pairs(slotHighlights) do hl:Hide() end
  end)

  -- Paperdoll slot hooks
  local CHAR_SLOT_NAMES = {
	"HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
	"ShirtSlot", "TabardSlot", "WristSlot", "HandsSlot", "WaistSlot",
	"LegsSlot", "FeetSlot", "Finger0Slot", "Finger1Slot",
	"Trinket0Slot", "Trinket1Slot", "MainHandSlot", "SecondaryHandSlot",
	"RangedSlot",
  }

  local POPOUT_TEX = imgpath .. "UI-GearManager-FlyoutButton"

  for _, slotName in ipairs(CHAR_SLOT_NAMES) do
	local slot = _G["Character" .. slotName]
	if slot then
	  local overlayFrame = CreateFrame("Frame", nil, slot)
	  overlayFrame:SetAllPoints(slot)
	  overlayFrame:SetFrameLevel(slot:GetFrameLevel() + 10)
	  local overlay = overlayFrame:CreateTexture(nil, "OVERLAY")
	  overlay:SetAllPoints(overlayFrame)
	  overlay:SetTexture(imgpath .. "UI-GearManager-LeaveItem-Transparent")
	  overlayFrame:Hide()
	  slotOverlays[slot:GetID()] = overlayFrame

	  local invSlot = slot:GetID()
	  local popout  = CreateFrame("Button", nil, slot)
	  popout:SetFrameLevel(slot:GetFrameLevel() + 1)

	  if WEAPON_SLOTS[invSlot] then
		popout:SetWidth(36); popout:SetHeight(16)
		popout:SetPoint("TOP", slot, "BOTTOM", 0, 4)
		popout.coordNormal	   = { 0.15625, 0.84375, 0.5, 0   }
		popout.coordReversed   = { 0.15625, 0.84375, 0,   0.5 }
		popout.coordNormalHi   = { 0.15625, 0.84375, 1,   0.5 }
		popout.coordReversedHi = { 0.15625, 0.84375, 0.5, 1   }
	  else
		popout:SetWidth(16); popout:SetHeight(37)
		popout:SetPoint("LEFT", slot, "RIGHT", -7, 0)
		popout.coordNormal	   = { 0.15625, 0.5, 0.84375, 0.5, 0.15625, 0,   0.84375, 0   }
		popout.coordReversed   = { 0.15625, 0,   0.84375, 0,   0.15625, 0.5, 0.84375, 0.5 }
		popout.coordNormalHi   = { 0.15625, 1,   0.84375, 1,   0.15625, 0.5, 0.84375, 0.5 }
		popout.coordReversedHi = { 0.15625, 0.5, 0.84375, 0.5, 0.15625, 1,   0.84375, 1   }
	  end

	  popout.normalTex = popout:CreateTexture(nil, "ARTWORK")
	  popout.normalTex:SetAllPoints(popout)
	  popout.normalTex:SetTexture(POPOUT_TEX)
	  popout.highlightTex = popout:CreateTexture(nil, "HIGHLIGHT")
	  popout.highlightTex:SetAllPoints(popout)
	  popout.highlightTex:SetTexture(POPOUT_TEX)
	  popout.highlightTex:SetBlendMode("ADD")
	  SetPopoutReversed(popout, false)

	  local hlFrame = CreateFrame("Frame", nil, slot)
	  hlFrame:SetAllPoints(slot)
	  hlFrame:SetFrameLevel(slot:GetFrameLevel() + 5)
	  local hlTex = hlFrame:CreateTexture(nil, "OVERLAY")
	  hlTex:SetWidth(50); hlTex:SetHeight(50)
	  hlTex:SetWidth(50); hlTex:SetHeight(50)
	  hlTex:SetPoint("CENTER", hlFrame, "CENTER")
	  hlTex:SetTexture(imgpath .. "UI-GearManager-ItemButton-Highlight")
	  hlTex:SetTexCoord(0, 0.78125, 0, 0.78125)
	  hlFrame:Hide()
	  slotHighlights[invSlot] = hlFrame

	  slot.popout	 = popout
	  slot.invSlotID = invSlot

	  popout:SetScript("OnClick", function()
		if flyout:IsShown() and flyout.targetInvSlot == invSlot then
		  flyout:Hide()
		else
		  eqmgr.ShowFlyout(slot)
		end
	  end)
	  popout:Hide()
	  table.insert(popoutButtons, popout)
	end
  end

  local altHoveredSlot = nil
  local altWasOpen	   = false

  local altTracker = CreateFrame("Frame")
  altTracker:SetScript("OnUpdate", function()
	-- Poll which paperdoll slot the mouse is over right now.
	local hovered = nil
	if CharacterFrame:IsVisible() then
	  for _, slotName in ipairs(CHAR_SLOT_NAMES) do
		local slot = _G["Character" .. slotName]
		if slot and slot:IsVisible() and MouseIsOver(slot) then
		  hovered = slot
		  break
		end
	  end
	end
	-- Only update altHoveredSlot when mouse is over a slot.
	-- When mouse is not over any slot, keep the last value so the flyout
	-- stays open on that slot for as long as Alt is held.
	if hovered then
	  altHoveredSlot = hovered
	end

	if frame:IsShown() then
	  if altWasOpen then flyout:Hide(); altWasOpen = false; altHoveredSlot = nil end
	  return
	end

	if IsAltKeyDown() then
	  if altHoveredSlot then
		if not flyout:IsShown() or flyout.targetInvSlot ~= altHoveredSlot.invSlotID then
		  eqmgr.ShowFlyout(altHoveredSlot)
		  altWasOpen = true
		end
	  end
	else
	  -- Alt released: close flyout and clear state.
	  if altWasOpen then
		flyout:Hide()
		altWasOpen = false
		if altHoveredSlot and altHoveredSlot:IsMouseOver() then
		  GameTooltip_SetDefaultAnchor(GameTooltip, altHoveredSlot)
		  GameTooltip:SetInventoryItem("player", altHoveredSlot:GetID())
		  GameTooltip:Show()
		end
	  end
	  -- Clear altHoveredSlot when Alt is not held and mouse is not over any
	  -- slot, so pressing Alt elsewhere doesn't reopen the flyout.
	  if not hovered then
		altHoveredSlot = nil
	  end
	end
  end)

  for _, slotName in ipairs(CHAR_SLOT_NAMES) do
	local slot = _G["Character" .. slotName]
	if slot then
	  local origEnter = slot:GetScript("OnEnter")
	  local origLeave = slot:GetScript("OnLeave")
	  slot:SetScript("OnEnter", function()
		if flyout:IsShown() and flyout.targetInvSlot == this:GetID() then
		  GameTooltip:SetOwner(buttonAnchor, "ANCHOR_RIGHT", 6, -buttonAnchor:GetHeight() - -6)
		  GameTooltip:SetInventoryItem("player", this:GetID())
		  GameTooltip:Show()
		elseif origEnter then
		  origEnter()
		end
	  end)
	  slot:SetScript("OnLeave", function()
		if origLeave then origLeave() end
	  end)
	end
  end

  frame:SetScript("OnHide", function()
	for _, b in ipairs(popoutButtons) do b:Hide() end
	flyout:Hide()
  end)

  local origCharHide = CharacterFrame:GetScript("OnHide")
  CharacterFrame:SetScript("OnHide", function()
	if origCharHide then origCharHide() end
	frame:Hide()
  end)

  for i = 1, 4 do
	local tab = getglobal("CharacterFrameTab" .. i)
	if tab then
	  local origClick = tab:GetScript("OnClick")
	  tab:SetScript("OnClick", function()
		if origClick then origClick() end
		flyout:Hide()
		altWasOpen = false
		altHoveredSlot = nil
		frame:Hide()
	  end)
	end
  end

  -- Refresh
  function eqmgr.Refresh()
	local ids	  = GetVisibleSetIDs()
	local numSets = table.getn(ids)

	if numSets > 0 then
	  local stillExists = false
	  if selectedSetID then
		for _, id in ipairs(ids) do
		  if id == selectedSetID then stillExists = true; break end
		end
	  end
	  if not stillExists then selectedSetID = ids[1] end
	else
	  selectedSetID = nil
	end

	local totalItems = numSets
	local maxOffset  = math.max(0, totalItems - LIST_VISIBLE_ROWS)
	if listFrame.offset > maxOffset then listFrame.offset = maxOffset end
	if listFrame.offset < 0			then listFrame.offset = 0 end
	local off = listFrame.offset

	for i = 1, numSets do
	  if not setRows[i] then setRows[i] = CreateSetRow() end
	  local row  = setRows[i]
	  local slot = i - off
	  if slot >= 1 and slot <= LIST_VISIBLE_ROWS then
		local setID = ids[i]
		local name, icon, _, isEquipped, _, _, _, numMissing =
		  C_EquipmentSet.GetEquipmentSetInfo(setID)
		row.setID = setID
		local color = (numMissing and numMissing > 0) and "|cffff5555"
					  or isEquipped and "|cff33ff33" or "|cffffffff"
		row.text:SetText(color .. (name or "?") .. "|r")
		if icon then
		  row.icon:SetTexture(string.find(icon, "\\") and icon or ("Interface\\Icons\\" .. icon))
		else
		  row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		end
		if setID == selectedSetID then row.selTex:Show() else row.selTex:Hide() end
		row:ClearAllPoints()
		row:SetPoint("LEFT",	listFrame, "LEFT",	  4, 0)
		row:SetPoint("RIGHT",	listFrame, "RIGHT",  -4, 0)
		row:SetPoint("TOPLEFT", listFrame, "TOPLEFT", 4, -4 - (slot - 1) * LIST_ROW_STRIDE)
		row:Show()
	  else
		row:Hide(); row.setID = nil
	  end
	end

	for i = numSets + 1, table.getn(setRows) do
	  setRows[i]:Hide(); setRows[i].setID = nil
	end

	local setIgnored = selectedSetID and GetEffectiveIgnored(selectedSetID) or {}
	for slotID, overlayFrame in pairs(slotOverlays) do
	  if selectedSetID and setIgnored[slotID] then overlayFrame:Show()
	  else overlayFrame:Hide() end
	end

	if selectedSetID then btnEquip:Enable(); btnSave:Enable()
	else btnEquip:Disable(); btnSave:Disable() end

	if eqmgr.RefreshExtras then eqmgr.RefreshExtras() end
  end

  local function SetupExtras()

  -- Shared widget helpers
  local widgetCount = 0
  local function NextName(prefix)
	widgetCount = widgetCount + 1
	return "STEqMgr" .. prefix .. widgetCount
  end

  local function CreateCheckbox(parent, label, labelOnLeft)
	local cb = CreateFrame("CheckButton", NextName("Check"), parent, "UICheckButtonTemplate")
	cb:SetWidth(24); cb:SetHeight(24)
	local builtin = _G[cb:GetName() .. "Text"]
	if builtin then builtin:SetText("") end
	if label then
	  cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	  if labelOnLeft then
		cb.label:SetPoint("RIGHT", cb, "LEFT", -2, 1)
	  else
		cb.label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
	  end
	  cb.label:SetText(label)
	end
	return cb
  end

  local function CreateArrowButton(parent, dir)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(18); b:SetHeight(18)
	local base = (dir == "up") and "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-"
	  or "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-"
	b:SetNormalTexture(base .. "Up")
	b:SetPushedTexture(base .. "Down")
	b:SetDisabledTexture(base .. "Disabled")
	b:SetHighlightTexture(base .. "Highlight", "ADD")
	return b
  end

  local function CreateDeleteButton(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetWidth(20); b:SetHeight(20)
	b:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
	b:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
	b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
	return b
  end

  -- Dropdown built on UIDropDownMenuTemplate. dd.menuFunc returns a list of
  -- { text, value, func } entries, rebuilt every time the menu opens.
  local function CreateDropdown(parent, width)
	local dd = CreateFrame("Frame", NextName("Dropdown"), parent, "UIDropDownMenuTemplate")
	UIDropDownMenu_SetWidth(width, dd)
	dd.initialize = function()
	  if not dd.menuFunc then return end
	  for _, e in ipairs(dd.menuFunc()) do
		local info = {}
		info.text	 = e.text
		info.value	 = e.value
		info.func	 = e.func
		info.checked = (dd.selectedValue ~= nil and dd.selectedValue == e.value) and 1 or nil
		UIDropDownMenu_AddButton(info)
	  end
	end
	return dd
  end

  -- Select an entry by value instead of index; shows its text.
  local function SelectDropdownValue(dd, value)
	dd.selectedValue = value
	if dd.menuFunc then
	  for _, e in ipairs(dd.menuFunc()) do
		if e.value == value then
		  UIDropDownMenu_SetText(e.text, dd)
		  return
		end
	  end
	end
	UIDropDownMenu_SetText("", dd)
  end

  local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ffccEquipment Manager|r: " .. msg)
  end

  -- Strips a full item link down to the "item:..." string 1.12 tooltips want.
  local function ItemString(link)
	if not link then return nil end
	local _, _, s = string.find(link, "(item:[%-%d:]+)")
	return s or link
  end

  local subPanels = {}
  local function CreateSubPanel(name, width, height, titleText)
	local p = CreateFrame("Frame", name, frame)
	p:SetWidth(width); p:SetHeight(height)
	p:SetFrameStrata("HIGH")
	p:SetPoint("TOPLEFT", frame, "TOPRIGHT", -4, 0)
	p:EnableMouse(true)
	ApplyDialogBackdrop(p)
	p:Hide()

	p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.title:SetPoint("TOP", p, "TOP", 0, -14)
	p.title:SetText(titleText)

	p.close = CreateFrame("Button", name .. "Close", p, "UIPanelCloseButton")
	p.close:SetPoint("TOPRIGHT", p, "TOPRIGHT", 4, 4)
	p.close:SetScript("OnClick", function()
	  PlaySound("INTERFACESOUND_BACKPACKCLOSE")
	  p:Hide()
	end)

	table.insert(subPanels, p)
	return p
  end

  local function ToggleSubPanel(p)
	if p:IsShown() then
	  PlaySound("INTERFACESOUND_BACKPACKCLOSE")
	  p:Hide()
	  return
	end
	for _, other in ipairs(subPanels) do other:Hide() end
	PlaySound("INTERFACESOUND_BACKPACKOPEN")
	p:Show()
  end

  -- Items not in any set
  local WHERE_ORDER = { equipped = 1, bags = 2, bank = 3 }
  local BANK_BAGS	= { -1, 5, 6, 7, 8, 9, 10 }  -- main bank, bank bags

  local bankOpen = false

  -- Returns the list of equippable items that no equipment set references,
  -- plus how many of those are on the ignore list. Ignored items are only
  -- included in the list when includeIgnored is set.
  local function ScanUnusedItems(includeIgnored)
	local minQuality = tonumber(db.config.unusedquality) or 0
	local result, numIgnored = {}, 0

	local function Consider(entry)
	  if not entry.itemID then return end
	  entry.icon	= C_Item.GetItemIconByID(entry.itemID)
	  entry.quality = C_Item.GetItemQualityByID(entry.itemID) or 1
	  if entry.quality < minQuality then return end
	  if db.ignore[entry.itemID] then
		numIgnored = numIgnored + 1
		if not includeIgnored then return end
		entry.ignored = true
	  end
	  table.insert(result, entry)
	end

	-- Packed location of every item some set uses. Paperdoll and bag items
	-- always resolve, so these match GetInventoryItemsForSlot's keys.
	local inSet = {}
	for _, setID in ipairs(GetVisibleSetIDs()) do
	  for _, location in pairs(C_EquipmentSet.GetItemLocations(setID) or {}) do
		inSet[location] = true
	  end
	end

	-- Everything on the paperdoll or in the bags that fits a gear slot,
	-- keyed by packed location (rings and trinkets fit two slots).
	local items = {}
	for invSlot = 1, 19 do GetInventoryItemsForSlot(invSlot, items) end

	for location in pairs(items) do
	  if not inSet[location] then
		local loc = UnpackLocation(location)
		if not loc.isBank then
		  local link
		  if loc.isBags then
			link = GetContainerItemLink(loc.bag, loc.slot)
		  else
			link = GetInventoryItemLink("player", loc.slot)
		  end
		  if link then
			Consider({
			  where  = loc.isBags and "bags" or "equipped",
			  bag	 = loc.isBags and loc.bag or nil,
			  slot	 = loc.slot,
			  itemID = (C_Item.GetItemInfoInstant(link)),
			  link	 = link,
			})
		  end
		end
	  end
	end

	if db.config.unusedbank then
	  for _, item in ipairs(db.bank) do
		if not item.inSet then
		  Consider({ where = "bank", bag = item.bag, slot = item.slot, itemID = item.id, link = item.link })
		end
	  end
	end

	table.sort(result, function(a, b)
	  if a.where ~= b.where then return WHERE_ORDER[a.where] < WHERE_ORDER[b.where] end
	  if a.quality ~= b.quality then return a.quality > b.quality end
	  if a.itemID ~= b.itemID then return a.itemID < b.itemID end
	  if a.bag ~= b.bag then return (a.bag or 0) < (b.bag or 0) end
	  return a.slot < b.slot
	end)

	return result, numIgnored
  end

  -- Snapshot the bank while it's open so its items stay listed afterwards.
  -- Set membership is recorded now as well: ClassicAPI only resolves set
  -- items in the bank while the bank window is open.
  local function ScanBank()
	local snapshot = {}
	for _, bag in ipairs(BANK_BAGS) do
	  for slot = 1, (GetContainerNumSlots(bag) or 0) do
		local itemID = C_Container.GetContainerItemID(bag, slot)
		if itemID then
		  local link = GetContainerItemLink(bag, slot)
		  if link and C_Item.IsEquippableItem(link) then
			table.insert(snapshot, {
			  id = itemID, link = link, bag = bag, slot = slot,
			  inSet = C_Container.GetContainerItemEquipmentSetInfo(bag, slot) and true or nil,
			})
		  end
		end
	  end
	end
	db.bank = snapshot
  end

  local UNUSED_COLS, UNUSED_ROWS = 7, 8
  local UNUSED_SIZE, UNUSED_GAP	 = 30, 4
  local UNUSED_STRIDE			 = UNUSED_SIZE + UNUSED_GAP

  local unusedPanel = CreateSubPanel("STEqMgrUnusedFrame",
	UNUSED_COLS * UNUSED_STRIDE + 44, 440, "Items Not In Any Set")
  unusedPanel.offset = 0  -- first visible row

  unusedPanel.info = unusedPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  unusedPanel.info:SetPoint("TOPLEFT", unusedPanel, "TOPLEFT", 20, -40)
  unusedPanel.info:SetJustifyH("LEFT")

  unusedPanel.showIgnored = CreateCheckbox(unusedPanel, "Show Ignored", true)
  unusedPanel.showIgnored:SetPoint("TOPRIGHT", unusedPanel, "TOPRIGHT", -16, -32)

  local unusedInset = CreateFrame("Frame", nil, unusedPanel)
  unusedInset:SetPoint("TOPLEFT", unusedPanel, "TOPLEFT", 14, -58)
  unusedInset:SetWidth(UNUSED_COLS * UNUSED_STRIDE + 16)
  unusedInset:SetHeight(UNUSED_ROWS * UNUSED_STRIDE + 16)
  ApplyInsetBackdrop(unusedInset)

  local unusedGrid = CreateFrame("Frame", nil, unusedInset)
  unusedGrid:SetPoint("TOPLEFT", unusedInset, "TOPLEFT", 8, -8)
  unusedGrid:SetWidth(UNUSED_COLS * UNUSED_STRIDE)
  unusedGrid:SetHeight(UNUSED_ROWS * UNUSED_STRIDE)
  unusedGrid:EnableMouseWheel(true)

  unusedPanel.empty = unusedPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  unusedPanel.empty:SetPoint("CENTER", unusedGrid, "CENTER", 0, 0)
  unusedPanel.empty:SetWidth(UNUSED_COLS * UNUSED_STRIDE - 10)
  unusedPanel.empty:SetText("Every equippable item is part of a set.")

  -- Options: minimum quality and whether to list the bank.
  unusedPanel.qualityLabel = unusedPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  unusedPanel.qualityLabel:SetPoint("TOPLEFT", unusedInset, "BOTTOMLEFT", 6, -12)
  unusedPanel.qualityLabel:SetText("Min. Quality")

  local ddQuality = CreateDropdown(unusedPanel, 90)
  ddQuality:SetPoint("LEFT", unusedPanel.qualityLabel, "RIGHT", -10, -2)

  unusedPanel.includeBank = CreateCheckbox(unusedPanel, "Bank", true)
  unusedPanel.includeBank:SetPoint("TOPRIGHT", unusedInset, "BOTTOMRIGHT", -2, -5)

  unusedPanel.hint = unusedPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  unusedPanel.hint:SetPoint("BOTTOMLEFT", unusedPanel, "BOTTOMLEFT", 20, 18)
  unusedPanel.hint:SetPoint("BOTTOMRIGHT", unusedPanel, "BOTTOMRIGHT", -20, 18)
  unusedPanel.hint:SetJustifyH("LEFT")
  unusedPanel.hint:SetText("Shift-Click: Link  Ctrl-Click: Preview\nRight-Click: Ignore / Unignore")

  local RefreshUnusedPanel  -- forward decl
  local unusedButtons = {}

  -- Bag highlight: while the panel is open, items of the list glow in the
  -- Blizzard bag and bank frames and every other item is dimmed.
  local bagHighlight = { active = false, locs = {}, hooked = false }

  local function ApplyBagHighlight(f, bag, slot)
	if not f then return end
	local o = f.stEqMgrUnused
	local hasItem = bag and slot and GetContainerItemInfo(bag, slot)

	if not bagHighlight.active or not hasItem or not f:IsVisible() then
	  if o then o:Hide() end
	  return
	end

	if not o then
	  o = CreateFrame("Frame", nil, f)
	  o:SetAllPoints(f)
	  o:SetFrameLevel(f:GetFrameLevel() + 3)

	  o.dim = o:CreateTexture(nil, "OVERLAY")
	  o.dim:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	  o.dim:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	  o.dim:SetTexture(0, 0, 0, .7)

	  o.glow = o:CreateTexture(nil, "OVERLAY")
	  o.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	  o.glow:SetBlendMode("ADD")
	  o.glow:SetVertexColor(.2, 1, .2, 1)
	  o.glow:SetPoint("CENTER", f, "CENTER", 0, 0)

	  f.stEqMgrUnused = o
	end

	if bagHighlight.locs[bag] and bagHighlight.locs[bag][slot] then
	  local w = f:GetWidth()
	  if w and w > 0 then o.glow:SetWidth(w * 1.8); o.glow:SetHeight(w * 1.8) end
	  o.dim:Hide()
	  -- oGlow already draws a rarity border here; stacking our green on it
	  -- tints it (e.g. purple + green = teal), so defer to oGlow.
	  if oGlow or IsAddOnLoaded("oGlow") then o.glow:Hide() else o.glow:Show() end
	else
	  o.glow:Hide()
	  o.dim:Show()
	end
	o:Show()
  end

  local MAX_CONTAINER_BUTTONS = MAX_CONTAINER_ITEMS or 36
  local NUM_BANK_BUTTONS	  = NUM_BANKGENERIC_SLOTS or 24

  local function DecorateContainerFrame(cf)
	if not cf or not cf.GetName then return end
	local name = cf:GetName()
	local bag  = cf:GetID()
	local shown = cf:IsShown()
	for j = 1, MAX_CONTAINER_BUTTONS do
	  local btn = _G[name .. "Item" .. j]
	  if not btn then break end
	  if shown and j <= (cf.size or 0) then
		ApplyBagHighlight(btn, bag, btn:GetID())
	  elseif btn.stEqMgrUnused then
		btn.stEqMgrUnused:Hide()
	  end
	end
  end

  local function DecorateBankFrame()
	for j = 1, NUM_BANK_BUTTONS do
	  local btn = _G["BankFrameItem" .. j]
	  if btn then ApplyBagHighlight(btn, -1, btn:GetID()) end
	end
  end

  local function UpdateBagHighlights()
	if not bagHighlight.hooked then
	  -- Re-apply whenever Blizzard redraws a bag or bank slot.
	  if ContainerFrame_Update then
		hooksecurefunc("ContainerFrame_Update", function(cf)
		  if bagHighlight.active then DecorateContainerFrame(cf) end
		end)
	  end
	  if BankFrameItemButton_Update then
		hooksecurefunc("BankFrameItemButton_Update", function(btn)
		  if bagHighlight.active and btn and btn.GetID then
			ApplyBagHighlight(btn, -1, btn:GetID())
		  end
		end)
	  end
	  bagHighlight.hooked = true
	end
	for i = 1, (NUM_CONTAINER_FRAMES or 12) do
	  DecorateContainerFrame(_G["ContainerFrame" .. i])
	end
	DecorateBankFrame()
  end

  local WHERE_TAG  = { equipped = "|cff33ff33E|r", bags = "", bank = "|cff66aaffB|r" }
  local WHERE_TEXT = { equipped = "Equipped", bags = "In Bags", bank = "In Bank" }

  local function CreateUnusedButton(i)
	local bname = NextName("UnusedBtn")
	local b = CreateFrame("Button", bname, unusedGrid, "ActionButtonTemplate")
	b:SetWidth(UNUSED_SIZE); b:SetHeight(UNUSED_SIZE)
	b:SetNormalTexture("")
	local col = math.mod(i - 1, UNUSED_COLS)
	local row = math.floor((i - 1) / UNUSED_COLS)
	b:SetPoint("TOPLEFT", unusedGrid, "TOPLEFT",
	  col * UNUSED_STRIDE + UNUSED_GAP / 2, -row * UNUSED_STRIDE - UNUSED_GAP / 2)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	b.icon = _G[bname .. "Icon"]

	-- Quality colored border, like the bag slots in the modern client.
	b.border = b:CreateTexture(nil, "OVERLAY")
	b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	b.border:SetBlendMode("ADD")
	b.border:SetWidth(UNUSED_SIZE * 1.8); b.border:SetHeight(UNUSED_SIZE * 1.8)
	b.border:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.border:Hide()

	b.tag = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	b.tag:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)

	b:SetScript("OnEnter", function()
	  local e = this.entry
	  if not e then return end
	  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	  if e.where == "equipped" then
		GameTooltip:SetInventoryItem("player", e.slot)
	  elseif e.where == "bags" then
		GameTooltip:SetBagItem(e.bag, e.slot)
	  else
		GameTooltip:SetHyperlink(ItemString(e.link))
	  end
	  GameTooltip:AddLine(" ")
	  GameTooltip:AddLine("Not part of any equipment set - " .. WHERE_TEXT[e.where], 1, .82, 0)
	  if e.ignored then
		GameTooltip:AddLine("Ignored (Right-Click to unignore)", .6, .6, .6)
	  end
	  GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)

	b:SetScript("OnClick", function()
	  local e = this.entry
	  if not e then return end
	  if arg1 == "RightButton" then
		db.ignore[e.itemID] = (not db.ignore[e.itemID]) and true or nil
		GameTooltip:Hide()
		PlaySound("igMainMenuOptionCheckBoxOn")
		eqmgr.Refresh()
	  elseif IsShiftKeyDown() then
		if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then ChatFrameEditBox:Insert(e.link) end
	  elseif IsControlKeyDown() then
		if DressUpItemLink then DressUpItemLink(e.link) end
	  end
	end)

	return b
  end

  unusedGrid:SetScript("OnMouseWheel", function()
	unusedPanel.offset = unusedPanel.offset - (arg1 or 0)
	RefreshUnusedPanel()
  end)

  local QUALITY_OPTIONS = {}
  for q = 0, 5 do
	local r, g, b, hex = GetItemQualityColor(q)
	local label = _G["ITEM_QUALITY" .. q .. "_DESC"] or tostring(q)
	table.insert(QUALITY_OPTIONS, { value = q, text = (hex or "") .. label .. (hex and "|r" or "") })
  end
  ddQuality.menuFunc = function()
	local menu = {}
	for _, o in ipairs(QUALITY_OPTIONS) do
	  local value = o.value
	  table.insert(menu, { text = o.text, value = value, func = function()
		db.config.unusedquality = value
		eqmgr.Refresh()
	  end })
	end
	return menu
  end

  function RefreshUnusedPanel()
	local showIgnored = unusedPanel.showIgnored:GetChecked() and true or nil
	local list, numIgnored = ScanUnusedItems(showIgnored)
	local total = table.getn(list)
	local numShownIgnored = showIgnored and numIgnored or 0
	unusedPanel.info:SetText(string.format("%d items, %d ignored", total - numShownIgnored, numIgnored))

	unusedPanel.includeBank:SetChecked(db.config.unusedbank and 1 or nil)
	SelectDropdownValue(ddQuality, tonumber(db.config.unusedquality) or 0)

	local totalRows = math.ceil(total / UNUSED_COLS)
	local maxOffset = math.max(0, totalRows - UNUSED_ROWS)
	if unusedPanel.offset > maxOffset then unusedPanel.offset = maxOffset end
	if unusedPanel.offset < 0 then unusedPanel.offset = 0 end
	local first = unusedPanel.offset * UNUSED_COLS

	for i = 1, UNUSED_COLS * UNUSED_ROWS do
	  local e = list[first + i]
	  local b = unusedButtons[i]
	  if e then
		if not b then
		  b = CreateUnusedButton(i)
		  unusedButtons[i] = b
		end
		b.entry = e
		b.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		b.icon:SetDesaturated(e.ignored and true or false)
		b.icon:SetAlpha(e.ignored and .5 or 1)
		b.tag:SetText(WHERE_TAG[e.where] or "")
		if (e.quality or 1) > 1 then
		  local r, g, bl = GetItemQualityColor(e.quality)
		  b.border:SetVertexColor(r, g, bl, 1)
		  b.border:Show()
		else
		  b.border:Hide()
		end
		b:Show()
	  elseif b then
		b.entry = nil
		b:Hide()
	  end
	end

	if total == 0 then unusedPanel.empty:Show() else unusedPanel.empty:Hide() end

	bagHighlight.active = true
	bagHighlight.locs = {}
	for _, e in ipairs(list) do
	  if e.bag then
		bagHighlight.locs[e.bag] = bagHighlight.locs[e.bag] or {}
		bagHighlight.locs[e.bag][e.slot] = true
	  end
	end
	UpdateBagHighlights()
  end

  unusedPanel.showIgnored:SetScript("OnClick", function() RefreshUnusedPanel() end)
  unusedPanel.includeBank:SetScript("OnClick", function()
	db.config.unusedbank = this:GetChecked() and true or false
	eqmgr.Refresh()
  end)
  unusedPanel:SetScript("OnShow", function() RefreshUnusedPanel() end)
  unusedPanel:SetScript("OnHide", function()
	CloseDropDownMenus()
	bagHighlight.active = false
	UpdateBagHighlights()
  end)

  local bankEvents = CreateFrame("Frame")
  bankEvents:RegisterEvent("BANKFRAME_OPENED")
  bankEvents:RegisterEvent("BANKFRAME_CLOSED")
  bankEvents:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
  bankEvents:RegisterEvent("BAG_UPDATE_DELAYED")
  bankEvents:RegisterEvent("EQUIPMENT_SETS_CHANGED")
  bankEvents:SetScript("OnEvent", function()
	if event == "BANKFRAME_OPENED" then
	  bankOpen = true
	elseif event == "BANKFRAME_CLOSED" then
	  bankOpen = false
	  return
	end
	if not bankOpen then return end
	ScanBank()
	if frame:IsShown() then eqmgr.Refresh() end
  end)

  -- Automatic set switching (triggers)
  local _, playerClass = UnitClass("player")

  -- Shapeshift form IDs as GetShapeshiftFormID reports them on this client
  -- (SpellShapeshiftForm.dbc). A value can list several IDs so e.g.
  -- "Bear Form" covers Dire Bear Form too.
  local FORM_OPTIONS = {
	DRUID = {
	  { value = "0",	text = "No Form (Caster)" },
	  { value = "5,8",	text = "Bear Form" },
	  { value = "1",	text = "Cat Form" },
	  { value = "3,11", text = "Travel Form" },
	  { value = "4",	text = "Aquatic Form" },
	  { value = "31",	text = "Moonkin Form" },
	  { value = "2,9",	text = "Tree of Life Form" },
	},
	WARRIOR = {
	  { value = "17", text = "Battle Stance" },
	  { value = "18", text = "Defensive Stance" },
	  { value = "19", text = "Berserker Stance" },
	},
	ROGUE  = { { value = "30", text = "Stealth" } },
	SHAMAN = { { value = "16", text = "Ghost Wolf" } },
	PRIEST = { { value = "28", text = "Shadowform" } },
  }
  local myForms = FORM_OPTIONS[playerClass]
  if myForms then table.insert(myForms, { value = "any", text = "Any Form" }) end

  local INSTANCE_OPTIONS = {
	{ value = "party", text = "Dungeon" },
	{ value = "raid",  text = "Raid" },
	{ value = "pvp",   text = "Battleground" },
	{ value = "none",  text = "Open World" },
  }

  -- value: nil (no parameter), "list" (dropdown from .options) or "text".
  local TRIGGER_TYPES = {
	{ key = "mounted",	text = "Mounted" },
	{ key = "swimming", text = "Swimming" },
	{ key = "dining",	text = "Eating / Drinking" },
	{ key = "resting",	text = "Resting (Inn / City)" },
	{ key = "stealth",	text = "Stealthed" },
	{ key = "form",		text = "Shapeshift Form / Stance", value = "list", options = myForms },
	{ key = "instance", text = "Instance Type", value = "list", options = INSTANCE_OPTIONS },
	{ key = "zone",		text = "Zone", value = "text" },
	{ key = "boss",		text = "Targeting A Boss" },
	{ key = "time",		text = "Time Of Day", value = "text" },
  }
  local TRIGGER_TYPE = {}
  for _, info in ipairs(TRIGGER_TYPES) do TRIGGER_TYPE[info.key] = info end

  local function DefaultTriggerValue(key)
	if key == "form" then return myForms and myForms[1].value end
	if key == "instance" then return "raid" end
	if key == "zone" then return GetRealZoneText() end
	if key == "time" then return "20:00-23:00" end
  end

  local function DescribeTrigger(t)
	local info = TRIGGER_TYPE[t.type]
	if not info then return "?" end
	if info.value == "list" then
	  for _, o in ipairs(info.options or {}) do
		if o.value == t.value then return info.text .. ": " .. o.text end
	  end
	  return info.text
	elseif info.value == "text" then
	  return info.text .. ": " .. (t.value or "")
	end
	return info.text
  end

  -- Condition checks

  -- Every food and drink buff shares the name of the base Food (433) or
  -- Drink (430) aura, so their localized names identify all of them.
  local DINING_AURAS = {}
  for _, spellID in ipairs({ 433, 430 }) do
	local n = C_Spell.GetSpellName(spellID)
	if n then table.insert(DINING_AURAS, n) end
  end

  -- Like Outfitter: the dining set stays on only while there's still
  -- health or mana to regenerate, so it comes off as soon as you're full.
  local function IsDining()
	local healthFull = UnitHealth("player") >= UnitHealthMax("player")
	local manaFull = UnitPowerType("player") ~= 0 or UnitMana("player") >= UnitManaMax("player")
	if healthFull and manaFull then return false end
	for _, name in ipairs(DINING_AURAS) do
	  if C_UnitAuras.GetAuraDataBySpellName("player", name, "HELPFUL") then return true end
	end
	return false
  end

  local function InForm(value)
	local formID = GetShapeshiftFormID() or 0
	if value == "any" then return formID ~= 0 end
	for _, id in ipairs({ strsplit(",", value or "") }) do
	  if tonumber(id) == formID then return true end
	end
	return false
  end

  -- Zone trigger values are "zone; subzone; ..." as typed or added with "Here".
  local function ZoneEntries(value)
	local entries = {}
	for _, entry in ipairs({ strsplit(";", value or "") }) do
	  entry = string.lower(strtrim(entry))
	  if entry ~= "" then table.insert(entries, entry) end
	end
	return entries
  end

  local function InZone(value)
	local zone	  = string.lower(GetRealZoneText() or "")
	local subzone = string.lower(GetSubZoneText() or "")
	local minimap = string.lower(GetMinimapZoneText() or "")
	for _, entry in ipairs(ZoneEntries(value)) do
	  if entry == zone or entry == subzone or entry == minimap then return true end
	end
	return false
  end

  local function ParseTimeWindow(value)
	local _, _, h1, m1, h2, m2 = string.find(value or "",
	  "^%s*(%d%d?):(%d%d)%s*%-%s*(%d%d?):(%d%d)%s*$")
	if not h1 then return nil end
	return tonumber(h1) * 60 + tonumber(m1), tonumber(h2) * 60 + tonumber(m2)
  end

  local function InTimeWindow(value)
	local from, to = ParseTimeWindow(value)
	if not from then return false end
	local now = tonumber(date("%H")) * 60 + tonumber(date("%M"))
	if from <= to then return now >= from and now < to end
	return now >= from or now < to  -- window wraps past midnight
  end

  local function TargetIsBoss()
	if not UnitExists("target") or UnitIsDead("target") then return false end
	if not UnitCanAttack("player", "target") or UnitIsPlayer("target") then return false end
	return UnitClassification("target") == "worldboss" or UnitLevel("target") == -1
  end

  local function ConditionActive(t)
	local key = t.type
	if key == "mounted" then return IsMounted() and true or false
	elseif key == "swimming" then return IsSwimming() and true or false
	elseif key == "dining" then return IsDining()
	elseif key == "resting" then return IsResting() and true or false
	elseif key == "stealth" then return IsStealthed() and true or false
	elseif key == "form" then return InForm(t.value)
	elseif key == "instance" then
	  local _, instanceType = GetInstanceInfo()
	  return instanceType == t.value
	elseif key == "zone" then return InZone(t.value)
	elseif key == "boss" then return TargetIsBoss()
	elseif key == "time" then return InTimeWindow(t.value)
	end
	return false
  end

  -- Engine

  -- forceApply: the active trigger was edited, equip its (new) set again.
  local engine = { ready = false, timer = nil, poll = nil, forceApply = nil }

  local function FindTrigger(id)
	if not id then return nil end
	for i, t in ipairs(db.triggers) do
	  if t.id == id then return t, i end
	end
  end

  local function SetExists(setID)
	return setID and C_EquipmentSet.GetEquipmentSetInfo(setID) and not IsRestoreSet(setID)
  end

  local function TriggerUsable(t)
	return t.enabled and SetExists(t.setID) and TRIGGER_TYPE[t.type] and true or false
  end

  -- Highest-priority (topmost) enabled trigger whose condition holds.
  local function GetActiveTrigger()
	for _, t in ipairs(db.triggers) do
	  if TriggerUsable(t) and ConditionActive(t) then return t end
	end
  end

  -- Whether the applied trigger differs from the one that should be, and
  -- the one that should be.
  local function NeedsSwitch()
	local best = GetActiveTrigger()
	return engine.forceApply or (best and best.id or 0) ~= (db.applied or 0), best
  end

  -- Gear can't change in combat or while dead, swapping mid-cast would
  -- interrupt it, and only one set swap runs at a time: the switch waits.
  local function SwapBlocked(setID)
	if UnitAffectingCombat("player") or UnitIsDeadOrGhost("player") then return true end
	if C_Spell.UnitCastingInfo("player") or C_Spell.UnitChannelInfo("player") then return true end
	if CursorHasItem() or not C_EquipmentSet.CanUseEquipmentSets() then return true end
	return C_EquipmentSet.EquipmentSetContainsLockedItems(setID)
  end

  -- A swap that's blocked or refused is retried by scheduling again.
  local function TryEquip(setID)
	return not SwapBlocked(setID) and C_EquipmentSet.UseEquipmentSet(setID)
  end

  -- Remember the gear worn before the first trigger fires. Only slots that
  -- some trigger set actually changes are recorded, so restoring doesn't
  -- undo unrelated gear changes made while the trigger was active.
  local function TakeRestoreSnapshot()
	local touched = {}
	for _, t in ipairs(db.triggers) do
	  if TriggerUsable(t) then
		local ignored = {}
		for _, s in ipairs(C_EquipmentSet.GetIgnoredSlots(t.setID) or {}) do ignored[s] = true end
		for s = 1, 19 do
		  if not ignored[s] then touched[s] = true end
		end
	  end
	end

	C_EquipmentSet.ClearIgnoredSlotsForSave()
	for s = 1, 19 do
	  if not touched[s] then C_EquipmentSet.IgnoreSlotForSave(s) end
	end
	local id = C_EquipmentSet.GetEquipmentSetID(RESTORE_SET_NAME)
	if id then
	  C_EquipmentSet.SaveEquipmentSet(id)
	else
	  C_EquipmentSet.CreateEquipmentSet(RESTORE_SET_NAME, "Spell_Nature_TimeStop")
	end
	C_EquipmentSet.ClearIgnoredSlotsForSave()
  end

  local function Announce(msg)
	if db.config.announce then Print(msg) end
  end

  local function SetName(setID)
	return (C_EquipmentSet.GetEquipmentSetInfo(setID)) or "?"
  end

  local RefreshTriggerPanel  -- forward decl
  local Schedule			 -- forward decl

  local function Evaluate()
	if not engine.ready or not db.config.autoswitch then return end

	local needed, best = NeedsSwitch()
	if not needed then return end
	local appliedID = db.applied or 0

	if best then
	  if SwapBlocked(best.setID) then return Schedule() end
	  -- Only the first trigger in a chain records what to go back to.
	  if appliedID == 0 then TakeRestoreSnapshot() end
	  if not C_EquipmentSet.UseEquipmentSet(best.setID) then return Schedule() end
	  db.applied = best.id
	  Announce(string.format("Equipping %s (%s)", SetName(best.setID), DescribeTrigger(best)))
	else
	  local prev = FindTrigger(appliedID)
	  local leave = prev and prev.leave or "restore"
	  local restoreID = C_EquipmentSet.GetEquipmentSetID(RESTORE_SET_NAME)
	  if leave == "restore" and restoreID then
		if not TryEquip(restoreID) then return Schedule() end
		Announce("Restoring previous gear")
	  elseif type(leave) == "number" and SetExists(leave) then
		if not TryEquip(leave) then return Schedule() end
		Announce(string.format("Equipping %s", SetName(leave)))
	  end
	  -- The swap copied the item GUIDs when it started; the set can go.
	  if restoreID then C_EquipmentSet.DeleteEquipmentSet(restoreID) end
	  db.applied = nil
	end

	engine.forceApply = nil
	RefreshTriggerPanel()
  end

  -- Switch half a second after something changed, so bobbing at the water
  -- surface or a quick target swap doesn't thrash gear. Also retries a
  -- swap that's blocked.
  function Schedule()
	if engine.timer then return end
	engine.timer = C_Timer.NewTimer(0.5, function()
	  engine.timer = nil
	  Evaluate()
	end)
  end

  -- Swimming and the time of day fire no event, so those are polled while
  -- a trigger needs them.
  local POLLED = { swimming = true, time = true }

  local engineEvents = CreateFrame("Frame")

  -- Call after any change to the triggers or the autoswitch setting.
  local function UpdateEngine()
	local poll, dining = false, false
	if db.config.autoswitch then
	  for _, t in ipairs(db.triggers) do
		if t.enabled and POLLED[t.type] then poll = true end
		if t.enabled and t.type == "dining" then dining = true end
	  end
	end

	-- The dining set comes off once health and mana are full; these fire
	-- constantly in combat, so only listen while a dining trigger exists.
	if dining then
	  engineEvents:RegisterUnitEvent("UNIT_HEALTH", "player")
	  engineEvents:RegisterUnitEvent("UNIT_MANA", "player")
	else
	  engineEvents:UnregisterEvent("UNIT_HEALTH")
	  engineEvents:UnregisterEvent("UNIT_MANA")
	end

	if poll and not engine.poll then
	  engine.poll = C_Timer.NewTicker(0.5, function()
		if NeedsSwitch() then Schedule() end
	  end)
	elseif not poll and engine.poll then
	  engine.poll:Cancel()
	  engine.poll = nil
	end
	Schedule()
  end

  engineEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
  engineEvents:RegisterEvent("PLAYER_LEAVING_WORLD")
  engineEvents:RegisterUnitEvent("UNIT_AURA", "player") -- mounted, stealth, dining
  engineEvents:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
  engineEvents:RegisterEvent("ZONE_CHANGED")
  engineEvents:RegisterEvent("ZONE_CHANGED_INDOORS")
  engineEvents:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  engineEvents:RegisterEvent("PLAYER_UPDATE_RESTING")
  engineEvents:RegisterEvent("PLAYER_TARGET_CHANGED")
  engineEvents:RegisterEvent("PLAYER_REGEN_ENABLED")	-- a boss target died mid-fight
  engineEvents:SetScript("OnEvent", function()
	if event == "PLAYER_LEAVING_WORLD" then
	  engine.ready = false
	elseif event == "PLAYER_ENTERING_WORLD" then
	  -- Zone/instance info is unreliable right after a loading screen.
	  engine.ready = false
	  C_Timer.After(3, function()
		engine.ready = true
		Schedule()
	  end)
	else
	  Schedule()
	end
  end)

  -- This file runs from PLAYER_LOGIN, after the first PLAYER_ENTERING_WORLD
  -- may already have been dispatched, so arm the engine once here as well.
  C_Timer.After(3, function()
	engine.ready = true
	Schedule()
  end)

  -- Trigger editor panel
  local TRIGGER_ROWS, TRIGGER_ROW_H = 5, 24
  local TRIGGER_STRIDE = TRIGGER_ROW_H + 2
  local TRIGGER_LIST_W = 296
  local triggerPanel = CreateSubPanel("STEqMgrTriggerFrame", TRIGGER_LIST_W + 36, 470, "Automatic Set Switching")
  local selectedTriggerID = nil
  triggerPanel.offset = 0

  local cbAuto = CreateCheckbox(triggerPanel, "Enable Automatic Set Switching")
  cbAuto:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", 16, -30)
  cbAuto:SetScript("OnClick", function()
	db.config.autoswitch = this:GetChecked() and true or false
	UpdateEngine()
	RefreshTriggerPanel()
  end)

  local cbAnnounce = CreateCheckbox(triggerPanel, "Announce Switches In Chat")
  cbAnnounce:SetPoint("TOPLEFT", cbAuto, "BOTTOMLEFT", 0, 4)
  cbAnnounce:SetScript("OnClick", function()
	db.config.announce = this:GetChecked() and true or false
  end)

  local triggerList = CreateFrame("Frame", nil, triggerPanel)
  triggerList:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", 18, -80)
  triggerList:SetWidth(TRIGGER_LIST_W)
  triggerList:SetHeight(TRIGGER_ROWS * TRIGGER_STRIDE + 10)
  ApplyInsetBackdrop(triggerList)
  triggerList:EnableMouseWheel(true)
  triggerList:SetScript("OnMouseWheel", function()
	triggerPanel.offset = triggerPanel.offset - (arg1 or 0)
	RefreshTriggerPanel()
  end)

  triggerList.empty = triggerList:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  triggerList.empty:SetPoint("CENTER", triggerList, "CENTER", 0, 0)
  triggerList.empty:SetWidth(TRIGGER_LIST_W - 20)
  triggerList.empty:SetText("No triggers yet. Click \"New Trigger\" to add one.")

  local function MoveTrigger(index, delta)
	local target = index + delta
	if target < 1 or target > table.getn(db.triggers) then return end
	db.triggers[index], db.triggers[target] = db.triggers[target], db.triggers[index]
	UpdateEngine()
	RefreshTriggerPanel()
  end

  local triggerRows = {}
  for i = 1, TRIGGER_ROWS do
	local row = CreateFrame("Button", nil, triggerList)
	row:SetWidth(TRIGGER_LIST_W - 12); row:SetHeight(TRIGGER_ROW_H)
	row:SetPoint("TOPLEFT", triggerList, "TOPLEFT", 6, -5 - (i - 1) * TRIGGER_STRIDE)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.selTex = row:CreateTexture(nil, "BACKGROUND")
	row.selTex:SetAllPoints(row)
	row.selTex:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
	row.selTex:SetBlendMode("ADD")
	row.selTex:SetVertexColor(0.4, 0.35, 0.1, 0.9)
	row.selTex:Hide()

	row.check = CreateCheckbox(row)
	row.check:SetPoint("LEFT", row, "LEFT", 0, 0)
	row.check:SetScript("OnClick", function()
	  local r = this:GetParent()
	  if not r.trigger then return end
	  r.trigger.enabled = this:GetChecked() and true or false
	  if not r.trigger.enabled and db.applied == r.trigger.id then engine.forceApply = nil end
	  UpdateEngine()
	  RefreshTriggerPanel()
	end)

	row.delete = CreateDeleteButton(row)
	row.delete:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.down = CreateArrowButton(row, "down")
	row.down:SetPoint("RIGHT", row.delete, "LEFT", 0, 0)
	row.up = CreateArrowButton(row, "up")
	row.up:SetPoint("RIGHT", row.down, "LEFT", 0, 0)

	row.up:SetScript("OnClick", function()
	  local r = this:GetParent()
	  if r.index then MoveTrigger(r.index, -1) end
	end)
	row.down:SetScript("OnClick", function()
	  local r = this:GetParent()
	  if r.index then MoveTrigger(r.index, 1) end
	end)
	row.delete:SetScript("OnClick", function()
	  local r = this:GetParent()
	  if not r.index then return end
	  local t = table.remove(db.triggers, r.index)
	  if t and t.id == selectedTriggerID then selectedTriggerID = nil end
	  PlaySound("igMainMenuOptionCheckBoxOn")
	  UpdateEngine()
	  RefreshTriggerPanel()
	end)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
	row.text:SetPoint("RIGHT", row.up, "LEFT", -4, 0)
	row.text:SetJustifyH("LEFT")

	row:SetScript("OnClick", function()
	  if not this.trigger then return end
	  selectedTriggerID = this.trigger.id
	  PlaySound("igMainMenuOptionFaerTab")
	  RefreshTriggerPanel()
	end)

	row:SetScript("OnEnter", function()
	  local t = this.trigger
	  if not t then return end
	  GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	  GameTooltip:SetText(DescribeTrigger(t), 1, 1, 1)
	  local equip = SetExists(t.setID) and SetName(t.setID) or ("|cffff5555No set selected|r")
	  GameTooltip:AddDoubleLine("Equip", equip, .7, .7, .7, 1, 1, 1)
	  local leave = "Restore Previous Gear"
	  if t.leave == "none" then leave = "Do Nothing"
	  elseif type(t.leave) == "number" then leave = SetExists(t.leave) and SetName(t.leave) or "?" end
	  GameTooltip:AddDoubleLine("When It Ends", leave, .7, .7, .7, 1, 1, 1)
	  if db.applied == t.id then
		GameTooltip:AddLine("Currently active", .2, 1, .2)
	  elseif TriggerUsable(t) and ConditionActive(t) then
		GameTooltip:AddLine("Condition met, but a trigger higher in the list wins", 1, .82, 0, 1)
	  end
	  GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	triggerRows[i] = row
  end

  local btnNewTrigger = CreateFrame("Button", "STEqMgrNewTrigger", triggerPanel, "UIPanelButtonTemplate")
  btnNewTrigger:SetWidth(110); btnNewTrigger:SetHeight(22)
  btnNewTrigger:SetPoint("TOPLEFT", triggerList, "BOTTOMLEFT", 0, -6)
  btnNewTrigger:SetText("New Trigger")
  btnNewTrigger:SetScript("OnClick", function()
	local ids = GetVisibleSetIDs()
	local t = {
	  id	  = db.nextID,
	  enabled = true,
	  type	  = "mounted",
	  setID   = ids[1],
	  leave   = "restore",
	}
	db.nextID = db.nextID + 1
	table.insert(db.triggers, t)
	selectedTriggerID = t.id
	PlaySound("igMainMenuOptionCheckBoxOn")
	-- Scroll so the new trigger is visible.
	triggerPanel.offset = math.max(0, table.getn(db.triggers) - TRIGGER_ROWS)
	UpdateEngine()
	RefreshTriggerPanel()
  end)

  -- Editor for the selected trigger
  local editor = CreateFrame("Frame", nil, triggerPanel)
  editor:SetPoint("TOPLEFT", btnNewTrigger, "BOTTOMLEFT", 0, -10)
  editor:SetWidth(TRIGGER_LIST_W); editor:SetHeight(132)

  editor.header = editor:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  editor.header:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, 0)
  editor.header:SetText("Selected Trigger")

  local EDITOR_ROW_Y = { -20, -48, -76, -104 }
  local EDITOR_FIELD_W = 190
  local function EditorLabel(text, row)
	local fs = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, EDITOR_ROW_Y[row] - 8)
	fs:SetText(text)
	return fs
  end

  local function EditorDropdown(row)
	-- UIDropDownMenuTemplate draws its box ~16px inside the frame on each
	-- side, so it is widened and shifted to line up with the text box.
	local dd = CreateDropdown(editor, EDITOR_FIELD_W - 24)
	dd:SetPoint("TOPRIGHT", editor, "TOPRIGHT", 16, EDITOR_ROW_Y[row] + 2)
	return dd
  end

  local function SelectedTrigger()
	return FindTrigger(selectedTriggerID)
  end

  local function OnTriggerEdited()
	-- Re-evaluate from scratch: the edit may change which trigger wins,
	-- and an edited active trigger may now point at another set.
	if selectedTriggerID and selectedTriggerID == db.applied then engine.forceApply = true end
	UpdateEngine()
	RefreshTriggerPanel()
  end

  EditorLabel("When", 1)
  local ddType = EditorDropdown(1)
  ddType.menuFunc = function()
	local menu = {}
	for _, info in ipairs(TRIGGER_TYPES) do
	  if info.value ~= "list" or info.options then
		local key = info.key
		table.insert(menu, { text = info.text, value = key, func = function()
		  local t = SelectedTrigger()
		  if not t or t.type == key then return end
		  t.type = key
		  t.value = DefaultTriggerValue(key)
		  OnTriggerEdited()
		end })
	  end
	end
	return menu
  end

  local valueLabel = EditorLabel("Value", 2)
  local ddValue = EditorDropdown(2)
  ddValue.menuFunc = function()
	local menu = {}
	local t = SelectedTrigger()
	local info = t and TRIGGER_TYPE[t.type]
	for _, o in ipairs(info and info.options or {}) do
	  local value = o.value
	  table.insert(menu, { text = o.text, value = value, func = function()
		local t = SelectedTrigger()
		if not t then return end
		t.value = value
		OnTriggerEdited()
	  end })
	end
	return menu
  end

  local editValue = CreateFrame("EditBox", "STEqMgrTriggerValueEdit", editor, "InputBoxTemplate")
  editValue:SetHeight(20)
  editValue:SetAutoFocus(false)
  editValue:SetMaxLetters(255)
  editValue:SetScript("OnTextChanged", function()
	if this.updating then return end
	local t = SelectedTrigger()
	if not t then return end
	t.value = this:GetText()
	local valid = t.type ~= "time" or ParseTimeWindow(t.value)
	this:SetTextColor(1, valid and 1 or .3, valid and 1 or .3)
	Schedule()
  end)
  editValue:SetScript("OnEnterPressed", function()
	this:ClearFocus()
	RefreshTriggerPanel()
  end)
  editValue:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  editValue:SetScript("OnEditFocusGained", function() this.hasFocus = true end)
  editValue:SetScript("OnEditFocusLost", function()
	this.hasFocus = nil
	RefreshTriggerPanel()
  end)
  editValue:SetScript("OnEnter", function()
	local t = SelectedTrigger()
	if not t then return end
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	if t.type == "zone" then
	  GameTooltip:SetText("Zone or subzone name", 1, 1, 1)
	  GameTooltip:AddLine("Separate several zones with ;", .8, .8, .8, 1)
	else
	  GameTooltip:SetText("Local time window, e.g. 20:00-23:00", 1, 1, 1)
	  GameTooltip:AddLine("Windows may wrap past midnight (22:00-02:00).", .8, .8, .8, 1)
	end
	GameTooltip:Show()
  end)
  editValue:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local btnCurrentZone = CreateFrame("Button", "STEqMgrTriggerHere", editor, "UIPanelButtonTemplate")
  btnCurrentZone:SetWidth(50); btnCurrentZone:SetHeight(20)
  btnCurrentZone:SetPoint("TOPRIGHT", editor, "TOPRIGHT", 0, EDITOR_ROW_Y[2] - 2)
  btnCurrentZone:SetText("Here")
  btnCurrentZone:SetScript("OnEnter", function()
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	GameTooltip:SetText("Add the current zone", 1, 1, 1)
	local sub = GetSubZoneText() or ""
	GameTooltip:AddLine(GetRealZoneText() .. ((sub ~= "") and (" / " .. sub) or ""), .8, .8, .8)
	GameTooltip:AddLine("Shift-Click adds the subzone instead.", .8, .8, .8)
	GameTooltip:Show()
  end)
  btnCurrentZone:SetScript("OnLeave", function() GameTooltip:Hide() end)
  btnCurrentZone:SetScript("OnClick", function()
	local t = SelectedTrigger()
	if not t then return end
	-- Shift adds the subzone instead of the zone.
	local here = IsShiftKeyDown() and GetSubZoneText() or GetRealZoneText()
	if not here or here == "" then here = GetRealZoneText() end
	local entries = ZoneEntries(t.value)
	if table.getn(entries) == 0 then
	  t.value = here
	else
	  for _, entry in ipairs(entries) do
		if entry == string.lower(here) then return end
	  end
	  t.value = t.value .. "; " .. here
	end
	OnTriggerEdited()
  end)

  EditorLabel("Equip", 3)
  local ddSet = EditorDropdown(3)
  ddSet.menuFunc = function()
	local menu = {}
	for _, id in ipairs(GetVisibleSetIDs()) do
	  local setID = id
	  table.insert(menu, { text = SetName(setID), value = setID, func = function()
		local t = SelectedTrigger()
		if not t then return end
		t.setID = setID
		OnTriggerEdited()
	  end })
	end
	return menu
  end

  EditorLabel("When It Ends", 4)
  local ddLeave = EditorDropdown(4)
  ddLeave.menuFunc = function()
	local function Choose(value)
	  return function()
		local t = SelectedTrigger()
		if not t then return end
		t.leave = value
		OnTriggerEdited()
	  end
	end
	local menu = {
	  { text = "Restore Previous Gear", value = "restore", func = Choose("restore") },
	  { text = "Do Nothing",			value = "none",    func = Choose("none") },
	}
	for _, id in ipairs(GetVisibleSetIDs()) do
	  table.insert(menu, { text = "Equip " .. SetName(id), value = id, func = Choose(id) })
	end
	return menu
  end

  editor.noSets = editor:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  editor.noSets:SetPoint("TOPRIGHT", editor, "TOPRIGHT", 0, EDITOR_ROW_Y[3] - 8)
  editor.noSets:SetText("Create an equipment set first.")

  local triggerHint = triggerPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  triggerHint:SetPoint("BOTTOMLEFT", triggerPanel, "BOTTOMLEFT", 20, 18)
  triggerHint:SetPoint("BOTTOMRIGHT", triggerPanel, "BOTTOMRIGHT", -20, 18)
  triggerHint:SetHeight(40)
  triggerHint:SetJustifyH("LEFT")
  triggerHint:SetJustifyV("BOTTOM")
  triggerHint:SetText("Triggers higher in the list take priority. Gear is never swapped in combat, while dead or while casting: the switch waits until it can happen.")

  editor.placeholder = triggerPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  editor.placeholder:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, -30)
  editor.placeholder:SetPoint("TOPRIGHT", editor, "TOPRIGHT", 0, -30)
  editor.placeholder:SetText("Select a trigger to edit it.")

  local function RefreshTriggerRows()
	cbAuto:SetChecked(db.config.autoswitch and 1 or nil)
	cbAnnounce:SetChecked(db.config.announce and 1 or nil)

	local num = table.getn(db.triggers)
	local maxOffset = math.max(0, num - TRIGGER_ROWS)
	if triggerPanel.offset > maxOffset then triggerPanel.offset = maxOffset end
	if triggerPanel.offset < 0 then triggerPanel.offset = 0 end

	for i, row in ipairs(triggerRows) do
	  local index = i + triggerPanel.offset
	  local t = db.triggers[index]
	  if t then
		row.trigger = t
		row.index = index
		row.check:SetChecked(t.enabled and 1 or nil)

		local color = "|cffffffff"
		if not t.enabled then
		  color = "|cff808080"
		elseif not SetExists(t.setID) then
		  color = "|cffff5555"
		elseif db.applied == t.id then
		  color = "|cff33ff33"
		elseif ConditionActive(t) then
		  color = "|cffffd100"
		end
		local target = SetExists(t.setID) and SetName(t.setID) or "No set selected"
		row.text:SetText(color .. DescribeTrigger(t) .. "|r |cffaaaaaa>|r " .. color .. target .. "|r")

		if t.id == selectedTriggerID then row.selTex:Show() else row.selTex:Hide() end
		if index > 1 then row.up:Enable() else row.up:Disable() end
		if index < num then row.down:Enable() else row.down:Disable() end
		row:Show()
	  else
		row.trigger = nil
		row.index = nil
		row:Hide()
	  end
	end
	if num == 0 then triggerList.empty:Show() else triggerList.empty:Hide() end
  end

  function RefreshTriggerPanel()
	if not triggerPanel:IsShown() then return end
	RefreshTriggerRows()

	local num = table.getn(db.triggers)
	local t = SelectedTrigger()
	if not t then
	  editor:Hide()
	  editor.placeholder:SetShown(num > 0)
	  return
	end
	editor:Show()
	editor.placeholder:Hide()

	SelectDropdownValue(ddType, t.type)

	local info = TRIGGER_TYPE[t.type]
	local kind = info and info.value
	valueLabel:SetShown(kind ~= nil)
	ddValue:SetShown(kind == "list")
	editValue:SetShown(kind == "text")
	btnCurrentZone:SetShown(t.type == "zone")
	if kind == "list" then
	  SelectDropdownValue(ddValue, t.value)
	elseif kind == "text" then
	  editValue:ClearAllPoints()
	  -- InputBoxTemplate's left border sits ~6px outside the frame.
	  editValue:SetPoint("TOPLEFT", editor, "TOPRIGHT", -EDITOR_FIELD_W + 6, EDITOR_ROW_Y[2] - 2)
	  if t.type == "zone" then
		editValue:SetPoint("BOTTOMRIGHT", btnCurrentZone, "BOTTOMLEFT", -6, 0)
	  else
		editValue:SetPoint("BOTTOMRIGHT", editor, "TOPRIGHT", -2, EDITOR_ROW_Y[2] - 22)
	  end
	  if not editValue.hasFocus then
		editValue.updating = true
		editValue:SetText(t.value or "")
		editValue.updating = nil
	  end
	  local valid = t.type ~= "time" or ParseTimeWindow(t.value)
	  editValue:SetTextColor(1, valid and 1 or .3, valid and 1 or .3)
	end

	local hasSets = table.getn(GetVisibleSetIDs()) > 0
	ddSet:SetShown(hasSets)
	editor.noSets:SetShown(not hasSets)
	SelectDropdownValue(ddSet, t.setID)
	SelectDropdownValue(ddLeave, t.leave or "restore")
  end

  triggerPanel:SetScript("OnShow", function() RefreshTriggerPanel() end)
  -- Row colors show which conditions currently hold; keep them live.
  triggerPanel:SetScript("OnUpdate", function()
	this.elapsed = (this.elapsed or 0) + (arg1 or 0)
	if this.elapsed < 1 then return end
	this.elapsed = 0
	RefreshTriggerRows()
  end)
  triggerPanel:SetScript("OnHide", function()
	CloseDropDownMenus()
	editValue:ClearFocus()
  end)

  -- Sidecar buttons that open the panels
  local btnUnused = CreateFrame("Button", "STEqMgrUnused", frame, "UIPanelButtonTemplate")
  btnUnused:SetWidth(98); btnUnused:SetHeight(22)
  btnUnused:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
  btnUnused:SetText("Unused")
  btnUnused:SetScript("OnClick", function() ToggleSubPanel(unusedPanel) end)
  btnUnused:SetScript("OnEnter", function()
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	GameTooltip:SetText("Items Not In Any Set", 1, 1, 1)
	GameTooltip:AddLine("Equippable items in your bags, bank and paperdoll that no equipment set uses.", .8, .8, .8, 1)
	GameTooltip:Show()
  end)
  btnUnused:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local btnTriggers = CreateFrame("Button", "STEqMgrTriggers", frame, "UIPanelButtonTemplate")
  btnTriggers:SetWidth(98); btnTriggers:SetHeight(22)
  btnTriggers:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 16)
  btnTriggers:SetText("Triggers")
  btnTriggers:SetScript("OnClick", function() ToggleSubPanel(triggerPanel) end)
  btnTriggers:SetScript("OnEnter", function()
	GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
	GameTooltip:SetText("Automatic Set Switching", 1, 1, 1)
	GameTooltip:AddLine("Equip sets automatically when mounted, swimming, eating, in a zone, at a given time and more.", .8, .8, .8, 1)
	GameTooltip:Show()
  end)
  btnTriggers:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Called at the end of every Refresh().
  function eqmgr.RefreshExtras()
	local list = ScanUnusedItems()
	btnUnused:SetText("Unused (" .. table.getn(list) .. ")")
	if unusedPanel:IsShown() then RefreshUnusedPanel() end
	if triggerPanel:IsShown() then RefreshTriggerPanel() end
  end

  UpdateEngine()
  end
  SetupExtras()

  -- Events
  local events = CreateFrame("Frame")
  events:RegisterEvent("EQUIPMENT_SETS_CHANGED")
  events:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
  events:RegisterEvent("BAG_UPDATE_DELAYED")
  events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
  events:RegisterEvent("WEAR_EQUIPMENT_SET")

  events:SetScript("OnEvent", function()
	if event == "CURSOR_CHANGED" then
	  if arg1 and arg3 == Enum.UICursorType.EquipmentSet then
		PlaySound("INTERFACESOUND_CURSORDROPOBJECT")
	  end
	elseif event == "WEAR_EQUIPMENT_SET" then
	  PlaySound("INTERFACESOUND_CHARWINDOWTAB")
	elseif event == "PLAYER_EQUIPMENT_CHANGED" then
	  local changedSlot = arg1
	  if frame:IsShown() then
		eqmgr.Refresh()
	  elseif flyout:IsShown() and flyout.targetInvSlot then
		if changedSlot == flyout.targetInvSlot then
		  for _, slotName in ipairs(CHAR_SLOT_NAMES) do
			local s = _G["Character" .. slotName]
			if s and s:GetID() == flyout.targetInvSlot then
			  eqmgr.ShowFlyout(s)
			  break
			end
		  end
		end
	  end
	elseif frame:IsShown() then
	  eqmgr.Refresh()
	elseif flyout:IsShown() and flyout.targetInvSlot then
	  for _, slotName in ipairs(CHAR_SLOT_NAMES) do
		local s = _G["Character" .. slotName]
		if s and s:GetID() == flyout.targetInvSlot then
		  eqmgr.ShowFlyout(s)
		  break
		end
	  end
	end
  end)

  if C_EquipmentSet.PickupEquipmentSet then
	events:RegisterEvent("CURSOR_CHANGED")
  end

  GameTooltip:HookScript("OnTooltipSetItem", function()
	this:Show()
  end)
end)