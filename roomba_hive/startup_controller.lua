local ok, err = pcall(function() shell.run("/roomba/controller.lua") end)
if not ok then printError("Roomba controller failed: " .. tostring(err)) end
