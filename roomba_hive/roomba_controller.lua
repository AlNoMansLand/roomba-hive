-- Roomba Hive Controller v0.1.0
-- Runs on an Advanced Computer at logical origin 0,0,0.

local VERSION = "0.1.0"
local PROTOCOL = "roomba_hive_v1"
local HOSTNAME = "roomba-hive"
local ROOT = "/roomba"
local MAP_DIR = fs.combine(ROOT, "maps")
local STATE_FILE = fs.combine(ROOT, "state.db")
local TMP_FILE = STATE_FILE .. ".tmp"
local DOCK_SIDES = { "front", "right", "back", "left" }
local SIDE_TO_DOCK = { front = "north", right = "east", back = "south", left = "west" }
local DOCK_ORDER = { "north", "east", "south", "west" }
local PULSE_SECONDS = 0.75
local HEARTBEAT_TIMEOUT = 30
local activeProbeDock = nil

local modem = peripheral.find("modem", function(_, p) return p.isWireless and p.isWireless() end)
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
    local h, err = fs.open(tmp, "w")
    if not h then error("Cannot write " .. path .. ": " .. tostring(err), 0) end
    h.write(textutils.serialize(value))
    h.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
end

local function loadTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local value = textutils.unserialize(h.readAll())
    h.close()
    return type(value) == "table" and value or nil
end

local state = loadTable(STATE_FILE) or {
    version = VERSION,
    maps = {},
    workers = {},
    docks = {},
    job = nil,
    fuelLock = nil,
}
state.workers = state.workers or {}
state.docks = state.docks or {}

local function saveState() atomicSave(STATE_FILE, state) end

local function send(id, kind, data)
    data = data or {}
    data.type = kind
    data.version = VERSION
    rednet.send(id, data, PROTOCOL)
end

local function broadcast(kind, data)
    data = data or {}
    data.type = kind
    data.version = VERSION
    rednet.broadcast(data, PROTOCOL)
end

local function countMapCells(map)
    local n = 0
    for _ in pairs(map.interior or {}) do n = n + 1 end
    return n
end

local function mapPath(name) return fs.combine(MAP_DIR, name .. ".db") end

local function sanitize(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w%-%_ ]", ""):gsub("%s+", "_"):sub(1, 32)
    return name ~= "" and name or nil
end

local function saveMap(map)
    assert(type(map) == "table" and type(map.interior) == "table" and type(map.bounds) == "table", "Invalid map")
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
    local out = {}
    for _, file in ipairs(fs.list(MAP_DIR)) do
        if file:sub(-3) == ".db" then out[#out + 1] = file:sub(1, -4) end
    end
    table.sort(out)
    return out
end

local function workerLabel(w)
    return (w.dock and w.dock:sub(1,1):upper() .. w.dock:sub(2) or "Unassigned") .. " #" .. tostring(w.id)
end

local function render()
    term.clear(); term.setCursorPos(1,1)
    print("ROOOMBA HIVE CONTROLLER v" .. VERSION)
    print("================================")
    print("Modem: " .. modemSide)
    print("")
    for _, dock in ipairs(DOCK_ORDER) do
        local id = state.docks[dock]
        local w = id and state.workers[tostring(id)] or nil
        if w then
            local age = w.lastSeen and math.floor((os.epoch("utc") - w.lastSeen) / 1000) or 9999
            print(string.format("%-5s  #%-4s %-16s %ss", dock, id, w.status or "unknown", age))
        else
            print(string.format("%-5s  empty", dock))
        end
    end
    print("")
    if state.job then
        local j = state.job
        print("Job: " .. tostring(j.mapName) .. " | layers " .. j.layers)
        print("Status: " .. tostring(j.status) .. " | complete " .. tostring(j.completedCount or 0) .. "/" .. j.layers)
    else
        print("No active job.")
    end
    print("")
    print("[D] Detect docks  [C] Calibrate  [J] Start job")
    print("[W] Workers       [P] Pause      [R] Resume")
    print("[M] Maps          [Q] Quit UI")
end

local function detectDocks()
    print("\nMake sure worker turtles are powered on, touching the four horizontal sides, and facing outward.")
    state.docks = {}
    for _, side in ipairs(DOCK_SIDES) do
        local dock = SIDE_TO_DOCK[side]
        print("Probing " .. dock .. " dock...")
        activeProbeDock = dock
        redstone.setOutput(side, true)
        broadcast("dock_probe_begin", { dock = dock, controller = os.getComputerID() })
        sleep(PULSE_SECONDS)
        redstone.setOutput(side, false)
        activeProbeDock = nil
        local found = state.docks[dock]
        if found then
            print("  Found turtle #" .. found)
        else
            print("  Empty")
        end
        sleep(0.25)
    end
    saveState()
    print("Dock detection complete. Press Enter.")
    read()
end

local function chooseDockedWorker()
    local choices = {}
    for _, dock in ipairs(DOCK_ORDER) do
        local id = state.docks[dock]
        if id then choices[#choices+1] = {dock=dock,id=id} end
    end
    if #choices == 0 then print("No docked workers. Run Detect docks first."); sleep(2); return nil end
    for i,v in ipairs(choices) do print(i .. ") " .. v.dock .. " turtle #" .. v.id) end
    write("Choose worker: ")
    return choices[tonumber(read())]
end

local function calibrate()
    term.clear(); term.setCursorPos(1,1)
    print("NEW MAP CALIBRATION")
    local chosen = chooseDockedWorker(); if not chosen then return end
    write("Map name: ")
    local name = sanitize(read())
    if not name then print("Invalid name."); sleep(2); return end
    print("The closed wall outline must be on mining layer 1 (Y=-1).")
    print("The selected turtle will descend, enter the center, trace the wall, and return.")
    write("Type CALIBRATE: ")
    if read() ~= "CALIBRATE" then return end
    state.pendingCalibration = { worker = chosen.id, name = name }
    saveState()
    send(chosen.id, "calibrate", { name = name })
    print("Calibration started. Waiting for worker...")
    while state.pendingCalibration do sleep(0.5) end
    local result = state.lastCalibrationResult
    if result and result.ok then
        print("Saved map '" .. name .. "' with " .. tostring(result.cellCount) .. " cells.")
    else
        print("Calibration failed: " .. tostring(result and result.message or "unknown error"))
    end
    state.lastCalibrationResult = nil
    saveState()
    print("Press Enter."); read()
end

local function buildSections(layers, workers)
    local sections = {}
    local n = #workers
    for i,w in ipairs(workers) do
        local first = math.floor((i-1) * layers / n) + 1
        local last = math.floor(i * layers / n)
        if first <= last then sections[#sections+1] = { worker=w.id, dock=w.dock, first=first, last=last } end
    end
    return sections
end

local function startJob()
    term.clear(); term.setCursorPos(1,1)
    local maps = listMaps()
    if #maps == 0 then print("No maps saved. Calibrate first."); sleep(2); return end
    print("SAVED MAPS")
    for i,n in ipairs(maps) do print(i .. ") " .. n) end
    write("Map number: ")
    local name = maps[tonumber(read())]
    if not name then return end
    write("Number of layers: ")
    local layers = tonumber(read())
    if not layers or layers < 1 or layers % 1 ~= 0 then print("Invalid layers."); sleep(2); return end
    local workers = {}
    for _,dock in ipairs(DOCK_ORDER) do
        local id = state.docks[dock]
        if id then workers[#workers+1] = {id=id,dock=dock} end
    end
    if #workers == 0 then print("No workers detected."); sleep(2); return end
    local map = loadMap(name)
    local sections = buildSections(layers, workers)
    local layerState = {}
    for i=1,layers do layerState[i] = "waiting" end
    state.job = {
        id = tostring(os.epoch("utc")), mapName=name, layers=layers, status="running",
        sections=sections, layerState=layerState, completedCount=0, started=os.epoch("utc")
    }
    saveState()
    for _,s in ipairs(sections) do
        for l=s.first,s.last do layerState[l] = "assigned" end
        send(s.worker, "start_section", { jobId=state.job.id, map=map, firstLayer=s.first, lastLayer=s.last, dock=s.dock })
    end
    saveState()
    print("Job started across " .. #sections .. " worker(s). Press Enter."); read()
end

local function handleMessage(sender, msg)
    if type(msg) ~= "table" then return end
    local key = tostring(sender)
    local w = state.workers[key] or { id=sender }
    w.lastSeen = os.epoch("utc")
    if msg.type == "dock_probe" and activeProbeDock then
        local dockName = activeProbeDock
        state.docks[dockName] = sender
        w.dock = dockName
        w.status = "docked"
        send(sender, "dock_assigned", { dock = dockName, controller = os.getComputerID() })
    elseif msg.type == "calibration_complete" and state.pendingCalibration and sender == state.pendingCalibration.worker then
        msg.map.name = state.pendingCalibration.name
        saveMap(msg.map)
        state.lastCalibrationResult = { ok=true, cellCount=msg.map.cellCount }
        state.pendingCalibration = nil
    elseif msg.type == "hello" or msg.type == "heartbeat" then
        w.status = msg.status or w.status or "online"
        w.layer = msg.layer or w.layer
        w.fuel = msg.fuel or w.fuel
        w.position = msg.position or w.position
        state.workers[key] = w
    elseif msg.type == "layer_started" then
        w.status = "mining"; w.layer = msg.layer
        if state.job and state.job.layerState then state.job.layerState[msg.layer] = "active" end
    elseif msg.type == "layer_complete" then
        w.status = "returning"; w.layer = msg.layer
        if state.job and state.job.layerState and state.job.layerState[msg.layer] ~= "complete" then
            state.job.layerState[msg.layer] = "complete"
            state.job.completedCount = (state.job.completedCount or 0) + 1
            if state.job.completedCount >= state.job.layers then state.job.status = "complete" end
        end
    elseif msg.type == "section_complete" then
        w.status = "docked"; w.layer=nil
    elseif msg.type == "worker_error" then
        w.status = "ERROR: " .. tostring(msg.message)
        w.error = msg
        if state.pendingCalibration and sender == state.pendingCalibration.worker then
            state.lastCalibrationResult = { ok=false, message=msg.message }
            state.pendingCalibration = nil
        end
    elseif msg.type == "fuel_lock_request" then
        if not state.fuelLock or state.fuelLock == sender then
            state.fuelLock = sender
            send(sender, "fuel_lock_granted", {})
        else
            send(sender, "fuel_lock_wait", { holder=state.fuelLock })
        end
    elseif msg.type == "fuel_lock_release" then
        if state.fuelLock == sender then state.fuelLock = nil end
    end
    state.workers[key] = w
    saveState()
end

local function workersView()
    term.clear(); term.setCursorPos(1,1)
    print("WORKERS")
    for _,w in pairs(state.workers) do
        print(workerLabel(w) .. " | " .. tostring(w.status) .. " | layer " .. tostring(w.layer or "-") .. " | fuel " .. tostring(w.fuel or "?"))
        if w.error then print("  " .. tostring(w.error.message) .. " @ " .. textutils.serialize(w.error.position or {})) end
    end
    print("\nPress Enter."); read()
end

local function mapsView()
    term.clear(); term.setCursorPos(1,1)
    print("MAP LIBRARY")
    for _,n in ipairs(listMaps()) do
        local m=loadMap(n); print(n .. " | cells " .. tostring(m and countMapCells(m) or "?"))
    end
    print("\nPress Enter."); read()
end

local running = true
local function uiLoop()
    while running do
        render()
        local ev, ch = os.pullEvent("char")
        ch = ch:lower()
        if ch == "d" then detectDocks()
        elseif ch == "c" then calibrate()
        elseif ch == "j" then startJob()
        elseif ch == "w" then workersView()
        elseif ch == "m" then mapsView()
        elseif ch == "p" then if state.job then state.job.status="paused"; saveState(); broadcast("pause", {jobId=state.job.id}) end
        elseif ch == "r" then if state.job then state.job.status="running"; saveState(); broadcast("resume", {jobId=state.job.id}) end
        elseif ch == "q" then running=false end
    end
end

local function networkLoop()
    while running do
        local sender,msg,proto = rednet.receive(PROTOCOL,1)
        if sender then handleMessage(sender,msg) end
        local now=os.epoch("utc")
        for _,w in pairs(state.workers) do
            if w.lastSeen and now-w.lastSeen > HEARTBEAT_TIMEOUT*1000 and not tostring(w.status):find("offline") then
                w.status="offline (not reassigned)"
            end
        end
    end
end

local ok, err = pcall(function() parallel.waitForAny(uiLoop, networkLoop) end)
rednet.unhost(PROTOCOL, HOSTNAME)
if not ok then printError(err) end
