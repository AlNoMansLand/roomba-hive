-- Roomba Hive direct installer v0.2.3
-- Usage:
--   wget run <raw install.lua URL> controller
--   wget run <raw install.lua URL> worker
--   wget run <raw install.lua URL> reset
--
-- Updating the controller automatically sends an over-the-air update request
-- to known connected workers. Workers running v0.2.3 or later can update
-- themselves without being terminated manually.

local VERSION = "0.2.3"
local BASE_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main"
local CACHE_TAG = "023"
local PROTOCOL = "roomba_hive_v1"
local STATE_FILE = "/roomba/state.db"
local args = { ... }
local role = args[1] and args[1]:lower() or nil

local function fail(message)
    printError(message)
    error(message, 0)
end

local function readTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local value = textutils.unserialize(handle.readAll())
    handle.close()
    return type(value) == "table" and value or nil
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

local function cacheUrl(url)
    local separator = url:find("?", 1, true) and "&" or "?"
    return url .. separator .. "v=" .. CACHE_TAG .. "&t=" .. tostring(os.epoch("utc"))
end

local function download(url, path)
    print("Downloading " .. path .. "...")
    local response, requestError = http.get(cacheUrl(url))
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

local function knownWorkerIds()
    local result, seen = {}, {}
    local state = readTable(STATE_FILE) or {}

    local function add(id)
        id = tonumber(id)
        if id and id ~= os.getComputerID() and not seen[id] then
            seen[id] = true
            result[#result + 1] = id
        end
    end

    for _, id in pairs(state.docks or {}) do add(id) end
    for _, id in pairs(state.dockOccupancy or {}) do add(id) end

    local now = os.epoch("utc")
    for key, worker in pairs(state.workers or {}) do
        local recent = not worker.lastSeen or now - worker.lastSeen <= 120000
        if recent then add(worker.id or key) end
    end

    table.sort(result)
    return result
end

local function requestWorkerUpdates()
    local modem = peripheral.find("modem", function(_, peripheralObject)
        return peripheralObject.isWireless and peripheralObject.isWireless()
    end)
    if not modem then
        print("No wireless modem found; skipping automatic worker updates.")
        return
    end

    local modemSide = peripheral.getName(modem)
    if not rednet.isOpen(modemSide) then rednet.open(modemSide) end

    local ids = knownWorkerIds()
    if #ids == 0 then
        print("No known workers found for automatic update.")
        return
    end

    print("")
    print("Requesting worker updates:")
    local request = {
        type = "update_request",
        version = VERSION,
        cacheTag = CACHE_TAG,
        controller = os.getComputerID(),
    }

    for _, id in ipairs(ids) do
        print("  Turtle #" .. tostring(id))
        -- Repeat the request in case the first wireless packet is missed.
        rednet.send(id, request, PROTOCOL)
        sleep(0.15)
        rednet.send(id, request, PROTOCOL)
    end

    print("Docks running v0.2.3+ will update and reboot automatically.")
    print("Busy workers queue the update until safely docked.")
    print("Older workers require one final manual v0.2.3 installation.")
    sleep(1.5)
end

term.clear()
term.setCursorPos(1, 1)
print("Roomba Hive Installer v" .. VERSION)
print("============================")
print("Role: " .. role)
print("")

if role == "controller" then requestWorkerUpdates() end

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
print("Future controller updates can be started with:")
print("  [U] Update Hive")
print("or: roomba update")
print("Factory reset command: roomba reset")
print("Rebooting in 3 seconds...")
sleep(3)
os.reboot()
