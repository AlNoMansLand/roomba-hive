-- Roomba Hive Worker v0.3.2
-- Requires a mining turtle with a wireless or ender modem.

local VERSION = "0.3.2"
local PROTOCOL_VERSION = 2
local PROTOCOL = "roomba_hive_worker_v2"
local LEGACY_PROTOCOL = "roomba_hive_v1"
local HOSTNAME = "roomba-hive"
local UPDATE_BASE_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main"
local ROOT = "/roomba"
local STATE_FILE = fs.combine(ROOT, "worker_state.db")
local BOOT_FILE = fs.combine(ROOT, "boot.lua")

local FUEL_SLOT = 1
local FIRST_STORAGE_SLOT = 2
local LAST_STORAGE_SLOT = 16
local FUEL_ITEM_RESERVE = 5
local FUEL_TARGET = 2048
local FUEL_MARGIN = 96
local POSITION_SAVE_INTERVAL = 24
local MAX_FALLING_DIGS = 32
local MAX_CALIBRATION_STEPS = 100000
local INVENTORY_CHECK_INTERVAL = 6
local MOVE_RETRY_DELAY = 0.4
local ABORT_SIGNAL = "__ROOMBA_ABORT__"
local FUEL_STATION_EMPTY_SIGNAL = "__ROOMBA_FUEL_STATION_EMPTY__"

local NORTH, EAST, SOUTH, WEST = 0, 1, 2, 3
local dirNames = { [NORTH] = "north", [EAST] = "east", [SOUTH] = "south", [WEST] = "west" }
local vec = {
    [NORTH] = { x = 0, z = -1 },
    [EAST] = { x = 1, z = 0 },
    [SOUTH] = { x = 0, z = 1 },
    [WEST] = { x = -1, z = 0 },
}
local dockInfo = {
    north = { x = 0, z = -1, out = NORTH, inward = SOUTH },
    east = { x = 1, z = 0, out = EAST, inward = WEST },
    south = { x = 0, z = 1, out = SOUTH, inward = NORTH },
    west = { x = -1, z = 0, out = WEST, inward = EAST },
}
local dockDisplay = { north = "front", east = "left", south = "back", west = "right" }
local neighbors = {
    { dx = 0, dz = -1, dir = NORTH },
    { dx = 1, dz = 0, dir = EAST },
    { dx = 0, dz = 1, dir = SOUTH },
    { dx = -1, dz = 0, dir = WEST },
}

if not fs.exists(ROOT) then fs.makeDir(ROOT) end

local modem = peripheral.find("modem", function(_, peripheralObject)
    return peripheralObject.isWireless and peripheralObject.isWireless()
end)
assert(modem, "Worker requires a wireless or ender modem upgrade.")
local modemSide = peripheral.getName(modem)
rednet.open(modemSide)

local function key(x, z)
    return tostring(x) .. "," .. tostring(z)
end

local function parseKey(value)
    local comma = value:find(",", 1, true)
    return tonumber(value:sub(1, comma - 1)), tonumber(value:sub(comma + 1))
end

local function saveTable(path, value)
    local tmp = path .. ".tmp"
    local handle = assert(fs.open(tmp, "w"))
    handle.write(textutils.serialize(value))
    handle.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
end

local function loadTable(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local value = textutils.unserialize(handle.readAll())
    handle.close()
    return type(value) == "table" and value or nil
end

local state = loadTable(STATE_FILE) or { status = "unassigned" }
state.protocolVersion = PROTOCOL_VERSION
state.positionConfidence = state.positionConfidence or "unknown"
state.alerts = state.alerts or {}
local controller = state.controller
local dock = state.dock
local pos = state.pos or { x = 0, y = 0, z = 0, dir = NORTH }
local movesSinceSave = 0

local function atDockCoordinates()
    local info = dock and dockInfo[dock] or nil
    return info ~= nil and pos.y == 0 and pos.x == info.x and pos.z == info.z
end

-- Crash recovery is deliberately conservative. Only a position explicitly
-- persisted while stationary at the layer centre is considered recoverable.
-- A crash during any movement leaves confidence unknown, even when the saved
-- coordinates happen to resemble a shaft position.
if atDockCoordinates() then
    state.positionConfidence = "confirmed"
    state.recoveryAnchor = "dock"
elseif state.jobId then
    if state.positionConfidence == "recoverable" and state.recoveryAnchor == "center"
        and pos.y < 0 and pos.x == 0 and pos.z == 0 then
        state.status = "recovery_required"
        state.error = "Worker rebooted at a persisted layer-centre anchor. Use Recover checkpoint."
    else
        state.positionConfidence = "unknown"
        state.recoveryAnchor = nil
        state.status = "recovery_required"
        state.error = "Worker rebooted during movement. Return it to a dock manually, then Detect docks."
    end
end

-- A successful updater reboots after marking the device as updating. On the
-- next boot, restore the normal docked state before reporting to the controller.
if state.status == "updating" and dock and dockInfo[dock] then
    local info = dockInfo[dock]
    if pos.y == 0 and pos.x == info.x and pos.z == info.z then
        state.status = "docked"
        state.error = nil
    end
end

local interior = {}
local bounds = nil
local carved = {}
local wall = {}

local paused = false
local abortRequested = false
local parkRequested = false
local taskActive = false
local fuelLockGranted = false
local fuelLockHeld = false

local uiMessage = "Starting worker"
local lastUiRender = 0

local STATUS_LABELS = {
    unassigned = "Waiting for dock assignment",
    docked = "Docked and ready",
    starting = "Preparing assigned section",
    descending = "Descending to mining layer",
    mining = "Mining",
    returning = "Returning to dock",
    returning_by_command = "Returning by command",
    refueling = "Refueling",
    waiting_for_fuel = "Waiting for fuel in chest",
    fuel_station_empty = "RESTOCK FUEL STATION",
    waiting_fuel_lock = "Waiting for shared fuel station",
    paused = "Paused safely",
    blocked_waiting = "Blocked - waiting for clearance",
    output_full = "Output chest is full",
    recovering = "Recovering worker position",
    calibrating = "Calibrating map boundary",
    parked = "Parked at dock",
    aborted = "Job aborted",
    error = "Stopped with an error",
    dock_conflict = "Dock assignment conflict",
    working = "Working",
    update_pending = "Update queued",
    updating = "Installing update",
    update_failed = "Update failed",
    preflight = "Running preflight checks",
    relocation_ready = "Ready to relocate",
    recovery_required = "Recovery required",
    position_unknown = "Position unknown - do not move",
    tool_missing = "Mining tool missing",
    modem_missing = "Wireless modem missing",
    incompatible = "Incompatible controller protocol",
}

local function trimLine(value, width)
    value = tostring(value or "")
    if #value <= width then return value end
    if width <= 3 then return value:sub(1, width) end
    return value:sub(1, width - 3) .. "..."
end

local function storageSummary()
    local usedSlots = 0
    local itemCount = 0
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        local count = turtle.getItemCount(slot)
        if count > 0 then usedSlots = usedSlots + 1 end
        itemCount = itemCount + count
    end
    return usedSlots, itemCount
end

local function renderWorkerScreen(force)
    local now = os.epoch("utc")
    if not force and now - lastUiRender < 500 then return end
    lastUiRender = now

    local width, height = term.getSize()
    local line = 1

    local function writeLine(value, color)
        if line > height then return end
        term.setCursorPos(1, line)
        term.clearLine()
        if term.isColor and term.isColor() and color then term.setTextColor(color) end
        write(trimLine(value, width))
        if term.isColor and term.isColor() then term.setTextColor(colors.white) end
        line = line + 1
    end

    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()

    writeLine("Roomba Hive Worker v" .. VERSION, colors.yellow)

    local dockName = dock and (dockDisplay[dock] or dock) or "unassigned"
    writeLine("ID " .. os.getComputerID() .. " | Dock: " .. dockName)

    local controllerText = controller and ("#" .. tostring(controller)) or "searching"
    writeLine("Controller: " .. controllerText .. " | Modem: " .. modemSide)
    writeLine("Protocol: " .. PROTOCOL_VERSION .. " | Position: " .. tostring(state.positionConfidence))
    if state.pendingUpdate then
        writeLine("Update queued: v" .. tostring(state.pendingUpdate.version), colors.cyan)
    end

    local statusText = STATUS_LABELS[state.status] or tostring(state.status or "unknown")
    local statusColor = state.status == "error" and colors.red
        or state.status == "fuel_station_empty" and colors.red
        or state.status == "blocked_waiting" and colors.orange
        or state.status == "paused" and colors.yellow
        or colors.lime
    writeLine("Status: " .. statusText, statusColor)
    writeLine("Action: " .. tostring(uiMessage or statusText))

    if state.jobId or state.firstLayer or state.layer then
        local range = "-"
        if state.firstLayer and state.lastLayer then
            range = tostring(state.firstLayer) .. "-" .. tostring(state.lastLayer)
        end
        writeLine("Job: " .. tostring(state.jobId or "-") .. " | Range: " .. range)
        writeLine("Layer: " .. tostring(state.layer or "-"))
    else
        writeLine("Job: none")
    end

    if state.progress and state.total and state.total > 0 then
        local percent = math.floor((state.progress / state.total) * 100)
        writeLine("Progress: " .. state.progress .. "/" .. state.total .. " (" .. percent .. "%)")
    else
        writeLine("Progress: -")
    end

    local fuel = turtle.getFuelLevel()
    writeLine("Fuel: " .. tostring(fuel) .. " | Slot 1: " .. turtle.getItemCount(FUEL_SLOT))

    local usedSlots, storedItems = storageSummary()
    writeLine("Storage: " .. usedSlots .. "/15 slots | " .. storedItems .. " items")

    writeLine("Pos: " .. pos.x .. "," .. pos.y .. "," .. pos.z .. " " .. (dirNames[pos.dir] or "?"))

    if state.error then
        writeLine("Problem: " .. tostring(state.error), colors.red)
    elseif line <= height then
        writeLine("Ready for controller commands.")
    end
end

local function setActivity(message)
    uiMessage = tostring(message or "")
    renderWorkerScreen(true)
end

local function persist(force)
    state.version = VERSION
    state.protocolVersion = PROTOCOL_VERSION
    state.controller = controller
    state.dock = dock
    state.pos = pos
    if force or movesSinceSave >= POSITION_SAVE_INTERVAL then
        saveTable(STATE_FILE, state)
        movesSinceSave = 0
    end
end

local function setStatus(status, activity)
    state.status = status
    uiMessage = activity or STATUS_LABELS[status] or tostring(status)
    persist(true)
    renderWorkerScreen(true)
end

local function restoreComputerLabel()
    if dock and dockInfo[dock] then
        os.setComputerLabel("Roomba " .. (dockDisplay[dock] or dock) .. " #" .. tostring(os.getComputerID()))
    elseif not os.getComputerLabel() then
        os.setComputerLabel("Roomba Worker (unassigned)")
    end
end
restoreComputerLabel()

local function send(kind, data)
    if not controller then return false end
    data = data or {}
    data.type = kind
    data.version = VERSION
    data.protocolVersion = PROTOCOL_VERSION
    data.positionConfidence = state.positionConfidence
    if data.dock == nil then data.dock = dock end
    return rednet.send(controller, data, PROTOCOL)
end


local function isPhysicallyDocked()
    local info = dock and dockInfo[dock] or nil
    return info ~= nil
        and pos.y == 0
        and pos.x == info.x
        and pos.z == info.z
end

local function normalizeUpdateRequest(message)
    if type(message) ~= "table" then return nil end
    local targetVersion = tostring(message.version or "")
    local cacheTag = tostring(message.cacheTag or "")
    if targetVersion == "" or cacheTag == "" then return nil end
    return {
        version = targetVersion,
        cacheTag = cacheTag,
        requestedAt = os.epoch("utc"),
    }
end

local function updateUrl(remote, cacheTag)
    local separator = UPDATE_BASE_URL:find("?", 1, true) and "&" or "?"
    return UPDATE_BASE_URL .. "/" .. remote
        .. separator .. "v=" .. tostring(cacheTag)
        .. "&worker=" .. tostring(os.getComputerID())
        .. "&t=" .. tostring(os.epoch("utc"))
end

local function cleanUpdateTemps()
    local paths = {
        "/roomba/worker.lua.update",
        "/roomba/boot.lua.update",
        "/startup.lua.update",
        "/roomba.lua.update",
    }
    for _, path in ipairs(paths) do
        if fs.exists(path) then fs.delete(path) end
    end
end

local function applyPendingUpdate()
    local request = state.pendingUpdate
    if type(request) ~= "table" then return false end
    if taskActive or not isPhysicallyDocked() or fuelLockHeld then return false end

    if request.version == VERSION and not request.force then
        state.pendingUpdate = nil
        state.error = nil
        persist(true)
        send("update_current", { targetVersion = request.version })
        return false
    end

    if not http then
        state.status = "update_failed"
        state.error = "HTTP is disabled; worker update could not download."
        uiMessage = state.error
        persist(true)
        renderWorkerScreen(true)
        send("update_failed", { targetVersion = request.version, message = state.error })
        return false
    end

    setStatus("updating", "Downloading Roomba Hive v" .. tostring(request.version))
    send("update_accepted", { targetVersion = request.version })

    local files = {
        { remote = "roomba_worker.lua", localPath = "/roomba/worker.lua" },
        { remote = "roomba_boot.lua", localPath = "/roomba/boot.lua" },
        { remote = "startup_worker.lua", localPath = "/startup.lua" },
        { remote = "roomba.lua", localPath = "/roomba.lua" },
    }

    cleanUpdateTemps()
    for _, entry in ipairs(files) do
        uiMessage = "Downloading " .. entry.remote
        renderWorkerScreen(true)

        local response, requestError = http.get(updateUrl(entry.remote, request.cacheTag))
        if not response then
            cleanUpdateTemps()
            state.status = "update_failed"
            state.error = "Download failed for " .. entry.remote .. ": " .. tostring(requestError)
            uiMessage = state.error
            persist(true)
            renderWorkerScreen(true)
            send("update_failed", { targetVersion = request.version, message = state.error })
            return false
        end

        local body = response.readAll()
        response.close()
        if not body or body == "" then
            cleanUpdateTemps()
            state.status = "update_failed"
            state.error = "Downloaded an empty file: " .. entry.remote
            uiMessage = state.error
            persist(true)
            renderWorkerScreen(true)
            send("update_failed", { targetVersion = request.version, message = state.error })
            return false
        end

        local compiled, syntaxError = load(body, "@" .. entry.localPath, "t", _ENV)
        if not compiled then
            cleanUpdateTemps()
            state.status = "update_failed"
            state.error = "Syntax error in " .. entry.remote .. ": " .. tostring(syntaxError)
            uiMessage = state.error
            persist(true)
            renderWorkerScreen(true)
            send("update_failed", { targetVersion = request.version, message = state.error })
            return false
        end

        local handle, openError = fs.open(entry.localPath .. ".update", "w")
        if not handle then
            cleanUpdateTemps()
            state.status = "update_failed"
            state.error = "Cannot write update file: " .. tostring(openError)
            uiMessage = state.error
            persist(true)
            renderWorkerScreen(true)
            send("update_failed", { targetVersion = request.version, message = state.error })
            return false
        end
        handle.write(body)
        handle.close()
    end

    local manifestFiles = {}
    for _, entry in ipairs(files) do manifestFiles[#manifestFiles + 1] = entry.localPath end
    saveTable(fs.combine(ROOT, "update_manifest.db"), {
        role = "worker",
        targetVersion = request.version,
        files = manifestFiles,
        attempts = 0,
        installedAt = os.epoch("utc"),
    })

    local committed = {}
    local ok, commitError = pcall(function()
        for _, entry in ipairs(files) do
            local backup = entry.localPath .. ".old"
            if fs.exists(backup) then fs.delete(backup) end
            if fs.exists(entry.localPath) then fs.move(entry.localPath, backup) end
            fs.move(entry.localPath .. ".update", entry.localPath)
            committed[#committed + 1] = entry
        end
    end)

    if not ok then
        for _, entry in ipairs(files) do
            local backup = entry.localPath .. ".old"
            if fs.exists(backup) then
                if fs.exists(entry.localPath) then fs.delete(entry.localPath) end
                fs.move(backup, entry.localPath)
            end
        end
        cleanUpdateTemps()
        local manifest = fs.combine(ROOT, "update_manifest.db")
        if fs.exists(manifest) then fs.delete(manifest) end
        state.status = "update_failed"
        state.error = "Could not install update: " .. tostring(commitError)
        uiMessage = state.error
        persist(true)
        renderWorkerScreen(true)
        send("update_failed", { targetVersion = request.version, message = state.error })
        return false
    end

    state.pendingUpdate = nil
    state.error = nil
    state.status = "updating"
    state.installedVersion = request.version
    uiMessage = "Update installed; rebooting"
    persist(true)
    renderWorkerScreen(true)
    send("update_installed", { targetVersion = request.version })
    sleep(1)
    os.reboot()
    return true
end

local function queueUpdateRequest(message)
    local request = normalizeUpdateRequest(message)
    if not request then
        send("update_failed", { message = "Controller sent an invalid update request." })
        return
    end

    if request.version == VERSION and not message.force then
        state.pendingUpdate = nil
        persist(true)
        send("update_current", { targetVersion = request.version })
        return
    end

    request.force = message.force == true
    state.pendingUpdate = request
    persist(true)

    if taskActive or not isPhysicallyDocked() or fuelLockHeld then
        send("update_deferred", {
            targetVersion = request.version,
            reason = taskActive and "worker busy"
                or (not isPhysicallyDocked() and "worker not docked")
                or "fuel station in use",
        })
        return
    end

    applyPendingUpdate()
end

local function releaseFuelLock()
    if fuelLockHeld then
        send("fuel_lock_release", {})
        fuelLockHeld = false
        fuelLockGranted = false
    end
end

local function reportError(message, extra)
    releaseFuelLock()
    state.status = "error"
    state.error = message
    local payload = extra or {}
    payload.message = message
    payload.position = { x = pos.x, y = pos.y, z = pos.z, dir = dirNames[pos.dir] }
    uiMessage = message
    persist(true)
    renderWorkerScreen(true)
    send("worker_error", payload)
    error(message, 0)
end

local function fuelLevel()
    return turtle.getFuelLevel()
end

local function isUnlimitedFuel()
    return fuelLevel() == "unlimited"
end

local collectionSlot = FIRST_STORAGE_SLOT

local function findEmptyStorageSlot()
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
    return nil
end

-- Keep one storage slot selected and let CC:Tweaked's normal collection logic
-- stack compatible drops. We only switch slots when the current collection
-- slot is full, avoiding an inventory scan and transfer after every block.
local function selectCollectionSlot()
    if collectionSlot < FIRST_STORAGE_SLOT or collectionSlot > LAST_STORAGE_SLOT then
        collectionSlot = FIRST_STORAGE_SLOT
    end

    if turtle.getItemSpace(collectionSlot) <= 0 then
        local empty = findEmptyStorageSlot()
        if not empty then return nil end
        collectionSlot = empty
    end

    if turtle.getSelectedSlot() ~= collectionSlot then turtle.select(collectionSlot) end
    return collectionSlot
end

local function countEmptyStorageSlots()
    local count = 0
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        if turtle.getItemCount(slot) == 0 then count = count + 1 end
    end
    return count
end

local function validateFuelSlot()
    turtle.select(FUEL_SLOT)
    local count = turtle.getItemCount(FUEL_SLOT)
    if count == 0 then return true end
    if turtle.refuel(0) then return true end

    local destination = findEmptyStorageSlot()
    if not destination then
        reportError("Slot 1 contains a non-fuel item and storage slots 2-16 are occupied.")
    end
    if not turtle.transferTo(destination) then
        reportError("Could not move the non-fuel item out of slot 1.")
    end
    turtle.select(FUEL_SLOT)
    return false
end

local function fuelItemsLow()
    if isUnlimitedFuel() then return false end
    validateFuelSlot()
    return turtle.getItemCount(FUEL_SLOT) <= FUEL_ITEM_RESERVE
end

local function refuelFromSlot(target)
    if isUnlimitedFuel() then return true end
    validateFuelSlot()
    turtle.select(FUEL_SLOT)
    while fuelLevel() < target and turtle.getItemCount(FUEL_SLOT) > FUEL_ITEM_RESERVE do
        if not turtle.refuel(1) then return false end
    end
    return fuelLevel() >= target
end

local function ensureFuel(amount)
    if isUnlimitedFuel() then return end
    if fuelLevel() < amount then
        refuelFromSlot(math.max(amount, FUEL_TARGET))
    end
    if fuelLevel() < amount then
        reportError("Insufficient fuel to move.", { fuel = fuelLevel(), required = amount })
    end
end

local function ensureEmergencyFuel(amount)
    if isUnlimitedFuel() then return end
    validateFuelSlot()
    turtle.select(FUEL_SLOT)
    while fuelLevel() < amount and turtle.getItemCount(FUEL_SLOT) > 1 do
        if not turtle.refuel(1) then break end
    end
    if fuelLevel() < amount then
        reportError("Insufficient emergency fuel to leave the fuel station.")
    end
end

local function markMoved()
    movesSinceSave = movesSinceSave + 1
    persist(false)
end

local function turnLeft()
    turtle.turnLeft()
    pos.dir = (pos.dir + 3) % 4
end

local function turnRight()
    turtle.turnRight()
    pos.dir = (pos.dir + 1) % 4
end

local function turnAround()
    turnRight()
    turnRight()
end

local function turnTo(direction)
    local difference = (direction - pos.dir) % 4
    if difference == 1 then turnRight()
    elseif difference == 2 then turnAround()
    elseif difference == 3 then turnLeft()
    end
end

local function markMovementUnsafe()
    if state.positionConfidence ~= "unknown" or state.recoveryAnchor ~= nil then
        state.positionConfidence = "unknown"
        state.recoveryAnchor = nil
        persist(true)
    end
end

local function advancePosition()
    local direction = vec[pos.dir]
    pos.x = pos.x + direction.x
    pos.z = pos.z + direction.z
    markMoved()
end

local function isComputerCraftBlock(data)
    local name = data and data.name or ""
    return name:find("computercraft") ~= nil
end

local function isLavaBlock(data)
    local name = tostring(data and data.name or ""):lower()
    return name:find("lava", 1, true) ~= nil
end

local function isWaterBlock(data)
    local name = tostring(data and data.name or ""):lower()
    return name:find("water", 1, true) ~= nil
end

local function protectedBlock(data)
    local name = data and data.name or ""
    return name:find("computercraft")
        or name:find("chest")
        or name:find("barrel")
        or name:find("shulker")
end

local function waitForComputerCraftObstruction(inspectFunction, description, resumeStatus)
    local previousStatus = resumeStatus or state.status or "working"
    local occupied, data = inspectFunction()
    if not occupied or not isComputerCraftBlock(data) then return false end

    state.status = "blocked_waiting"
    state.error = "Blocked " .. description .. " by " .. tostring(data and data.name)
    uiMessage = "Remove the ComputerCraft block to continue automatically"
    persist(true)
    renderWorkerScreen(true)
    send("worker_blocked", {
        message = state.error,
        position = { x = pos.x, y = pos.y, z = pos.z, dir = dirNames[pos.dir] },
    })

    while true do
        if abortRequested then error(ABORT_SIGNAL, 0) end
        occupied, data = inspectFunction()
        if not occupied then break end
        if not isComputerCraftBlock(data) then
            reportError("Recoverable obstruction was replaced by " .. tostring(data and data.name))
        end
        renderWorkerScreen(false)
        sleep(1)
    end

    state.error = nil
    setStatus(previousStatus)
    return true
end

local function entityBlockedForward()
    sleep(5)
    if turtle.forward() then advancePosition(); return true end
    local occupied = turtle.inspect()
    if occupied then return false, "block appeared during entity wait" end
    turtle.attack()
    sleep(MOVE_RETRY_DELAY)
    if turtle.forward() then advancePosition(); return true end
    reportError("Entity remained in the path after waiting 5 seconds and attacking once.")
end

local function forwardOpen()
    ensureFuel(1)
    markMovementUnsafe()
    local occupied, data = turtle.inspect()
    if occupied and isLavaBlock(data) then
        reportError("Lava detected in a known-open route. Worker stopped before entering it.", { block = data.name })
    end
    if occupied and isComputerCraftBlock(data) then
        waitForComputerCraftObstruction(turtle.inspect, "in front", state.status)
        return forwardOpen()
    end
    if occupied and not isWaterBlock(data) then
        return false, "blocked by " .. tostring(data and data.name)
    end
    if turtle.forward() then advancePosition(); return true end
    return entityBlockedForward()
end

local function forwardMine()
    ensureFuel(1)
    markMovementUnsafe()
    local direction = vec[pos.dir]
    local nextX, nextZ = pos.x + direction.x, pos.z + direction.z
    if not interior[key(nextX, nextZ)] then return false, "map boundary", false end

    for _ = 1, MAX_FALLING_DIGS do
        local occupied, data = turtle.inspect()
        if occupied and isLavaBlock(data) then
            reportError("Lava detected in the mining route. Worker stopped before entering it.", { block = data.name })
        end

        if not occupied or isWaterBlock(data) then
            if turtle.forward() then
                advancePosition()
                carved[key(pos.x, pos.z)] = true
                return true, nil, false
            end
            local moved, reason = entityBlockedForward()
            if moved then carved[key(pos.x, pos.z)] = true end
            return moved, reason or "entity obstruction", false
        end

        if protectedBlock(data) or (peripheral.hasType and peripheral.hasType("front", "inventory")) then
            reportError("Protected block or inventory in mining route: " .. tostring(data and data.name))
        end
        if not selectCollectionSlot() then return false, "storage full", false end
        local dug, reason = turtle.dig()
        if not dug then reportError("Unable to dig block: " .. tostring(reason), { block = data and data.name }) end
        if turtle.forward() then
            advancePosition()
            carved[key(pos.x, pos.z)] = true
            return true, nil, true
        end
        sleep(MOVE_RETRY_DELAY)
    end
    reportError("Too many falling blocks prevented movement.")
end

local function upOpen()
    ensureFuel(1)
    markMovementUnsafe()
    local occupied, data = turtle.inspectUp()
    if occupied and isLavaBlock(data) then
        reportError("Lava detected above the worker. Worker stopped before entering it.", { block = data.name })
    end
    if occupied and isComputerCraftBlock(data) then
        waitForComputerCraftObstruction(turtle.inspectUp, "above", state.status)
        return upOpen()
    end
    if occupied and not isWaterBlock(data) then
        reportError("Vertical shaft blocked above by " .. tostring(data and data.name))
    end
    if turtle.up() then pos.y = pos.y + 1; markMoved(); return end
    sleep(5)
    if turtle.up() then pos.y = pos.y + 1; markMoved(); return end
    turtle.attackUp()
    sleep(MOVE_RETRY_DELAY)
    if turtle.up() then pos.y = pos.y + 1; markMoved(); return end
    reportError("Cannot ascend after waiting and attacking once.")
end

local function downOpen()
    ensureFuel(1)
    markMovementUnsafe()
    local occupied, data = turtle.inspectDown()
    if occupied and isLavaBlock(data) then
        reportError("Lava detected below the worker. Worker stopped before entering it.", { block = data.name })
    end
    if occupied and isComputerCraftBlock(data) then
        waitForComputerCraftObstruction(turtle.inspectDown, "below", state.status)
        return downOpen()
    end
    if occupied and not isWaterBlock(data) then
        reportError("Expected-open route blocked below by " .. tostring(data and data.name))
    end
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    sleep(5)
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    turtle.attackDown()
    sleep(MOVE_RETRY_DELAY)
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    reportError("Entity remained below after waiting and attacking once.")
end

local function downDig()
    ensureFuel(1)
    markMovementUnsafe()
    local occupied, data = turtle.inspectDown()
    if occupied and isLavaBlock(data) then
        reportError("Lava detected below the mining shaft. Worker stopped before descending.", { block = data.name })
    end
    if occupied and isComputerCraftBlock(data) then
        waitForComputerCraftObstruction(turtle.inspectDown, "below the shaft", state.status)
        return downDig()
    end

    if not occupied or isWaterBlock(data) then
        if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
        sleep(5)
        if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
        turtle.attackDown()
        sleep(MOVE_RETRY_DELAY)
        if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
        reportError("Cannot descend the shaft after waiting and attacking once.")
    end

    if protectedBlock(data) or (peripheral.hasType and peripheral.hasType("bottom", "inventory")) then
        reportError("Protected block below the shaft.")
    end
    if not selectCollectionSlot() then reportError("Storage slots 2-16 are occupied before shaft digging.") end
    local dug, reason = turtle.digDown()
    if not dug then reportError("Cannot dig shaft downward: " .. tostring(reason)) end
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    reportError("Cannot descend the shaft after digging.")
end

local function findPath(startX, startZ, goalX, goalZ, allowed)
    if startX == goalX and startZ == goalZ then return {} end
    local startKey, goalKey = key(startX, startZ), key(goalX, goalZ)
    if not allowed[startKey] or not allowed[goalKey] then return nil, "endpoint not allowed" end

    local queue = { { x = startX, z = startZ } }
    local head = 1
    local seen = { [startKey] = true }
    local cameFrom = {}

    while head <= #queue do
        local current = queue[head]
        head = head + 1
        for _, neighbor in ipairs(neighbors) do
            local x, z = current.x + neighbor.dx, current.z + neighbor.dz
            local cellKey = key(x, z)
            if allowed[cellKey] and not seen[cellKey] then
                seen[cellKey] = true
                cameFrom[cellKey] = { parent = key(current.x, current.z), direction = neighbor.dir }
                if cellKey == goalKey then
                    local reverse = {}
                    local cursor = cellKey
                    while cursor ~= startKey do
                        reverse[#reverse + 1] = cameFrom[cursor].direction
                        cursor = cameFrom[cursor].parent
                    end
                    local path = {}
                    for index = #reverse, 1, -1 do path[#path + 1] = reverse[index] end
                    return path
                end
                queue[#queue + 1] = { x = x, z = z }
            end
        end
    end
    return nil, "no path"
end

local function followOpen(path)
    for _, direction in ipairs(path) do
        turnTo(direction)
        local moved, reason = forwardOpen()
        if not moved then reportError("Known-open path blocked: " .. tostring(reason)) end
    end
end

local function countCells(cells)
    local count = 0
    for _ in pairs(cells) do count = count + 1 end
    return count
end

local function inspectWall(relativeDirection)
    local original = pos.dir
    if relativeDirection == -1 then turnLeft()
    elseif relativeDirection == 1 then turnRight()
    end
    local occupied, data = turtle.inspect()
    if occupied then
        local direction = vec[pos.dir]
        wall[key(pos.x + direction.x, pos.z + direction.z)] = true
    end
    turnTo(original)
    return occupied, data
end

local function driveToNorthWall()
    turnTo(NORTH)
    while true do
        if inspectWall(0) then return end
        local moved, reason = forwardOpen()
        if not moved then reportError("Calibration could not reach north wall: " .. tostring(reason)) end
    end
end

local function tracePerimeter()
    turnRight()
    local startX, startZ, startDirection = pos.x, pos.z, pos.dir
    local moves, iterations = 0, 0
    while true do
        iterations = iterations + 1
        if iterations > MAX_CALIBRATION_STEPS * 4 then reportError("Calibration loop exceeded safety limit.") end
        local leftBlocked = inspectWall(-1)
        if not leftBlocked then
            turnLeft()
            local moved, reason = forwardOpen()
            if not moved then reportError("Calibration outline changed: " .. tostring(reason)) end
            moves = moves + 1
        elseif not inspectWall(0) then
            local moved, reason = forwardOpen()
            if not moved then reportError("Calibration outline changed: " .. tostring(reason)) end
            moves = moves + 1
        else
            turnRight()
        end
        if moves > MAX_CALIBRATION_STEPS then reportError("Perimeter is too large.") end
        if moves > 0 and pos.x == startX and pos.z == startZ and pos.dir == startDirection then return end
    end
end

local function buildInterior()
    local minX, maxX, minZ, maxZ = 0, 0, 0, 0
    for cellKey in pairs(wall) do
        local x, z = parseKey(cellKey)
        minX, maxX = math.min(minX, x), math.max(maxX, x)
        minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
    end

    local floodMinX, floodMaxX = minX - 1, maxX + 1
    local floodMinZ, floodMaxZ = minZ - 1, maxZ + 1
    interior = { [key(0, 0)] = true }
    local queue = { { x = 0, z = 0 } }
    local head = 1
    local escaped = false
    bounds = { minX = 0, maxX = 0, minZ = 0, maxZ = 0 }

    while head <= #queue do
        local current = queue[head]
        head = head + 1
        if current.x == floodMinX or current.x == floodMaxX or current.z == floodMinZ or current.z == floodMaxZ then
            escaped = true
        end
        bounds.minX, bounds.maxX = math.min(bounds.minX, current.x), math.max(bounds.maxX, current.x)
        bounds.minZ, bounds.maxZ = math.min(bounds.minZ, current.z), math.max(bounds.maxZ, current.z)
        for _, neighbor in ipairs(neighbors) do
            local x, z = current.x + neighbor.dx, current.z + neighbor.dz
            local cellKey = key(x, z)
            if x >= floodMinX and x <= floodMaxX and z >= floodMinZ and z <= floodMaxZ
                and not wall[cellKey] and not interior[cellKey] then
                interior[cellKey] = true
                queue[#queue + 1] = { x = x, z = z }
            end
        end
    end
    if escaped then reportError("Calibration flood-fill escaped the outline.") end
end

local function enterCenterFromDockAtCurrentY()
    local info = dockInfo[dock]
    turnTo(info.inward)
    local moved, reason = forwardOpen()
    if not moved then reportError("Cannot enter center from shaft: " .. tostring(reason)) end
end

local function leaveCenterToShaft()
    local info = dockInfo[dock]
    turnTo(info.out)
    local moved, reason = forwardOpen()
    if not moved then reportError("Cannot return to dock shaft: " .. tostring(reason)) end
end

local function ascendDock()
    local info = dockInfo[dock]
    if pos.x ~= info.x or pos.z ~= info.z then reportError("Not at assigned shaft before ascent.") end
    while pos.y < 0 do upOpen() end
    turnTo(info.out)
    state.recoveryAnchor = "dock"
    state.positionConfidence = "confirmed"
    persist(true)
end

local function descendDock(layer)
    local info = dockInfo[dock]
    if pos.x ~= info.x or pos.z ~= info.z or pos.y ~= 0 then reportError("Not at dock before descent.") end
    state.positionConfidence = "unknown"
    state.recoveryAnchor = nil
    persist(true)
    while pos.y > -layer do downDig() end
end

local function returnToDockFromCenter()
    leaveCenterToShaft()
    ascendDock()
end

local function goCenterForLayer(layer)
    descendDock(layer)
    enterCenterFromDockAtCurrentY()
    turnTo(NORTH)
    state.recoveryAnchor = "center"
    persist(true)
end

local function dumpUp(allowIncomplete)
    local allUnloaded = true
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        while turtle.getItemCount(slot) > 0 do
            turtle.select(slot)
            local before = turtle.getItemCount(slot)
            turtle.dropUp()
            if turtle.getItemCount(slot) >= before then
                allUnloaded = false
                state.status = "output_full"
                persist(true)
                if abortRequested or allowIncomplete then
                    turtle.select(FUEL_SLOT)
                    return false
                end
                sleep(1)
            else
                state.status = "working"
            end
        end
    end
    collectionSlot = FIRST_STORAGE_SLOT
    turtle.select(collectionSlot)
    return allUnloaded
end

local function applyTaskMessage(message)
    if type(message) ~= "table" then return end
    if message.type == "pause" then
        paused = true
    elseif message.type == "resume" then
        paused = false
    elseif message.type == "abort" then
        parkRequested = false
        abortRequested = true
        paused = false
    elseif message.type == "return_to_dock" then
        parkRequested = true
        abortRequested = true
        paused = false
    elseif message.type == "fuel_lock_granted" then
        fuelLockGranted = true
    elseif message.type == "fuel_lock_wait" then
        fuelLockGranted = false
    elseif message.type == "update_request" then
        queueUpdateRequest(message)
    elseif message.type == "recover_checkpoint" then
        abortRequested = true
        parkRequested = true
        paused = false
    end
end

local function taskHeartbeat()
    renderWorkerScreen(false)
    local usedStorageSlots, storedItems = storageSummary()
    send("heartbeat", {
        status = state.status,
        layer = state.layer,
        fuel = fuelLevel(),
        position = pos,
        progress = state.progress,
        total = state.total,
        firstLayer = state.firstLayer,
        lastLayer = state.lastLayer,
        checkpoint = state.checkpoint,
        recoveryAnchor = state.recoveryAnchor,
        fuelItems = turtle.getItemCount(FUEL_SLOT),
        emptyStorageSlots = countEmptyStorageSlots(),
        usedStorageSlots = usedStorageSlots,
        storedItems = storedItems,
    })
    persist(false)
end

local function safePoint(resumeStatus)
    if abortRequested then error(ABORT_SIGNAL, 0) end
    if paused then
        setStatus("paused")
        while paused do
            if abortRequested then error(ABORT_SIGNAL, 0) end
            sleep(0.2)
        end
        setStatus(resumeStatus or "working")
    end
    if abortRequested then error(ABORT_SIGNAL, 0) end
end

local function requestFuelLock()
    fuelLockGranted = false
    setStatus("waiting_fuel_lock", "Waiting for another turtle to leave the fuel station")
    local lastRequest = 0
    while not fuelLockGranted do
        if abortRequested then return false end
        local now = os.epoch("utc")
        if now - lastRequest >= 2000 then
            send("fuel_lock_request", {})
            lastRequest = now
        end
        sleep(0.1)
    end
    fuelLockHeld = true
    return true
end

local function returnFromFuelStation(info)
    -- The worker never mines on this route, so it is safe to consume reserve
    -- items if necessary to guarantee enough movement fuel to get home.
    ensureEmergencyFuel(5)
    turnAround()
    local moved, reason = forwardOpen()
    if not moved then releaseFuelLock(); reportError("Cannot leave fuel chest: " .. tostring(reason)) end
    downOpen(); downOpen(); downOpen()
    turnAround()
    moved, reason = forwardOpen()
    if not moved then releaseFuelLock(); reportError("Cannot return to dock from fuel route: " .. tostring(reason)) end
    turnTo(info.out)
    releaseFuelLock()
    state.positionConfidence = "confirmed"
    state.recoveryAnchor = "dock"
    persist(true)
end

local function stopForEmptyFuelStation(info)
    returnFromFuelStation(info)
    state.error = "Restock the shared fuel station, then restart this worker's remaining work."
    setStatus("fuel_station_empty", "RESTOCK FUEL STATION")
    send("fuel_station_empty", {
        message = state.error,
        fuel = fuelLevel(),
        fuelItems = turtle.getItemCount(FUEL_SLOT),
        position = pos,
    })
    error(FUEL_STATION_EMPTY_SIGNAL, 0)
end

local function refuelAtStation(required)
    if isUnlimitedFuel() then return true end
    local info = dockInfo[dock]
    if pos.x ~= info.x or pos.z ~= info.z or pos.y ~= 0 then
        reportError("Refuel requested while worker was not docked.")
    end
    if not requestFuelLock() then return false end

    -- Reserve enough movement fuel for the full trip to the station and back,
    -- even when the station turns out to be empty.
    ensureEmergencyFuel(10)
    setStatus("refueling", "Taking fuel from the shared fuel chest")
    turnTo(info.out)
    local moved, reason = forwardOpen()
    if not moved then releaseFuelLock(); reportError("Fuel route outward blocked: " .. tostring(reason)) end
    upOpen(); upOpen(); upOpen()
    turnAround()
    moved, reason = forwardOpen()
    if not moved then releaseFuelLock(); reportError("Fuel chest approach blocked: " .. tostring(reason)) end

    validateFuelSlot()
    turtle.select(FUEL_SLOT)
    local target = math.max(required or 0, FUEL_TARGET)

    while not abortRequested do
        while fuelLevel() < target and turtle.getItemCount(FUEL_SLOT) > FUEL_ITEM_RESERVE do
            if not turtle.refuel(1) then
                releaseFuelLock()
                reportError("Slot 1 contains an invalid fuel item.")
            end
        end

        if fuelLevel() >= target and turtle.getItemCount(FUEL_SLOT) > FUEL_ITEM_RESERVE then
            break
        end

        -- Pull the next fuel stack into an empty mining-storage slot first.
        -- This allows the station to switch between coal, charcoal, or another
        -- valid fuel without putting that new stack into an unrelated slot.
        local bufferSlot = findEmptyStorageSlot()
        if not bufferSlot then
            releaseFuelLock()
            reportError("No empty storage slot was available to receive fuel from the station.")
        end
        turtle.select(bufferSlot)
        if not turtle.suck(64) then stopForEmptyFuelStation(info) end
        if not turtle.refuel(0) then
            turtle.drop()
            releaseFuelLock()
            reportError("Fuel chest supplied a non-fuel item. Fuel chest must contain fuel only.")
        end

        -- Fuel was successfully found. Consume the old five-item reserve to
        -- free slot 1, then move the fresh fuel stack into the protected slot.
        turtle.select(FUEL_SLOT)
        while turtle.getItemCount(FUEL_SLOT) > 0 do
            if not turtle.refuel(1) then
                releaseFuelLock()
                reportError("Slot 1 contains an invalid fuel item.")
            end
        end
        turtle.select(bufferSlot)
        if not turtle.transferTo(FUEL_SLOT) then
            releaseFuelLock()
            reportError("Could not move station fuel into protected slot 1.")
        end
        turtle.select(FUEL_SLOT)
        setStatus("refueling", "Taking fuel from the shared fuel chest")
    end

    returnFromFuelStation(info)
    state.error = nil
    setStatus("docked", "Docked, refueled, and ready")
    return not abortRequested
end

local function buildTargets()
    local rows = {}
    for cellKey in pairs(interior) do
        local x, z = parseKey(cellKey)
        rows[z] = rows[z] or {}
        rows[z][#rows[z] + 1] = x
    end
    local zValues = {}
    for z in pairs(rows) do zValues[#zValues + 1] = z end
    table.sort(zValues)

    local targets = {}
    local leftToRight = true
    for _, z in ipairs(zValues) do
        local xValues = rows[z]
        table.sort(xValues)
        if leftToRight then
            for _, x in ipairs(xValues) do targets[#targets + 1] = { x = x, z = z } end
        else
            for index = #xValues, 1, -1 do targets[#targets + 1] = { x = xValues[index], z = z } end
        end
        leftToRight = not leftToRight
    end
    return targets
end

local function directionBetween(x1, z1, x2, z2)
    if x2 == x1 and z2 == z1 - 1 then return NORTH end
    if x2 == x1 + 1 and z2 == z1 then return EAST end
    if x2 == x1 and z2 == z1 + 1 then return SOUTH end
    if x2 == x1 - 1 and z2 == z1 then return WEST end
    return nil
end

local function buildRoute()
    local route = {}
    local virtualX, virtualZ = 0, 0
    local moves = 0
    local function add(direction)
        local last = route[#route]
        if last and last.direction == direction then last.count = last.count + 1
        else route[#route + 1] = { direction = direction, count = 1 }
        end
        moves = moves + 1
    end

    for _, target in ipairs(buildTargets()) do
        if virtualX ~= target.x or virtualZ ~= target.z then
            local direction = directionBetween(virtualX, virtualZ, target.x, target.z)
            if direction then
                add(direction)
            else
                local path, err = findPath(virtualX, virtualZ, target.x, target.z, interior)
                if not path then reportError("Cannot build mining route: " .. tostring(err)) end
                for _, pathDirection in ipairs(path) do add(pathDirection) end
            end
            virtualX, virtualZ = target.x, target.z
        end
    end
    return route, moves
end

local function routeCenter()
    if pos.x == 0 and pos.z == 0 then
        state.positionConfidence = "recoverable"
        state.recoveryAnchor = "center"
        persist(true)
        return
    end
    carved[key(pos.x, pos.z)] = true
    carved[key(0, 0)] = true
    local path, err = findPath(pos.x, pos.z, 0, 0, carved)
    if not path then reportError("No carved return path: " .. tostring(err)) end
    followOpen(path)
    state.positionConfidence = "recoverable"
    state.recoveryAnchor = "center"
    persist(true)
end

local function reserveForDock(layer)
    local path = findPath(pos.x, pos.z, 0, 0, carved)
    local horizontal = path and #path or 0
    return horizontal + 1 + layer + 10 + FUEL_MARGIN
end

local function unloadAndReturnToCheckpoint(layer, checkpointX, checkpointZ)
    routeCenter()
    returnToDockFromCenter()
    dumpUp()
    safePoint("returning")

    if not isUnlimitedFuel() and (fuelLevel() < FUEL_TARGET / 2 or fuelItemsLow()) then
        refuelAtStation(layer * 2 + FUEL_MARGIN)
    end
    safePoint("returning")

    goCenterForLayer(layer)
    carved[key(0, 0)] = true
    if checkpointX ~= 0 or checkpointZ ~= 0 then
        local path, err = findPath(0, 0, checkpointX, checkpointZ, carved)
        if not path then reportError("Cannot return to mining checkpoint: " .. tostring(err)) end
        followOpen(path)
    end
end

local function excavateLayer(layer, route, totalMoves)
    state.layer = layer
    state.progress = 0
    state.total = totalMoves
    state.checkpoint = { layer = layer, progress = 0, status = "mining", position = { x = pos.x, y = pos.y, z = pos.z, dir = pos.dir } }
    setStatus("mining", "Mining layer " .. tostring(layer))
    send("layer_started", { layer = layer })
    carved = { [key(0, 0)] = true }

    local movesDone = 0
    local inventoryChecks = 0
    for _, run in ipairs(route) do
        turnTo(run.direction)
        for _ = 1, run.count do
            safePoint("mining")

            local moved, reason, dug = forwardMine()
            if not moved and reason == "storage full" then
                local checkpointX, checkpointZ = pos.x, pos.z
                unloadAndReturnToCheckpoint(layer, checkpointX, checkpointZ)
                turnTo(run.direction)
                moved, reason, dug = forwardMine()
            end
            if not moved then reportError("Mining route failed: " .. tostring(reason)) end

            movesDone = movesDone + 1
            inventoryChecks = inventoryChecks + 1
            state.progress = movesDone
            state.checkpoint = {
                layer = layer,
                progress = movesDone,
                status = "mining",
                position = { x = pos.x, y = pos.y, z = pos.z, dir = pos.dir },
            }
            if movesDone % 8 == 0 then
                uiMessage = "Mining layer " .. tostring(layer) .. " - " .. tostring(movesDone) .. "/" .. tostring(totalMoves)
                persist(true)
                renderWorkerScreen(false)
            end

            if inventoryChecks >= INVENTORY_CHECK_INTERVAL then
                inventoryChecks = 0

                -- A full inventory scan is done only periodically. If six or
                -- fewer empty slots remain, unload now; at most six new stack
                -- types can appear before the next check, so collection stays safe.
                if countEmptyStorageSlots() <= INVENTORY_CHECK_INTERVAL then
                    local checkpointX, checkpointZ = pos.x, pos.z
                    unloadAndReturnToCheckpoint(layer, checkpointX, checkpointZ)
                    turnTo(run.direction)
                end

                local reserve = reserveForDock(layer)
                if not isUnlimitedFuel() and (fuelLevel() < reserve or fuelItemsLow()) then
                    local checkpointX, checkpointZ = pos.x, pos.z
                    unloadAndReturnToCheckpoint(layer, checkpointX, checkpointZ)
                    turnTo(run.direction)
                end
            end
        end
    end

    for cellKey in pairs(interior) do
        if not carved[cellKey] then reportError("Layer verification failed at " .. cellKey) end
    end

    routeCenter()
    returnToDockFromCenter()
    dumpUp()
    safePoint("returning")
    send("layer_complete", { layer = layer })
    state.layer = nil
    state.progress = nil
    state.total = nil
    setStatus("docked", "Docked, unloaded, and ready")
end

local function recoverFromFuelRoute()
    local info = dockInfo[dock]
    local outwardVector = vec[info.out]
    local outwardX = info.x + outwardVector.x
    local outwardZ = info.z + outwardVector.z

    if pos.y == 3 and pos.x == info.x and pos.z == info.z then
        turnTo(info.out)
        local moved, reason = forwardOpen()
        if not moved then reportError("Abort could not leave the fuel chest: " .. tostring(reason)) end
    end

    if pos.x ~= outwardX or pos.z ~= outwardZ then
        reportError("Abort cannot identify the current fuel-route position.")
    end
    while pos.y > 0 do downOpen() end
    turnTo(info.inward)
    local moved, reason = forwardOpen()
    if not moved then reportError("Abort could not return from fuel route: " .. tostring(reason)) end
    turnTo(info.out)
end

local function clearJobState()
    state.jobId = nil
    state.firstLayer = nil
    state.lastLayer = nil
    state.layer = nil
    state.progress = nil
    state.total = nil
    state.checkpoint = nil
    state.assignment = nil
    state.jobMap = nil
    state.recoveryAnchor = "dock"
    state.error = nil
end

local function recoverToDockAndUnload()
    local info = dockInfo[dock]
    if not info then reportError("Worker has no valid dock assignment for recovery.") end
    local outwardVector = vec[info.out]
    local outwardX = info.x + outwardVector.x
    local outwardZ = info.z + outwardVector.z

    if pos.y > 0 or (pos.y == 0 and pos.x == outwardX and pos.z == outwardZ) then
        recoverFromFuelRoute()
    elseif pos.y < 0 then
        if pos.x == info.x and pos.z == info.z then
            ascendDock()
        else
            routeCenter()
            returnToDockFromCenter()
        end
    elseif pos.x ~= info.x or pos.z ~= info.z then
        reportError("Recovery found the worker away from its dock at Y=0.")
    end

    releaseFuelLock()
    return dumpUp(true)
end

local function performAbort(note, messageType)
    local parked = messageType == "worker_parked"
    paused = false
    abortRequested = false
    setStatus("aborting")
    local unloaded = recoverToDockAndUnload()
    clearJobState()
    parkRequested = false
    setStatus(parked and "parked" or "docked")
    send(messageType or "worker_aborted", {
        note = note or (unloaded and "returned and unloaded" or "returned; output chest was full"),
        position = pos,
    })
end


local function runCalibration(name)
    state.error = nil
    setStatus("calibrating", "Tracing and saving the map boundary")
    descendDock(1)
    enterCenterFromDockAtCurrentY()
    turnTo(NORTH)
    wall = {}
    interior = {}
    driveToNorthWall()
    tracePerimeter()
    buildInterior()

    local path, err = findPath(pos.x, pos.z, 0, 0, interior)
    if not path then reportError("Cannot return after calibration: " .. tostring(err)) end
    followOpen(path)
    turnTo(NORTH)
    local map = {
        version = 3,
        name = name,
        interior = interior,
        bounds = bounds,
        cellCount = countCells(interior),
    }
    send("calibration_complete", { map = map })
    returnToDockFromCenter()
    dumpUp()
    setStatus("docked", "Docked, unloaded, and ready")
end

local function runSectionWork(message)
    interior = message.map.interior
    bounds = message.map.bounds
    state.jobId = message.jobId
    state.firstLayer = message.firstLayer
    state.lastLayer = message.lastLayer
    state.assignment = {
        jobId = message.jobId,
        firstLayer = message.firstLayer,
        lastLayer = message.lastLayer,
        dock = message.dock or dock,
        mapName = message.mapName,
        testRun = message.testRun == true,
    }
    state.jobMap = message.map
    state.error = nil
    persist(true)
    setStatus("starting", "Building route for layers " .. tostring(message.firstLayer) .. "-" .. tostring(message.lastLayer))

    validateFuelSlot()
    local route, totalMoves = buildRoute()
    if not isUnlimitedFuel() and (fuelLevel() < FUEL_TARGET / 2 or fuelItemsLow()) then
        refuelAtStation(message.lastLayer * 2 + FUEL_MARGIN)
    end

    for layer = message.firstLayer, message.lastLayer do
        safePoint("starting")
        setStatus("descending", "Descending to layer " .. tostring(layer))
        goCenterForLayer(layer)
        excavateLayer(layer, route, totalMoves)
    end

    clearJobState()
    setStatus("docked", "Docked, unloaded, and ready")
    send("section_complete", { firstLayer = message.firstLayer, lastLayer = message.lastLayer })
end

local function recoverAndRetry(message)
    paused = false
    abortRequested = false
    parkRequested = false
    send("worker_recovery_started", { position = pos })
    setStatus("recovering", "Returning safely before retrying work")
    recoverToDockAndUnload()
    if abortRequested then error(ABORT_SIGNAL, 0) end
    clearJobState()
    runSectionWork(message)
end


local function runManagedTask(taskFunction)
    taskActive = true
    local taskDone = false
    local taskOk, taskError

    parallel.waitForAny(
        function()
            taskOk, taskError = pcall(taskFunction)
            taskDone = true
        end,
        function()
            while not taskDone do
                local sender, message, protocol = rednet.receive(nil, 1)
                if sender == controller and (protocol == PROTOCOL or protocol == LEGACY_PROTOCOL) then applyTaskMessage(message) end
                if not sender then taskHeartbeat() end
            end
        end
    )

    taskActive = false
    persist(true)
    applyPendingUpdate()
    return taskOk, taskError
end

local function safeToolCheck()
    local occupied = turtle.inspect()
    if occupied then return "unknown", "front is occupied; tool check skipped" end
    local ok, reason = turtle.dig()
    reason = tostring(reason or "")
    if ok then return true, "tool responded" end
    if reason:lower():find("no tool", 1, true) then return false, reason end
    return true, reason ~= "" and reason or "air test passed"
end

local function buildPreflightReport(requestId)
    local previousSlot = turtle.getSelectedSlot()
    local usedStorageSlots, storedItems = storageSummary()
    turtle.select(FUEL_SLOT)
    local fuelCount = turtle.getItemCount(FUEL_SLOT)
    local fuelValid = fuelCount == 0 or turtle.refuel(0)
    turtle.select(previousSlot)
    local toolOk, toolMessage = safeToolCheck()
    local outputAbove = peripheral.hasType and peripheral.hasType("top", "inventory") or false
    return {
        requestId = requestId,
        status = state.status,
        version = VERSION,
        protocolVersion = PROTOCOL_VERSION,
        physicallyDocked = isPhysicallyDocked(),
        dock = dock,
        positionConfidence = state.positionConfidence,
        fuel = fuelLevel(),
        fuelItems = fuelCount,
        fuelValid = fuelValid,
        emptyStorageSlots = countEmptyStorageSlots(),
        usedStorageSlots = usedStorageSlots,
        storedItems = storedItems,
        outputInventoryAbove = outputAbove,
        modemSide = modemSide,
        toolOk = toolOk,
        toolMessage = toolMessage,
        pendingUpdate = state.pendingUpdate and state.pendingUpdate.version or nil,
        assignment = state.assignment,
    }
end

local function prepareRelocation()
    if taskActive or not isPhysicallyDocked() then
        send("relocation_rejected", { message = "Worker must be idle and physically docked." })
        return
    end
    local _, storedItems = storageSummary()
    if storedItems > 0 then
        dumpUp(true)
        _, storedItems = storageSummary()
        if storedItems > 0 then
            send("relocation_rejected", { message = "Worker still holds mined items. Clear the output inventory and unload before relocating." })
            return
        end
    end
    clearJobState()
    dock = nil
    state.dock = nil
    state.positionConfidence = "unknown"
    state.status = "relocation_ready"
    state.error = nil
    controller = controller
    os.setComputerLabel("Roomba Worker (relocation)")
    persist(true)
    renderWorkerScreen(true)
    send("relocation_ready", {})
end

local function recoverSavedCheckpoint()
    if state.positionConfidence ~= "recoverable" then
        send("recovery_rejected", { message = "Saved position is not safe enough for automatic movement." })
        return
    end
    local ok, err = runManagedTask(function()
        setStatus("recovering", "Returning from saved shaft/centre anchor")
        local unloaded = recoverToDockAndUnload()
        state.positionConfidence = "confirmed"
        state.status = "parked"
        state.error = nil
        state.recoveryAnchor = "dock"
        persist(true)
        send("worker_parked", { note = unloaded and "recovered from checkpoint" or "recovered; output chest full", position = pos })
    end)
    if not ok then reportError("Checkpoint recovery failed: " .. tostring(err)) end
end

local function discoverController()
    setActivity("Searching Rednet for the Roomba controller")
    while not controller do
        renderWorkerScreen(false)
        local id = rednet.lookup(PROTOCOL, HOSTNAME)
        if id then
            controller = id
            persist(true)
            break
        end
        rednet.broadcast({ type = "hello", version = VERSION, protocolVersion = PROTOCOL_VERSION, status = state.status, dock = dock }, PROTOCOL)
        sleep(2)
    end
    setActivity("Connected to controller #" .. tostring(controller))
    send("hello", { status = state.status, fuel = fuelLevel(), position = pos })
end

local function dockProbeLoop()
    while true do
        os.pullEvent("redstone")
        if redstone.getInput("back") then
            controller = controller or rednet.lookup(PROTOCOL, HOSTNAME)
            if controller then
                persist(true)
                rednet.send(controller, { type = "dock_probe", version = VERSION, protocolVersion = PROTOCOL_VERSION, dock = dock }, PROTOCOL)
            end
        end
    end
end

local function handleReturnWhileIdleOrErrored(messageType, note)
    if not dock then return end
    abortRequested = true
    local ok, err = pcall(function() performAbort(note, messageType) end)
    if not ok then
        state.status = "error"
        state.error = "Return recovery failed: " .. tostring(err)
        persist(true)
        send("worker_error", {
            message = state.error,
            position = { x = pos.x, y = pos.y, z = pos.z, dir = dirNames[pos.dir] },
        })
    end
end

local function commandLoop()
    discoverController()
    while true do
        local sender, message, protocol = rednet.receive(nil, 5)
        if not sender then
            applyPendingUpdate()
            renderWorkerScreen(false)
            local found = rednet.lookup(PROTOCOL, HOSTNAME)
            if found then controller = found end
            local usedStorageSlots, storedItems = storageSummary()
            send("heartbeat", {
                status = state.status,
                layer = state.layer,
                fuel = fuelLevel(),
                fuelItems = turtle.getItemCount(FUEL_SLOT),
                emptyStorageSlots = countEmptyStorageSlots(),
                usedStorageSlots = usedStorageSlots,
                storedItems = storedItems,
                position = pos,
                progress = state.progress,
                total = state.total,
                firstLayer = state.firstLayer,
                lastLayer = state.lastLayer,
                checkpoint = state.checkpoint,
                recoveryAnchor = state.recoveryAnchor,
                assignment = state.assignment,
            })
        elseif (protocol == PROTOCOL or protocol == LEGACY_PROTOCOL) and type(message) == "table" then
            local trusted = sender == controller
            local pairingMessage = message.type == "dock_probe_begin" or message.type == "dock_assigned" or message.type == "dock_conflict"
            if not trusted and not pairingMessage then
                -- Ignore direct commands from pockets or unrelated computers.
            elseif message.type == "dock_probe_begin" then
                controller = message.controller or controller
                persist(true)

            elseif message.type == "dock_assigned" then
                setActivity("Receiving dock assignment from controller")
                controller = message.controller
                dock = message.dock
                local info = dockInfo[dock]
                pos = { x = info.x, y = 0, z = info.z, dir = info.out }
                state.positionConfidence = "confirmed"
                state.recoveryAnchor = "dock"
                clearJobState()
                setStatus("docked", "Docked, unloaded, and ready")
                restoreComputerLabel()
                send("hello", { status = "docked", fuel = fuelLevel(), position = pos })
                applyPendingUpdate()

            elseif message.type == "dock_conflict" then
                state.error = "Dock conflict at " .. tostring(message.dock)
                setStatus("dock_conflict")

            elseif message.type == "calibrate" then
                setActivity("Controller requested map calibration")
                local ok, err = pcall(function()
                    if not dock then reportError("Worker is not dock-assigned.") end
                    runCalibration(message.name)
                end)
                if not ok then printError(err) end

            elseif message.type == "start_section" then
                setActivity("Controller assigned a mining section")
                if tonumber(message.protocolVersion or PROTOCOL_VERSION) ~= PROTOCOL_VERSION then
                    state.status = "incompatible"
                    state.error = "Controller protocol is incompatible with this worker."
                    persist(true)
                    send("worker_error", { message = state.error, position = pos })
                elseif state.positionConfidence ~= "confirmed" then
                    state.status = "position_unknown"
                    state.error = "Position must be confirmed at a dock before starting work."
                    persist(true)
                    send("worker_error", { message = state.error, position = pos })
                elseif not dock then
                    state.status = "error"
                    state.error = "Worker is not dock-assigned."
                    persist(true)
                    send("worker_error", { message = state.error, position = pos })
                elseif message.dock and message.dock ~= dock then
                    state.status = "error"
                    state.error = "Controller assigned a section for the wrong dock."
                    persist(true)
                    send("worker_error", { message = state.error, position = pos })
                else
                    paused = false
                    abortRequested = false
                    parkRequested = false
                    fuelLockGranted = false
                    local ok, err = runManagedTask(function() runSectionWork(message) end)
                    if not ok then
                        if err == FUEL_STATION_EMPTY_SIGNAL then
                            -- The worker is already safely docked and waiting for restock.
                        elseif err == ABORT_SIGNAL then
                            local messageType = parkRequested and "worker_parked" or "worker_aborted"
                            local note = parkRequested and "returned by worker command" or nil
                            local abortOk, abortErr = pcall(function() performAbort(note, messageType) end)
                            if not abortOk then printError(abortErr) end
                        else
                            printError(err)
                        end
                    end
                end

            elseif message.type == "pause" then
                paused = true
                setActivity("Pause requested; stopping at the next safe point")

            elseif message.type == "resume" then
                paused = false
                setActivity("Resume requested")

            elseif message.type == "abort" then
                setActivity("Abort requested; returning safely")
                parkRequested = false
                handleReturnWhileIdleOrErrored("worker_aborted", "recovered after worker error")

            elseif message.type == "return_to_dock" then
                setActivity("Return-to-dock command received")
                parkRequested = true
                handleReturnWhileIdleOrErrored("worker_parked", "returned by worker command")

            elseif message.type == "recover_and_retry" then
                setActivity("Recovery and retry command received")
                if not dock then
                    reportError("Worker is not dock-assigned for recovery.")
                else
                    local ok, err = runManagedTask(function() recoverAndRetry(message) end)
                    if not ok then
                        if err == FUEL_STATION_EMPTY_SIGNAL then
                            -- The worker is already safely docked and waiting for restock.
                        elseif err == ABORT_SIGNAL then
                            local messageType = parkRequested and "worker_parked" or "worker_aborted"
                            local abortOk, abortErr = pcall(function() performAbort("recovery interrupted", messageType) end)
                            if not abortOk then printError(abortErr) end
                        else
                            printError(err)
                        end
                    end
                end

            elseif message.type == "preflight_request" then
                send("preflight_response", buildPreflightReport(message.requestId))

            elseif message.type == "prepare_relocation" then
                prepareRelocation()

            elseif message.type == "recover_checkpoint" then
                recoverSavedCheckpoint()

            elseif message.type == "update_request" then
                queueUpdateRequest(message)

            elseif message.type == "status_request" then
                local usedStorageSlots, storedItems = storageSummary()
                send("heartbeat", {
                    status = state.status,
                    layer = state.layer,
                    fuel = fuelLevel(),
                    position = pos,
                    progress = state.progress,
                    total = state.total,
                    firstLayer = state.firstLayer,
                    lastLayer = state.lastLayer,
                    checkpoint = state.checkpoint,
                    recoveryAnchor = state.recoveryAnchor,
                    fuelItems = turtle.getItemCount(FUEL_SLOT),
                    emptyStorageSlots = countEmptyStorageSlots(),
                    usedStorageSlots = usedStorageSlots,
                    storedItems = storedItems,
                    assignment = state.assignment,
                })

            elseif message.type == "clear_error" then
                state.error = nil
                if pos.y == 0 and dockInfo[dock] and pos.x == dockInfo[dock].x and pos.z == dockInfo[dock].z then
                    state.status = "docked"
                end
                persist(true)
                send("heartbeat", { status = state.status, fuel = fuelLevel(), position = pos })
            end
        end
    end
end

renderWorkerScreen(true)

local function healthLoop()
    sleep(8)
    if fs.exists(BOOT_FILE) then
        local ok, boot = pcall(dofile, BOOT_FILE)
        if ok and boot and boot.markHealthy then boot.markHealthy("worker", VERSION) end
    end
    while true do sleep(3600) end
end

local ok, err = pcall(function()
    parallel.waitForAny(dockProbeLoop, commandLoop, healthLoop)
end)
if not ok then
    state.status = "error"
    state.error = tostring(err)
    uiMessage = "Worker program stopped"
    persist(true)
    renderWorkerScreen(true)
end
