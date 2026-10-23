local recipesOk, recipes = pcall(require, "industry_supply_links/recipes")

local function isIndustry(fileName, data)
	if type(data) ~= "table" then return false end
	if data.type == "INDUSTRY" or tostring(data.type) == "INDUSTRY" then return true end
	local name = string.lower((tostring(fileName or ""):gsub("\\", "/")))
	return name:match("^industry/") ~= nil or name:match("/industry/") ~= nil
end

-- Vanilla industries (and most mods) build their recipe with industryutil from
-- a table called stockListConfig that the updateFn closes over. Find it
-- without running the updateFn.
local function findUpvalue(fn, wanted, depth, seen)
	if type(fn) ~= "function" or depth <= 0 or seen[fn] then return nil end
	if not (debug and type(debug.getupvalue) == "function") then return nil end
	seen[fn] = true
	for index = 1, 64 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == wanted and type(value) == "table" then return value end
		if type(value) == "function" then
			local nested = findUpvalue(value, wanted, depth - 1, seen)
			if nested then return nested end
		end
	end
	return nil
end

local function captureRecipe(store, fileName, data)
	local config = findUpvalue(data.updateFn, "stockListConfig", 6, {})
	if type(config) ~= "table" then return end
	local recipe = recipes.fromStockConfig(config.stocks, config.rule)
	if recipe then store[recipes.normalizeFileName(fileName)] = recipe end
end

function data()
	return {
		info = {
			minorVersion = 15,
			severityAdd = "NONE",
			severityRemove = "NONE",
			name = _("ISL_MOD_NAME"),
			description = _("ISL_MOD_DESC"),
			tags = { "Script Mod", "Misc" },
			visible = true,
			authors = {
				{ name = "JohnnyGP[CZ]", role = "CREATOR" },
			},
			params = {
				{
					key = "maxPerCargo",
					name = _("ISL_PARAM_MAX"),
					tooltip = _("ISL_PARAM_MAX_TIP"),
					values = { "5", "10", "20", _("ISL_ALL") },
					defaultIndex = 1,
				},
				{
					key = "lineWidth",
					name = _("ISL_PARAM_WIDTH"),
					values = { _("ISL_THIN"), _("ISL_NORMAL"), _("ISL_WIDE") },
					defaultIndex = 1,
				},
				{
					key = "fill",
					name = _("ISL_PARAM_FILL"),
					values = { _("ISL_OFF"), _("ISL_ON") },
					defaultIndex = 1,
				},
				{
					key = "consumers",
					name = _("ISL_PARAM_CONSUMERS"),
					tooltip = _("ISL_PARAM_CONSUMERS_TIP"),
					values = { _("ISL_OFF"), _("ISL_ON") },
					defaultIndex = 1,
				},
				{
					key = "towns",
					name = _("ISL_PARAM_TOWNS"),
					tooltip = _("ISL_PARAM_TOWNS_TIP"),
					values = { _("ISL_OFF"), _("ISL_ON") },
					defaultIndex = 1,
				},
				{
					key = "legend",
					name = _("ISL_PARAM_LEGEND"),
					values = { _("ISL_OFF"), _("ISL_ON") },
					defaultIndex = 1,
				},
				{
					key = "suppliersTab",
					name = _("ISL_PARAM_SUPPLIERS_TAB"),
					tooltip = _("ISL_PARAM_TAB_TIP"),
					values = { _("ISL_AUTO"), "1", "2", "3", "4", "5", "6" },
					defaultIndex = 0,
				},
				{
					key = "consumersTab",
					name = _("ISL_PARAM_CONSUMERS_TAB"),
					tooltip = _("ISL_PARAM_TAB_TIP"),
					values = { _("ISL_AUTO"), "1", "2", "3", "4", "5", "6" },
					defaultIndex = 0,
				},
				{
					key = "debug",
					name = _("ISL_PARAM_DEBUG"),
					tooltip = _("ISL_PARAM_DEBUG_TIP"),
					values = { _("ISL_OFF"), _("ISL_ON") },
					defaultIndex = 0,
				},
			},
		},
		runFn = function(settings, modParams)
			local selected = {}
			if modParams and getCurrentModId then
				selected = modParams[getCurrentModId()] or {}
			end
			local function pick(key, default)
				return tonumber(selected[key]) or default
			end

			game.config.industrySupplyLinks = game.config.industrySupplyLinks or { recipes = {} }
			local cfg = game.config.industrySupplyLinks
			cfg.params = {
				maxPerCargo = ({ 5, 10, 20, 0 })[pick("maxPerCargo", 1) + 1] or 10,
				lineWidth = ({ 10, 25, 50 })[pick("lineWidth", 1) + 1] or 25,
				consumers = pick("consumers", 1) == 1,
				legend = pick("legend", 1) == 1,
				fill = pick("fill", 1) == 1,
				towns = pick("towns", 1) == 1,
				suppliersTab = pick("suppliersTab", 0),
				consumersTab = pick("consumersTab", 0),
				debug = pick("debug", 0) == 1,
			}

			if recipesOk then
				local store = cfg.recipes
				addModifier("loadConstruction", function(fileName, data)
					if isIndustry(fileName, data) then
						pcall(captureRecipe, store, fileName, data)
					end
					return data
				end)
			end
		end,
	}
end
