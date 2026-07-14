-- Roomba Hive Controller v0.2.0
-- Runs on an Advanced Computer at logical origin 0,0,0.

local VERSION = "0.2.0"
local PROTOCOL = "roomba_hive_v1"
local HOSTNAME = "roomba-hive"
local ROOT = "/roomba"
local MAP_DIR = fs.combine(ROOT, "maps")
local STATE_FILE = fs.combine(ROOT, "state.db")
local DOCK_SIDES = { "front", "right", "back", "left" }
local SIDE_TO_DOCK = { front = "north", right = "east", back = "south", left = "west" }
local DOCK_ORDER = { "north", "east", "south", "west" }
local PULSE_SECONDS = 0.75
local HEARTBEAT_TIMEOUT = 30
local ABORT_RETRY_SECONDS = 5

local activeProbeDock = nil
local running = true

local modem = peripheral.find("modem", function(_, p)
    return p.isWireless and p.isWireless()
end)
assert(modem, "Attach a wireless or ender modem to the controller.")
local modemSide = peripheral.getName(modem)
rednet.open(modemSide)
rednet.host(PROTOCOL, HOSTNAME)

local function ensureDir(path)
    if not fs.exists(path) then fs.makeDir(path) end
end

ensureDir(ROOT)
ensureDir(MAP_DIR)

local function atomicSave(path, value)
    local tmp = path .. ".tmp"
    local handle, err = fs.open(tmp, "w")
    if not handle then error("Cannot write " .. path .. ": " .. tostring(err), 0) end
    handle.write(textutils.serialize(value))
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
state.version = VERSION
state.maps = state.maps or {}
state.workers = state.workers or {}
state.docks = state.docks or {}
state.dockOccupancy = {}
state.job = state.job or nil
state.fuelLock = state.fuelLock or nil

local function saveState()
    state.version = VERSION
    atomicSave(STATE_FILE, state)
end

local function send(id, kind, data)
    data = data or {}
    data.type = kind
    data.version = VERSION
    return rednet.send(id, data, PROTOCOL)
end

local function broadcast(kind, data)
    data = data or {}
    data.type = kind
    data.version = VERSION
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

local function workerLabel(worker)
    local dockName = worker.dock and (worker.dock:sub(1, 1):upper() .. worker.dock:sub(2)) or "Unassigned"
    return dockName .. " #" .. tostring(worker.id)
end

local function isActiveJob()
    return state.job and (
        state.job.status == "running"
        or state.job.status == "paused"
        or state.job.status == "aborting"
    )
end

local function render()
    term.clear()
    term.setCursorPos(1, 1)
    print("ROOMBA HIVE CONTROLLER v" .. VERSION)
    print("================================")
    print("Modem: " .. modemSide)
    print("")

    for _, dock in ipairs(DOCK_ORDER) do
        local occupied = state.dockOccupancy[dock]
        local assigned = state.docks[dock]
        local id = occupied or assigned
        local worker = id and state.workers[tostring(id)] or nil
        if occupied and worker then
            local age = worker.lastSeen and math.floor((os.epoch("utc") - worker.lastSeen) / 1000) or 9999
            print(string.format("%-5s #%-4s %-14s %ss", dock, id, worker.status or "unknown", age))
        elseif assigned then
            local status = worker and worker.status or "assigned"
            print(string.format("%-5s #%-4s %-14s away", dock, assigned, status))
        else
            print(string.format("%-5s empty", dock))
        end
    end

    print("")
    if state.job then
        local job = state.job
        print("Job: " .. tostring(job.mapName) .. " | " .. tostring(job.layers) .. " layers")
        print("Status: " .. tostring(job.status) .. " | " .. tostring(job.completedCount or 0) .. "/" .. tostring(job.layers))
    else
        print("No job recorded.")
    end

    print("")
    print("[D] Detect  [C] Calibrate  [J] Start")
    print("[P] Pause   [R] Resume     [A] Abort")
    print("[W] Workers [M] Maps       [I] Import")
    print("[Q] Quit UI")
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
        print("Probing " .. dock .. " dock...")
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
        print(index .. ") " .. choice.dock .. " turtle #" .. tostring(choice.id))
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
    local workerCount = #workers
    for index, worker in ipairs(workers) do
        local firstLayer = math.floor((index - 1) * layers / workerCount) + 1
        local lastLayer = math.floor(index * layers / workerCount)
        if firstLayer <= lastLayer then
            sections[#sections + 1] = {
                worker = worker.id,
                dock = worker.dock,
                first = firstLayer,
                last = lastLayer,
            }
        end
    end
    return sections
end

local function startJob()
    if isActiveJob() then
        print("A job is already active.")
        sleep(2)
        return
    end

    term.clear()
    term.setCursorPos(1, 1)
    local maps = listMaps()
    if #maps == 0 then print("No maps saved. Calibrate or import first."); sleep(2); return end
    print("SAVED MAPS")
    for index, name in ipairs(maps) do print(index .. ") " .. name) end
    write("Map number: ")
    local name = maps[tonumber(read())]
    if not name then return end
    write("Number of layers: ")
    local layers = tonumber(read())
    if not layers or layers < 1 or layers % 1 ~= 0 then print("Invalid layer count."); sleep(2); return end

    local workers = {}
    for _, dock in ipairs(DOCK_ORDER) do
        local id = state.dockOccupancy[dock]
        if id then workers[#workers + 1] = { id = id, dock = dock } end
    end
    if #workers == 0 then print("No docked workers detected."); sleep(2); return end

    local map = loadMap(name)
    if not map then print("Map file could not be loaded."); sleep(2); return end
    local sections = buildSections(layers, workers)
    local layerState = {}
    for layer = 1, layers do layerState[layer] = "waiting" end

    state.job = {
        id = tostring(os.epoch("utc")),
        mapName = name,
        layers = layers,
        status = "running",
        sections = sections,
        layerState = layerState,
        completedCount = 0,
        abortAcks = {},
        started = os.epoch("utc"),
    }
    state.fuelLock = nil

    for _, section in ipairs(sections) do
        for layer = section.first, section.last do layerState[layer] = "assigned" end
        local worker = state.workers[tostring(section.worker)]
        if worker then worker.error = nil end
    end
    saveState()

    for _, section in ipairs(sections) do
        send(section.worker, "start_section", {
            jobId = state.job.id,
            map = map,
            firstLayer = section.first,
            lastLayer = section.last,
            dock = section.dock,
        })
        state.dockOccupancy[section.dock] = nil
    end
    saveState()
    print("Job started across " .. tostring(#sections) .. " worker(s). Press Enter.")
    read()
end

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
    end
end

local function handleMessage(sender, message)
    if type(message) ~= "table" then return end
    local key = tostring(sender)
    local worker = state.workers[key] or { id = sender }
    worker.lastSeen = os.epoch("utc")

    if message.type == "dock_probe" and activeProbeDock then
        local dock = activeProbeDock
        state.dockOccupancy[dock] = sender
        if restoreReportedDock(sender, dock, worker) then
            worker.status = "docked"
            send(sender, "dock_assigned", { dock = dock, controller = os.getComputerID() })
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
        worker.status = message.status or worker.status or "online"
        worker.layer = message.layer
        worker.fuel = message.fuel or worker.fuel
        worker.position = message.position or worker.position
        worker.progress = message.progress or worker.progress
        worker.total = message.total or worker.total
        local restored = restoreReportedDock(sender, message.dock, worker)
        if (message.status == "docked" or message.status == "aborted") and restored then
            state.dockOccupancy[message.dock] = sender
        elseif message.status and message.status ~= "docked" and message.status ~= "aborted" then
            for dockName, id in pairs(state.dockOccupancy) do
                if tostring(id) == tostring(sender) then state.dockOccupancy[dockName] = nil end
            end
        end

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
            if state.job.completedCount >= state.job.layers then state.job.status = "complete" end
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
        worker.abortNote = message.note
        if validDock(worker.dock) and tostring(state.docks[worker.dock]) == tostring(sender) then
            state.dockOccupancy[worker.dock] = sender
        end
        acknowledgeAbort(sender)

    elseif message.type == "worker_error" then
        worker.status = "ERROR: " .. tostring(message.message)
        worker.error = message
        if state.fuelLock == sender then state.fuelLock = nil end
        if state.pendingCalibration and sender == state.pendingCalibration.worker then
            state.lastCalibrationResult = { ok = false, message = message.message }
            state.pendingCalibration = nil
        end

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

local function workersView()
    term.clear()
    term.setCursorPos(1, 1)
    print("WORKERS")
    local workers = {}
    for _, worker in pairs(state.workers) do workers[#workers + 1] = worker end
    table.sort(workers, function(a, b) return tostring(a.dock or "z") < tostring(b.dock or "z") end)
    for _, worker in ipairs(workers) do
        print(workerLabel(worker) .. " | " .. tostring(worker.status) .. " | L" .. tostring(worker.layer or "-") .. " | F" .. tostring(worker.fuel or "?"))
        if worker.progress and worker.total then
            print("  Progress " .. tostring(worker.progress) .. "/" .. tostring(worker.total))
        end
        if worker.error then
            print("  " .. tostring(worker.error.message) .. " @ " .. textutils.serialize(worker.error.position or {}))
        end
    end
    print("\nPress Enter.")
    read()
end

local function mapsView()
    term.clear()
    term.setCursorPos(1, 1)
    print("MAP LIBRARY")
    local maps = listMaps()
    if #maps == 0 then print("No maps saved.") end
    for _, name in ipairs(maps) do
        local map = loadMap(name)
        print(name .. " | " .. tostring(map and countMapCells(map) or "?") .. " cells")
    end
    print("\nPress Enter.")
    read()
end

local function uiLoop()
    while running do
        render()
        local _, character = os.pullEvent("char")
        character = character:lower()
        if character == "d" then detectDocks()
        elseif character == "c" then calibrate()
        elseif character == "i" then importLegacyMap()
        elseif character == "j" then startJob()
        elseif character == "p" then pauseJob()
        elseif character == "r" then resumeJob()
        elseif character == "a" then abortJob()
        elseif character == "w" then workersView()
        elseif character == "m" then mapsView()
        elseif character == "q" then running = false
        end
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
        local sender, message = rednet.receive(PROTOCOL, 1)
        if sender then handleMessage(sender, message) end

        local now = os.epoch("utc")
        for _, worker in pairs(state.workers) do
            if worker.lastSeen and now - worker.lastSeen > HEARTBEAT_TIMEOUT * 1000 then
                if not tostring(worker.status):find("^offline") then worker.status = "offline (assignment kept)" end
                if state.fuelLock == worker.id then state.fuelLock = nil end
            end
        end
        resendAbortIfNeeded(now)
    end
end

local ok, err = pcall(function()
    parallel.waitForAny(uiLoop, networkLoop)
end)
rednet.unhost(PROTOCOL, HOSTNAME)
if not ok then printError(err) end
