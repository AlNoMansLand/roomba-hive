-- Roomba Hive one-command installer v0.1.2
-- Usage:
--   wget run <raw-install-url> controller
--   wget run <raw-install-url> worker
--   wget run <raw-install-url> reset

local args = { ... }
local role = args[1] and args[1]:lower() or nil
local BASE_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main"

local function fail(message)
    printError(message)
    error(message, 0)
end

if role == "reset" then
    term.clear()
    term.setCursorPos(1, 1)
    print("ROOMBA HIVE FACTORY RESET")
    print("==========================")
    print("This deletes /roomba, /startup.lua, and the computer label.")
    print("Controller maps and all saved job/worker state will be erased.")
    write("Type RESET to continue: ")
    if read() ~= "RESET" then
        print("Cancelled.")
        return
    end
    if fs.exists("/roomba") then fs.delete("/roomba") end
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    if fs.exists("/roomba-reset.lua") then fs.delete("/roomba-reset.lua") end
    os.setComputerLabel(nil)
    print("Factory reset complete. Rebooting...")
    sleep(2)
    os.reboot()
end

local files = {
    controller = {
        { remote = "roomba_controller.lua", localPath = "/roomba/controller.lua" },
        { remote = "startup_controller.lua", localPath = "/startup.lua" },
    },
    worker = {
        { remote = "roomba_worker.lua", localPath = "/roomba/worker.lua" },
        { remote = "startup_worker.lua", localPath = "/startup.lua" },
    },
}

if not files[role] then fail("Usage: install.lua controller|worker|reset") end
if not http then fail("HTTP is disabled in CC:Tweaked.") end
if not fs.exists("/roomba") then fs.makeDir("/roomba") end

local function download(url, path)
    print("Downloading " .. path .. "...")
    local response, err = http.get(url .. "?v=012b")
    if not response then fail("Download failed: " .. tostring(err)) end
    local body = response.readAll()
    response.close()
    if not body or body == "" then fail("Downloaded an empty file: " .. url) end
    local tmp = path .. ".new"
    local h = assert(fs.open(tmp, "w"))
    h.write(body)
    h.close()
    if fs.exists(path .. ".old") then fs.delete(path .. ".old") end
    if fs.exists(path) then fs.move(path, path .. ".old") end
    fs.move(tmp, path)
end

term.clear()
term.setCursorPos(1, 1)
print("Roomba Hive Installer v0.1.2b")
print("============================")
print("Role: " .. role)
print("")

for _, entry in ipairs(files[role]) do
    download(BASE_URL .. "/" .. entry.remote, entry.localPath)
end

download(BASE_URL .. "/patch_v012.lua", "/roomba/patch_v012.lua")
download(BASE_URL .. "/roomba_reset.lua", "/roomba-reset.lua")

local ok, result = pcall(function()
    return shell.run("/roomba/patch_v012.lua", role)
end)
if not ok then fail("v0.1.2 patch crashed: " .. tostring(result)) end
if result == false then fail("v0.1.2 patch reported a failure. The old program was left available as .old.") end

if role == "controller" then
    os.setComputerLabel("Roomba Hive Controller")
else
    -- Existing saved dock label will be restored by the worker on reboot.
    if not os.getComputerLabel() then os.setComputerLabel("Roomba Worker (unassigned)") end
end

print("")
term.setTextColor(colors.lime)
print("Installation complete.")
term.setTextColor(colors.white)
print("Factory reset command: roomba-reset")
print("Rebooting in 3 seconds...")
sleep(3)
os.reboot()
