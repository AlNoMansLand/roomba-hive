-- Roomba Hive Controller v0.3.4
-- Runs on an Advanced Computer at logical origin 0,0,0.

local VERSION = "0.3.4"
local PROTOCOL_VERSION = 2
local PROTOCOL = "roomba_hive_worker_v2"
local LEGACY_PROTOCOL = "roomba_hive_v1"
local REMOTE_PROTOCOL = "roomba_hive_remote_v1"
local HOSTNAME = "roomba-hive"
local REMOTE_HOSTNAME = "roomba-hive-remote"
local INSTALL_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua"
local ROOT = "/roomba"
local MAP_DIR = fs.combine(ROOT, "maps")
local BACKUP_DIR = fs.combine(ROOT, "backups")
local STATE_FILE = fs.combine(ROOT, "state.db")
local BOOT_FILE = fs.combine(ROOT, "boot.lua")
local CRYPTO_FILE = fs.combine(ROOT, "crypto.lua")
local DOCK_SIDES = { "front", "right", "back", "left" }
local SIDE_TO_DOCK = { front = "north", right = "east", back = "south", left = "west" }
local DOCK_ORDER = { "north", "east", "south", "west" }
local DOCK_DISPLAY = { north = "front", east = "left", south = "back", west = "right" }
local PULSE_SECONDS = 0.75
local HEARTBEAT_TIMEOUT = 30
local ABORT_RETRY_SECONDS = 5
local COAL_FUEL_UNITS = 80
local PREFLIGHT_TIMEOUT = 6
local MAX_JOB_HISTORY = 20
local MAX_LOG_ENTRIES = 200
local PAIRING_SECONDS = 90

local activeProbeDock = nil
local running = true
local pairingSession = nil
local pendingControllerUpdate = false

assert(fs.exists(CRYPTO_FILE), "Missing /roomba/crypto.lua. Reinstall the controller.")
local crypto = dofile(CRYPTO_FILE)

local modem = peripheral.find("modem", function(_, p)
    return p.isWireless and p.isWireless()
end)
assert(modem, "Attach a wireless or ender modem to the controller.")
local modemSide = peripheral.getName(modem)
rednet.open(modemSide)
rednet.host(PROTOCOL, HOSTNAME)
rednet.host(REMOTE_PROTOCOL, REMOTE_HOSTNAME)

local function ensureDir(path)
    if not fs.exists(path) then fs.makeDir(path) end
end

ensureDir(ROOT)
ensureDir(MAP_DIR)
ensureDir(BACKUP_DIR)

local function copyForSerialization(value, active, path)
    if type(value) ~= "table" then return value end

    active = active or {}
    path = path or "state"
    if active[value] then
        error("Cannot save cyclic controller state at " .. path, 0)
    end

    active[value] = true
    local copy = {}
    for key, item in pairs(value) do
        local copiedKey = copyForSerialization(key, active, path .. ".<key>")
        local copiedValue = copyForSerialization(item, active, path .. "." .. tostring(key))
        copy[copiedKey] = copiedValue
    end
    active[value] = nil
    return copy
end

local function atomicSave(path, value)
    local tmp = path .. ".tmp"
    local handle, err = fs.open(tmp, "w")
    if not handle then error("Cannot write " .. path .. ": " .. tostring(err), 0) end

    -- CC:Tweaked's serializer rejects a table referenced from more than one
    -- location. Runtime messages may legitimately cause those shared
    -- references, especially after reconnect/recovery. Copy each occurrence
    -- independently before serializing while still rejecting actual cycles.
    local serializable = copyForSerialization(value)
    local ok, encoded = pcall(textutils.serialize, serializable)
    if not ok then
        handle.close()
        if fs.exists(tmp) then fs.delete(tmp) end
        error("Cannot serialize controller state: " .. tostring(encoded), 0)
    end

    handle.write(encoded)
    handle.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
end

local function loadTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local value = textutils.unserialize(handle.readAll())
    handle.close()
    return type(value) == "table" and value or nil
end

local state = loadTable(STATE_FILE) or {}
local savedStateVersion = state.version
state.version = VERSION
state.maps = state.maps or {}
state.workers = state.workers or {}
state.docks = state.docks or {}
state.dockOccupancy = {}
state.job = state.job or nil
state.fuelLock = state.fuelLock or nil
state.logs = state.logs or {}
state.jobHistory = state.jobHistory or {}
state.config = state.config or {
    remoteEnabled = true,
    pocketIdleLockSeconds = 300,
    fuelItemUnits = COAL_FUEL_UNITS,
    estimateSafetyMultiplier = 1.25,
}
state.config.siteGeneration = tonumber(state.config.siteGeneration or 1) or 1
state.security = state.security or { enabled = true, paired = {} }
state.security.paired = state.security.paired or {}
state.preflight = state.preflight or nil
state.safeUpdate = state.safeUpdate or nil
state.emergencyRecovery = state.emergencyRecovery or nil
state.relocationMode = state.relocationMode or false

if state.safeUpdate and state.safeUpdate.stage == "committing"
    and savedStateVersion and savedStateVersion ~= VERSION then
    state.safeUpdate.stage = "complete"
    state.safeUpdate.completedVersion = VERSION
    state.safeUpdate.completedAt = os.epoch("utc")
end
state.version = VERSION
state.protocolVersion = PROTOCOL_VERSION

local function saveState()
    state.version = VERSION
    atomicSave(STATE_FILE, state)
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do copy[deepCopy(key, seen)] = deepCopy(item, seen) end
    return copy
end

local function capList(list, maximum)
    while #list > maximum do table.remove(list, 1) end
end

local function nowUtc()
    return os.epoch("utc")
end

local function roleRank(role)
    if role == "administrator" then return 3 end
    if role == "operator" then return 2 end
    return 1
end

local function signedRemoteSend(pocketId, kind, payload)
    local paired = state.security.paired[tostring(pocketId)]
    if not paired or not paired.key then return false end
    paired.serverSeq = (paired.serverSeq or 0) + 1
    local message = payload or {}
    message.type = kind
    message.version = VERSION
    message.protocolVersion = PROTOCOL_VERSION
    message.controllerId = os.getComputerID()
    message.pocketId = pocketId
    message.serverSeq = paired.serverSeq
    crypto.signed(paired.key, message)
    return rednet.send(pocketId, message, REMOTE_PROTOCOL)
end

local function sendAlert(severity, title, message, data)
    if not state.config.remoteEnabled or not state.security.enabled then return end
    for key, paired in pairs(state.security.paired) do
        signedRemoteSend(tonumber(key), "remote_alert", {
            severity = severity,
            title = title,
            message = message,
            data = data,
            createdAt = nowUtc(),
        })
    end
end

local function logEvent(severity, kind, message, data, suppressAlert)
    local entry = {
        time = nowUtc(), severity = severity or "info", kind = kind or "general",
        message = tostring(message or ""), data = data,
    }
    state.logs[#state.logs + 1] = entry
    capList(state.logs, MAX_LOG_ENTRIES)
    if not suppressAlert and (severity == "warning" or severity == "error" or severity == "success") then
        sendAlert(severity, kind, entry.message, data)
    end
    return entry
end

local function isDockedStatus(status)
    return status == "docked" or status == "parked" or status == "aborted"
        or status == "fuel_station_empty" or status == "relocation_ready"
end

local function archiveCurrentJob()
    if not state.job or state.job.archived then return end
    if state.job.status ~= "complete" and state.job.status ~= "aborted" then return end
    state.job.archived = true
    state.job.finished = nowUtc()
    state.jobHistory[#state.jobHistory + 1] = {
        id = state.job.id,
        mapName = state.job.mapName,
        layers = state.job.layers,
        status = state.job.status,
        completedCount = state.job.completedCount or 0,
        started = state.job.started,
        finished = state.job.finished,
        workerCount = #(state.job.sections or {}),
        testRun = state.job.testRun == true,
        forceClosed = state.job.forceClosed == true,
    }
    capList(state.jobHistory, MAX_JOB_HISTORY)
    logEvent(state.job.status == "complete" and "success" or "warning", "job", "Job " .. tostring(state.job.id) .. " finished: " .. tostring(state.job.status), {
        mapName = state.job.mapName, layers = state.job.layers, completed = state.job.completedCount,
    })
end

local function send(id, kind, data)
    data = data or {}
    data.type = kind
    data.version = VERSION
    data.protocolVersion = PROTOCOL_VERSION
    return rednet.send(id, data, PROTOCOL)
end

local function broadcast(kind, data)
    data = data or {}
    data.type = kind
    data.version = VERSION
    data.protocolVersion = PROTOCOL_VERSION
    rednet.broadcast(data, PROTOCOL)
end

local function countMapCells(map)
    local count = 0
    for _ in pairs(map.interior or {}) do count = count + 1 end
    return count
end

local function mapPath(name)
    return fs.combine(MAP_DIR, name .. ".db")
end

local function sanitize(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w%-%_ ]", ""):gsub("%s+", "_"):sub(1, 32)
    return name ~= "" and name or nil
end

local function saveMap(map)
    assert(type(map) == "table", "Invalid map")
    assert(type(map.interior) == "table", "Map has no interior table")
    assert(type(map.bounds) == "table", "Map has no bounds table")
    local name = sanitize(map.name)
    assert(name, "Invalid map name")
    map.name = name
    map.version = map.version or 3
    map.cellCount = countMapCells(map)
    atomicSave(mapPath(name), map)
    state.maps[name] = { cellCount = map.cellCount, bounds = map.bounds }
    saveState()
end

local function loadMap(name)
    return loadTable(mapPath(name))
end

local function listMaps()
    local maps = {}
    for _, file in ipairs(fs.list(MAP_DIR)) do
        if file:sub(-3) == ".db" then maps[#maps + 1] = file:sub(1, -4) end
    end
    table.sort(maps)
    return maps
end

local function validDock(dock)
    for _, name in ipairs(DOCK_ORDER) do
        if dock == name then return true end
    end
    return false
end

local function workerIsActive(id)
    local worker = state.workers[tostring(id)]
    if not worker or not worker.lastSeen then return false end
    local age = os.epoch("utc") - worker.lastSeen
    return age <= HEARTBEAT_TIMEOUT * 1000
        and not tostring(worker.status or ""):find("^offline")
end

local function restoreReportedDock(sender, reportedDock, worker)
    if not validDock(reportedDock) then return false end
    local assigned = state.docks[reportedDock]
    if assigned and tostring(assigned) ~= tostring(sender) and workerIsActive(assigned) then
        return false
    end

    for dockName, id in pairs(state.docks) do
        if dockName ~= reportedDock and tostring(id) == tostring(sender) then
            state.docks[dockName] = nil
        end
    end

    if assigned and tostring(assigned) ~= tostring(sender) then
        local displaced = state.workers[tostring(assigned)]
        if displaced and displaced.dock == reportedDock then displaced.dock = nil end
    end

    state.docks[reportedDock] = sender
    worker.dock = reportedDock
    return true
end

local function displayDock(dock)
    return dock and (DOCK_DISPLAY[dock] or dock) or "unassigned"
end

local function titleCase(value)
    value = tostring(value or "")
    return value:sub(1, 1):upper() .. value:sub(2)
end

local function mapTestedForCurrentSite(name)
    local map = loadMap(name)
    return map ~= nil and tonumber(map.testedGeneration) == tonumber(state.config.siteGeneration)
end

local function markMapTested(name)
    local map = loadMap(name)
    if not map then return false end
    map.testedGeneration = state.config.siteGeneration
    map.testedAt = nowUtc()
    atomicSave(mapPath(name), map)
    state.maps[name] = state.maps[name] or {}
    state.maps[name].cellCount = map.cellCount or countMapCells(map)
    state.maps[name].bounds = map.bounds
    state.maps[name].testedGeneration = map.testedGeneration
    saveState()
    return true
end

local function wrapText(text, width)
    text = tostring(text or "")
    width = math.max(1, tonumber(width) or 1)
    local lines, current = {}, ""

    for word in text:gmatch("%S+") do
        if #word > width then
            if current ~= "" then lines[#lines + 1] = current; current = "" end
            local index = 1
            while index <= #word do
                lines[#lines + 1] = word:sub(index, index + width - 1)
                index = index + width
            end
        elseif current == "" then
            current = word
        elseif #current + 1 + #word <= width then
            current = current .. " " .. word
        else
            lines[#lines + 1] = current
            current = word
        end
    end

    if current ~= "" then lines[#lines + 1] = current end
    if #lines == 0 then lines[1] = "" end
    return lines
end

local function printMenuOption(number, label)
    local width = select(1, term.getSize())
    local prefix = tostring(number) .. "  "
    local continuation = string.rep(" ", #prefix)
    local lines = wrapText(label, width - #prefix)
    for index, line in ipairs(lines) do
        print((index == 1 and prefix or continuation) .. line)
    end
end

local function workerLabel(worker)
    return titleCase(displayDock(worker.dock)) .. " #" .. tostring(worker.id)
end

local function isActiveJob()
    return state.job and (
        state.job.status == "running"
        or state.job.status == "paused"
        or state.job.status == "aborting"
    )
end

local function controllerSummary()
    local online, docked, issues = 0, 0, 0
    local fuelState = "OK"
    local attention = nil

    for _, worker in pairs(state.workers) do
        if workerIsActive(worker.id) then online = online + 1 end
        if workerIsActive(worker.id) and isDockedStatus(worker.status) then docked = docked + 1 end

        local status = tostring(worker.status or "unknown")
        if status == "fuel_station_empty" or status == "waiting_for_fuel" then
            fuelState = "RESTOCK"
            attention = attention or (workerLabel(worker) .. " needs fuel")
        elseif status == "output_full" then
            issues = issues + 1
            attention = attention or (workerLabel(worker) .. " output is full")
        elseif status:find("^offline") then
            issues = issues + 1
            attention = attention or (workerLabel(worker) .. " is offline")
        elseif status == "error" or status == "position_unknown" or status == "recovery_required"
            or status == "surface_recovered" or status == "surface_recovery_paused"
            or status == "incompatible" then
            issues = issues + 1
            attention = attention or (workerLabel(worker) .. " needs attention")
        end
    end

    return online, docked, issues, fuelState, attention
end

local function render()
    term.clear()
    term.setCursorPos(1, 1)
    print("ROOMBA HIVE v" .. VERSION)
    print("==============================")

    if state.job then
        print("Job: " .. tostring(state.job.mapName))
        print("Status: " .. tostring(state.job.status) .. " | " .. tostring(state.job.completedCount or 0) .. "/" .. tostring(state.job.layers))
    else
        print("Job: none")
        print("Status: idle")
    end

    local online, docked, issues, fuelState, attention = controllerSummary()
    print("Workers: " .. tostring(online) .. " online | " .. tostring(docked) .. " docked")
    print("Fuel: " .. fuelState .. " | Issues: " .. tostring(issues))

    if state.emergencyRecovery and state.emergencyRecovery.stage ~= "complete" then
        local completed, total = 0, 0
        for _ in pairs(state.emergencyRecovery.expected or {}) do total = total + 1 end
        for _ in pairs(state.emergencyRecovery.completed or {}) do completed = completed + 1 end
        print("RESCUE: " .. tostring(completed) .. "/" .. tostring(total) .. " workers surfaced")
    elseif state.relocationMode then
        print("ATTENTION: relocation mode active")
    elseif attention then
        print("ATTENTION: " .. attention)
    else
        print("Hive ready for commands")
    end

    print("")
    printMenuOption("1", "Operations")
    printMenuOption("2", "Workers")
    printMenuOption("3", "Jobs & Maps")
    printMenuOption("4", "Maintenance")
    printMenuOption("5", "Remote & Security")
    printMenuOption("6", "Logs & History")
    printMenuOption("0", "Exit")
end

local function detectDocks()
    if isActiveJob() then
        print("\nDock detection is disabled during an active job.")
        sleep(2)
        return
    end

    print("\nPlace powered workers against the four horizontal sides, facing outward.")
    state.dockOccupancy = {}
    for _, side in ipairs(DOCK_SIDES) do
        local dock = SIDE_TO_DOCK[side]
        print("Probing " .. displayDock(dock) .. " dock...")
        activeProbeDock = dock
        redstone.setOutput(side, true)
        broadcast("dock_probe_begin", { dock = dock, controller = os.getComputerID() })
        sleep(PULSE_SECONDS)
        redstone.setOutput(side, false)
        activeProbeDock = nil
        local found = state.dockOccupancy[dock]
        print(found and ("  Found turtle #" .. tostring(found)) or "  Empty")
        sleep(0.2)
    end
    local foundCount = 0
    for _ in pairs(state.dockOccupancy) do foundCount = foundCount + 1 end
    if state.relocationMode and foundCount > 0 then
        state.relocationMode = false
        state.relocationAcks = nil
        state.relocationExpected = nil
        logEvent("success", "relocation", "Hive relocation completed with " .. tostring(foundCount) .. " worker(s).")
    end
    saveState()
    print("Dock detection complete. Press Enter.")
    read()
end

local function chooseDockedWorker()
    local choices = {}
    for _, dock in ipairs(DOCK_ORDER) do
        local id = state.dockOccupancy[dock]
        if id then choices[#choices + 1] = { dock = dock, id = id } end
    end
    if #choices == 0 then
        print("No physically docked workers. Run Detect first.")
        sleep(2)
        return nil
    end
    for index, choice in ipairs(choices) do
        print(index .. ") " .. displayDock(choice.dock) .. " turtle #" .. tostring(choice.id))
    end
    write("Choose worker: ")
    return choices[tonumber(read())]
end

local function calibrate()
    if isActiveJob() then
        print("An active job must finish or be aborted first.")
        sleep(2)
        return
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("NEW MAP CALIBRATION")
    local chosen = chooseDockedWorker()
    if not chosen then return end
    write("Map name: ")
    local name = sanitize(read())
    if not name then print("Invalid name."); sleep(2); return end
    print("The closed wall outline must be on layer 1 (Y=-1).")
    print("The selected turtle will trace it and return.")
    write("Type CALIBRATE: ")
    if read() ~= "CALIBRATE" then return end

    state.pendingCalibration = { worker = chosen.id, name = name }
    state.lastCalibrationResult = nil
    saveState()
    send(chosen.id, "calibrate", { name = name })
    print("Calibration started. Waiting for worker...")
    while state.pendingCalibration do sleep(0.5) end

    local result = state.lastCalibrationResult
    if result and result.ok then
        print("Saved '" .. name .. "' with " .. tostring(result.cellCount) .. " cells.")
    else
        print("Calibration failed: " .. tostring(result and result.message or "unknown error"))
    end
    state.lastCalibrationResult = nil
    saveState()
    print("Press Enter.")
    read()
end

local function importLegacyMap()
    if isActiveJob() then
        print("Import is disabled during an active job.")
        sleep(2)
        return
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("IMPORT LEGACY MAP")
    print("Example: /roomba_map.db")
    write("File path: ")
    local path = read()
    if path == "" then path = "/roomba_map.db" end
    local map = loadTable(path)
    if not map or type(map.interior) ~= "table" or type(map.bounds) ~= "table" then
        print("That file is not a compatible Roomba map.")
        sleep(3)
        return
    end
    write("New map name: ")
    local name = sanitize(read())
    if not name then print("Invalid name."); sleep(2); return end
    map.name = name
    saveMap(map)
    print("Imported " .. tostring(countMapCells(map)) .. " cells as '" .. name .. "'.")
    print("Press Enter.")
    read()
end

local function buildSections(layers, workers)
    local sections = {}
    local activeCount = math.min(layers, #workers)
    if activeCount <= 0 then return sections end
    for index = 1, activeCount do
        local worker = workers[index]
        local firstLayer = math.floor((index - 1) * layers / activeCount) + 1
        local lastLayer = math.floor(index * layers / activeCount)
        sections[#sections + 1] = {
            worker = worker.id,
            dock = worker.dock,
            first = firstLayer,
            last = lastLayer,
        }
    end
    return sections
end

local function estimateFuel(map, layers, workerCount)
    local cells = countMapCells(map)
    local routeMoves = cells * layers
    local verticalMoves = layers * (layers + 1) -- descend and ascend each layer.
    local dockMoves = layers * 2
    local operationalMargin = math.max(96 * math.max(workerCount, 1), math.ceil((routeMoves + verticalMoves + dockMoves) * 0.08))
    local minimum = routeMoves + verticalMoves + dockMoves + operationalMargin
    local multiplier = tonumber(state.config.estimateSafetyMultiplier or 1.25) or 1.25
    local recommended = math.ceil(minimum * multiplier)
    local fuelPerItem = tonumber(state.config.fuelItemUnits or COAL_FUEL_UNITS) or COAL_FUEL_UNITS
    return {
        cellsPerLayer = cells,
        layers = layers,
        workers = workerCount,
        minimumUnits = minimum,
        recommendedUnits = recommended,
        minimumCoal = math.ceil(minimum / fuelPerItem),
        recommendedCoal = math.ceil(recommended / fuelPerItem),
        fuelPerItem = fuelPerItem,
    }
end

local function startPreflight(workers, mapName, layers, purpose)
    local requestId = tostring(nowUtc()) .. "-" .. crypto.randomHex(4)
    local expected = {}
    for _, worker in ipairs(workers) do expected[tostring(worker.id)] = true end
    state.preflight = {
        id = requestId,
        started = nowUtc(),
        deadline = nowUtc() + PREFLIGHT_TIMEOUT * 1000,
        expected = expected,
        responses = {},
        mapName = mapName,
        layers = layers,
        purpose = purpose or "job",
    }
    saveState()
    for _, worker in ipairs(workers) do
        send(worker.id, "preflight_request", { requestId = requestId })
    end
    logEvent("info", "preflight", "Started preflight for " .. tostring(#workers) .. " worker(s).", { requestId = requestId }, true)
    return requestId
end

local function preflightAllResponded(preflight)
    if not preflight then return false end
    for id in pairs(preflight.expected or {}) do
        if not preflight.responses[id] then return false end
    end
    return true
end

local function evaluatePreflight(preflight)
    local result = { ready = true, rows = {}, warnings = {}, errors = {} }
    if not preflight then
        result.ready = false
        result.errors[#result.errors + 1] = "No preflight has been run."
        return result
    end

    for id in pairs(preflight.expected or {}) do
        local report = preflight.responses[id]
        local worker = state.workers[id]
        local row = { id = tonumber(id), dock = worker and worker.dock or nil, checks = {}, ready = true }
        if not report then
            row.ready = false
            row.checks[#row.checks + 1] = "NO RESPONSE"
            result.errors[#result.errors + 1] = "Worker #" .. id .. " did not answer preflight."
        else
            local function failCheck(text)
                row.ready = false; row.checks[#row.checks + 1] = text
                result.errors[#result.errors + 1] = "Worker #" .. id .. ": " .. text
            end
            local function warnCheck(text)
                row.checks[#row.checks + 1] = text
                result.warnings[#result.warnings + 1] = "Worker #" .. id .. ": " .. text
            end

            if tonumber(report.protocolVersion) ~= PROTOCOL_VERSION then failCheck("incompatible protocol") end
            if report.version ~= VERSION then failCheck("version " .. tostring(report.version) .. " does not match controller " .. VERSION) end
            if not report.physicallyDocked then failCheck("not physically docked") end
            if report.positionConfidence ~= "confirmed" then failCheck("position is " .. tostring(report.positionConfidence)) end
            if not report.outputInventoryAbove then failCheck("output chest/inventory not detected above") end
            if report.fuelValid == false then failCheck("slot 1 is not valid fuel") end
            if tonumber(report.fuel or 0) < 20 and report.fuel ~= "unlimited" then failCheck("less than 20 movement fuel") end
            if tonumber(report.emptyStorageSlots or 0) < 1 then failCheck("no empty storage slots 2-16") end
            if tonumber(report.storedItems or 0) > 0 then failCheck("worker still holds " .. tostring(report.storedItems) .. " mined item(s); check output chest") end
            if report.toolOk == false then failCheck("mining tool missing")
            elseif report.toolOk == "unknown" then warnCheck("mining tool could not be safely tested") end
            if tonumber(report.fuelItems or 0) <= 5 and report.fuel ~= "unlimited" then
                warnCheck("fuel reserve is at five or fewer; shared station must be stocked")
            end
            if report.pendingUpdate then failCheck("update pending: " .. tostring(report.pendingUpdate)) end
            if row.ready then row.checks[#row.checks + 1] = "READY" end
        end
        result.rows[#result.rows + 1] = row
        if not row.ready then result.ready = false end
    end

    local map = preflight.mapName and loadMap(preflight.mapName) or nil
    if preflight.mapName and (not map or type(map.interior) ~= "table" or countMapCells(map) < 1) then
        result.ready = false
        result.errors[#result.errors + 1] = "Selected map is missing or invalid."
    end
    if not preflightAllResponded(preflight) and nowUtc() < (preflight.deadline or 0) then
        result.ready = false
        result.pending = true
    end
    return result
end

local function printPreflight(result)
    print("HIVE PREFLIGHT")
    print(string.rep("=", 32))
    for _, row in ipairs(result.rows or {}) do
        local dock = row.dock and displayDock(row.dock) or "unknown"
        print(string.format("%-5s #%-4s %s", dock, row.id or "?", row.ready and "READY" or "BLOCKED"))
        for _, check in ipairs(row.checks or {}) do
            if check ~= "READY" then print("  - " .. check) end
        end
    end
    if #(result.warnings or {}) > 0 then
        print("\nWarnings:")
        for _, warning in ipairs(result.warnings) do print("- " .. warning) end
    end
    if #(result.errors or {}) > 0 then
        print("\nCannot start:")
        for _, problem in ipairs(result.errors) do print("- " .. problem) end
    end
end

local function launchJob(name, layers, workers, testRun)
    local map = loadMap(name)
    if not map then return false, "Map file could not be loaded." end
    local sections = buildSections(layers, workers)
    if #sections == 0 then return false, "No worker sections could be created." end
    local layerState = {}
    for layer = 1, layers do layerState[layer] = "waiting" end

    state.job = {
        id = tostring(nowUtc()), mapName = name, layers = layers, status = "running",
        sections = sections, layerState = layerState, completedCount = 0,
        abortAcks = {}, started = nowUtc(), protocolVersion = PROTOCOL_VERSION,
        testRun = testRun == true,
    }
    state.fuelLock = nil
    for _, section in ipairs(sections) do
        for layer = section.first, section.last do layerState[layer] = "assigned" end
        local worker = state.workers[tostring(section.worker)]
        if worker then worker.error = nil end
    end
    logEvent("info", "job", (testRun and "Test run" or "Job") .. " started on map " .. name, {
        layers = layers, workers = #sections,
    }, true)
    saveState()

    for _, section in ipairs(sections) do
        send(section.worker, "start_section", {
            jobId = state.job.id,
            map = map,
            mapName = name,
            firstLayer = section.first,
            lastLayer = section.last,
            dock = section.dock,
            protocolVersion = PROTOCOL_VERSION,
            testRun = testRun == true,
        })
        state.dockOccupancy[section.dock] = nil
    end
    saveState()
    return true
end

local function jobWizard(testRun)
    if isActiveJob() then print("A job is already active."); sleep(2); return end
    term.clear(); term.setCursorPos(1, 1)
    local maps = listMaps()
    if #maps == 0 then print("No maps saved. Calibrate or import first."); sleep(2); return end
    print(testRun and "ONE-LAYER TEST RUN" or "START QUARRY JOB")
    for index, name in ipairs(maps) do print(index .. ") " .. name) end
    write("Map number: ")
    local name = maps[tonumber(read())]
    if not name then return end

    local layers = 1
    if not testRun then
        write("Number of layers: ")
        layers = tonumber(read())
        if not layers or layers < 1 or layers % 1 ~= 0 then print("Invalid layer count."); sleep(2); return end
    end

    local workers = {}
    if testRun then
        local chosen = chooseDockedWorker()
        if not chosen then return end
        workers[1] = { id = chosen.id, dock = chosen.dock }
    else
        for _, dock in ipairs(DOCK_ORDER) do
            local id = state.dockOccupancy[dock]
            if id then workers[#workers + 1] = { id = id, dock = dock } end
        end
    end
    if #workers == 0 then print("No docked workers detected."); sleep(2); return end

    local map = loadMap(name)
    if not map then print("Map file could not be loaded."); sleep(2); return end
    if not testRun and not mapTestedForCurrentSite(name) then
        print("\nOPTIONAL SAFETY TEST NOT PASSED")
        print("A one-layer test is recommended for this map and hive location,")
        print("but it is not required. The normal preflight will still run.")
    end
    local estimate = estimateFuel(map, layers, math.min(layers, #workers))
    print("\nQUARRY ESTIMATE")
    print("Cells per layer: " .. tostring(estimate.cellsPerLayer))
    print("Minimum fuel: " .. tostring(estimate.minimumUnits) .. " units (~" .. tostring(estimate.minimumCoal) .. " coal)")
    print("Recommended: " .. tostring(estimate.recommendedUnits) .. " units (~" .. tostring(estimate.recommendedCoal) .. " coal)")
    print("Estimate assumes " .. tostring(estimate.fuelPerItem) .. " fuel units per coal item.")

    print("\nRunning preflight...")
    startPreflight(workers, name, layers, testRun and "test" or "job")
    while state.preflight and not preflightAllResponded(state.preflight) and nowUtc() < state.preflight.deadline do sleep(0.2) end
    local result = evaluatePreflight(state.preflight)
    print("")
    printPreflight(result)
    if not result.ready then print("\nPress Enter."); read(); return end

    write("\nType " .. (testRun and "TEST" or "START") .. " to continue: ")
    if read() ~= (testRun and "TEST" or "START") then return end
    local ok, err = launchJob(name, layers, workers, testRun)
    if not ok then printError(err); sleep(2); return end
    print((testRun and "Test run" or "Job") .. " started across " .. tostring(math.min(layers, #workers)) .. " worker(s).")
    print("Press Enter."); read()
end

local function startJob() jobWizard(false) end
local function testRun() jobWizard(true) end

local function pauseJob()
    if not state.job or state.job.status ~= "running" then return end
    state.job.status = "paused"
    saveState()
    broadcast("pause", { jobId = state.job.id })
end

local function resumeJob()
    if not state.job or state.job.status ~= "paused" then return end
    state.job.status = "running"
    saveState()
    broadcast("resume", { jobId = state.job.id })
end

local function markUnfinishedLayers(status)
    if not state.job or not state.job.layerState then return end
    for layer, layerStatus in pairs(state.job.layerState) do
        if layerStatus ~= "complete" then state.job.layerState[layer] = status end
    end
end

local function forceCloseAbort()
    markUnfinishedLayers("aborted")
    state.job.status = "aborted"
    state.job.forceClosed = true
    state.fuelLock = nil
    archiveCurrentJob()
    saveState()
end

local function abortJob()
    if not state.job then
        print("\nNo job to abort.")
        sleep(2)
        return
    end

    if state.job.status == "aborting" then
        print("\nThe controller is waiting for worker acknowledgements.")
        print("Use FORCE only when a worker program has crashed or cannot respond.")
        write("Type FORCE to close the job anyway: ")
        if read() == "FORCE" then forceCloseAbort() end
        return
    end

    if state.job.status ~= "running" and state.job.status ~= "paused" then
        print("\nThis job is already " .. tostring(state.job.status) .. ".")
        sleep(2)
        return
    end

    print("\nABORT ACTIVE JOB")
    print("Live workers will return through carved paths, unload, and dock.")
    print("A crashed or rebooted underground worker may require manual recovery.")
    write("Type ABORT: ")
    if read() ~= "ABORT" then return end

    state.job.status = "aborting"
    state.job.abortAcks = {}
    state.job.lastAbortSent = 0
    markUnfinishedLayers("aborting")
    saveState()

    for _, section in ipairs(state.job.sections or {}) do
        send(section.worker, "abort", { jobId = state.job.id })
    end
    state.job.lastAbortSent = os.epoch("utc")
    saveState()
end

local function allAbortWorkersAcknowledged()
    if not state.job then return true end
    for _, section in ipairs(state.job.sections or {}) do
        if not state.job.abortAcks[tostring(section.worker)] then return false end
    end
    return true
end

local function acknowledgeAbort(sender)
    if not state.job then return end
    state.job.abortAcks = state.job.abortAcks or {}
    state.job.abortAcks[tostring(sender)] = true
    if allAbortWorkersAcknowledged() then
        markUnfinishedLayers("aborted")
        state.job.status = "aborted"
        state.fuelLock = nil
        archiveCurrentJob()
    end
end

local function emergencyRecoveryCounts(recovery)
    local total, complete, failed = 0, 0, 0
    for _ in pairs(recovery and recovery.expected or {}) do total = total + 1 end
    for _ in pairs(recovery and recovery.completed or {}) do complete = complete + 1 end
    for _ in pairs(recovery and recovery.failed or {}) do failed = failed + 1 end
    return complete, total, failed
end

local function finishEmergencyRecoveryIfDone()
    local recovery = state.emergencyRecovery
    if not recovery or recovery.stage == "complete" or recovery.stage == "complete_with_failures" then return end
    local complete, total, failed = emergencyRecoveryCounts(recovery)
    if complete + failed < total then return end

    recovery.stage = failed > 0 and "complete_with_failures" or "complete"
    recovery.completedAt = nowUtc()

    if state.job and state.job.status == "emergency_recovery" then
        markUnfinishedLayers("aborted")
        state.job.status = "aborted"
        state.fuelLock = nil
        archiveCurrentJob()
    end

    logEvent(
        failed > 0 and "warning" or "success",
        "recovery",
        "Emergency surface recovery finished: " .. tostring(complete) .. " recovered, " .. tostring(failed) .. " failed.",
        { recoveryId = recovery.id }
    )
end

local function beginEmergencySurfaceRecovery(requestedBy)
    if state.emergencyRecovery
        and state.emergencyRecovery.stage ~= "complete"
        and state.emergencyRecovery.stage ~= "complete_with_failures"
        and state.emergencyRecovery.stage ~= "cancelled" then
        return false, "An emergency surface recovery is already active."
    end

    local recovery = {
        id = tostring(nowUtc()),
        stage = "surfacing",
        requestedBy = requestedBy,
        startedAt = nowUtc(),
        expected = {},
        completed = {},
        failed = {},
    }

    for key, worker in pairs(state.workers) do
        local id = tonumber(worker.id or key)
        if id and workerIsActive(id) then
            recovery.expected[tostring(id)] = true
        end
    end

    local expectedCount = 0
    for _ in pairs(recovery.expected) do expectedCount = expectedCount + 1 end
    if expectedCount == 0 then return false, "No connected workers are available for emergency recovery." end

    state.emergencyRecovery = recovery
    if state.job and state.job.status ~= "complete" and state.job.status ~= "aborted" then
        state.job.status = "emergency_recovery"
        markUnfinishedLayers("recovery_requested")
    end

    for key in pairs(recovery.expected) do
        send(tonumber(key), "emergency_surface", {
            recoveryId = recovery.id,
            targetY = -1,
            jobId = state.job and state.job.id,
        })
    end

    logEvent(
        "warning",
        "recovery",
        "Emergency vertical recovery started for " .. tostring(expectedCount) .. " connected worker(s).",
        { recoveryId = recovery.id, requestedBy = requestedBy }
    )
    saveState()
    return true, deepCopy(recovery)
end

local function emergencySurfaceRecoveryUI()
    term.clear(); term.setCursorPos(1, 1)
    print("EMERGENCY SURFACE RECOVERY")
    print("==========================")
    print("Connected underground workers will mine straight upward and stop at logical Y=-1.")
    print("")
    print("They stop before:")
    print("- Lava")
    print("- Turtles or computers")
    print("- Chests or other inventories")
    print("- Blocks their tool cannot break")
    print("")
    print("This abandons unfinished quarry work. It does not return turtles horizontally to their docks.")
    write("Type SURFACE: ")
    if read() ~= "SURFACE" then return end

    local ok, result = beginEmergencySurfaceRecovery(nil)
    if not ok then
        printError(result)
        sleep(3)
        return
    end

    print("Recovery command sent to connected workers.")
    print("Use Workers to view individual progress.")
    sleep(3)
end

local function handleMessage(sender, message)
    if type(message) ~= "table" then return end
    local key = tostring(sender)
    local worker = state.workers[key] or { id = sender }
    worker.lastSeen = nowUtc()
    worker.protocolVersion = message.protocolVersion or worker.protocolVersion
    worker.positionConfidence = message.positionConfidence or worker.positionConfidence

    if message.type == "dock_probe" and activeProbeDock then
        local dock = activeProbeDock
        state.dockOccupancy[dock] = sender
        if restoreReportedDock(sender, dock, worker) then
            worker.status = "docked"
            worker.positionConfidence = "confirmed"
            send(sender, "dock_assigned", { dock = dock, controller = os.getComputerID(), protocolVersion = PROTOCOL_VERSION })
            logEvent("info", "dock", "Assigned worker #" .. tostring(sender) .. " to " .. displayDock(dock) .. ".", nil, true)
        else
            worker.status = "dock conflict"
            send(sender, "dock_conflict", { dock = dock, assignedTo = state.docks[dock] })
        end

    elseif message.type == "calibration_complete"
        and state.pendingCalibration
        and sender == state.pendingCalibration.worker then
        message.map.name = state.pendingCalibration.name
        local ok, err = pcall(saveMap, message.map)
        state.lastCalibrationResult = ok
            and { ok = true, cellCount = message.map.cellCount }
            or { ok = false, message = tostring(err) }
        state.pendingCalibration = nil

    elseif message.type == "hello" or message.type == "heartbeat" then
        local previousStatus = worker.status
        worker.status = message.status or worker.status or "online"
        worker.version = message.version or worker.version
        worker.protocolVersion = message.protocolVersion or worker.protocolVersion
        worker.layer = message.layer
        worker.fuel = message.fuel or worker.fuel
        worker.fuelItems = message.fuelItems or worker.fuelItems
        worker.emptyStorageSlots = message.emptyStorageSlots or worker.emptyStorageSlots
        worker.usedStorageSlots = message.usedStorageSlots or worker.usedStorageSlots
        worker.storedItems = message.storedItems or worker.storedItems
        worker.position = message.position and copyForSerialization(message.position) or worker.position
        worker.positionConfidence = message.positionConfidence or worker.positionConfidence
        worker.progress = message.progress or worker.progress
        worker.total = message.total or worker.total
        worker.firstLayer = message.firstLayer or worker.firstLayer
        worker.lastLayer = message.lastLayer or worker.lastLayer
        worker.checkpoint = message.checkpoint and copyForSerialization(message.checkpoint) or worker.checkpoint
        worker.recoveryAnchor = message.recoveryAnchor or worker.recoveryAnchor
        worker.assignment = message.assignment and copyForSerialization(message.assignment) or worker.assignment
        if message.status and message.status ~= "error" and message.status ~= "blocked_waiting" then
            worker.error = nil
        end
        local restored = restoreReportedDock(sender, message.dock, worker)
        if isDockedStatus(message.status) and restored then
            state.dockOccupancy[message.dock] = sender
        elseif message.status and not isDockedStatus(message.status) then
            for dockName, id in pairs(state.dockOccupancy) do
                if tostring(id) == tostring(sender) then state.dockOccupancy[dockName] = nil end
            end
        end
        if previousStatus ~= worker.status then
            if worker.status == "blocked_waiting" then
                logEvent("warning", "worker", workerLabel(worker) .. " is blocked and waiting.", { worker = sender })
            elseif worker.status == "fuel_station_empty" then
                logEvent("warning", "fuel", workerLabel(worker) .. " needs the shared fuel station restocked.", { worker = sender })
            elseif worker.status == "recovery_required" or worker.status == "position_unknown" then
                logEvent("error", "recovery", workerLabel(worker) .. " requires position recovery.", { worker = sender })
            end
        end

    elseif message.type == "worker_surface_started" then
        worker.status = "emergency_surfacing"
        worker.position = message.position and copyForSerialization(message.position) or worker.position
        worker.error = nil

    elseif message.type == "worker_surface_progress" then
        worker.status = "emergency_surfacing"
        worker.position = message.position and copyForSerialization(message.position) or worker.position
        worker.surfaceRemaining = message.remaining
        if state.emergencyRecovery and tostring(message.recoveryId) == tostring(state.emergencyRecovery.id) then
            state.emergencyRecovery.lastProgress = nowUtc()
        end

    elseif message.type == "worker_surface_recovered" then
        worker.status = message.alreadyDocked and "docked" or "surface_recovered"
        worker.position = message.position and copyForSerialization(message.position) or worker.position
        worker.positionConfidence = message.alreadyDocked and "confirmed" or "recoverable"
        worker.error = message.alreadyDocked and nil or {
            message = "Recovered at logical Y=-1. Retrieve or reposition this turtle, then Detect docks.",
            position = message.position,
        }
        worker.surfaceRemaining = 0
        if state.emergencyRecovery and tostring(message.recoveryId) == tostring(state.emergencyRecovery.id) then
            state.emergencyRecovery.completed[key] = {
                time = nowUtc(),
                position = message.position and copyForSerialization(message.position) or nil,
                note = message.note,
            }
            finishEmergencyRecoveryIfDone()
        end

    elseif message.type == "preflight_response" then
        if state.preflight and message.requestId == state.preflight.id and state.preflight.expected[key] then
            state.preflight.responses[key] = deepCopy(message)
        end

    elseif message.type == "relocation_ready" then
        worker.status = "relocation_ready"
        worker.dock = nil
        worker.positionConfidence = "unknown"
        state.relocationAcks = state.relocationAcks or {}
        state.relocationAcks[key] = true
        for dockName, id in pairs(state.docks) do if tostring(id) == key then state.docks[dockName] = nil end end
        for dockName, id in pairs(state.dockOccupancy) do if tostring(id) == key then state.dockOccupancy[dockName] = nil end end
        logEvent("info", "relocation", "Worker #" .. key .. " is ready to relocate.", nil, true)

    elseif message.type == "relocation_rejected" then
        worker.status = "relocation_rejected"
        worker.error = { message = message.message }
        logEvent("error", "relocation", "Worker #" .. key .. " rejected relocation: " .. tostring(message.message), { worker = sender })

    elseif message.type == "recovery_rejected" then
        worker.status = "recovery_required"
        worker.error = { message = message.message }
        logEvent("warning", "recovery", "Worker #" .. key .. " recovery rejected: " .. tostring(message.message), { worker = sender })

    elseif message.type == "layer_started" then
        worker.status = "mining"
        worker.layer = message.layer
        if state.job and state.job.layerState then state.job.layerState[message.layer] = "active" end

    elseif message.type == "layer_complete" then
        worker.status = "returning"
        worker.layer = message.layer
        if state.job and state.job.layerState and state.job.layerState[message.layer] ~= "complete" then
            state.job.layerState[message.layer] = "complete"
            state.job.completedCount = (state.job.completedCount or 0) + 1
            if state.job.completedCount >= state.job.layers then
                state.job.status = "complete"
                if state.job.testRun then
                    markMapTested(state.job.mapName)
                    logEvent("success", "test", "Map " .. tostring(state.job.mapName) .. " passed its one-layer test for site generation " .. tostring(state.config.siteGeneration) .. ".", nil)
                end
                archiveCurrentJob()
            end
        end

    elseif message.type == "section_complete" then
        worker.status = "docked"
        worker.layer = nil
        if validDock(worker.dock) and tostring(state.docks[worker.dock]) == tostring(sender) then
            state.dockOccupancy[worker.dock] = sender
        end
        if state.job and state.job.status == "aborting" then acknowledgeAbort(sender) end

    elseif message.type == "worker_aborted" then
        worker.status = "docked"
        worker.layer = nil
        worker.error = nil
        worker.abortNote = message.note
        if validDock(worker.dock) and tostring(state.docks[worker.dock]) == tostring(sender) then
            state.dockOccupancy[worker.dock] = sender
        end
        acknowledgeAbort(sender)

    elseif message.type == "worker_parked" then
        worker.status = "parked"
        worker.layer = nil
        worker.error = nil
        worker.abortNote = message.note
        if validDock(worker.dock) and tostring(state.docks[worker.dock]) == tostring(sender) then
            state.dockOccupancy[worker.dock] = sender
        end

    elseif message.type == "worker_recovery_started" then
        worker.status = "recovering"
        worker.error = nil

    elseif message.type == "worker_blocked" then
        worker.status = "blocked_waiting"
        worker.error = {
            message = message.message,
            position = message.position,
            recoverable = true,
        }
        logEvent("warning", "worker", workerLabel(worker) .. " blocked: " .. tostring(message.message), { worker = sender })

    elseif message.type == "fuel_station_empty" then
        worker.status = "fuel_station_empty"
        worker.fuel = message.fuel or worker.fuel
        worker.position = message.position and copyForSerialization(message.position) or worker.position
        worker.error = {
            message = message.message or "RESTOCK FUEL STATION, then restart remaining work.",
            position = message.position,
        }
        if state.fuelLock == sender then state.fuelLock = nil end
        logEvent("warning", "fuel", workerLabel(worker) .. " returned because the fuel station is empty.", { worker = sender })

    elseif message.type == "update_accepted" then
        worker.status = "updating"
        worker.updateTarget = message.targetVersion
        worker.error = nil

    elseif message.type == "update_deferred" then
        worker.status = "update_pending"
        worker.updateTarget = message.targetVersion
        worker.updateReason = message.reason

    elseif message.type == "update_installed" then
        worker.status = "rebooting_after_update"
        worker.version = message.targetVersion or worker.version
        worker.updateTarget = nil
        worker.updateReason = nil
        worker.error = nil

    elseif message.type == "update_current" then
        worker.version = message.targetVersion or message.version or worker.version
        worker.updateTarget = nil
        worker.updateReason = nil

    elseif message.type == "update_failed" then
        worker.status = "update_failed"
        worker.updateTarget = message.targetVersion
        worker.error = {
            message = message.message or "Worker update failed.",
            position = message.position,
        }
        logEvent("error", "update", workerLabel(worker) .. " update failed: " .. tostring(worker.error.message), { worker = sender })

    elseif message.type == "worker_error" then
        worker.status = "ERROR: " .. tostring(message.message)
        if state.emergencyRecovery and state.emergencyRecovery.expected[key]
            and not state.emergencyRecovery.completed[key] then
            state.emergencyRecovery.failed[key] = {
                time = nowUtc(),
                message = message.message,
                position = message.position and copyForSerialization(message.position) or nil,
            }
            finishEmergencyRecoveryIfDone()
        end
        worker.error = copyForSerialization(message)
        if state.fuelLock == sender then state.fuelLock = nil end
        if state.pendingCalibration and sender == state.pendingCalibration.worker then
            state.lastCalibrationResult = { ok = false, message = message.message }
            state.pendingCalibration = nil
        end
        logEvent("error", "worker", workerLabel(worker) .. " stopped: " .. tostring(message.message), { worker = sender, position = message.position })

    elseif message.type == "fuel_lock_request" then
        if state.fuelLock and not workerIsActive(state.fuelLock) then state.fuelLock = nil end
        if not state.fuelLock or state.fuelLock == sender then
            state.fuelLock = sender
            send(sender, "fuel_lock_granted", {})
        else
            send(sender, "fuel_lock_wait", { holder = state.fuelLock })
        end

    elseif message.type == "fuel_lock_release" then
        if state.fuelLock == sender then state.fuelLock = nil end
    end

    state.workers[key] = worker
    saveState()
end

local function sortedWorkers()
    local workers = {}
    for _, worker in pairs(state.workers) do workers[#workers + 1] = worker end
    table.sort(workers, function(a, b)
        local ad = displayDock(a.dock)
        local bd = displayDock(b.dock)
        if ad == bd then return tonumber(a.id) < tonumber(b.id) end
        return ad < bd
    end)
    return workers
end

local function findWorkerSection(workerId)
    if not state.job then return nil end
    for _, section in ipairs(state.job.sections or {}) do
        if tostring(section.worker) == tostring(workerId) then return section end
    end
    return nil
end

local function firstIncompleteLayer(section)
    if not state.job or not section then return nil end
    for layer = section.first, section.last do
        if not state.job.layerState or state.job.layerState[layer] ~= "complete" then return layer end
    end
    return nil
end

local function assignmentForWorker(worker)
    if not state.job then return nil, "No job is recorded." end
    if state.job.status == "complete" or state.job.status == "aborted" or state.job.status == "aborting" then
        return nil, "The recorded job is already " .. tostring(state.job.status) .. "."
    end
    if state.job.status == "paused" then
        return nil, "Resume the job before restarting worker operations."
    end
    local section = findWorkerSection(worker.id)
    if not section then return nil, "This worker has no section in the current job." end
    local first = firstIncompleteLayer(section)
    if not first then return nil, "This worker's assigned layers are already complete." end
    local map = loadMap(state.job.mapName)
    if not map then return nil, "The job map could not be loaded." end
    return {
        jobId = state.job.id,
        map = map,
        mapName = state.job.mapName,
        firstLayer = first,
        lastLayer = section.last,
        dock = section.dock,
        protocolVersion = PROTOCOL_VERSION,
        testRun = state.job.testRun == true,
    }
end

local function markWorkerLayersAssigned(worker)
    local section = findWorkerSection(worker.id)
    local first = firstIncompleteLayer(section)
    if not section or not first or not state.job or not state.job.layerState then return end
    for layer = first, section.last do
        if state.job.layerState[layer] ~= "complete" then state.job.layerState[layer] = "assigned" end
    end
end

local function workerDetails(worker)
    term.clear()
    term.setCursorPos(1, 1)
    print("WORKER " .. workerLabel(worker))
    print(string.rep("=", 30))
    print("ID: " .. tostring(worker.id))
    print("Physical dock: " .. titleCase(displayDock(worker.dock)))
    print("Logical dock: " .. tostring(worker.dock or "unassigned"))
    print("Status: " .. tostring(worker.status or "unknown"))
    print("Version: " .. tostring(worker.version or "unknown") .. " | Protocol: " .. tostring(worker.protocolVersion or "?"))
    print("Position confidence: " .. tostring(worker.positionConfidence or "unknown"))
    if worker.updateTarget then
        print("Update target: " .. tostring(worker.updateTarget))
        if worker.updateReason then print("Update wait: " .. tostring(worker.updateReason)) end
    end
    print("Layer: " .. tostring(worker.layer or "-"))
    print("Fuel: " .. tostring(worker.fuel or "?") .. " | Slot 1: " .. tostring(worker.fuelItems or "?"))
    print("Empty storage slots: " .. tostring(worker.emptyStorageSlots or "?") .. " | Stored items: " .. tostring(worker.storedItems or "?"))
    if worker.position then print("Position: " .. textutils.serialize(worker.position)) end
    if worker.progress and worker.total then print("Progress: " .. tostring(worker.progress) .. "/" .. tostring(worker.total)) end
    if worker.status == "fuel_station_empty" then
        print("")
        print("RESTOCK FUEL STATION")
        print("After adding fuel, choose option 6 to continue remaining work.")
    end
    if worker.error then
        print("")
        print("Last problem:")
        print(tostring(worker.error.message or worker.error))
        if worker.error.position then print(textutils.serialize(worker.error.position)) end
    end
    print("")
    printMenuOption("1", "Refresh status")
    printMenuOption("2", "Recover and retry unfinished work")
    printMenuOption("3", "Return to dock and stop")
    printMenuOption("4", "Pause worker")
    printMenuOption("5", "Resume worker")
    printMenuOption("6", "Restart unfinished work from dock")
    printMenuOption("7", "Clear displayed error")
    printMenuOption("8", "Forget worker record")
    printMenuOption("9", "Recover saved shaft or centre checkpoint")
    printMenuOption("10", "Run worker preflight")
    printMenuOption("11", "Emergency vertical recovery to Y=-1")
    printMenuOption("0", "Back")
    write("Choose: ")
end

local function manageWorker(worker)
    while true do
        worker = state.workers[tostring(worker.id)] or worker
        workerDetails(worker)
        local choice = read()
        if choice == "0" or choice == "" then return

        elseif choice == "1" then
            send(worker.id, "status_request", {})
            print("Status request sent.")
            sleep(1)

        elseif choice == "2" then
            local assignment, err = assignmentForWorker(worker)
            if not assignment then
                print(err)
                sleep(2)
            else
                print("This returns the worker to its dock, unloads, then restarts at layer " .. tostring(assignment.firstLayer) .. ".")
                print("The partially mined layer may be traversed again, but already empty blocks are not re-mined.")
                write("Type RETRY: ")
                if read() == "RETRY" then
                    markWorkerLayersAssigned(worker)
                    worker.status = "recovering"
                    worker.error = nil
                    saveState()
                    send(worker.id, "recover_and_retry", assignment)
                    print("Recovery and retry command sent.")
                    sleep(2)
                end
            end

        elseif choice == "3" then
            print("The worker will return through its known carved route, unload, and wait at the dock.")
            write("Type RETURN: ")
            if read() == "RETURN" then
                worker.status = "returning_by_command"
                saveState()
                send(worker.id, "return_to_dock", { jobId = state.job and state.job.id or nil })
                print("Return command sent.")
                sleep(2)
            end

        elseif choice == "4" then
            send(worker.id, "pause", { jobId = state.job and state.job.id or nil })
            worker.status = "pause_requested"
            saveState()
            sleep(1)

        elseif choice == "5" then
            send(worker.id, "resume", { jobId = state.job and state.job.id or nil })
            worker.status = "resume_requested"
            saveState()
            sleep(1)

        elseif choice == "6" then
            local assignment, err = assignmentForWorker(worker)
            if not assignment then
                print(err)
                sleep(2)
            elseif worker.status ~= "docked"
                and worker.status ~= "parked"
                and worker.status ~= "aborted"
                and worker.status ~= "fuel_station_empty" then
                print("Use Recover and retry unless the worker is physically docked.")
                sleep(2)
            else
                markWorkerLayersAssigned(worker)
                worker.status = "starting"
                worker.error = nil
                saveState()
                send(worker.id, "start_section", assignment)
                print("Remaining section resent from layer " .. tostring(assignment.firstLayer) .. ".")
                sleep(2)
            end

        elseif choice == "7" then
            worker.error = nil
            saveState()
            send(worker.id, "clear_error", {})
            print("Displayed error cleared.")
            sleep(1)

        elseif choice == "8" then
            if findWorkerSection(worker.id) and isActiveJob() then
                print("This worker belongs to the active job and cannot be forgotten yet.")
                sleep(2)
            else
                write("Type FORGET: ")
                if read() == "FORGET" then
                    for dockName, id in pairs(state.docks) do
                        if tostring(id) == tostring(worker.id) then state.docks[dockName] = nil end
                    end
                    for dockName, id in pairs(state.dockOccupancy) do
                        if tostring(id) == tostring(worker.id) then state.dockOccupancy[dockName] = nil end
                    end
                    state.workers[tostring(worker.id)] = nil
                    saveState()
                    return
                end
            end

        elseif choice == "9" then
            if worker.positionConfidence ~= "recoverable" then
                print("Automatic recovery is only allowed from a saved shaft or centre anchor.")
                print("Unknown positions must be returned to a dock manually, then Detect docks.")
                sleep(3)
            else
                write("Type RECOVER: ")
                if read() == "RECOVER" then
                    send(worker.id, "recover_checkpoint", {})
                    worker.status = "recovering"
                    saveState()
                    sleep(2)
                end
            end

        elseif choice == "11" then
            print("This mines straight upward from the worker's current column and stops at logical Y=-1.")
            print("It will not move horizontally or return to the dock.")
            write("Type SURFACE: ")
            if read() == "SURFACE" then
                local recoveryId = tostring(nowUtc())
                send(worker.id, "emergency_surface", { recoveryId = recoveryId, targetY = -1 })
                worker.status = "emergency_surfacing"
                worker.error = nil
                saveState()
                print("Emergency recovery command sent.")
                sleep(2)
            end

        elseif choice == "10" then
            startPreflight({ { id = worker.id, dock = worker.dock } }, nil, 0, "worker")
            while state.preflight and not preflightAllResponded(state.preflight) and nowUtc() < state.preflight.deadline do sleep(0.2) end
            term.clear(); term.setCursorPos(1, 1)
            printPreflight(evaluatePreflight(state.preflight))
            print("\nPress Enter."); read()
        end
    end
end

local function workersView()
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("WORKERS")
        print(string.rep("=", 30))
        local workers = sortedWorkers()
        if #workers == 0 then
            print("No workers have reported yet.")
            print("\nPress Enter.")
            read()
            return
        end
        for index, worker in ipairs(workers) do
            printMenuOption(index, workerLabel(worker) .. " | " .. tostring(worker.status or "unknown")
                .. " | L" .. tostring(worker.layer or "-") .. " | F" .. tostring(worker.fuel or "?"))
        end
        printMenuOption("0", "Back")
        write("Select worker: ")
        local selected = tonumber(read())
        if not selected or selected == 0 then return end
        if workers[selected] then manageWorker(workers[selected]) end
    end
end

local function mapsView()
    term.clear()
    term.setCursorPos(1, 1)
    print("MAP LIBRARY")
    local maps = listMaps()
    if #maps == 0 then print("No maps saved.") end
    for _, name in ipairs(maps) do
        local map = loadMap(name)
        local testStatus = mapTestedForCurrentSite(name) and "TESTED" or "UNTESTED (OPTIONAL)"
        print(name .. " | " .. tostring(map and countMapCells(map) or "?") .. " cells | " .. testStatus)
    end
    print("\nPress Enter.")
    read()
end

local function historyView()
    term.clear(); term.setCursorPos(1, 1)
    print("JOB HISTORY")
    print(string.rep("=", 32))
    if #state.jobHistory == 0 then print("No completed or aborted jobs yet.") end
    for index = #state.jobHistory, math.max(1, #state.jobHistory - 19), -1 do
        local job = state.jobHistory[index]
        local seconds = job.finished and job.started and math.floor((job.finished - job.started) / 1000) or 0
        print(string.format("%s | %s | %s/%s | %ss%s",
            tostring(job.mapName), tostring(job.status), tostring(job.completedCount), tostring(job.layers),
            tostring(seconds), job.testRun and " | TEST" or ""))
    end
    print("\nPress Enter."); read()
end

local function logsView()
    term.clear(); term.setCursorPos(1, 1)
    print("EVENT LOG (latest 40)")
    print(string.rep("=", 32))
    if #state.logs == 0 then print("No events recorded.") end
    for index = math.max(1, #state.logs - 39), #state.logs do
        local entry = state.logs[index]
        local timestamp = entry.time and os.date("!%H:%M:%S", math.floor(entry.time / 1000)) or "--:--:--"
        print(timestamp .. " [" .. tostring(entry.severity):upper() .. "] " .. tostring(entry.message))
    end
    print("\nPress Enter."); read()
end

local function backupPath(name)
    return fs.combine(BACKUP_DIR, sanitize(name) .. ".db")
end

local function listBackups()
    local output = {}
    for _, file in ipairs(fs.list(BACKUP_DIR)) do
        if file:sub(-3) == ".db" then output[#output + 1] = file:sub(1, -4) end
    end
    table.sort(output)
    return output
end

local function createBackup(name)
    name = sanitize(name or ("backup_" .. tostring(nowUtc())))
    if not name then return false, "Invalid backup name." end
    local maps = {}
    for _, mapName in ipairs(listMaps()) do maps[mapName] = loadMap(mapName) end
    local backup = {
        format = 1,
        createdAt = nowUtc(),
        version = VERSION,
        protocolVersion = PROTOCOL_VERSION,
        controllerId = os.getComputerID(),
        state = {
            config = deepCopy(state.config),
            security = deepCopy(state.security),
            jobHistory = deepCopy(state.jobHistory),
            logs = deepCopy(state.logs),
            docks = deepCopy(state.docks),
            workers = deepCopy(state.workers),
        },
        maps = maps,
    }
    atomicSave(backupPath(name), backup)
    logEvent("success", "backup", "Created controller backup '" .. name .. "'.", nil)
    saveState()
    return true, name
end

local function restoreBackup(name)
    if isActiveJob() then return false, "Abort or finish the active job first." end
    local backup = loadTable(backupPath(name))
    if not backup or backup.format ~= 1 or type(backup.state) ~= "table" or type(backup.maps) ~= "table" then
        return false, "Backup is missing or invalid."
    end
    for mapName, map in pairs(backup.maps) do
        map.name = mapName
        saveMap(map)
    end
    state.config = deepCopy(backup.state.config or state.config)
    state.config.siteGeneration = (tonumber(state.config.siteGeneration or 1) or 1) + 1
    state.security = deepCopy(backup.state.security or state.security)
    state.jobHistory = deepCopy(backup.state.jobHistory or {})
    state.logs = deepCopy(backup.state.logs or {})
    state.docks = deepCopy(backup.state.docks or {})
    state.workers = deepCopy(backup.state.workers or {})
    state.dockOccupancy = {}
    state.job = nil
    state.fuelLock = nil
    state.safeUpdate = nil
    state.preflight = nil
    state.relocationMode = true
    logEvent("warning", "backup", "Restored backup '" .. name .. "'. Run Detect docks before starting.", nil, true)
    saveState()
    return true
end

local function backupsMenu()
    while true do
        term.clear(); term.setCursorPos(1, 1)
        print("CONTROLLER BACKUPS")
        printMenuOption("1", "Create backup")
        printMenuOption("2", "Restore backup")
        printMenuOption("3", "List backups")
        printMenuOption("0", "Back")
        write("Choose: ")
        local choice = read()
        if choice == "0" or choice == "" then return
        elseif choice == "1" then
            write("Backup name (blank = automatic): ")
            local ok, result = createBackup(read())
            print(ok and ("Created " .. result) or tostring(result)); sleep(2)
        elseif choice == "2" then
            local backups = listBackups()
            for index, name in ipairs(backups) do print(index .. ") " .. name) end
            write("Backup number: ")
            local name = backups[tonumber(read())]
            if name then
                print("This restores maps, configuration, pairings, history, and saved worker assignments.")
                print("Physical occupancy and active jobs are deliberately not restored.")
                write("Type RESTORE: ")
                if read() == "RESTORE" then
                    local ok, err = restoreBackup(name)
                    print(ok and "Backup restored. Run Detect docks." or tostring(err)); sleep(3)
                end
            end
        elseif choice == "3" then
            local backups = listBackups()
            if #backups == 0 then print("No backups.") end
            for _, name in ipairs(backups) do print("- " .. name) end
            print("Press Enter."); read()
        end
    end
end

local function assignedWorkers()
    local output = {}
    for _, dock in ipairs(DOCK_ORDER) do
        local id = state.docks[dock]
        if id then output[#output + 1] = { id = id, dock = dock, worker = state.workers[tostring(id)] } end
    end
    return output
end

local function relocationIssues()
    local issues = {}
    for _, entry in ipairs(assignedWorkers()) do
        local worker = entry.worker
        if not worker or not workerIsActive(entry.id) then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker is offline."
        elseif tostring(state.dockOccupancy[entry.dock]) ~= tostring(entry.id) then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker is not physically docked."
        elseif not isDockedStatus(worker.status) then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker status is " .. tostring(worker.status) .. "."
        elseif worker.positionConfidence ~= "confirmed" then
            issues[#issues + 1] = displayDock(entry.dock) .. " position is " .. tostring(worker.positionConfidence) .. "."
        elseif tonumber(worker.storedItems or 0) > 0 then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker still contains " .. tostring(worker.storedItems) .. " item(s); clear its output chest and unload first."
        end
    end
    return issues
end

local function prepareRelocation(requestedBy)
    if isActiveJob() then return false, "Finish or abort the active job first." end
    local workers = assignedWorkers()
    if #workers == 0 then return false, "No assigned workers were found." end
    local issues = relocationIssues()
    if #issues > 0 then return false, table.concat(issues, " ") end

    state.relocationMode = true
    state.config.siteGeneration = (tonumber(state.config.siteGeneration or 1) or 1) + 1
    state.relocationAcks = {}
    state.relocationExpected = {}
    for _, entry in ipairs(workers) do
        state.relocationExpected[tostring(entry.id)] = true
        send(entry.id, "prepare_relocation", {})
    end
    logEvent("warning", "relocation", "Relocation mode started" .. (requestedBy and (" by pocket #" .. requestedBy) or "") .. ".", nil)
    saveState()
    return true
end

local function relocationMenu()
    term.clear(); term.setCursorPos(1, 1)
    print("RELOCATE HIVE")
    print("This preserves maps, history, settings, and pairings.")
    print("Workers clear their old dock names so they can be detected at the new position.")
    print("All workers must be online, idle, and physically docked.")
    local issues = relocationIssues()
    if #issues > 0 then
        print("\nCannot relocate:")
        for _, issue in ipairs(issues) do print("- " .. issue) end
        print("\nPress Enter."); read(); return
    end
    write("Type RELOCATE: ")
    if read() ~= "RELOCATE" then return end
    local ok, err = prepareRelocation()
    if not ok then printError(err); sleep(2); return end
    print("Waiting for workers to prepare...")
    local deadline = nowUtc() + 6000
    while nowUtc() < deadline do
        local all = true
        for id in pairs(state.relocationExpected or {}) do
            if not state.relocationAcks[tostring(id)] then all = false; break end
        end
        if all then break end
        sleep(0.2)
    end
    print("You may now break and move the controller, turtles, chests, modem, and fuel chest.")
    print("After rebuilding, power everything on and press D to Detect docks.")
    print("Do not factory-reset any device.")
    print("\nPress Enter."); read()
end

local function pairedPocketArray()
    local output = {}
    for key, paired in pairs(state.security.paired or {}) do
        paired.id = tonumber(paired.id or key)
        output[#output + 1] = paired
    end
    table.sort(output, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    return output
end

local function pairPocketUI()
    print("Permission role:")
    printMenuOption("1", "Viewer - read only")
    printMenuOption("2", "Operator - jobs and worker controls")
    printMenuOption("3", "Administrator - updates, security, relocation, and backups")
    write("Role: ")
    local roles = { "viewer", "operator", "administrator" }
    local role = roles[tonumber(read())]
    if not role then return end
    write("Pocket name: ")
    local name = read()
    if name == "" then name = "Pocket" end

    pairingSession = {
        code = crypto.randomCode(12),
        controllerNonce = crypto.randomHex(16),
        role = role,
        name = name,
        expires = nowUtc() + PAIRING_SECONDS * 1000,
        complete = false,
    }
    term.clear(); term.setCursorPos(1, 1)
    print("PAIR ROOMBA POCKET")
    print("Controller ID: #" .. os.getComputerID())
    print("Role: " .. role)
    print("Code: " .. pairingSession.code:sub(1, 4) .. "-" .. pairingSession.code:sub(5, 8) .. "-" .. pairingSession.code:sub(9, 12))
    print("\nOn the pocket choose Pair and enter this code.")
    print("The code expires in " .. PAIRING_SECONDS .. " seconds.")
    while pairingSession and not pairingSession.complete and nowUtc() < pairingSession.expires do sleep(0.2) end
    if pairingSession and pairingSession.complete then print("\nPaired pocket #" .. tostring(pairingSession.pocketId) .. ".")
    else print("\nPairing expired or was cancelled.") end
    pairingSession = nil
    print("Press Enter."); read()
end

local function securityMenu()
    while true do
        term.clear(); term.setCursorPos(1, 1)
        print("REMOTE SECURITY")
        print("Status: " .. (state.security.enabled and "enabled" or "disabled"))
        printMenuOption("1", "Pair new pocket")
        printMenuOption("2", "View or manage paired pockets")
        printMenuOption("3", (state.security.enabled and "Disable" or "Enable") .. " remote control")
        printMenuOption("0", "Back")
        write("Choose: ")
        local choice = read()
        if choice == "0" or choice == "" then return
        elseif choice == "1" then pairPocketUI()
        elseif choice == "2" then
            local pockets = pairedPocketArray()
            if #pockets == 0 then print("No paired pockets."); sleep(2)
            else
                for index, pocket in ipairs(pockets) do print(index .. ") #" .. pocket.id .. " " .. tostring(pocket.name) .. " | " .. tostring(pocket.role)) end
                write("Select pocket (0 back): ")
                local pocket = pockets[tonumber(read())]
                if pocket then
                    printMenuOption("1", "Rename pocket")
                    printMenuOption("2", "Change permission role")
                    printMenuOption("3", "Revoke pocket")
                    printMenuOption("0", "Back")
                    write("Choose: ")
                    local action = read()
                    if action == "1" then write("New name: "); pocket.name = read(); saveState()
                    elseif action == "2" then
                        printMenuOption("1", "Viewer")
                        printMenuOption("2", "Operator")
                        printMenuOption("3", "Administrator")
                        write("Role: ")
                        local role = ({ "viewer", "operator", "administrator" })[tonumber(read())]
                        if role then pocket.role = role; saveState() end
                    elseif action == "3" then
                        write("Type REVOKE: ")
                        if read() == "REVOKE" then
                            state.security.paired[tostring(pocket.id)] = nil
                            logEvent("warning", "security", "Revoked pocket #" .. tostring(pocket.id) .. ".", nil, true)
                            saveState()
                        end
                    end
                end
            end
        elseif choice == "3" then
            state.security.enabled = not state.security.enabled
            logEvent("warning", "security", "Remote control " .. (state.security.enabled and "enabled" or "disabled") .. ".", nil, true)
            saveState()
        end
    end
end

local function initiateAbortWithoutPrompt()
    if not state.job or (state.job.status ~= "running" and state.job.status ~= "paused") then return end
    state.job.status = "aborting"
    state.job.abortAcks = {}
    state.job.lastAbortSent = 0
    markUnfinishedLayers("aborting")
    for _, section in ipairs(state.job.sections or {}) do send(section.worker, "abort", { jobId = state.job.id }) end
    state.job.lastAbortSent = nowUtc()
    logEvent("warning", "job", "Safe update requested an automatic job abort.", nil)
    saveState()
end

local function safeUpdateIssues()
    local issues = {}
    for _, entry in ipairs(assignedWorkers()) do
        local worker = entry.worker
        if not worker or not workerIsActive(entry.id) then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker is offline"
        elseif tostring(state.dockOccupancy[entry.dock]) ~= tostring(entry.id) then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker is not physically docked"
        elseif not isDockedStatus(worker.status) then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker is " .. tostring(worker.status)
        elseif worker.positionConfidence ~= "confirmed" then
            issues[#issues + 1] = displayDock(entry.dock) .. " position is " .. tostring(worker.positionConfidence)
        elseif tonumber(worker.storedItems or 0) > 0 then
            issues[#issues + 1] = displayDock(entry.dock) .. " worker still contains " .. tostring(worker.storedItems) .. " item(s)"
        end
    end
    return issues
end

local function beginSafeUpdate(requestedBy)
    if state.safeUpdate and state.safeUpdate.stage ~= "failed" and state.safeUpdate.stage ~= "cancelled" then
        return true, state.safeUpdate
    end
    state.safeUpdate = {
        stage = isActiveJob() and "aborting" or "waiting_docked",
        requestedBy = requestedBy,
        started = nowUtc(),
        issues = {},
    }
    if isActiveJob() then initiateAbortWithoutPrompt() end
    logEvent("warning", "update", "Safe hive update preparation started" .. (requestedBy and (" by pocket #" .. requestedBy) or "") .. ".", nil)
    saveState()
    return true, state.safeUpdate
end

local function processSafeUpdate()
    local update = state.safeUpdate
    if not update then return end
    if update.stage == "aborting" then
        if not state.job or state.job.status == "aborted" or state.job.status == "complete" then
            update.stage = "waiting_docked"
        end
    end
    if update.stage == "waiting_docked" or update.stage == "blocked" then
        local issues = safeUpdateIssues()
        update.issues = issues
        update.stage = #issues == 0 and "ready" or "blocked"
        if update.stage == "ready" and not update.readyAlerted then
            update.readyAlerted = true
            logEvent("success", "update", "All connected workers are safely docked and ready to update.", nil)
        end
    end
    saveState()
end

local function commitSafeUpdate(requestedBy)
    if not state.safeUpdate or state.safeUpdate.stage ~= "ready" then return false, "Safe update is not ready." end
    if state.safeUpdate.requestedBy and requestedBy and tonumber(state.safeUpdate.requestedBy) ~= tonumber(requestedBy) then
        return false, "A different pocket started this safe update."
    end
    state.safeUpdate.stage = "committing"
    pendingControllerUpdate = true
    logEvent("warning", "update", "Safe hive update committed.", nil)
    saveState()
    return true
end

local function updateHive()
    term.clear(); term.setCursorPos(1, 1)
    print("SAFE UPDATE ROOMBA HIVE")
    print("=======================")
    print("The controller will abort active work, wait for every known worker to return, then require final confirmation.")
    write("Type PREPARE: ")
    if read() ~= "PREPARE" then return end
    beginSafeUpdate(nil)

    while state.safeUpdate do
        processSafeUpdate()
        term.clear(); term.setCursorPos(1, 1)
        print("SAFE UPDATE ROOMBA HIVE")
        print("Stage: " .. tostring(state.safeUpdate.stage))
        if state.safeUpdate.stage == "aborting" then
            print("Workers are returning and unloading...")
            sleep(1)
        elseif state.safeUpdate.stage == "waiting_docked" then
            print("Waiting for all workers to report docked...")
            sleep(1)
        elseif state.safeUpdate.stage == "blocked" then
            print("\nUpdate is blocked:")
            for _, issue in ipairs(state.safeUpdate.issues or {}) do print("- " .. issue) end
            write("\nPress Enter to recheck or type CANCEL: ")
            if read() == "CANCEL" then
                state.safeUpdate.stage = "cancelled"; saveState(); return
            end
        elseif state.safeUpdate.stage == "ready" then
            print("\nAll known workers are online, docked, unloaded, and position-confirmed.")
            print("The installer will update workers first and this controller last.")
            write("Type UPDATE: ")
            if read() == "UPDATE" then
                local ok, err = commitSafeUpdate(nil)
                if not ok then printError(err); sleep(2) end
            end
            return
        elseif state.safeUpdate.stage == "committing" then return
        else
            print("Update ended: " .. tostring(state.safeUpdate.stage)); sleep(2); return
        end
    end
end

local function waitForMenuChoice()
    local _, character = os.pullEvent("char")
    return tostring(character):lower()
end

local function menuHeader(title)
    term.clear()
    term.setCursorPos(1, 1)
    print(title)
    print(string.rep("=", math.min(#title, select(1, term.getSize()))))
end

local function operationsMenu()
    while true do
        menuHeader("OPERATIONS")
        if state.job then
            print("Job: " .. tostring(state.job.mapName) .. " | " .. tostring(state.job.status))
            print("Progress: " .. tostring(state.job.completedCount or 0) .. "/" .. tostring(state.job.layers))
        else
            print("No active or recorded job.")
        end
        print("")
        printMenuOption("1", "Pause hive")
        printMenuOption("2", "Resume hive")
        printMenuOption("3", "Safe abort")
        printMenuOption("4", "Safe update hive")
        printMenuOption("5", "Emergency surface recovery")
        printMenuOption("0", "Back")
        local choice = waitForMenuChoice()
        if choice == "0" then return
        elseif choice == "1" then pauseJob()
        elseif choice == "2" then resumeJob()
        elseif choice == "3" then abortJob()
        elseif choice == "4" then updateHive()
        elseif choice == "5" then emergencySurfaceRecoveryUI() end
    end
end

local function jobsAndMapsMenu()
    while true do
        menuHeader("JOBS & MAPS")
        printMenuOption("1", "Start quarry job")
        printMenuOption("2", "Optional one-layer test")
        printMenuOption("3", "Calibrate new map")
        printMenuOption("4", "View saved maps")
        printMenuOption("5", "Import legacy map")
        printMenuOption("0", "Back")
        local choice = waitForMenuChoice()
        if choice == "0" then return
        elseif choice == "1" then startJob()
        elseif choice == "2" then testRun()
        elseif choice == "3" then calibrate()
        elseif choice == "4" then mapsView()
        elseif choice == "5" then importLegacyMap() end
    end
end

local function maintenanceMenu()
    while true do
        menuHeader("MAINTENANCE")
        printMenuOption("1", "Detect docks")
        printMenuOption("2", "Relocate hive")
        printMenuOption("3", "Backups")
        printMenuOption("0", "Back")
        local choice = waitForMenuChoice()
        if choice == "0" then return
        elseif choice == "1" then detectDocks()
        elseif choice == "2" then relocationMenu()
        elseif choice == "3" then backupsMenu() end
    end
end

local function logsAndHistoryMenu()
    while true do
        menuHeader("LOGS & HISTORY")
        printMenuOption("1", "Event logs")
        printMenuOption("2", "Job history")
        printMenuOption("0", "Back")
        local choice = waitForMenuChoice()
        if choice == "0" then return
        elseif choice == "1" then logsView()
        elseif choice == "2" then historyView() end
    end
end

local function remoteWorkerSummary(worker)
    return {
        id = worker.id,
        dock = worker.dock,
        displayDock = displayDock(worker.dock),
        status = worker.status,
        version = worker.version,
        protocolVersion = worker.protocolVersion,
        positionConfidence = worker.positionConfidence,
        layer = worker.layer,
        fuel = worker.fuel,
        fuelItems = worker.fuelItems,
        emptyStorageSlots = worker.emptyStorageSlots,
        usedStorageSlots = worker.usedStorageSlots,
        storedItems = worker.storedItems,
        progress = worker.progress,
        total = worker.total,
        error = worker.error,
        lastSeen = worker.lastSeen,
        updateTarget = worker.updateTarget,
    }
end

local function remoteStatus()
    local workers = {}
    for _, worker in ipairs(sortedWorkers()) do workers[#workers + 1] = remoteWorkerSummary(worker) end
    local pairedCount = 0
    for _ in pairs(state.security.paired or {}) do pairedCount = pairedCount + 1 end
    return {
        controllerId = os.getComputerID(),
        version = VERSION,
        protocolVersion = PROTOCOL_VERSION,
        job = state.job and {
            id = state.job.id, mapName = state.job.mapName, layers = state.job.layers,
            status = state.job.status, completedCount = state.job.completedCount,
            testRun = state.job.testRun,
        } or nil,
        workers = workers,
        maps = listMaps(),
        fuelLock = state.fuelLock,
        relocationMode = state.relocationMode,
        safeUpdate = state.safeUpdate,
        emergencyRecovery = state.emergencyRecovery,
        preflight = state.preflight and {
            id = state.preflight.id,
            mapName = state.preflight.mapName,
            layers = state.preflight.layers,
            deadline = state.preflight.deadline,
            result = evaluatePreflight(state.preflight),
        } or nil,
        remoteEnabled = state.security.enabled and state.config.remoteEnabled,
        pairedCount = pairedCount,
        latestLogs = { table.unpack(state.logs, math.max(1, #state.logs - 9), #state.logs) },
    }
end

local ACTION_RANK = {
    status = 1, workers = 1, maps = 1, map_details = 1, history = 1, logs = 1,
    preflight_status = 1, safe_update_status = 1,
    preflight = 2, start_job = 2, pause_hive = 2, resume_hive = 2,
    abort_hive = 2, worker_action = 2,
    emergency_surface_hive = 3,
    safe_update_prepare = 3, safe_update_commit = 3, safe_update_cancel = 3,
    relocate = 3, backup_create = 3, backup_list = 3, backup_restore = 3,
    security_list = 3, security_rename = 3, security_set_role = 3, security_revoke = 3,
}

local function workerActionFromRemote(params)
    local worker = state.workers[tostring(params and params.id)]
    if not worker then return false, "Worker not found." end
    local action = params.action
    if action == "refresh" then send(worker.id, "status_request", {}); return true
    elseif action == "pause" then send(worker.id, "pause", { jobId = state.job and state.job.id }); return true
    elseif action == "resume" then send(worker.id, "resume", { jobId = state.job and state.job.id }); return true
    elseif action == "return" then send(worker.id, "return_to_dock", { jobId = state.job and state.job.id }); return true
    elseif action == "clear_error" then worker.error = nil; send(worker.id, "clear_error", {}); saveState(); return true
    elseif action == "recover_checkpoint" then
        if worker.positionConfidence ~= "recoverable" then return false, "Worker is not at a recoverable anchor." end
        send(worker.id, "recover_checkpoint", {}); return true
    elseif action == "emergency_surface" then
        send(worker.id, "emergency_surface", {
            recoveryId = tostring(nowUtc()),
            targetY = -1,
        })
        worker.status = "emergency_surfacing"
        worker.error = nil
        saveState()
        return true
    elseif action == "recover_retry" or action == "restart" then
        local assignment, err = assignmentForWorker(worker)
        if not assignment then return false, err end
        markWorkerLayersAssigned(worker)
        worker.error = nil
        if action == "recover_retry" then send(worker.id, "recover_and_retry", assignment)
        else
            if not isDockedStatus(worker.status) then return false, "Worker must be docked for restart." end
            send(worker.id, "start_section", assignment)
        end
        saveState(); return true
    end
    return false, "Unknown worker action."
end

local function remotePreflight(params)
    local mapName = params and params.mapName
    local layers = tonumber(params and params.layers)
    if not mapName or not layers or layers < 1 then return false, "Map name and positive layer count are required." end
    local map = loadMap(mapName)
    if not map then return false, "Map not found." end
    local workers = {}
    if type(params.workerIds) == "table" and #params.workerIds > 0 then
        for _, id in ipairs(params.workerIds) do
            local worker = state.workers[tostring(id)]
            if not worker or not worker.dock then return false, "Worker #" .. tostring(id) .. " is unavailable." end
            workers[#workers + 1] = { id = tonumber(id), dock = worker.dock }
        end
    else
        for _, dock in ipairs(DOCK_ORDER) do
            local id = state.dockOccupancy[dock]
            if id then workers[#workers + 1] = { id = id, dock = dock } end
        end
    end
    if params.testRun and #workers > 1 then workers = { workers[1] }; layers = 1 end
    if #workers == 0 then return false, "No docked workers." end
    startPreflight(workers, mapName, layers, params.testRun and "test" or "remote")
    return true, {
        requestId = state.preflight.id,
        estimate = estimateFuel(map, layers, math.min(layers, #workers)),
        testRecommended = not (params and params.testRun) and not mapTestedForCurrentSite(mapName),
    }
end

local function remoteStartJob(params)
    if isActiveJob() then return false, "A job is already active." end
    local preflight = state.preflight
    if not preflight or preflight.mapName ~= params.mapName or tonumber(preflight.layers) ~= tonumber(params.layers) then
        return false, "Run a matching preflight first."
    end
    local result = evaluatePreflight(preflight)
    if not result.ready then return false, "Preflight has not passed." end
    local workers = {}
    for id in pairs(preflight.expected or {}) do
        local worker = state.workers[id]
        workers[#workers + 1] = { id = tonumber(id), dock = worker.dock }
    end
    table.sort(workers, function(a, b)
        local ai, bi = 99, 99
        for index, dock in ipairs(DOCK_ORDER) do if a.dock == dock then ai = index end; if b.dock == dock then bi = index end end
        return ai < bi
    end)
    return launchJob(params.mapName, tonumber(params.layers), workers, params.testRun == true)
end

local function remoteMapDetails()
    local output = {}
    for _, name in ipairs(listMaps()) do
        local map = loadMap(name)
        output[#output + 1] = {
            name = name,
            cellCount = map and countMapCells(map) or nil,
            tested = mapTestedForCurrentSite(name),
            testedAt = map and map.testedAt or nil,
            siteGeneration = state.config.siteGeneration,
        }
    end
    return output
end

local function remoteSecurityAction(sender, action, params)
    params = params or {}
    if action == "security_list" then
        local output = {}
        for key, pocket in pairs(state.security.paired or {}) do
            output[#output + 1] = {
                id = tonumber(pocket.id or key),
                name = pocket.name,
                role = pocket.role,
                pairedAt = pocket.pairedAt,
                lastSeen = pocket.lastSeen,
                isCurrent = tonumber(pocket.id or key) == tonumber(sender),
            }
        end
        table.sort(output, function(left, right) return tonumber(left.id) < tonumber(right.id) end)
        return true, output
    end

    local targetId = tonumber(params.id)
    local target = targetId and state.security.paired[tostring(targetId)] or nil
    if not target then return false, "Paired pocket not found." end

    if action == "security_rename" then
        local name = tostring(params.name or ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 24)
        if name == "" then return false, "Pocket name cannot be empty." end
        target.name = name
        logEvent("warning", "security", "Pocket #" .. targetId .. " renamed by pocket #" .. sender .. ".", nil, true)
        saveState()
        return true
    elseif action == "security_set_role" then
        local role = tostring(params.role or "")
        if role ~= "viewer" and role ~= "operator" and role ~= "administrator" then return false, "Invalid role." end
        if targetId == tonumber(sender) and role ~= "administrator" then
            return false, "An administrator pocket cannot lower its own role remotely. Use the controller."
        end
        target.role = role
        logEvent("warning", "security", "Pocket #" .. targetId .. " role changed to " .. role .. " by pocket #" .. sender .. ".", nil, true)
        saveState()
        return true
    elseif action == "security_revoke" then
        if targetId == tonumber(sender) then return false, "A pocket cannot revoke itself remotely. Use the controller." end
        state.security.paired[tostring(targetId)] = nil
        logEvent("warning", "security", "Pocket #" .. targetId .. " revoked by pocket #" .. sender .. ".", nil, true)
        saveState()
        return true
    end
    return false, "Unknown security action."
end

local function restoreBackupFromRemote(sender, name)
    local currentPocket = deepCopy(state.security.paired[tostring(sender)])
    local ok, err = restoreBackup(name)
    if not ok then return false, err end
    -- Preserve the authenticated administrator which performed the restore.
    -- Otherwise restoring an older security set could remove/change its key
    -- before the signed success response is sent.
    if currentPocket then
        state.security.paired[tostring(sender)] = currentPocket
        saveState()
    end
    return true
end

local function executeRemoteAction(sender, paired, action, params)
    if action == "status" then return true, remoteStatus()
    elseif action == "workers" then
        local output = {}; for _, worker in ipairs(sortedWorkers()) do output[#output + 1] = remoteWorkerSummary(worker) end
        return true, output
    elseif action == "maps" then return true, listMaps()
    elseif action == "map_details" then return true, remoteMapDetails()
    elseif action == "history" then return true, deepCopy(state.jobHistory)
    elseif action == "logs" then return true, deepCopy(state.logs)
    elseif action == "preflight_status" then return true, state.preflight and evaluatePreflight(state.preflight) or nil
    elseif action == "safe_update_status" then return true, deepCopy(state.safeUpdate)
    elseif action == "preflight" then return remotePreflight(params)
    elseif action == "start_job" then return remoteStartJob(params)
    elseif action == "pause_hive" then pauseJob(); return true
    elseif action == "resume_hive" then resumeJob(); return true
    elseif action == "abort_hive" then initiateAbortWithoutPrompt(); return true
    elseif action == "emergency_surface_hive" then return beginEmergencySurfaceRecovery(sender)
    elseif action == "worker_action" then return workerActionFromRemote(params)
    elseif action == "safe_update_prepare" then return beginSafeUpdate(sender)
    elseif action == "safe_update_commit" then return commitSafeUpdate(sender)
    elseif action == "safe_update_cancel" then
        if state.safeUpdate then state.safeUpdate.stage = "cancelled"; saveState() end
        return true
    elseif action == "relocate" then return prepareRelocation(sender)
    elseif action == "backup_create" then return createBackup(params and params.name)
    elseif action == "backup_list" then return true, listBackups()
    elseif action == "backup_restore" then return restoreBackupFromRemote(sender, params and params.name)
    elseif action == "security_list" or action == "security_rename" or action == "security_set_role" or action == "security_revoke" then
        return remoteSecurityAction(sender, action, params)
    end
    return false, "Unknown remote action."
end

local function handlePairingMessage(sender, message)
    if not pairingSession or nowUtc() >= pairingSession.expires then return end
    if message.type == "pair_hello" then
        if type(message.pocketNonce) ~= "string" then return end
        pairingSession.pocketId = sender
        pairingSession.pocketNonce = message.pocketNonce
        rednet.send(sender, {
            type = "pair_challenge",
            controllerId = os.getComputerID(),
            controllerNonce = pairingSession.controllerNonce,
            pocketNonce = message.pocketNonce,
            expires = pairingSession.expires,
            version = VERSION,
        }, REMOTE_PROTOCOL)
    elseif message.type == "pair_proof"
        and sender == pairingSession.pocketId
        and message.pocketNonce == pairingSession.pocketNonce
        and message.controllerNonce == pairingSession.controllerNonce then
        local key = crypto.derivePairKey(pairingSession.code, os.getComputerID(), sender, pairingSession.controllerNonce, pairingSession.pocketNonce)
        local expected = crypto.hmac(key, "roomba-hive-pair-proof-v1")
        if crypto.constantTimeEquals(expected, message.proof) then
            local paired = {
                id = sender, name = pairingSession.name, role = pairingSession.role,
                key = key, lastSeq = 0, serverSeq = 0, pairedAt = nowUtc(),
            }
            state.security.paired[tostring(sender)] = paired
            pairingSession.complete = true
            pairingSession.pocketId = sender
            saveState()
            signedRemoteSend(sender, "pair_accept", {
                role = paired.role, name = paired.name, controllerName = os.getComputerLabel() or "Roomba Hive",
            })
            logEvent("success", "security", "Paired pocket #" .. tostring(sender) .. " as " .. paired.role .. ".", nil, true)
        else
            rednet.send(sender, { type = "pair_rejected", message = "Pairing code proof was invalid." }, REMOTE_PROTOCOL)
        end
    end
end

local function handleRemoteMessage(sender, message)
    if type(message) ~= "table" then return end
    if message.type == "pair_hello" or message.type == "pair_proof" then
        handlePairingMessage(sender, message); return
    end
    if not state.security.enabled or not state.config.remoteEnabled then return end
    if message.type ~= "remote_request" then return end
    local paired = state.security.paired[tostring(sender)]
    if not paired or not paired.key then return end
    if tonumber(message.pocketId) ~= tonumber(sender) or tonumber(message.controllerId) ~= os.getComputerID() then return end
    if not crypto.verify(paired.key, message) then
        logEvent("warning", "security", "Rejected invalid signature from pocket #" .. tostring(sender) .. ".", nil, true)
        return
    end
    local sequence = tonumber(message.seq)
    if not sequence or sequence <= tonumber(paired.lastSeq or 0) then
        logEvent("warning", "security", "Rejected replayed request from pocket #" .. tostring(sender) .. ".", nil, true)
        return
    end
    paired.lastSeq = sequence
    paired.lastSeen = nowUtc()
    local required = ACTION_RANK[message.action] or 99
    local ok, result, err
    if roleRank(paired.role) < required then
        ok, err = false, "Permission denied for role " .. tostring(paired.role) .. "."
    else
        local actionOk, first, second = pcall(executeRemoteAction, sender, paired, message.action, message.params or {})
        if not actionOk then ok, err = false, tostring(first)
        else ok, result, err = first, second, second end
    end
    signedRemoteSend(sender, "remote_response", {
        requestId = message.requestId,
        ok = ok == true,
        result = ok == true and result or nil,
        error = ok == true and nil or tostring(err or result or "Request failed"),
    })
    saveState()
end

local function uiLoop()
    while running do
        render()
        local _, character = os.pullEvent("char")
        character = character:lower()
        if character == "1" then operationsMenu()
        elseif character == "2" then workersView()
        elseif character == "3" then jobsAndMapsMenu()
        elseif character == "4" then maintenanceMenu()
        elseif character == "5" then securityMenu()
        elseif character == "6" then logsAndHistoryMenu()
        elseif character == "0" then running = false
        -- Legacy shortcuts remain accepted for experienced users.
        elseif character == "d" then detectDocks()
        elseif character == "c" then calibrate()
        elseif character == "i" then importLegacyMap()
        elseif character == "j" then startJob()
        elseif character == "t" then testRun()
        elseif character == "p" then pauseJob()
        elseif character == "r" then resumeJob()
        elseif character == "a" then abortJob()
        elseif character == "w" then workersView()
        elseif character == "m" then mapsView()
        elseif character == "l" then relocationMenu()
        elseif character == "s" then securityMenu()
        elseif character == "b" then backupsMenu()
        elseif character == "h" then historyView()
        elseif character == "g" then logsView()
        elseif character == "u" then updateHive()
        elseif character == "q" then running = false end
    end
end

local function resendAbortIfNeeded(now)
    if not state.job or state.job.status ~= "aborting" then return end
    local last = state.job.lastAbortSent or 0
    if now - last < ABORT_RETRY_SECONDS * 1000 then return end
    for _, section in ipairs(state.job.sections or {}) do
        if not state.job.abortAcks[tostring(section.worker)] then
            send(section.worker, "abort", { jobId = state.job.id })
        end
    end
    state.job.lastAbortSent = now
    saveState()
end

local function networkLoop()
    while running do
        local sender, message, protocol = rednet.receive(nil, 1)
        if sender then
            if protocol == PROTOCOL or protocol == LEGACY_PROTOCOL then handleMessage(sender, message)
            elseif protocol == REMOTE_PROTOCOL then handleRemoteMessage(sender, message) end
        end

        local now = nowUtc()
        local stateChanged = false
        for _, worker in pairs(state.workers) do
            if worker.lastSeen and now - worker.lastSeen > HEARTBEAT_TIMEOUT * 1000 then
                if not tostring(worker.status):find("^offline") then
                    worker.status = "offline (assignment kept)"
                    logEvent("warning", "worker", workerLabel(worker) .. " went offline.", { worker = worker.id })
                    stateChanged = true
                end
                if state.fuelLock == worker.id then state.fuelLock = nil; stateChanged = true end
            end
        end
        if stateChanged then saveState() end
        resendAbortIfNeeded(now)
        processSafeUpdate()
        archiveCurrentJob()
    end
end

local function updateLoop()
    while running do
        if pendingControllerUpdate then
            pendingControllerUpdate = false
            sendAlert("warning", "update", "Controller is beginning the update and will reboot.", nil)
            sleep(1)
            local separator = INSTALL_URL:find("?", 1, true) and "&" or "?"
            local url = INSTALL_URL .. separator .. "launch=" .. tostring(nowUtc())
            local ok = shell.run("wget", "run", url, "controller")
            if not ok then
                state.safeUpdate = state.safeUpdate or {}
                state.safeUpdate.stage = "failed"
                state.safeUpdate.error = "The installer did not complete."
                logEvent("error", "update", state.safeUpdate.error, nil)
                saveState()
            end
        end
        sleep(0.25)
    end
end

local function healthLoop()
    sleep(8)
    if fs.exists(BOOT_FILE) then
        local ok, boot = pcall(dofile, BOOT_FILE)
        if ok and boot and boot.markHealthy then boot.markHealthy("controller", VERSION) end
    end
    while running do sleep(3600) end
end

local ok, err = pcall(function()
    parallel.waitForAny(uiLoop, networkLoop, updateLoop, healthLoop)
end)
rednet.unhost(PROTOCOL, HOSTNAME)
rednet.unhost(REMOTE_PROTOCOL, REMOTE_HOSTNAME)
if not ok then printError(err) end
