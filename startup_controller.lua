local ok, result = pcall(function()
    return shell.run("/roomba/controller.lua")
end)
if not ok then
    printError("Roomba controller crashed: " .. tostring(result))
elseif result == false then
    printError("Roomba controller stopped with an error.")
end
