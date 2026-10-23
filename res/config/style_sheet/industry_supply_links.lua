local ssu = require "stylesheetutil"

-- Same colours as res/scripts/industry_supply_links/palette.lua (kept inline so
-- the style sheet does not depend on the script search path).
local palette = {
	{ 0.96, 0.19, 0.21 },
	{ 0.27, 0.69, 1.00 },
	{ 1.00, 0.86, 0.13 },
	{ 0.40, 0.87, 0.25 },
	{ 0.79, 0.30, 0.81 },
	{ 0.98, 0.55, 0.15 },
	{ 0.10, 0.85, 0.85 },
	{ 1.00, 0.45, 0.70 },
	{ 0.95, 0.95, 0.95 },
	{ 0.60, 0.40, 0.20 },
}

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	for index, c in ipairs(palette) do
		local colour = { c[1], c[2], c[3], 1 }
		local style = { backgroundColor = colour, color = colour, fontSize = 16 }
		-- by component name and by style class ("!")
		a("isl-swatch-" .. index, style)
		a("!isl-swatch-" .. index, style)
	end

	a("isl-swatch-cell", { padding = { 0, 4, 0, 4 } })

	return result
end
