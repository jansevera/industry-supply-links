-- GUI-side logic: watches industry windows, detects when the Suppliers (or
-- Consumers) tab is selected, and draws ground lines to every industry that
-- could supply (or consume from) that industry.
--
-- Rules followed here:
--   * guiHandleEvent only records what happened; all widget and world work is
--     done in guiUpdate (touching a window from inside its own event callback
--     can hang the game).
--   * Every engine/GUI call is wrapped in pcall, so an API difference between
--     game versions turns a feature off instead of crashing the game.

local recipes = require "industry_supply_links/recipes"
local palette = require "industry_supply_links/palette"

local M = {}

local ZONE_PREFIX = "industry_supply_links."
local CHECK_EVERY_FRAMES = 10
local INDUSTRY_CACHE_FRAMES = 1800
local SEED_TIMEOUT_FRAMES = 300
local MAX_WALK_ITEMS = 400
local MAX_ZONES_PER_WINDOW = 5000
local ARROWS_MIN = 5
local ARROW_MAX_GAP = 150
local FILL_STEP = 3
local SWATCH_SIZE = 14
local SWATCH_CELL = 24

-- Lower-case fragments of the tab captions in the languages we know about.
-- Matching is by substring, so "suppl" matches "Suppliers" and "Supply".
local TAB_WORDS = {
	suppliers = { "suppl", "dodavatel", "liefer", "fournisseur", "proveedor", "fornitor",
		"dostawc", "fornecedor", "leverancier", "dodávateľ", "beszállító", "оставщик", "供应", "供給" },
	consumers = { "consum", "odběratel", "spotřebitel", "abnehmer", "verbraucher", "consommat",
		"consumidor", "consumator", "odbiorc", "afnemer", "odberateľ", "fogyaszt", "отребител", "消费", "消費" },
}

local state = {
	frame = 0,
	windows = {},          -- construction id -> tracked industry window
	pendingIds = {},       -- entity ids seen in events, resolved in guiUpdate
	industries = nil,      -- cached list of all industries
	industriesFrame = -math.huge,
	legend = nil,
	legendOwner = nil,
}

------------------------------------------------------------------------------
-- small helpers

local unpackArgs = table.unpack or unpack

local function tr(key)
	local ok, text = pcall(_, key)
	if ok and type(text) == "string" then return text end
	return key
end

local function settings()
	local ok, p = pcall(function() return game.config.industrySupplyLinks.params end)
	if not ok or type(p) ~= "table" then p = {} end
	return {
		maxPerCargo = tonumber(p.maxPerCargo) or 10,
		lineWidth = tonumber(p.lineWidth) or 25,
		consumers = p.consumers ~= false,
		legend = p.legend ~= false,
		fill = p.fill ~= false,
		suppliersTab = tonumber(p.suppliersTab) or 0,
		consumersTab = tonumber(p.consumersTab) or 0,
		debug = p.debug == true,
	}
end

local function capturedRecipes()
	local ok, r = pcall(function() return game.config.industrySupplyLinks.recipes end)
	if ok and type(r) == "table" then return r end
	return nil
end

local function log(...)
	if not settings().debug then return end
	local parts = {}
	for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
	print("[IndustrySupplyLinks] " .. table.concat(parts, " "))
end

local function member(object, name)
	if object == nil then return nil end
	local ok, value = pcall(function() return object[name] end)
	if ok then return value end
	return nil
end

-- Calls object:method(...) and returns result, ok.
local function invoke(object, method, ...)
	local fn = member(object, method)
	if fn == nil then return nil, false end
	local args, n = { ... }, select("#", ...)
	local ok, result = pcall(function() return fn(object, unpackArgs(args, 1, n)) end)
	if not ok then return nil, false end
	return result, true
end

local function downcast(component)
	local fn = api and api.gui and api.gui.util and api.gui.util.downcast
	if fn == nil or component == nil then return component end
	local ok, result = pcall(fn, component)
	if ok and result ~= nil then return result end
	return component
end

local function byId(id)
	local ok, component = pcall(function() return api.gui.util.getById(id) end)
	if ok then return component end
	return nil
end

local function getEntity(id)
	if id == nil then return nil end
	local ok, entity = pcall(game.interface.getEntity, id)
	if ok and type(entity) == "table" then return entity end
	return nil
end

local function positionOf(entity)
	local p = entity and entity.position
	if type(p) ~= "table" then return nil end
	local x, y = tonumber(p[1] or p.x), tonumber(p[2] or p.y)
	if x and y then return x, y end
	return nil
end

------------------------------------------------------------------------------
-- industries

local function constructionForSimBuilding(simBuildingId)
	local ok, cid = pcall(function()
		return api.engine.system.streetConnectorSystem.getConstructionEntityForSimBuilding(simBuildingId)
	end)
	cid = ok and tonumber(cid) or nil
	if cid and cid >= 0 then return cid end
	local entity = getEntity(simBuildingId)
	if entity and tonumber(entity.stockList) then return tonumber(entity.stockList) end
	return nil
end

-- Returns the construction id of the industry an entity belongs to.
local function resolveIndustryId(entityId)
	local entity = getEntity(entityId)
	if not entity then return nil end
	if entity.type == "SIM_BUILDING" then return constructionForSimBuilding(entityId) end
	if entity.type == "CONSTRUCTION" and type(entity.simBuildings) == "table" and next(entity.simBuildings) ~= nil then
		return entityId
	end
	return nil
end

local function makeIndustry(cid)
	local entity = getEntity(cid)
	if not entity or entity.type ~= "CONSTRUCTION" then return nil end
	local simBuildings = {}
	for _, sb in pairs(entity.simBuildings or {}) do
		if tonumber(sb) then simBuildings[#simBuildings + 1] = tonumber(sb) end
	end
	if #simBuildings == 0 then return nil end
	local x, y = positionOf(entity)
	if not x then return nil end
	local recipe = recipes.lookup(entity.fileName, capturedRecipes())
	for _, sb in ipairs(simBuildings) do recipes.addObserved(recipe, getEntity(sb)) end
	return {
		id = cid,
		name = tostring(entity.name or ""),
		fileName = tostring(entity.fileName or ""),
		x = x, y = y,
		simBuildings = simBuildings,
		recipe = recipe,
	}
end

local function scanIndustries()
	local simBuildings = {}
	pcall(api.engine.forEachEntityWithComponent, function(id)
		simBuildings[#simBuildings + 1] = id
	end, api.type.ComponentType.SIM_BUILDING)

	local cids, seen = {}, {}
	local function add(cid)
		cid = tonumber(cid)
		if cid and not seen[cid] then
			seen[cid] = true
			cids[#cids + 1] = cid
		end
	end
	for _, sb in ipairs(simBuildings) do add(constructionForSimBuilding(sb)) end

	if #cids == 0 then
		-- Fallback for game versions without forEachEntityWithComponent.
		local ok, result = pcall(game.interface.getEntities,
			{ pos = { 0, 0 }, radius = 1e9 }, { type = "CONSTRUCTION", includeData = false })
		if ok and type(result) == "table" then
			for key, value in pairs(result) do add(tonumber(value) or tonumber(key)) end
		end
	end

	local industries = {}
	for _, cid in ipairs(cids) do
		local industry = makeIndustry(cid)
		if industry then industries[#industries + 1] = industry end
	end
	log("scanned industries:", #industries)
	return industries
end

local function allIndustries(force)
	if force or not state.industries or state.frame - state.industriesFrame > INDUSTRY_CACHE_FRAMES then
		state.industries = scanIndustries()
		state.industriesFrame = state.frame
	end
	return state.industries
end

local function findIndustry(industries, cid)
	for _, industry in ipairs(industries) do
		if industry.id == cid then return industry end
	end
	return nil
end

-- mode "suppliers": industries producing what `target` consumes.
-- mode "consumers": industries consuming what `target` produces.
-- Kept generic so other link kinds (e.g. towns as consumers) can be added here.
local function computeLinks(target, mode, industries, maxPerCargo)
	local wanted = mode == "suppliers" and target.recipe.inputs or target.recipe.outputs
	local byCargo = {}
	for _, other in ipairs(industries) do
		if other.id ~= target.id then
			local offers = mode == "suppliers" and other.recipe.outputs or other.recipe.inputs
			for cargo in pairs(wanted) do
				if offers[cargo] then
					local dx, dy = other.x - target.x, other.y - target.y
					byCargo[cargo] = byCargo[cargo] or {}
					table.insert(byCargo[cargo], { other = other, cargo = cargo, distance = math.sqrt(dx * dx + dy * dy) })
				end
			end
		end
	end

	local cargos = {}
	for cargo in pairs(wanted) do cargos[#cargos + 1] = cargo end
	table.sort(cargos)

	local result = {}
	for _, cargo in ipairs(cargos) do
		local list = byCargo[cargo] or {}
		table.sort(list, function(a, b) return a.distance < b.distance end)
		local limit = (maxPerCargo and maxPerCargo > 0) and math.min(maxPerCargo, #list) or #list
		local kept = {}
		for i = 1, limit do kept[i] = list[i] end
		result[#result + 1] = { cargo = cargo, links = kept, total = #list }
	end
	return result
end

------------------------------------------------------------------------------
-- drawing (game.interface.setZone paints polygons onto the terrain)

local function setZone(key, zone)
	local ok, err = pcall(function() game.interface.setZone(key, zone) end)
	if not ok then log("setZone failed:", err) end
	return ok
end

-- Arrowheads ("darts") spaced along the way from (x1,y1) to (x2,y2), all
-- pointing at (x2,y2). At least 5 per link; more are added so the empty gap
-- between two arrows never exceeds ARROW_MAX_GAP metres.
-- With `fill`, each dart is drawn as nested, shrinking outlines inside one
-- polygon, which reads as a filled shape (zones only draw outlines).
local function arrows(x1, y1, x2, y2, width, fill)
	local dx, dy = x2 - x1, y2 - y1
	local length = math.sqrt(dx * dx + dy * dy)
	if length < 1 then return {} end
	local ux, uy = dx / length, dy / length
	local nx, ny = -uy, ux
	local fullLength = width * 5
	local count = math.max(ARROWS_MIN, math.ceil(length / (fullLength + ARROW_MAX_GAP)))
	local spacing = length / count
	local arrowLength = math.min(fullLength, spacing * 0.6)
	local halfWidth = arrowLength * 0.35
	local loops = 1
	if fill then loops = math.max(2, math.ceil(halfWidth / FILL_STEP)) end
	local result = {}
	for i = 1, count do
		local t = (i - 0.5) / count
		local cx, cy = x1 + dx * t, y1 + dy * t
		local polygon = {}
		for loop = 0, loops - 1 do
			-- Scale about the dart's centre, which lies inside the shape.
			local scale = 1 - loop / loops
			local function add(along, side)
				along, side = along * scale, side * scale
				polygon[#polygon + 1] = { cx + ux * along + nx * side, cy + uy * along + ny * side }
			end
			add(arrowLength / 2, 0)
			add(-arrowLength / 2, halfWidth)
			add(-arrowLength / 4, 0)
			add(-arrowLength / 2, -halfWidth)
			if loops > 1 then add(arrowLength / 2, 0) end
		end
		result[#result + 1] = polygon
	end
	return result
end

-- An outline ring (outer circle, then inner circle reversed).
local function ring(x, y, radius, thickness)
	local inner = math.max(1, radius - thickness)
	local outer, back = {}, {}
	for i = 0, 32 do
		local a = i / 32 * math.pi * 2
		outer[#outer + 1] = { x + math.cos(a) * radius, y + math.sin(a) * radius }
		back[#back + 1] = { x + math.cos(a) * inner, y + math.sin(a) * inner }
	end
	for i = #back, 1, -1 do outer[#outer + 1] = back[i] end
	return outer
end

local function clearZones(window)
	for _, key in ipairs(window.zones) do setZone(key, nil) end
	window.zones = {}
end

local function addZone(window, polygon, colour)
	if not polygon or #window.zones >= MAX_ZONES_PER_WINDOW then return end
	local key = ZONE_PREFIX .. window.id .. "." .. (#window.zones + 1)
	if setZone(key, { polygon = polygon, draw = true, drawColor = colour }) then
		window.zones[#window.zones + 1] = key
	end
end

local function drawLinks(window, target, mode, groups, width, fill)
	clearZones(window)
	addZone(window, ring(target.x, target.y, width * 5, width * 0.8), { 1, 1, 1, 1 })
	for index, group in ipairs(groups) do
		local c = palette[(index - 1) % #palette + 1]
		local colour = { c[1], c[2], c[3], 1 }
		for _, link in ipairs(group.links) do
			-- Arrows always point at the industry that receives the cargo.
			local fromX, fromY, toX, toY = link.other.x, link.other.y, target.x, target.y
			if mode == "consumers" then fromX, fromY, toX, toY = toX, toY, fromX, fromY end
			for _, arrow in ipairs(arrows(fromX, fromY, toX, toY, width, fill)) do
				addZone(window, arrow, colour)
			end
			addZone(window, ring(link.other.x, link.other.y, width * 3, width * 0.8), colour)
		end
	end
	log("drew", #window.zones, "zones for industry", target.id)
end

------------------------------------------------------------------------------
-- legend window

local function cargoName(cargo)
	local ok, name = pcall(function()
		local rep = api.res.cargoTypeRep
		return rep.get(rep.find(cargo)).name
	end)
	if ok and type(name) == "string" and name ~= "" then return tr(name) end
	local pretty = cargo:lower():gsub("_", " ")
	return (pretty:gsub("^%l", string.upper))
end

-- A filled square in the colour of the cargo's arrows, centred in its table
-- cell. The colour comes from the style sheet (isl-swatch-<index>).
local function colourSquare(colourIndex)
	local styleName = "isl-swatch-" .. colourIndex
	local square = api.gui.comp.Component.new(styleName)
	square:setName(styleName)
	invoke(square, "setStyleClassList", { styleName })
	local ok, size = pcall(function() return api.gui.util.Size.new(SWATCH_SIZE, SWATCH_SIZE) end)
	if ok and size then
		invoke(square, "setMinimumSize", size)
		invoke(square, "setMaximumSize", size)
	end
	invoke(square, "setGravity", 0.5, 0.5)

	-- Wrap it in a fixed-size cell so it sits centred before the cargo name.
	local cell = api.gui.comp.Component.new("isl-swatch-cell")
	local layout = api.gui.layout.BoxLayout.new("VERTICAL")
	local _, added = invoke(layout, "addItem", square, 0.5, 0.5)
	if not added then layout:addItem(square) end
	cell:setLayout(layout)
	local okCell, cellSize = pcall(function() return api.gui.util.Size.new(SWATCH_CELL, SWATCH_CELL) end)
	if okCell and cellSize then invoke(cell, "setMinimumSize", cellSize) end
	invoke(cell, "setGravity", 0.5, 0.5)
	return cell
end

local function hideLegend(window)
	if state.legend and (window == nil or state.legendOwner == window.id) then
		invoke(state.legend.window, "setVisible", false, false)
		state.legendOwner = nil
	end
end

-- Creates the (hidden) legend window. Done once at startup: creating a new
-- window while an industry window is open makes the game close that
-- (unpinned) industry window, which cleared the arrows on first use.
local function createLegend()
	if state.legend then return true end
	local ok, err = pcall(function()
		local tbl = api.gui.comp.Table.new(3, "NONE")
		local win = api.gui.comp.Window.new(tr("ISL_LEGEND_TITLE"), tbl)
		win:addHideOnCloseHandler()
		win:setMovable(true)
		win:setPosition(20, 160)
		win:setVisible(false, false)
		state.legend = { window = win, table = tbl }
	end)
	if not ok then log("legend creation failed:", err) end
	return state.legend ~= nil
end

local function showLegend(window, target, mode, groups)
	if not createLegend() then return end
	local ok, err = pcall(function()
		local legend = state.legend
		legend.table:deleteRows(0, legend.table:getNumRows())
		for index, group in ipairs(groups) do
			local colourIndex = (index - 1) % #palette + 1
			local okSquare, dot = pcall(colourSquare, colourIndex)
			if not okSquare then
				log("colour square failed:", dot)
				dot = api.gui.comp.TextView.new("■")
				dot:setName("isl-swatch-" .. colourIndex)
			end
			local count = tostring(#group.links)
			if #group.links < group.total then count = count .. " / " .. group.total end
			legend.table:addRow({ dot, api.gui.comp.TextView.new(cargoName(group.cargo)), api.gui.comp.TextView.new(count) })
		end
		if #groups == 0 then
			legend.table:addRow({ api.gui.comp.TextView.new(""), api.gui.comp.TextView.new(tr("ISL_NO_LINKS")), api.gui.comp.TextView.new("") })
		end
		local title = tr(mode == "suppliers" and "ISL_LEGEND_SUPPLIERS" or "ISL_LEGEND_CONSUMERS")
		legend.window:setTitle(title .. ": " .. target.name)
		legend.window:setVisible(true, false)
		state.legendOwner = window.id
	end)
	if not ok then log("legend failed:", err) end
end

------------------------------------------------------------------------------
-- industry windows and their tabs

local function children(component)
	local result = {}
	local content = invoke(component, "getContent")
	if content ~= nil then result[#result + 1] = downcast(content) end
	local layout = invoke(component, "getLayout")
	if layout == nil and member(component, "getNumItems") then layout = component end
	layout = downcast(layout)
	local count = tonumber((invoke(layout, "getNumItems"))) or 0
	for i = 0, math.min(count, 128) - 1 do
		local item = invoke(layout, "getItem", i)
		if item ~= nil then result[#result + 1] = downcast(item) end
	end
	return result
end

-- Visits components breadth first; stops when visitor returns true.
local function walk(root, visitor)
	local queue, head, visited = { root }, 1, 0
	while head <= #queue and visited < MAX_WALK_ITEMS do
		local item = queue[head]
		head = head + 1
		visited = visited + 1
		if visitor(item) then return true end
		for _, child in ipairs(children(item)) do queue[#queue + 1] = child end
	end
	return false
end

local function findWindowComponent(seed)
	local current = seed
	for _ = 1, 32 do
		if tostring(invoke(current, "getName") or "") == "Window" then return current end
		local parent = invoke(current, "getParent")
		if parent == nil then break end
		current = downcast(parent)
	end
	return seed
end

local function textOf(component)
	local parts = {}
	walk(component, function(item)
		local text = invoke(item, "getText")
		if type(text) == "string" and text ~= "" then parts[#parts + 1] = text end
		return #parts >= 4
	end)
	return table.concat(parts, " ")
end

local function matches(label, words)
	local lower = string.lower(label)
	for _, word in ipairs(words) do
		if lower:find(word, 1, true) then return true end
	end
	return false
end

-- Finds the tab widget of an industry window and which tab index is which.
local function inspectTabs(windowComponent, config)
	local found = nil
	walk(windowComponent, function(item)
		local numTabs = tonumber((invoke(item, "getNumTabs")))
		if not numTabs or member(item, "getCurrentTabIndex") == nil then return false end
		local info = { widget = item, labels = {} }
		for i = 0, numTabs - 1 do
			local indicator = invoke(item, "getIndicator", i)
			local label = indicator and textOf(downcast(indicator)) or ""
			info.labels[i] = label
			if not info.suppliers and matches(label, TAB_WORDS.suppliers) then info.suppliers = i end
			if not info.consumers and matches(label, TAB_WORDS.consumers) then info.consumers = i end
		end
		if config.suppliersTab > 0 then info.suppliers = config.suppliersTab - 1 end
		if config.consumersTab > 0 then info.consumers = config.consumersTab - 1 end
		found = found or info
		if info.suppliers or info.consumers then
			found = info
			return true
		end
		return false
	end)
	return found
end

local function findSeed(window)
	for _, id in ipairs(window.seeds) do
		local component = byId(id)
		if component ~= nil then return component end
	end
	return nil
end

local function addSeed(window, id)
	local seed = "temp.view.entity_" .. tostring(id)
	for _, existing in ipairs(window.seeds) do
		if existing == seed then return end
	end
	window.seeds[#window.seeds + 1] = seed
end

local function track(entityId)
	local cid = resolveIndustryId(entityId)
	if not cid then return end
	local window = state.windows[cid]
	if not window then
		window = { id = cid, seeds = {}, zones = {}, mode = nil, found = false }
		state.windows[cid] = window
		log("tracking industry window", cid, "from entity", entityId)
	end
	window.created = state.frame
	window.dirty = true
	addSeed(window, entityId)
	addSeed(window, cid)
	local entity = getEntity(cid)
	for _, sb in pairs(entity and entity.simBuildings or {}) do addSeed(window, sb) end
end

local function forget(window)
	clearZones(window)
	hideLegend(window)
	state.windows[window.id] = nil
	log("stopped tracking industry window", window.id)
end

local function activeMode(window, config)
	local seed = findSeed(window)
	if seed == nil then return nil, false end
	local windowComponent = findWindowComponent(seed)
	local visible = invoke(windowComponent, "isVisible")
	if visible == false then return nil, true end
	local tabs = inspectTabs(windowComponent, config)
	if not tabs then return nil, true end
	local current = tonumber((invoke(tabs.widget, "getCurrentTabIndex")))
	if not window.loggedTabs then
		window.loggedTabs = true
		local labels = {}
		for i = 0, #tabs.labels do labels[#labels + 1] = i .. "=" .. tostring(tabs.labels[i]) end
		log("tabs of industry", window.id, ":", table.concat(labels, ", "),
			"suppliers=", tabs.suppliers, "consumers=", tabs.consumers)
	end
	if current == nil then return nil, true end
	if tabs.suppliers ~= nil and current == tabs.suppliers then return "suppliers", true end
	if config.consumers and tabs.consumers ~= nil and current == tabs.consumers then return "consumers", true end
	return nil, true
end

local function refresh(window, config)
	local mode, open = activeMode(window, config)
	if open then
		window.found = true
	elseif window.found or state.frame - window.created > SEED_TIMEOUT_FRAMES then
		forget(window)
		return
	end
	if mode == window.mode and not window.forceRedraw then return end
	window.mode = mode
	window.forceRedraw = false
	if not mode then
		clearZones(window)
		hideLegend(window)
		return
	end
	local industries = allIndustries(true)
	local target = findIndustry(industries, window.id)
	if not target then
		clearZones(window)
		return
	end
	local groups = computeLinks(target, mode, industries, config.maxPerCargo)
	drawLinks(window, target, mode, groups, config.lineWidth, config.fill)
	if config.legend then showLegend(window, target, mode, groups) end
end

------------------------------------------------------------------------------
-- game script callbacks

local function eventEntityIds(param)
	local ids = {}
	if tonumber(param) then ids[#ids + 1] = tonumber(param) end
	if type(param) == "table" then
		for _, key in ipairs({ "entity", "id", "entityId", "selectedEntity" }) do
			if tonumber(param[key]) then ids[#ids + 1] = tonumber(param[key]) end
		end
	end
	return ids
end

function M.guiHandleEvent(id, name, param)
	local source = tostring(id or "")
	local entityFromId = tonumber(source:match("^temp%.view%.entity_(%d+)"))

	if settings().debug and (entityFromId or source == "mainView" and name == "select"
			or tostring(name):find("tab", 1, true)) then
		log("event id=", source, "name=", name, "param=", type(param) == "table" and "table" or param)
	end

	if source == "mainView" and name == "select" then
		for _, entity in ipairs(eventEntityIds(param)) do state.pendingIds[#state.pendingIds + 1] = entity end
	elseif entityFromId then
		state.pendingIds[#state.pendingIds + 1] = entityFromId
	end

	if tostring(name) == "tabWidget.currentChanged" then
		for _, window in pairs(state.windows) do window.dirty = true end
	end
end

function M.guiUpdate()
	state.frame = state.frame + 1

	if state.frame == 1 and settings().legend then createLegend() end

	if #state.pendingIds > 0 then
		local pending = state.pendingIds
		state.pendingIds = {}
		for _, entity in ipairs(pending) do pcall(track, entity) end
	end

	local periodic = state.frame % CHECK_EVERY_FRAMES == 0
	local config = nil
	for _, window in pairs(state.windows) do
		if periodic or window.dirty then
			window.dirty = false
			config = config or settings()
			local ok, err = pcall(refresh, window, config)
			if not ok then log("refresh failed:", err) end
		end
	end
end

-- Exposed for tests.
M._computeLinks = computeLinks
M._arrows = arrows
M._matches = matches
M._TAB_WORDS = TAB_WORDS

return M
