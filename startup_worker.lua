local ok, result = pcall(function()
    return shell.run("/roomba/worker.lua")
end)
if not ok then
    printError("Roomba worker crashed: " .. tostring(result))
elseif result == false then
    printError("Roomba worker stopped with an error.")
end
