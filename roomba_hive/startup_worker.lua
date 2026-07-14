local ok, err = pcall(function() shell.run("/roomba/worker.lua") end)
if not ok then printError("Roomba worker failed: " .. tostring(err)) end
