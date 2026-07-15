if fs.exists("/roomba/boot.lua") then
    local boot = dofile("/roomba/boot.lua")
    boot.prepare("worker")
end
local ok, result = pcall(function() return shell.run("/roomba/worker.lua") end)
local failed = not ok or result == false
if not ok then printError("Roomba worker crashed: " .. tostring(result))
elseif result == false then printError("Roomba worker stopped with an error.") end
if failed and fs.exists("/roomba/update_manifest.db") then
    print("Update startup failed. Retrying so rollback protection can run...")
    sleep(3)
    os.reboot()
end
