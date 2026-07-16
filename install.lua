-- Roomba Hive direct transactional installer v0.3.6
-- Usage: wget run <raw install.lua URL> controller|worker|pocket|reset

local VERSION = "0.3.6"
local CACHE_TAG = "036"
local BASE_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main"
local ROOT = "/roomba"
local MANIFEST = fs.combine(ROOT, "update_manifest.db")
local INSTALL_MARKER = fs.combine(ROOT, "last_install.db")
local LEGACY_PROTOCOL = "roomba_hive_v1"
local WORKER_PROTOCOL = "roomba_hive_worker_v2"
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

local function writeTable(path, value)
    local temporary = path .. ".tmp"
    local handle, openError = fs.open(temporary, "w")
    if not handle then fail("Cannot write " .. path .. ": " .. tostring(openError)) end
    handle.write(textutils.serialize(value))
    handle.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(temporary, path)
end

local function factoryReset()
    term.clear(); term.setCursorPos(1, 1)
    print("ROOMBA HIVE FACTORY RESET")
    print("==========================")
    print("This deletes programs, maps, jobs, pairings, and device state.")
    write("Type RESET to continue: ")
    if read() ~= "RESET" then print("Cancelled."); return end
    if fs.exists(ROOT) then fs.delete(ROOT) end
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    if fs.exists("/roomba.lua") then fs.delete("/roomba.lua") end
    os.setComputerLabel(nil)
    print("Factory reset complete. Rebooting...")
    sleep(2); os.reboot()
end

if role == "reset" then factoryReset(); return end

local files = {
    controller = {
        { remote = "roomba_controller.lua", path = "/roomba/controller.lua" },
        { remote = "roomba_crypto.lua", path = "/roomba/crypto.lua" },
        { remote = "roomba_boot.lua", path = "/roomba/boot.lua" },
        { remote = "startup_controller.lua", path = "/startup.lua" },
        { remote = "roomba.lua", path = "/roomba.lua" },
    },
    worker = {
        { remote = "roomba_worker.lua", path = "/roomba/worker.lua" },
        { remote = "roomba_boot.lua", path = "/roomba/boot.lua" },
        { remote = "startup_worker.lua", path = "/startup.lua" },
        { remote = "roomba.lua", path = "/roomba.lua" },
    },
    pocket = {
        { remote = "roomba_pocket.lua", path = "/roomba/pocket.lua" },
        { remote = "roomba_crypto.lua", path = "/roomba/crypto.lua" },
        { remote = "roomba_boot.lua", path = "/roomba/boot.lua" },
        { remote = "startup_pocket.lua", path = "/startup.lua" },
        { remote = "roomba.lua", path = "/roomba.lua" },
    },
}

if not files[role] then fail("Usage: install.lua controller|worker|pocket|reset") end
if not http then fail("HTTP is disabled in the CC:Tweaked configuration.") end
if not fs.exists(ROOT) then fs.makeDir(ROOT) end

local function coordinatedTargetVersion()
    if role == "controller" then
        local controllerState = readTable(fs.combine(ROOT, "state.db")) or {}
        local update = controllerState.safeUpdate
        if type(update) == "table" and update.stage == "installing_controller" then
            return update.targetVersion
        end
    elseif role == "pocket" then
        local pocketState = readTable(fs.combine(ROOT, "pocket_state.db")) or {}
        local update = pocketState.pendingSafeUpdate
        if type(update) == "table" and update.committed == true then
            return update.targetVersion
        end
    end
    return nil
end

local coordinatedTarget = coordinatedTargetVersion()
if coordinatedTarget and tostring(coordinatedTarget) ~= VERSION then
    fail("GitHub changed to v" .. VERSION .. " after this Safe Update selected v" .. tostring(coordinatedTarget)
        .. ". Start Safe Update again so workers, controller, and pocket stay on one release.")
end

local function cacheUrl(remote)
    return BASE_URL .. "/" .. remote
        .. "?v=" .. CACHE_TAG
        .. "&device=" .. tostring(os.getComputerID())
        .. "&t=" .. tostring(os.epoch("utc"))
end

local function knownWorkerIds()
    local state = readTable(fs.combine(ROOT, "state.db")) or {}
    local result, seen = {}, {}
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
        if not worker.lastSeen or now - worker.lastSeen <= 300000 then add(worker.id or key) end
    end
    table.sort(result)
    return result
end

local function safeUpdateWorkersAlreadyVerified()
    local controllerState = readTable(fs.combine(ROOT, "state.db")) or {}
    local update = controllerState.safeUpdate
    return type(update) == "table"
        and update.stage == "installing_controller"
        and update.workersVerified == true
        and tostring(update.targetVersion or "") == VERSION
end

local function requestWorkerUpdates()
    if safeUpdateWorkersAlreadyVerified() then
        print("Safe Update already verified all workers on v" .. VERSION .. "; skipping duplicate worker reboots.")
        return
    end

    local modem = peripheral.find("modem", function(_, device)
        return device.isWireless and device.isWireless()
    end)
    if not modem then
        print("No wireless modem found; worker update requests skipped.")
        return
    end
    local side = peripheral.getName(modem)
    if not rednet.isOpen(side) then rednet.open(side) end
    local ids = knownWorkerIds()
    if #ids == 0 then print("No known workers found for update."); return end

    local request = {
        type = "update_request",
        version = VERSION,
        protocolVersion = 2,
        cacheTag = CACHE_TAG,
        controller = os.getComputerID(),
        force = false,
    }
    print("Requesting updates from " .. tostring(#ids) .. " worker(s)...")
    for _, id in ipairs(ids) do
        rednet.send(id, request, LEGACY_PROTOCOL)
        rednet.send(id, request, WORKER_PROTOCOL)
        sleep(0.1)
        rednet.send(id, request, LEGACY_PROTOCOL)
        rednet.send(id, request, WORKER_PROTOCOL)
        sleep(0.15)
        rednet.send(id, request, LEGACY_PROTOCOL)
        rednet.send(id, request, WORKER_PROTOCOL)
    end
    sleep(2)
end

local function downloadAll(entries)
    for _, entry in ipairs(entries) do
        print("Downloading " .. entry.remote .. "...")
        local response, requestError = http.get(cacheUrl(entry.remote))
        if not response then fail("Download failed for " .. entry.remote .. ": " .. tostring(requestError)) end
        local body = response.readAll(); response.close()
        if not body or body == "" then fail("Downloaded an empty file: " .. entry.remote) end
        local compiled, syntaxError = load(body, "@" .. entry.path, "t", _ENV)
        if not compiled then fail("Syntax error in " .. entry.remote .. ": " .. tostring(syntaxError)) end
        local handle, openError = fs.open(entry.path .. ".new", "w")
        if not handle then fail("Cannot write temporary update: " .. tostring(openError)) end
        handle.write(body); handle.close()
    end
end

local function cleanupTemps(entries)
    for _, entry in ipairs(entries) do
        if fs.exists(entry.path .. ".new") then fs.delete(entry.path .. ".new") end
    end
end

local function rollback(entries)
    for _, entry in ipairs(entries) do
        local backup = entry.path .. ".old"
        if fs.exists(backup) then
            if fs.exists(entry.path) then fs.delete(entry.path) end
            fs.move(backup, entry.path)
        end
    end
end

local function commit(entries)
    local paths = {}
    for _, entry in ipairs(entries) do paths[#paths + 1] = entry.path end
    writeTable(MANIFEST, {
        role = role,
        targetVersion = VERSION,
        files = paths,
        attempts = 0,
        installedAt = os.epoch("utc"),
    })

    local ok, commitError = pcall(function()
        for _, entry in ipairs(entries) do
            local backup = entry.path .. ".old"
            if fs.exists(backup) then fs.delete(backup) end
            if fs.exists(entry.path) then fs.move(entry.path, backup) end
            fs.move(entry.path .. ".new", entry.path)
        end
    end)
    if not ok then
        rollback(entries)
        cleanupTemps(entries)
        if fs.exists(MANIFEST) then fs.delete(MANIFEST) end
        fail("Update transaction failed and was rolled back: " .. tostring(commitError))
    end
end

term.clear(); term.setCursorPos(1, 1)
print("Roomba Hive Installer v" .. VERSION)
print("============================")
print("Role: " .. role)
print("")

if role == "controller" then requestWorkerUpdates() end
cleanupTemps(files[role])
downloadAll(files[role])
commit(files[role])
writeTable(INSTALL_MARKER, {
    role = role,
    targetVersion = VERSION,
    cacheTag = CACHE_TAG,
    installedAt = os.epoch("utc"),
})

if role == "controller" then os.setComputerLabel("Roomba Hive Controller")
elseif role == "pocket" then os.setComputerLabel("Roomba Hive Pocket")
elseif not os.getComputerLabel() then os.setComputerLabel("Roomba Worker (unassigned)") end

print("")
term.setTextColor(colors.lime); print("Installation complete."); term.setTextColor(colors.white)
print("Two failed startup attempts trigger automatic rollback to the previous files.")
print("Rebooting in 3 seconds...")
sleep(3); os.reboot()
