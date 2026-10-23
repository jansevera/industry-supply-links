local ssu = require "stylesheetutil"
local palette = require "industry_supply_links/palette"

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	for index, colour in ipairs(palette) do
		a("isl-colour-" .. index, {
			color = { colour[1], colour[2], colour[3], 1 },
			fontSize = 18,
		})
	end

	return result
end
