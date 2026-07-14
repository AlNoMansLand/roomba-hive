-- Roomba Hive direct installer v0.2.1
-- Usage:
--   wget run <raw install.lua URL> controller
--   wget run <raw install.lua URL> worker
--   wget run <raw install.lua URL> reset

local VERSION = "0.2.1"
local BASE_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main"
local CACHE_TAG = "021"
local args = { ... }
local role = args[1] and args[1]:lower() or nil

local function fail(message)
    printError(message)
    error(message, 0)
end

local function factoryReset()
    term.clear()
    term.setCursorPos(1, 1)
    print("ROOMBA HIVE FACTORY RESET")
    print("==========================")
    print("This permanently deletes the Roomba program, maps, and saved state.")
    write("Type RESET to continue: ")
    if read() ~= "RESET" then print("Cancelled."); return end
    if fs.exists("/roomba") then fs.delete("/roomba") end
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    if fs.exists("/roomba.lua") then fs.delete("/roomba.lua") end
    os.setComputerLabel(nil)
    print("Factory reset complete. Rebooting...")
    sleep(2)
    os.reboot()
end

if role == "reset" then factoryReset(); return end

local files = {
    controller = {
        { remote = "roomba_controller.lua", localPath = "/roomba/controller.lua" },
        { remote = "startup_controller.lua", localPath = "/startup.lua" },
        { remote = "roomba.lua", localPath = "/roomba.lua" },
    },
    worker = {
        { remote = "roomba_worker.lua", localPath = "/roomba/worker.lua" },
        { remote = "startup_worker.lua", localPath = "/startup.lua" },
        { remote = "roomba.lua", localPath = "/roomba.lua" },
    },
}

if not files[role] then fail("Usage: install.lua controller|worker|reset") end
if not http then fail("HTTP is disabled in the CC:Tweaked configuration.") end
if not fs.exists("/roomba") then fs.makeDir("/roomba") end

local function download(url, path)
    print("Downloading " .. path .. "...")
    local separator = url:find("?", 1, true) and "&" or "?"
    local response, requestError = http.get(url .. separator .. "v=" .. CACHE_TAG)
    if not response then fail("Download failed: " .. tostring(requestError)) end
    local body = response.readAll()
    response.close()
    if not body or body == "" then fail("Downloaded an empty file: " .. url) end

    local compiled, syntaxError = load(body, "@" .. path, "t", _ENV)
    if not compiled then fail("Downloaded Lua has a syntax error for " .. path .. ": " .. tostring(syntaxError)) end

    local temporary = path .. ".new"
    local handle, openError = fs.open(temporary, "w")
    if not handle then fail("Cannot write " .. temporary .. ": " .. tostring(openError)) end
    handle.write(body)
    handle.close()

    local backup = path .. ".old"
    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(path) then fs.move(path, backup) end
    fs.move(temporary, path)
end

term.clear()
term.setCursorPos(1, 1)
print("Roomba Hive Installer v" .. VERSION)
print("============================")
print("Role: " .. role)
print("")

for _, entry in ipairs(files[role]) do
    download(BASE_URL .. "/" .. entry.remote, entry.localPath)
end

if fs.exists("/roomba/patch_v012.lua") then fs.delete("/roomba/patch_v012.lua") end

if role == "controller" then
    os.setComputerLabel("Roomba Hive Controller")
elseif not os.getComputerLabel() then
    os.setComputerLabel("Roomba Worker (unassigned)")
end

print("")
term.setTextColor(colors.lime)
print("Installation complete.")
term.setTextColor(colors.white)
print("Factory reset command: roomba reset")
print("Rebooting in 3 seconds...")
sleep(3)
os.reboot()
