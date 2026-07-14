-- Roomba Hive Worker v0.2.0
-- Requires a mining turtle with a wireless or ender modem.

local VERSION = "0.2.0"
local PROTOCOL = "roomba_hive_v1"
local HOSTNAME = "roomba-hive"
local ROOT = "/roomba"
local STATE_FILE = fs.combine(ROOT, "worker_state.db")

local FUEL_SLOT = 1
local FIRST_STORAGE_SLOT = 2
local LAST_STORAGE_SLOT = 16
local FUEL_ITEM_RESERVE = 5
local FUEL_TARGET = 2048
local FUEL_MARGIN = 96
local POSITION_SAVE_INTERVAL = 24
local MAX_FALLING_DIGS = 32
local MAX_CALIBRATION_STEPS = 100000
local INVENTORY_CHECK_INTERVAL = 16
local MOVE_RETRY_DELAY = 0.4
local ABORT_SIGNAL = "__ROOMBA_ABORT__"

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
local controller = state.controller
local dock = state.dock
local pos = state.pos or { x = 0, y = 0, z = 0, dir = NORTH }
local movesSinceSave = 0

local interior = {}
local bounds = nil
local carved = {}
local wall = {}

local paused = false
local abortRequested = false
local taskActive = false
local fuelLockGranted = false
local fuelLockHeld = false

local function persist(force)
    state.version = VERSION
    state.controller = controller
    state.dock = dock
    state.pos = pos
    if force or movesSinceSave >= POSITION_SAVE_INTERVAL then
        saveTable(STATE_FILE, state)
        movesSinceSave = 0
    end
end

local function setStatus(status)
    state.status = status
    persist(true)
end

local function restoreComputerLabel()
    if dock and dockInfo[dock] then
        os.setComputerLabel("Roomba " .. dock .. " #" .. tostring(os.getComputerID()))
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
    if data.dock == nil then data.dock = dock end
    return rednet.send(controller, data, PROTOCOL)
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
    persist(true)
    send("worker_error", payload)
    error(message, 0)
end

local function fuelLevel()
    return turtle.getFuelLevel()
end

local function isUnlimitedFuel()
    return fuelLevel() == "unlimited"
end

local function findEmptyStorageSlot()
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        if turtle.getItemCount(slot) == 0 then return slot end
    end
    return nil
end

local function selectEmptyStorageSlot()
    local slot = findEmptyStorageSlot()
    if not slot then return nil end
    turtle.select(slot)
    return slot
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

local function advancePosition()
    local direction = vec[pos.dir]
    pos.x = pos.x + direction.x
    pos.z = pos.z + direction.z
    markMoved()
end

local function protectedBlock(data)
    local name = data and data.name or ""
    return name:find("computercraft")
        or name:find("chest")
        or name:find("barrel")
        or name:find("shulker")
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
    if turtle.forward() then advancePosition(); return true end
    local occupied, data = turtle.inspect()
    if occupied then return false, "blocked by " .. tostring(data and data.name) end
    return entityBlockedForward()
end

local function forwardMine()
    ensureFuel(1)
    local direction = vec[pos.dir]
    local nextX, nextZ = pos.x + direction.x, pos.z + direction.z
    if not interior[key(nextX, nextZ)] then return false, "map boundary", false end

    if turtle.forward() then
        advancePosition()
        carved[key(pos.x, pos.z)] = true
        return true, nil, false
    end

    for _ = 1, MAX_FALLING_DIGS do
        local occupied, data = turtle.inspect()
        if occupied then
            if protectedBlock(data) or (peripheral.hasType and peripheral.hasType("front", "inventory")) then
                reportError("Protected block or inventory in mining route: " .. tostring(data and data.name))
            end
            if not selectEmptyStorageSlot() then return false, "storage full", false end
            local dug, reason = turtle.dig()
            if not dug then reportError("Unable to dig block: " .. tostring(reason), { block = data and data.name }) end
            if turtle.forward() then
                advancePosition()
                carved[key(pos.x, pos.z)] = true
                return true, nil, true
            end
        else
            local moved, reason = entityBlockedForward()
            return moved, reason or "entity obstruction", false
        end
        sleep(MOVE_RETRY_DELAY)
    end
    reportError("Too many falling blocks prevented movement.")
end

local function upOpen()
    ensureFuel(1)
    if turtle.up() then pos.y = pos.y + 1; markMoved(); return end
    local occupied, data = turtle.inspectUp()
    if occupied then reportError("Vertical shaft blocked above by " .. tostring(data and data.name)) end
    sleep(5)
    if turtle.up() then pos.y = pos.y + 1; markMoved(); return end
    turtle.attackUp()
    sleep(MOVE_RETRY_DELAY)
    if turtle.up() then pos.y = pos.y + 1; markMoved(); return end
    reportError("Cannot ascend after waiting and attacking once.")
end

local function downOpen()
    ensureFuel(1)
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    local occupied, data = turtle.inspectDown()
    if occupied then reportError("Expected-open route blocked below by " .. tostring(data and data.name)) end
    sleep(5)
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    turtle.attackDown()
    sleep(MOVE_RETRY_DELAY)
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    reportError("Entity remained below after waiting and attacking once.")
end

local function downDig()
    ensureFuel(1)
    if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    local occupied, data = turtle.inspectDown()
    if occupied then
        if protectedBlock(data) or (peripheral.hasType and peripheral.hasType("bottom", "inventory")) then
            reportError("Protected block below the shaft.")
        end
        if not selectEmptyStorageSlot() then reportError("Storage slots 2-16 are occupied before shaft digging.") end
        local dug, reason = turtle.digDown()
        if not dug then reportError("Cannot dig shaft downward: " .. tostring(reason)) end
        if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    else
        sleep(5)
        if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
        turtle.attackDown()
        sleep(MOVE_RETRY_DELAY)
        if turtle.down() then pos.y = pos.y - 1; markMoved(); return end
    end
    reportError("Cannot descend the shaft.")
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
    persist(true)
end

local function descendDock(layer)
    local info = dockInfo[dock]
    if pos.x ~= info.x or pos.z ~= info.z or pos.y ~= 0 then reportError("Not at dock before descent.") end
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
end

local function dumpUp()
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
                if abortRequested then
                    turtle.select(FUEL_SLOT)
                    return false
                end
                sleep(1)
            else
                state.status = "working"
            end
        end
    end
    turtle.select(FUEL_SLOT)
    return allUnloaded
end

local function applyTaskMessage(message)
    if type(message) ~= "table" then return end
    if message.type == "pause" then
        paused = true
    elseif message.type == "resume" then
        paused = false
    elseif message.type == "abort" then
        abortRequested = true
        paused = false
    elseif message.type == "fuel_lock_granted" then
        fuelLockGranted = true
    elseif message.type == "fuel_lock_wait" then
        fuelLockGranted = false
    end
end

local function taskHeartbeat()
    send("heartbeat", {
        status = state.status,
        layer = state.layer,
        fuel = fuelLevel(),
        position = pos,
        progress = state.progress,
        total = state.total,
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
    setStatus("waiting_fuel_lock")
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

local function refuelAtStation(required)
    if isUnlimitedFuel() then return true end
    local info = dockInfo[dock]
    if pos.x ~= info.x or pos.z ~= info.z or pos.y ~= 0 then
        reportError("Refuel requested while worker was not docked.")
    end
    if not requestFuelLock() then return false end

    -- A low-item trigger may happen with little movement fuel remaining. Consume
    -- emergency reserve only when necessary to reach the station, while keeping
    -- at least one item in slot 1 so mined blocks still cannot occupy it.
    ensureEmergencyFuel(5)
    setStatus("refueling")
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
    while fuelLevel() < target or turtle.getItemCount(FUEL_SLOT) <= FUEL_ITEM_RESERVE do
        if abortRequested then break end
        if turtle.getItemCount(FUEL_SLOT) <= FUEL_ITEM_RESERVE then
            if not turtle.suck(64) then
                setStatus("waiting_for_fuel")
                sleep(1)
            else
                validateFuelSlot()
                setStatus("refueling")
            end
        elseif fuelLevel() < target then
            if not turtle.refuel(1) then
                releaseFuelLock()
                reportError("Fuel chest supplied a non-fuel item. Fuel chest must contain fuel only.")
            end
        end
    end

    ensureEmergencyFuel(5)
    turnAround()
    moved, reason = forwardOpen()
    if not moved then releaseFuelLock(); reportError("Cannot leave fuel chest: " .. tostring(reason)) end
    downOpen(); downOpen(); downOpen()
    turnAround()
    moved, reason = forwardOpen()
    if not moved then releaseFuelLock(); reportError("Cannot return to dock from fuel route: " .. tostring(reason)) end
    turnTo(info.out)
    releaseFuelLock()
    setStatus("docked")
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
    if pos.x == 0 and pos.z == 0 then return end
    carved[key(pos.x, pos.z)] = true
    carved[key(0, 0)] = true
    local path, err = findPath(pos.x, pos.z, 0, 0, carved)
    if not path then reportError("No carved return path: " .. tostring(err)) end
    followOpen(path)
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
    setStatus("mining")
    send("layer_started", { layer = layer })
    carved = { [key(0, 0)] = true }

    local movesDone = 0
    local inventoryChecks = 0
    for _, run in ipairs(route) do
        turnTo(run.direction)
        for _ = 1, run.count do
            safePoint("mining")

            if not findEmptyStorageSlot() then
                local checkpointX, checkpointZ = pos.x, pos.z
                unloadAndReturnToCheckpoint(layer, checkpointX, checkpointZ)
                turnTo(run.direction)
            end

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

            if dug or inventoryChecks >= INVENTORY_CHECK_INTERVAL then
                inventoryChecks = 0
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
    setStatus("docked")
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
    state.error = nil
end

local function performAbort(note)
    paused = false
    setStatus("aborting")

    local info = dockInfo[dock]
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
        reportError("Abort recovery found the worker away from its dock at Y=0.")
    end

    releaseFuelLock()
    local unloaded = dumpUp()
    clearJobState()
    abortRequested = false
    setStatus("docked")
    send("worker_aborted", {
        note = note or (unloaded and "returned and unloaded" or "returned; output chest was full"),
        position = pos,
    })
end

local function runCalibration(name)
    state.error = nil
    setStatus("calibrating")
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
    setStatus("docked")
end

local function runSectionWork(message)
    interior = message.map.interior
    bounds = message.map.bounds
    state.jobId = message.jobId
    state.firstLayer = message.firstLayer
    state.lastLayer = message.lastLayer
    state.error = nil
    setStatus("starting")

    validateFuelSlot()
    local route, totalMoves = buildRoute()
    if not isUnlimitedFuel() and (fuelLevel() < FUEL_TARGET / 2 or fuelItemsLow()) then
        refuelAtStation(message.lastLayer * 2 + FUEL_MARGIN)
    end

    for layer = message.firstLayer, message.lastLayer do
        safePoint("starting")
        setStatus("descending")
        goCenterForLayer(layer)
        excavateLayer(layer, route, totalMoves)
    end

    clearJobState()
    setStatus("docked")
    send("section_complete", { firstLayer = message.firstLayer, lastLayer = message.lastLayer })
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
                local sender, message, protocol = rednet.receive(PROTOCOL, 1)
                if sender == controller and protocol == PROTOCOL then applyTaskMessage(message) end
                if not sender then taskHeartbeat() end
            end
        end
    )

    taskActive = false
    persist(true)
    return taskOk, taskError
end

local function discoverController()
    while not controller do
        local id = rednet.lookup(PROTOCOL, HOSTNAME)
        if id then
            controller = id
            persist(true)
            break
        end
        rednet.broadcast({ type = "hello", version = VERSION, status = state.status, dock = dock }, PROTOCOL)
        sleep(2)
    end
    send("hello", { status = state.status, fuel = fuelLevel(), position = pos })
end

local function dockProbeLoop()
    while true do
        os.pullEvent("redstone")
        if redstone.getInput("back") then
            controller = controller or rednet.lookup(PROTOCOL, HOSTNAME)
            if controller then
                persist(true)
                rednet.send(controller, { type = "dock_probe", version = VERSION, dock = dock }, PROTOCOL)
            end
        end
    end
end

local function handleAbortWhileIdleOrErrored()
    if not state.jobId then return end
    abortRequested = true
    local ok, err = pcall(function() performAbort("recovered after worker error") end)
    if not ok then
        state.status = "error"
        state.error = "Abort recovery failed: " .. tostring(err)
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
        local sender, message, protocol = rednet.receive(PROTOCOL, 5)
        if not sender then
            local found = rednet.lookup(PROTOCOL, HOSTNAME)
            if found then controller = found end
            send("heartbeat", {
                status = state.status,
                layer = state.layer,
                fuel = fuelLevel(),
                position = pos,
                progress = state.progress,
                total = state.total,
            })
        elseif protocol == PROTOCOL and type(message) == "table" then
            if message.type == "dock_probe_begin" then
                controller = message.controller or controller
                persist(true)

            elseif message.type == "dock_assigned" then
                controller = message.controller
                dock = message.dock
                local info = dockInfo[dock]
                pos = { x = info.x, y = 0, z = info.z, dir = info.out }
                clearJobState()
                setStatus("docked")
                restoreComputerLabel()
                send("hello", { status = "docked", fuel = fuelLevel(), position = pos })

            elseif message.type == "dock_conflict" then
                state.error = "Dock conflict at " .. tostring(message.dock)
                setStatus("dock_conflict")

            elseif message.type == "calibrate" then
                local ok, err = pcall(function()
                    if not dock then reportError("Worker is not dock-assigned.") end
                    runCalibration(message.name)
                end)
                if not ok then printError(err) end

            elseif message.type == "start_section" then
                if not dock then
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
                    fuelLockGranted = false
                    local ok, err = runManagedTask(function() runSectionWork(message) end)
                    if not ok then
                        if err == ABORT_SIGNAL then
                            local abortOk, abortErr = pcall(function() performAbort() end)
                            if not abortOk then printError(abortErr) end
                        else
                            printError(err)
                        end
                    end
                end

            elseif message.type == "pause" then
                paused = true

            elseif message.type == "resume" then
                paused = false

            elseif message.type == "abort" then
                handleAbortWhileIdleOrErrored()
            end
        end
    end
end

term.clear()
term.setCursorPos(1, 1)
print("Roomba Hive Worker v" .. VERSION)
print("ID: " .. tostring(os.getComputerID()))
print("Modem: " .. modemSide)
print("Waiting for controller...")

local ok, err = pcall(function()
    parallel.waitForAny(dockProbeLoop, commandLoop)
end)
if not ok then
    term.setTextColor(colors.red)
    printError(err)
    term.setTextColor(colors.white)
end
