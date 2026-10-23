local links = require "industry_supply_links/links"

function data()
	return {
		guiUpdate = function()
			links.guiUpdate()
		end,
		guiHandleEvent = function(id, name, param)
			links.guiHandleEvent(id, name, param)
		end,
	}
end
