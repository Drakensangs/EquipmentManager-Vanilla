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

  -- -----------------------------------------------------------------------
  -- Location-bitfield helpers
  -- -----------------------------------------------------------------------
  local LOC_PLAYER = 1048576
  local LOC_BAGS   = 2097152

  local function UnpackLocation(location)
	local r    = {}
	r.isPlayer = (math.mod(math.floor(location / LOC_PLAYER), 2) == 1)
	r.isBags   = (math.mod(math.floor(location / LOC_BAGS),   2) == 1)
	r.slot	   = math.mod(location, 256)
	r.bag	   = math.mod(math.floor(location / 256), 256)
	return r
  end

  local function PlayerEquipLocation(invSlot)
	return LOC_PLAYER + invSlot
  end

  local WEAPON_SLOTS = { [16] = true, [17] = true, [18] = true }

  -- -----------------------------------------------------------------------
  -- State - reset on every login so character switching works correctly.
  -- -----------------------------------------------------------------------
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
	local name, _, _, _, _, _, _, numMissing = C_EquipmentSet.GetEquipmentSetInfo(setID)
	if numMissing and numMissing > 0 then
	  UIErrorsFrame:AddMessage(string.format(ERR_EQUIPMENT_MANAGER_MISSING_ITEM_S, name), 1, .1, .1, 1)
	end
	PlaySound("INTERFACESOUND_CHARWINDOWTAB")
	ClearCursor()
	C_EquipmentSet.UseEquipmentSet(setID)
  end

  -- -----------------------------------------------------------------------
  -- Icon picker data
  -- -----------------------------------------------------------------------
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

  -- -----------------------------------------------------------------------
  -- Main sidecar frame
  -- -----------------------------------------------------------------------
  local frame = CreateFrame("Frame", "STEquipmentManagerFrame", UIParent)
  frame:SetWidth(232)
  frame:SetHeight(350)
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

  -- -----------------------------------------------------------------------
  -- Toggle button on the paperdoll
  -- -----------------------------------------------------------------------
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

  -- -----------------------------------------------------------------------
  -- New Set, Equip, Save buttons
  -- -----------------------------------------------------------------------
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

  -- -----------------------------------------------------------------------
  -- Set list
  -- -----------------------------------------------------------------------
  local listFrame = CreateFrame("Frame", nil, frame)
  listFrame:SetPoint("TOPLEFT",		frame, "TOPLEFT",	  14, -52)
  listFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
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
	row.iconBtn:EnableMouse(false)
	row.iconBtn:SetNormalTexture("")
	row.icon = _G["STEqMgrRowIcon" .. setRowIconCount .. "Icon"]

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


  -- -----------------------------------------------------------------------
  -- Name/Icon popup
  -- -----------------------------------------------------------------------
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

  -- -----------------------------------------------------------------------
  -- Equipment slot flyout
  -- -----------------------------------------------------------------------
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
		GameTooltip:SetBagItem(this.bag, this.slot)
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
	  if loc.isBags then
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
		b.specialAction = nil; b.bag = nil; b.slot = nil; b.invSlot = nil

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
		  if loc.isBags then
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

  -- -----------------------------------------------------------------------
  -- Paperdoll slot hooks
  -- -----------------------------------------------------------------------
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
	for _, slotName in ipairs(CHAR_SLOT_NAMES) do
	  local slot = _G["Character" .. slotName]
	  if slot and MouseIsOver(slot) then
		hovered = slot
		break
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

  -- -----------------------------------------------------------------------
  -- Refresh
  -- -----------------------------------------------------------------------
  function eqmgr.Refresh()
	local ids	  = C_EquipmentSet.GetEquipmentSetIDs() or {}
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
  end

  -- -----------------------------------------------------------------------
  -- Events
  -- -----------------------------------------------------------------------
  local events = CreateFrame("Frame")
  events:RegisterEvent("EQUIPMENT_SETS_CHANGED")
  events:RegisterEvent("EQUIPMENT_SWAP_FINISHED")
  events:RegisterEvent("BAG_UPDATE_DELAYED")
  events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
  events:SetScript("OnEvent", function()
	if event == "PLAYER_EQUIPMENT_CHANGED" then
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
end)