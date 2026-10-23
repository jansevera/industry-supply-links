-- Which cargo each industry type can consume (inputs) and produce (outputs).
--
-- Three sources are merged, in this order:
--   1. recipes captured from the loaded .con files while the game loads
--      (mod.lua puts them into game.config.industrySupplyLinks.recipes),
--   2. the built-in table of vanilla industries below,
--   3. cargo the industry has actually produced or consumed (observed at runtime).
-- The result describes what an industry *could* trade, not what it trades now.

local M = {}

M.VANILLA = {
	["industry/coal_mine.con"]             = { inputs = {}, outputs = { "COAL" } },
	["industry/farm.con"]                  = { inputs = {}, outputs = { "GRAIN" } },
	["industry/forest.con"]                = { inputs = {}, outputs = { "LOGS" } },
	["industry/iron_ore_mine.con"]         = { inputs = {}, outputs = { "IRON_ORE" } },
	["industry/oil_well.con"]              = { inputs = {}, outputs = { "CRUDE" } },
	["industry/quarry.con"]                = { inputs = {}, outputs = { "STONE" } },
	["industry/chemical_plant.con"]        = { inputs = { "OIL" }, outputs = { "PLASTIC" } },
	["industry/construction_material.con"] = { inputs = { "STONE" }, outputs = { "CONSTRUCTION_MATERIALS" } },
	["industry/food_processing_plant.con"] = { inputs = { "GRAIN" }, outputs = { "FOOD" } },
	["industry/fuel_refinery.con"]         = { inputs = { "OIL" }, outputs = { "FUEL" } },
	["industry/goods_factory.con"]         = { inputs = { "PLASTIC", "STEEL" }, outputs = { "GOODS" } },
	["industry/machines_factory.con"]      = { inputs = { "PLANKS", "STEEL" }, outputs = { "MACHINES" } },
	["industry/oil_refinery.con"]          = { inputs = { "CRUDE" }, outputs = { "OIL" } },
	["industry/saw_mill.con"]              = { inputs = { "LOGS" }, outputs = { "PLANKS" } },
	["industry/steel_mill.con"]            = { inputs = { "IRON_ORE", "COAL" }, outputs = { "STEEL" } },
	["industry/tools_factory.con"]         = { inputs = { "PLANKS" }, outputs = { "TOOLS" } },
}

local function normalizeFileName(fileName)
	return string.lower((tostring(fileName or ""):gsub("\\", "/")))
end

local function baseName(fileName)
	return normalizeFileName(fileName):match("([^/]+)$") or ""
end

local VANILLA_BY_BASENAME = {}
for fileName, recipe in pairs(M.VANILLA) do
	VANILLA_BY_BASENAME[baseName(fileName)] = recipe
end

-- Turns the rule data of an industry .con (stockListConfig or an updateFn
-- result) into { inputs = {...}, outputs = {...} }. Used by mod.lua at load time.
function M.fromStockConfig(stocks, rule)
	local recipe = { inputs = {}, outputs = {} }
	for _, stock in ipairs(stocks or {}) do
		local cargo = type(stock) == "table" and stock.cargoType or stock
		if type(cargo) == "string" and cargo ~= "" then
			recipe.inputs[#recipe.inputs + 1] = cargo
		end
	end
	if type(rule) == "table" and type(rule.output) == "table" then
		for cargo, amount in pairs(rule.output) do
			if type(cargo) == "string" and (tonumber(amount) or 1) > 0 then
				recipe.outputs[#recipe.outputs + 1] = cargo
			end
		end
	end
	table.sort(recipe.outputs)
	if #recipe.inputs == 0 and #recipe.outputs == 0 then return nil end
	return recipe
end

local function addAll(set, list)
	for _, cargo in ipairs(list or {}) do set[cargo] = true end
end

-- Returns { inputs = set, outputs = set } for a construction file name.
-- `captured` is the table mod.lua collected at load time (may be nil).
function M.lookup(fileName, captured)
	local result = { inputs = {}, outputs = {} }
	local key = normalizeFileName(fileName)
	local fromLoader = captured and (captured[key] or captured[fileName])
	if fromLoader then
		addAll(result.inputs, fromLoader.inputs)
		addAll(result.outputs, fromLoader.outputs)
	end
	local vanilla = M.VANILLA[key] or VANILLA_BY_BASENAME[baseName(key)]
	-- Only fall back to the vanilla table when the loader found nothing, so a
	-- mod that changes a vanilla industry's recipe wins.
	if vanilla and not fromLoader then
		addAll(result.inputs, vanilla.inputs)
		addAll(result.outputs, vanilla.outputs)
	end
	return result
end

-- Adds cargo seen in SIM_BUILDING statistics (itemsProduced / itemsConsumed).
function M.addObserved(recipe, simBuildingData)
	if type(simBuildingData) ~= "table" then return end
	local function scan(stats, target)
		if type(stats) ~= "table" then return end
		for cargo, amount in pairs(stats) do
			if type(cargo) == "string" and cargo:sub(1, 1) ~= "_" and (tonumber(amount) or 0) > 0 then
				target[cargo] = true
			end
		end
	end
	scan(simBuildingData.itemsProduced, recipe.outputs)
	scan(simBuildingData.itemsConsumed, recipe.inputs)
end

M.normalizeFileName = normalizeFileName

return M
