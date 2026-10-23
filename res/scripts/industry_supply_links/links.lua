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
local EVENT_ID = "industry_supply_links"
-- "Lines:" choices in the legend window (0 = all), same as the mod setting.
local LINE_CHOICES = { 5, 10, 20, 0 }
-- Cargo vanilla towns can ask for (used only if a town's data lists none).
local TOWN_CARGO = { "FOOD", "GOODS", "FUEL", "TOOLS", "CONSTRUCTION_MATERIALS", "MACHINES" }
local ICON_SIZE = 20
local COUNT_WIDTH = 70
local NAME_WIDTH = 170
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
	arrowsOn = true,       -- switched with the toggle in the legend window
	maxPerCargo = nil,     -- chosen in the legend window; nil = mod setting
	controls = nil,        -- legend window buttons
	sentChoice = nil,      -- last choice sent to the engine, until it comes back
	persist = nil,         -- engine side: choice stored in the savegame
	hiddenCargo = {},      -- cargo hidden by clicking its legend row
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
		towns = p.towns ~= false,
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

-- A solid-looking ring: concentric circles FILL_STEP apart from `radius`
-- down to `radius - thickness`, joined into one polygon.
local function ring(x, y, radius, thickness)
	local inner = math.max(1, radius - thickness)
	local loops = math.max(2, math.ceil((radius - inner) / FILL_STEP) + 1)
	local polygon = {}
	for loop = 0, loops - 1 do
		local r = radius - (radius - inner) * loop / (loops - 1)
		for i = 0, 32 do
			local a = i / 32 * math.pi * 2
			polygon[#polygon + 1] = { x + math.cos(a) * r, y + math.sin(a) * r }
		end
	end
	return polygon
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
	addZone(window, ring(target.x, target.y, width * 5, width * 1.6), { 1, 1, 1, 1 })
	for index, group in ipairs(groups) do
		local c = palette[(index - 1) % #palette + 1]
		local colour = { c[1], c[2], c[3], 1 }
		local shown = state.hiddenCargo[group.cargo] and {} or group.links
		for _, link in ipairs(shown) do
			-- Arrows always point at the industry that receives the cargo.
			local fromX, fromY, toX, toY = link.other.x, link.other.y, target.x, target.y
			if mode == "consumers" then fromX, fromY, toX, toY = toX, toY, fromX, fromY end
			if state.arrowsOn then
				for _, arrow in ipairs(arrows(fromX, fromY, toX, toY, width, fill)) do
					addZone(window, arrow, colour)
				end
			end
			addZone(window, ring(link.other.x, link.other.y, width * 3, width * 1.2), colour)
		end
	end
	log("drew", #window.zones, "zones for industry", target.id)
end

------------------------------------------------------------------------------
-- legend window

-- The cargo's own icon (as used in the game's cargo lists), or an empty cell.
local function cargoIcon(cargo)
	local ok, image = pcall(function()
		local rep = api.res.cargoTypeRep
		local icon = rep.get(rep.find(cargo)).icon
		if type(icon) ~= "string" or icon == "" then error("no icon") end
		local view = api.gui.comp.ImageView.new(icon)
		local okSize, size = pcall(function() return api.gui.util.Size.new(ICON_SIZE, ICON_SIZE) end)
		if okSize and size then
			invoke(view, "setMaximumSize", size)
			invoke(view, "setMinimumSize", size)
		end
		invoke(view, "setGravity", 0.5, 0.5)
		return view
	end)
	if ok and image then return image end
	log("no icon for cargo", cargo, image)
	return api.gui.comp.TextView.new("")
end

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
local function redrawAll()
	for _, window in pairs(state.windows) do
		window.forceRedraw = true
		window.dirty = true
	end
end

-- Shows the current choices on the legend buttons.
local function syncControls()
	local controls = state.controls
	if not controls then return end
	invoke(controls.arrows, "setSelected", state.arrowsOn, false)
	local current = state.maxPerCargo or settings().maxPerCargo
	for index, button in ipairs(controls.lines) do
		invoke(button, "setSelected", LINE_CHOICES[index] == current, false)
	end
end

-- Stores the choices in the savegame (through the engine-side script).
local function sendChoice()
	local choice = { arrowsOn = state.arrowsOn, maxPerCargo = state.maxPerCargo }
	state.sentChoice = choice
	local ok, err = pcall(function() game.interface.sendScriptEvent(EVENT_ID, "settings", choice) end)
	if not ok then
		log("saving choice failed:", err)
		state.sentChoice = nil
	end
end

-- Widget callbacks only record the click; guiUpdate applies it.
local function setArrows(on)
	state.pendingArrows = on
end

local function setLines(value)
	state.pendingLines = value
end

-- Each legend row is one flat button (a selectable table selected its first
-- row by itself, and an already selected row ignored clicks).
local function clickCargo(cargo)
	state.pendingCargo = cargo
end

-- Clicking a legend row hides or shows that cargo's arrows and rings.
local function applyCargoClick()
	local cargo = state.pendingCargo
	state.pendingCargo = nil
	if not cargo then return end
	state.hiddenCargo[cargo] = not state.hiddenCargo[cargo] or nil
	log("cargo", cargo, state.hiddenCargo[cargo] and "hidden" or "shown")
	redrawAll()
end

local function applyPendingControls()
	local changed = false
	if state.pendingArrows ~= nil then
		changed = changed or state.pendingArrows ~= state.arrowsOn
		state.arrowsOn = state.pendingArrows
		state.pendingArrows = nil
	end
	if state.pendingLines ~= nil then
		changed = changed or state.pendingLines ~= (state.maxPerCargo or settings().maxPerCargo)
		state.maxPerCargo = state.pendingLines
		state.pendingLines = nil
	end
	syncControls()
	if changed then
		sendChoice()
		redrawAll()
	end
end

local function lineLabel(value)
	if value == 0 then return tr("ISL_ALL") end
	return tostring(value)
end

-- Row at the top of the legend: [Show arrows]   Lines: [5] [10] [20] [All]
local function createControls()
	local row = api.gui.comp.Component.new("isl-controls")
	local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	local controls = { lines = {} }

	controls.arrows = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(tr("ISL_SHOW_ARROWS")))
	controls.arrows:onToggle(function(selected) setArrows(selected == true) end)
	layout:addItem(controls.arrows)

	local okLines, err = pcall(function()
		local label = api.gui.comp.TextView.new("   " .. tr("ISL_LINES"))
		layout:addItem(label)
		for index, value in ipairs(LINE_CHOICES) do
			local button = api.gui.comp.ToggleButton.new(api.gui.comp.TextView.new(lineLabel(value)))
			button:onToggle(function() setLines(value) end)
			layout:addItem(button)
			controls.lines[index] = button
		end
	end)
	if not okLines then log("lines buttons failed:", err) end

	row:setLayout(layout)
	state.controls = controls
	syncControls()
	return row
end

local function createLegend()
	if state.legend then return true end
	local ok, err = pcall(function()
		local tbl = api.gui.comp.Table.new(1, "NONE")
		local content = api.gui.comp.Component.new("isl-legend")
		local layout = api.gui.layout.BoxLayout.new("VERTICAL")
		local okControls, controlsErr = pcall(function() layout:addItem(createControls()) end)
		if not okControls then log("legend controls failed:", controlsErr) end
		layout:addItem(tbl)
		content:setLayout(layout)
		local win = api.gui.comp.Window.new(tr("ISL_LEGEND_TITLE"), content)
		win:addHideOnCloseHandler()
		win:setMovable(true)
		win:setPosition(20, 160)
		win:setVisible(false, false)
		state.legend = { window = win, table = tbl }
	end)
	if not ok then log("legend creation failed:", err) end
	return state.legend ~= nil
end

local function fixedWidth(component, width)
	local ok, size = pcall(function() return api.gui.util.Size.new(width, ICON_SIZE) end)
	if ok and size then
		invoke(component, "setMinimumSize", size)
		invoke(component, "setMaximumSize", size)
	end
	return component
end

-- One row: [square] [icon] name        count, laid out with fixed widths so
-- rows line up and "hidden" does not move anything.
local function rowContent(cells)
	local row = api.gui.comp.Component.new("isl-legend-row")
	local layout = api.gui.layout.BoxLayout.new("HORIZONTAL")
	for _, cell in ipairs(cells) do layout:addItem(cell) end
	row:setLayout(layout)
	return row
end

-- The whole row as one flat button; a click anywhere toggles its cargo.
local function rowButton(cells, cargo)
	local content = rowContent(cells)
	if not cargo then return content end
	local ok, button = pcall(function()
		local b = api.gui.comp.Button.new(content, true)
		b:onClick(function() clickCargo(cargo) end)
		return b
	end)
	if ok and button then return button end
	return content
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
			if state.hiddenCargo[group.cargo] then count = tr("ISL_HIDDEN") end
			local cargo = group.cargo
			legend.table:addRow({ rowButton({
				dot,
				cargoIcon(cargo),
				fixedWidth(api.gui.comp.TextView.new(cargoName(cargo)), NAME_WIDTH),
				fixedWidth(api.gui.comp.TextView.new(count), COUNT_WIDTH),
			}, cargo) })
		end
		if #groups == 0 then
			legend.table:addRow({ rowButton({ api.gui.comp.TextView.new(tr("ISL_NO_LINKS")) }) })
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
-- `kind` is "industry" or "town". The tab-position settings are for
-- industry windows; a town window's Suppliers tab is found by its caption,
-- or else taken to be the last tab (where the game puts it).
local function inspectTabs(windowComponent, config, kind)
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
		if kind == "town" then
			info.consumers = nil
		else
			if config.suppliersTab > 0 then info.suppliers = config.suppliersTab - 1 end
			if config.consumersTab > 0 then info.consumers = config.consumersTab - 1 end
		end
		info.count = numTabs
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

-- The demand number of a { supply, needs } pair (or a bare number).
local function demandOf(value)
	if type(value) == "number" then return value end
	if type(value) ~= "table" then return 0 end
	return tonumber(value[2] or value.needs or value.limit) or 0
end

-- What a town needs right now: cargo whose demand in its land uses'
-- cargo2supplyAndNeeds (COMMERCIAL / INDUSTRIAL / RESIDENTIAL) is above 0.
-- The data also lists cargo the town will only ask for once it grows, with
-- demand 0; those are left out. Returns needs, hasData.
local function describe(value, depth)
	depth = depth or 0
	if type(value) == "userdata" then
		local ok, text = pcall(function()
			local parts = {}
			for k, v in pairs(value) do parts[#parts + 1] = tostring(k) .. "=" .. describe(v, depth + 1) end
			return "u{" .. table.concat(parts, ",") .. "}"
		end)
		if ok then return text end
		local okLen, n = pcall(function() return #value end)
		if okLen and n and n > 0 and depth < 3 then
			local parts = {}
			for i = 1, n do
				local okItem, item = pcall(function() return value[i] end)
				parts[#parts + 1] = okItem and describe(item, depth + 1) or "?"
			end
			return "u[" .. table.concat(parts, ",") .. "]"
		end
		return tostring(value)
	end
	if type(value) ~= "table" or depth > 3 then return tostring(value) end
	local parts = {}
	for k, v in pairs(value) do parts[#parts + 1] = tostring(k) .. "=" .. describe(v, depth + 1) end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

local function townNeeds(entity)
	local needs, hasData = {}, false
	for landUse, info in pairs(type(entity.lu2cargoInfo) == "table" and entity.lu2cargoInfo or {}) do
		local list = type(info) == "table" and info.cargo2supplyAndNeeds
		if type(list) == "table" then
			for cargo, value in pairs(list) do
				if type(cargo) == "string" then
					hasData = true
					if demandOf(value) > 0 then needs[cargo] = true end
					log("town", entity.id, landUse, cargo, "supplyAndNeeds=", describe(value),
						"productionAndNeeds=", describe(type(info.cargo2productionAndNeeds) == "table"
							and info.cargo2productionAndNeeds[cargo]))
				end
			end
		end
	end
	return needs, hasData
end

-- Iterates a Lua table or a userdata vector (0- or 1-based).
local function eachValue(container, fn)
	if container == nil then return end
	local ok = pcall(function()
		for key, value in pairs(container) do fn(value, key) end
	end)
	if ok then return end
	pcall(function()
		local n = #container
		for i = 0, n do
			local okItem, value = pcall(function() return container[i] end)
			if okItem and value ~= nil then fn(value, i) end
		end
	end)
end

-- Cargo id ("FOOD") for a cargo given as id string or cargoTypeRep index.
local function cargoId(value)
	if type(value) == "string" and value ~= "" then return value end
	local index = tonumber(value)
	if not index then return nil end
	local rep = api.res.cargoTypeRep
	local ok, name = pcall(function() return rep.getName(index) end)
	if not (ok and type(name) == "string" and name ~= "") then
		ok, name = pcall(function() return rep.get(index).id end)
	end
	if ok and type(name) == "string" and name ~= "" then
		return (name:match("([^/\\]+)$") or name):gsub("%.lua$", ""):upper()
	end
	return nil
end

-- Primary source: the cargo the town requests, from its TOWN component
-- (cargoNeeds per land use). This is what the town's Suppliers tab lists,
-- whether or not anything has been delivered yet. Returns needs, hasData.
local function townNeedsFromComponent(townId)
	local needs, hasData = {}, false
	pcall(function()
		local town = api.engine.getComponent(townId, api.type.ComponentType.TOWN)
		local cargoNeeds = town and town.cargoNeeds
		if cargoNeeds == nil then return end
		eachValue(cargoNeeds, function(perLandUse)
			local function add(value)
				local cargo = cargoId(value)
				if cargo then
					needs[cargo] = true
					hasData = true
				end
			end
			if type(perLandUse) == "string" or type(perLandUse) == "number" then
				add(perLandUse)
			else
				eachValue(perLandUse, add)
			end
		end)
	end)
	return needs, hasData
end

-- Primary source: the keys of townBuildingSystem.getCargoSupplyAndLimit(town)
-- are exactly the cargo the town asks for (its Suppliers tab), even before
-- anything is delivered (the value is then 0), e.g. Osaka {14,12,11,15},
-- Incheon {11,14}.
local function townNeedsFromSystem(townId)
	local needs, hasData = {}, false
	pcall(function()
		local map = api.engine.system.townBuildingSystem.getCargoSupplyAndLimit(townId)
		for key, value in pairs(map) do
			local cargo = key
			if type(key) ~= "string" then
				local rep = api.res.cargoTypeRep
				local okName, name = pcall(function() return rep.getName(key) end)
				if not (okName and type(name) == "string") then
					okName, name = pcall(function() return rep.get(key).id end)
				end
				cargo = okName and type(name) == "string" and name or nil
			end
			if cargo then
				hasData = true
				needs[cargo] = true
			end
		end
	end)
	return needs, hasData
end

local function makeTown(townId)
	local entity = getEntity(townId)
	if not entity or entity.type ~= "TOWN" then return nil end
	local x, y = positionOf(entity)
	if not x then return nil end
	if settings().debug then
		pcall(function()
			local town = api.engine.getComponent(townId, api.type.ComponentType.TOWN)
			log("town", townId, "TOWN.cargoNeeds=", describe(town and town.cargoNeeds))
		end)
		pcall(function()
			log("town", townId, "getCargoSupplyAndLimit=",
				describe(api.engine.system.townBuildingSystem.getCargoSupplyAndLimit(townId)))
		end)
	end
	-- Fallbacks: cargo with demand > 0, then TOWN.cargoNeeds (which lists
	-- every cargo the town could ever want).
	local needs, hasData = townNeedsFromSystem(townId)
	if not hasData or next(needs) == nil then
		needs, hasData = townNeeds(entity)
		if not hasData or next(needs) == nil then
			log("town", townId, "no requested cargo found; using TOWN.cargoNeeds")
			needs, hasData = townNeedsFromComponent(townId)
		end
	end
	if not hasData then
		-- No demand data at all: assume the usual town cargo.
		log("town", townId, "has no cargo demand data, using the default town cargo list")
		for _, cargo in ipairs(TOWN_CARGO) do needs[cargo] = true end
	end
	local list = {}
	for cargo in pairs(needs) do list[#list + 1] = cargo end
	table.sort(list)
	log("town", townId, tostring(entity.name), "needs:", table.concat(list, ", "))
	return {
		id = townId,
		name = tostring(entity.name or ""),
		x = x, y = y,
		recipe = { inputs = needs, outputs = {} },
	}
end

-- Clicking a house opens its town's window, so map town buildings to the town:
-- first through townBuildingSystem, else the nearest town.
local function townForBuilding(entityId, entity)
	local direct = tonumber(entity.town or entity.townId or entity.townEntity)
	if direct and (getEntity(direct) or {}).type == "TOWN" then return direct end
	local ok, map = pcall(function() return api.engine.system.townBuildingSystem.getTown2BuildingMap() end)
	if ok and map then
		local found = nil
		pcall(function()
			for town, buildings in pairs(map) do
				for _, building in pairs(buildings) do
					if tonumber(building) == entityId then found = tonumber(town) return end
				end
			end
		end)
		if found then return found end
	end
	local x, y = positionOf(entity)
	if not x then return nil end
	local okTowns, towns = pcall(game.interface.getEntities, { pos = { x, y }, radius = 1e9 }, { type = "TOWN", includeData = false })
	local best, bestDistance = nil, math.huge
	for key, value in pairs(okTowns and type(towns) == "table" and towns or {}) do
		local id = tonumber(value) or tonumber(key)
		local tx, ty = positionOf(getEntity(id))
		if tx then
			local d = (tx - x) ^ 2 + (ty - y) ^ 2
			if d < bestDistance then best, bestDistance = id, d end
		end
	end
	return best
end

local function resolveTownId(entityId)
	local entity = getEntity(entityId)
	if not entity then return nil end
	if entity.type == "TOWN" then return entityId end
	if tostring(entity.type):find("TOWN", 1, true) then return townForBuilding(entityId, entity) end
	return nil
end

local function track(entityId)
	local kind, cid = "industry", resolveIndustryId(entityId)
	if not cid and settings().towns then
		local townId = resolveTownId(entityId)
		if townId then kind, cid = "town", townId end
	end
	if not cid then
		local entity = getEntity(entityId)
		log("ignoring entity", entityId, "of type", entity and entity.type)
		return
	end
	local window = state.windows[cid]
	if not window then
		window = { id = cid, kind = kind, seeds = {}, zones = {}, mode = nil, found = false }
		state.windows[cid] = window
		log("tracking", kind, "window", cid, "from entity", entityId)
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
	local tabs = inspectTabs(windowComponent, config, window.kind)
	if window.kind == "town" then
		-- No tabs at all: show the suppliers while the town window is open.
		if not tabs then return "suppliers", true end
		if tabs.suppliers == nil and (tabs.count or 0) > 0 then tabs.suppliers = tabs.count - 1 end
	end
	if not tabs then return nil, true end
	local current = tonumber((invoke(tabs.widget, "getCurrentTabIndex")))
	if not window.loggedTabs then
		window.loggedTabs = true
		local labels = {}
		for i = 0, #tabs.labels do labels[#labels + 1] = i .. "=" .. tostring(tabs.labels[i]) end
		log("tabs of", window.kind, window.id, ":", table.concat(labels, ", "),
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
	local target
	if window.kind == "town" then
		target = makeTown(window.id)
	else
		target = findIndustry(industries, window.id)
	end
	if not target then
		clearZones(window)
		return
	end
	local groups = computeLinks(target, mode, industries, state.maxPerCargo or config.maxPerCargo)
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

	if state.pendingArrows ~= nil or state.pendingLines ~= nil then
		pcall(applyPendingControls)
	end
	if state.pendingCargo ~= nil then pcall(applyCargoClick) end

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

-- Savegame persistence of the legend choices. The engine-side script keeps
-- the choice and saves it; the GUI side receives it through load().

local function validChoice(data)
	if type(data) ~= "table" then return nil end
	local lines = tonumber(data.maxPerCargo)
	local known = false
	for _, value in ipairs(LINE_CHOICES) do known = known or value == lines end
	return { arrowsOn = data.arrowsOn ~= false, maxPerCargo = known and lines or nil }
end

-- engine state
function M.handleEvent(src, id, name, param)
	if id == EVENT_ID and name == "settings" then
		state.persist = validChoice(param)
	end
end

function M.save()
	return state.persist
end

-- Called with the saved data in both states (in the GUI several times a second).
function M.load(data)
	local choice = validChoice(data)
	state.persist = choice
	if not choice then return end
	local sent = state.sentChoice
	if sent then
		-- Ignore stale data until the engine has stored what we sent.
		if sent.arrowsOn ~= choice.arrowsOn or sent.maxPerCargo ~= choice.maxPerCargo then return end
		state.sentChoice = nil
	end
	if choice.arrowsOn ~= state.arrowsOn or choice.maxPerCargo ~= state.maxPerCargo then
		state.arrowsOn = choice.arrowsOn
		state.maxPerCargo = choice.maxPerCargo
		pcall(syncControls)
		redrawAll()
	end
end

-- Exposed for tests.
M._computeLinks = computeLinks
M._arrows = arrows
M._matches = matches
M._TAB_WORDS = TAB_WORDS

return M
