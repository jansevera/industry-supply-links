local links = require "industry_supply_links/links"

function data()
	return {
		save = function()
			return links.save()
		end,
		load = function(data)
			links.load(data)
		end,
		handleEvent = function(src, id, name, param)
			links.handleEvent(src, id, name, param)
		end,
		guiUpdate = function()
			links.guiUpdate()
		end,
		guiHandleEvent = function(id, name, param)
			links.guiHandleEvent(id, name, param)
		end,
	}
end
