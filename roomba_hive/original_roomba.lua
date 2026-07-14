--[[
    roomba_excavator.lua
    CC:Tweaked Mining Turtle multi-map fast excavator v2

    STARTING SETUP
    ------------------------------------------------------------
    1. Turtle begins at logical coordinate:
           X = 0, Y = 0, Z = 0
    2. Turtle faces NORTH.
    3. A compatible inventory is directly above the starting position.
    4. Slot 1 is permanently reserved for turtle fuel.
    5. The wall outline is closed and exists on calibration level Y=0.
    6. Unless ALLOW_CENTER_DIG_DOWN is enabled, the center shaft at
       X=0, Z=0 must already be open through every requested layer.

    COORDINATE SYSTEM
    ------------------------------------------------------------
    North: Z decreases
    East:  X increases
    South: Z increases
    West:  X decreases

    EXCAVATION RULES
    ------------------------------------------------------------
    * turtle.digDown() is used only at the center when the optional
      ALLOW_CENTER_DIG_DOWN setting is enabled.
    * turtle.digUp() is NEVER called.
    * Blocks are only mined with turtle.dig(), directly in front.
    * Any compatible inventory detected in front causes an emergency stop.
    * Slot 1 is never emptied into the output inventory.
    * Named maps are saved in the "roomba_maps" directory.

    USAGE
    ------------------------------------------------------------
        roomba_excavator <number_of_layers>

    Example:
        roomba_excavator 15

    Layer 1 is the turtle's starting Y-level.
    Layer 2 is one block below it, and so on.
]]

-----------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------

local MAP_DIR = "roomba_maps"
local LEGACY_MAP_FILE = "roomba_map.db"
local selectedMapName = nil
local selectedMapFile = nil

local FUEL_SLOT = 1
local FIRST_STORAGE_SLOT = 2
local LAST_STORAGE_SLOT = 16

-- Set true to let the turtle mine exactly one block downward at the
-- center between layers. It will still never dig down anywhere else.
local ALLOW_CENTER_DIG_DOWN = true

-- Extra fuel kept beyond the calculated unload-and-return requirement.
local FUEL_SAFETY_MARGIN = 32

-- Refill to at least this amount whenever fuel is low.
-- The script may dynamically request more for long trips.
local DEFAULT_FUEL_TARGET = 256

-- Prevent an accidental infinite perimeter trace.
local MAX_CALIBRATION_STEPS = 100000

-- Movement retry count for temporary entity obstruction.
local MOVE_RETRIES = 5
local MOVE_RETRY_DELAY = 0.5

-- Expensive inventory scans are throttled, but a scan is forced after digs.
local INVENTORY_CHECK_INTERVAL = 16


-----------------------------------------------------------------------
-- Arguments
-----------------------------------------------------------------------

local args = { ... }
local totalLayers = tonumber(args[1])

if not totalLayers or totalLayers < 1 or totalLayers % 1 ~= 0 then
    error("Usage: roomba_excavator <positive integer layer count>", 0)
end

-----------------------------------------------------------------------
-- Position and direction state
-----------------------------------------------------------------------

local NORTH = 0
local EAST  = 1
local SOUTH = 2
local WEST  = 3

local directionNames = {
    [NORTH] = "north",
    [EAST]  = "east",
    [SOUTH] = "south",
    [WEST]  = "west",
}

local directionVectors = {
    [NORTH] = { x =  0, z = -1 },
    [EAST]  = { x =  1, z =  0 },
    [SOUTH] = { x =  0, z =  1 },
    [WEST]  = { x = -1, z =  0 },
}

-- Logical coordinates, not Minecraft GPS coordinates.
local pos = {
    x = 0,
    y = 0,
    z = 0,
    dir = NORTH,
}

-----------------------------------------------------------------------
-- Map state
-----------------------------------------------------------------------

-- interior["x,z"] == true when the coordinate is inside the outline.
local interior = {}

-- wall["x,z"] == true when calibration observed an outline block.
local wall = {}

-- Cells physically entered/carved on the current excavation layer.
-- Used to guarantee a safe, already-open path back to the center.
local carved = {}

local bounds = {
    minX = 0,
    maxX = 0,
    minZ = 0,
    maxZ = 0,
}

-----------------------------------------------------------------------
-- Utility functions
-----------------------------------------------------------------------

local function key(x, z)
    return tostring(x) .. "," .. tostring(z)
end

local function parseKey(value)
    local comma = string.find(value, ",", 1, true)
    if not comma then
        error("Invalid coordinate key: " .. tostring(value), 0)
    end

    local x = tonumber(string.sub(value, 1, comma - 1))
    local z = tonumber(string.sub(value, comma + 1))

    return x, z
end

local function emergencyStop(message)
    term.setTextColor(colors.red)
    print("")
    print("EMERGENCY STOP")
    print(message)
    print(
        "Position: X=" .. pos.x ..
        " Y=" .. pos.y ..
        " Z=" .. pos.z ..
        " facing=" .. directionNames[pos.dir]
    )
    term.setTextColor(colors.white)
    error(message, 0)
end

local function peripheralIsInventory(side)
    if peripheral.hasType then
        local ok, result = pcall(peripheral.hasType, side, "inventory")
        if ok and result then return true end
    end

    local ok, methods = pcall(peripheral.getMethods, side)
    if not ok or type(methods) ~= "table" then return false end

    local found = {}
    for _, method in ipairs(methods) do found[method] = true end
    return found.list == true and found.size == true
end

local function frontIsInventory()
    return peripheralIsInventory("front")
end

local function topIsInventory()
    return peripheralIsInventory("top")
end

local function updateBounds(x, z)
    if x < bounds.minX then bounds.minX = x end
    if x > bounds.maxX then bounds.maxX = x end
    if z < bounds.minZ then bounds.minZ = z end
    if z > bounds.maxZ then bounds.maxZ = z end
end

local function fuelLevel()
    return turtle.getFuelLevel()
end

local function ensureFuel(required)
    required = math.max(required or 1, 1)

    local level = fuelLevel()

    -- CC:Tweaked returns "unlimited" when fuel use is disabled.
    if level == "unlimited" then
        return
    end

    if level >= required then
        return
    end

    local target = math.max(required, DEFAULT_FUEL_TARGET)

    turtle.select(FUEL_SLOT)

    while fuelLevel() < target do
        if turtle.getItemCount(FUEL_SLOT) == 0 then
            emergencyStop(
                "Out of fuel. Place valid turtle fuel in reserved slot 1."
            )
        end

        local accepted = turtle.refuel(1)

        if not accepted then
            local detail = turtle.getItemDetail(FUEL_SLOT)
            local itemName = detail and detail.name or "unknown item"

            emergencyStop(
                "Slot 1 does not contain valid turtle fuel: " .. itemName
            )
        end
    end
end

local function inventoryNeedsUnload()
    -- Unload once every storage slot is occupied, even if some stacks are
    -- partial. This guarantees space for a newly mined item type and avoids
    -- drops caused by a full set of incompatible partial stacks.
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        if turtle.getItemCount(slot) == 0 then
            return false
        end
    end

    return true
end

local function storageHasItems()
    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        if turtle.getItemCount(slot) > 0 then
            return true
        end
    end

    return false
end

-----------------------------------------------------------------------
-- Turning
-----------------------------------------------------------------------

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

local function turnTo(targetDirection)
    local difference = (targetDirection - pos.dir) % 4

    if difference == 1 then
        turnRight()
    elseif difference == 2 then
        turnAround()
    elseif difference == 3 then
        turnLeft()
    end
end

-----------------------------------------------------------------------
-- Inspection
-----------------------------------------------------------------------

local function inspectFrontForProtectedInventory()
    local occupied, data = turtle.inspect()

    if occupied and frontIsInventory() then
        emergencyStop(
            "Protected inventory detected directly in front: " ..
            tostring(data and data.name or "unknown inventory")
        )
    end

    return occupied, data
end

-- Inspect a direction relative to the turtle without permanently
-- changing its facing direction.
--
-- relative:
--     -1 = left
--      0 = front
--      1 = right
local function inspectRelative(relative)
    if relative == -1 then
        turnLeft()
        local occupied, data = inspectFrontForProtectedInventory()
        turnRight()
        return occupied, data
    elseif relative == 1 then
        turnRight()
        local occupied, data = inspectFrontForProtectedInventory()
        turnLeft()
        return occupied, data
    end

    return inspectFrontForProtectedInventory()
end

local function coordinateInFront()
    local vector = directionVectors[pos.dir]
    return pos.x + vector.x, pos.z + vector.z
end

local function recordObservedWall(relative)
    local originalDirection = pos.dir

    if relative == -1 then
        turnLeft()
    elseif relative == 1 then
        turnRight()
    end

    local occupied, data = inspectFrontForProtectedInventory()

    if occupied then
        local wx, wz = coordinateInFront()
        wall[key(wx, wz)] = true
        updateBounds(wx, wz)
    end

    turnTo(originalDirection)

    return occupied, data
end

-----------------------------------------------------------------------
-- Raw movement
-----------------------------------------------------------------------

-- Forward movement without mining.
-- Used for calibration and travel through known-open cells.
local function forwardOpen()
    ensureFuel(1)

    for attempt = 1, MOVE_RETRIES do
        local occupied, data = inspectFrontForProtectedInventory()

        if occupied then
            return false, "blocked by " .. tostring(data and data.name)
        end

        if turtle.forward() then
            local vector = directionVectors[pos.dir]
            pos.x = pos.x + vector.x
            pos.z = pos.z + vector.z
            return true
        end

        sleep(MOVE_RETRY_DELAY)
    end

    return false, "movement failed, possibly due to an entity"
end

-- Forward movement with front-only excavation.
local function forwardMining()
    ensureFuel(1)

    local nextX, nextZ = coordinateInFront()

    if not interior[key(nextX, nextZ)] then
        return false, "map boundary", false
    end

    -- Fast path: most already-cleared cells allow immediate movement.
    if turtle.forward() then
        pos.x = nextX
        pos.z = nextZ
        carved[key(pos.x, pos.z)] = true
        return true, nil, false
    end

    -- Movement failed. Inspect only now, preserving chest safety while
    -- avoiding an inspect call on every empty-cell movement.
    for attempt = 1, MOVE_RETRIES do
        local occupied, data = turtle.inspect()

        if occupied then
            if frontIsInventory() then
                emergencyStop(
                    "Protected inventory detected directly in front: " ..
                    tostring(data and data.name or "unknown inventory")
                )
            end

            local dug, reason = turtle.dig()

            if not dug then
                emergencyStop(
                    "Unable to dig front block at X=" .. nextX ..
                    " Z=" .. nextZ .. ": " .. tostring(reason)
                )
            end

            if turtle.forward() then
                pos.x = nextX
                pos.z = nextZ
                carved[key(pos.x, pos.z)] = true
                return true, nil, true
            end
        else
            -- Usually a mob or another temporary obstruction.
            if turtle.forward() then
                pos.x = nextX
                pos.z = nextZ
                carved[key(pos.x, pos.z)] = true
                return true, nil, false
            end
        end

        sleep(MOVE_RETRY_DELAY)
    end

    return false, "movement failed after retries", false
end

local function moveUp()
    ensureFuel(1)

    for attempt = 1, MOVE_RETRIES do
        if turtle.up() then
            pos.y = pos.y + 1
            return true
        end

        sleep(MOVE_RETRY_DELAY)
    end

    emergencyStop(
        "Cannot move upward in the center shaft. " ..
        "The shaft may be obstructed."
    )
end

local function moveDown()
    ensureFuel(1)

    for attempt = 1, MOVE_RETRIES do
        if turtle.down() then
            pos.y = pos.y - 1
            return true
        end

        if ALLOW_CENTER_DIG_DOWN and pos.x == 0 and pos.z == 0 then
            local occupied, data = turtle.inspectDown()
            if occupied then
                if peripheralIsInventory("bottom") then
                    emergencyStop(
                        "Protected inventory detected below the center: " ..
                        tostring(data and data.name or "unknown inventory")
                    )
                end

                local dug, reason = turtle.digDown()
                if not dug then
                    emergencyStop(
                        "Cannot dig the next center-shaft block: " ..
                        tostring(reason)
                    )
                end
            end
        end

        sleep(MOVE_RETRY_DELAY)
    end

    emergencyStop(
        "Cannot move down. Pre-clear the center shaft or set " ..
        "ALLOW_CENTER_DIG_DOWN = true near the top of the script."
    )
end

-----------------------------------------------------------------------
-- Pathfinding
-----------------------------------------------------------------------

local neighborDirections = {
    { dx =  0, dz = -1, dir = NORTH },
    { dx =  1, dz =  0, dir = EAST  },
    { dx =  0, dz =  1, dir = SOUTH },
    { dx = -1, dz =  0, dir = WEST  },
}

-- Breadth-first search.
--
-- allowedMap is either:
--     interior: all calibrated cells may be crossed
--     carved:   only cells already entered on this layer may be crossed
--
-- Returns a list of directions.
local function findPath(startX, startZ, goalX, goalZ, allowedMap)
    if startX == goalX and startZ == goalZ then
        return {}
    end

    local startKey = key(startX, startZ)
    local goalKey = key(goalX, goalZ)

    if not allowedMap[startKey] then
        return nil, "start is not in allowed map"
    end

    if not allowedMap[goalKey] then
        return nil, "goal is not in allowed map"
    end

    local queue = {
        { x = startX, z = startZ }
    }

    local head = 1
    local visited = {
        [startKey] = true
    }

    -- cameFrom[childKey] = {
    --     previous = parentKey,
    --     direction = movement direction from parent to child
    -- }
    local cameFrom = {}

    while head <= #queue do
        local current = queue[head]
        head = head + 1

        for _, neighbor in ipairs(neighborDirections) do
            local nx = current.x + neighbor.dx
            local nz = current.z + neighbor.dz
            local neighborKey = key(nx, nz)

            if allowedMap[neighborKey] and not visited[neighborKey] then
                visited[neighborKey] = true
                cameFrom[neighborKey] = {
                    previous = key(current.x, current.z),
                    direction = neighbor.dir,
                }

                if neighborKey == goalKey then
                    local reversePath = {}
                    local cursor = goalKey

                    while cursor ~= startKey do
                        local entry = cameFrom[cursor]

                        if not entry then
                            return nil, "path reconstruction failed"
                        end

                        reversePath[#reversePath + 1] = entry.direction
                        cursor = entry.previous
                    end

                    local path = {}

                    for i = #reversePath, 1, -1 do
                        path[#path + 1] = reversePath[i]
                    end

                    return path
                end

                queue[#queue + 1] = {
                    x = nx,
                    z = nz,
                }
            end
        end
    end

    return nil, "no path found"
end

local function followOpenPath(path)
    for _, direction in ipairs(path) do
        turnTo(direction)

        local moved, reason = forwardOpen()

        if not moved then
            emergencyStop(
                "Known-open return path became blocked: " ..
                tostring(reason)
            )
        end
    end
end

-----------------------------------------------------------------------
-- Calibration
-----------------------------------------------------------------------

local function driveToNorthWall()
    print("Calibration: driving north to find outline...")

    turnTo(NORTH)

    while true do
        local occupied = recordObservedWall(0)

        if occupied then
            print(
                "North wall reached at interior coordinate X=" ..
                pos.x .. " Z=" .. pos.z
            )
            return
        end

        local moved, reason = forwardOpen()

        if not moved then
            emergencyStop(
                "Could not reach north wall: " .. tostring(reason)
            )
        end
    end
end

local function tracePerimeter()
    -- The turtle is immediately south of the north wall and facing north.
    -- Turn east so the wall is on its left.
    turnRight()

    local startX = pos.x
    local startZ = pos.z
    local startDirection = pos.dir

    local movementCount = 0
    local iterationCount = 0

    print("Calibration: tracing inside perimeter...")

    while true do
        iterationCount = iterationCount + 1

        if iterationCount > MAX_CALIBRATION_STEPS * 4 then
            emergencyStop(
                "Perimeter trace exceeded safety limit. " ..
                "Check that the outline is closed and the interior is clear."
            )
        end

        -- Left-hand wall follower:
        -- 1. Turn into an open left cell.
        -- 2. Otherwise continue forward if possible.
        -- 3. Otherwise rotate right.
        local leftBlocked = recordObservedWall(-1)

        if not leftBlocked then
            turnLeft()

            local moved, reason = forwardOpen()

            if not moved then
                emergencyStop(
                    "Calibration path changed unexpectedly: " ..
                    tostring(reason)
                )
            end

            movementCount = movementCount + 1
        else
            local frontBlocked = recordObservedWall(0)

            if not frontBlocked then
                local moved, reason = forwardOpen()

                if not moved then
                    emergencyStop(
                        "Calibration path changed unexpectedly: " ..
                        tostring(reason)
                    )
                end

                movementCount = movementCount + 1
            else
                turnRight()
            end
        end

        if movementCount > MAX_CALIBRATION_STEPS then
            emergencyStop(
                "Perimeter movement exceeded " ..
                MAX_CALIBRATION_STEPS .. " steps."
            )
        end

        if movementCount > 0
           and pos.x == startX
           and pos.z == startZ
           and pos.dir == startDirection then
            break
        end
    end

    print("Calibration: perimeter trace complete.")
end

local function buildInteriorMap()
    print("Calibration: flood-filling enclosed interior...")

    -- Wall observations define the blocking outline. Add one cell of
    -- padding around the observed wall bounds. If flood-fill reaches that
    -- padding edge, the wall is not closed or calibration missed a gap.
    local floodMinX = bounds.minX - 1
    local floodMaxX = bounds.maxX + 1
    local floodMinZ = bounds.minZ - 1
    local floodMaxZ = bounds.maxZ + 1

    local originKey = key(0, 0)

    if wall[originKey] then
        emergencyStop("The center origin was recorded as a wall.")
    end

    interior = {
        [originKey] = true
    }

    local queue = {
        { x = 0, z = 0 }
    }

    local head = 1
    local touchedOuterBoundary = false

    bounds.minX = 0
    bounds.maxX = 0
    bounds.minZ = 0
    bounds.maxZ = 0

    while head <= #queue do
        local current = queue[head]
        head = head + 1

        if current.x == floodMinX
           or current.x == floodMaxX
           or current.z == floodMinZ
           or current.z == floodMaxZ then
            touchedOuterBoundary = true
        end

        updateBounds(current.x, current.z)

        for _, neighbor in ipairs(neighborDirections) do
            local nx = current.x + neighbor.dx
            local nz = current.z + neighbor.dz
            local neighborKey = key(nx, nz)

            local insideFloodBounds =
                nx >= floodMinX and nx <= floodMaxX
                and nz >= floodMinZ and nz <= floodMaxZ

            if insideFloodBounds
               and not wall[neighborKey]
               and not interior[neighborKey] then
                interior[neighborKey] = true
                queue[#queue + 1] = {
                    x = nx,
                    z = nz,
                }
            end
        end
    end

    if touchedOuterBoundary then
        emergencyStop(
            "Flood-fill escaped the outline. The wall may have a gap, " ..
            "the outline may not be closed, or calibration encountered " ..
            "an interior obstacle."
        )
    end

    local count = 0

    for _ in pairs(interior) do
        count = count + 1
    end

    print("Calibration: mapped " .. count .. " interior cells.")
    print(
        "Bounds: X=" .. bounds.minX .. ".." .. bounds.maxX ..
        ", Z=" .. bounds.minZ .. ".." .. bounds.maxZ
    )
end

local function returnToCenterAfterCalibration()
    print("Calibration: returning to center...")

    local path, reason = findPath(
        pos.x,
        pos.z,
        0,
        0,
        interior
    )

    if not path then
        emergencyStop(
            "Cannot return to center after calibration: " ..
            tostring(reason)
        )
    end

    followOpenPath(path)
    turnTo(NORTH)

    print("Calibration complete. Turtle is at center facing north.")
end

local function sanitizeMapName(name)
    name = tostring(name or "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w%-%_ ]", "")
    name = name:gsub("%s+", "_")
    name = name:sub(1, 32)

    if name == "" then
        return nil
    end

    return name
end

local function mapPath(name)
    return fs.combine(MAP_DIR, name .. ".db")
end

local function ensureMapDirectory()
    if fs.exists(MAP_DIR) then
        if not fs.isDir(MAP_DIR) then
            emergencyStop(MAP_DIR .. " exists but is not a directory.")
        end
        return
    end

    fs.makeDir(MAP_DIR)
end

local function countCells(map)
    local count = 0
    for _ in pairs(map or {}) do count = count + 1 end
    return count
end

local function saveMap(name)
    ensureMapDirectory()

    local cleanName = sanitizeMapName(name)
    if not cleanName then
        emergencyStop("Invalid map name.")
    end

    local path = mapPath(cleanName)
    local data = {
        version = 2,
        name = cleanName,
        created = os.epoch and os.epoch("utc") or nil,
        interior = interior,
        bounds = bounds,
        cellCount = countCells(interior),
    }

    local handle, reason = fs.open(path, "w")
    if not handle then
        emergencyStop("Cannot save map: " .. tostring(reason))
    end

    handle.write(textutils.serialize(data))
    handle.close()

    selectedMapName = cleanName
    selectedMapFile = path
    print("Map saved as '" .. cleanName .. "' in " .. path)
end

local function loadMapFile(path, fallbackName)
    if not fs.exists(path) or fs.isDir(path) then
        return false, "Map file does not exist."
    end

    local handle, openError = fs.open(path, "r")
    if not handle then
        return false, "Could not open map: " .. tostring(openError)
    end

    local raw = handle.readAll()
    handle.close()

    local data = textutils.unserialize(raw)
    if type(data) ~= "table" then
        return false, "Map file does not contain a valid table."
    end
    if type(data.interior) ~= "table" then
        return false, "Map file has no valid interior map."
    end
    if type(data.bounds) ~= "table" then
        return false, "Map file has no valid bounds."
    end
    if not data.interior[key(0, 0)] then
        return false, "Saved map does not contain the center coordinate."
    end

    interior = data.interior
    bounds = data.bounds
    selectedMapName = sanitizeMapName(data.name) or fallbackName or "unnamed"
    selectedMapFile = path

    return true, data
end

local function listSavedMaps()
    ensureMapDirectory()
    local maps = {}

    for _, filename in ipairs(fs.list(MAP_DIR)) do
        if filename:sub(-3) == ".db" then
            local path = fs.combine(MAP_DIR, filename)
            if not fs.isDir(path) then
                maps[#maps + 1] = {
                    name = filename:sub(1, -4),
                    path = path,
                    legacy = false,
                }
            end
        end
    end

    table.sort(maps, function(a, b)
        return a.name:lower() < b.name:lower()
    end)

    if fs.exists(LEGACY_MAP_FILE) and not fs.isDir(LEGACY_MAP_FILE) then
        table.insert(maps, 1, {
            name = "legacy_roomba_map",
            path = LEGACY_MAP_FILE,
            legacy = true,
        })
    end

    return maps
end

local function askForNewMapName()
    while true do
        print("")
        write("Name this calibration: ")
        local cleanName = sanitizeMapName(read())

        if not cleanName then
            print("Use letters, numbers, spaces, hyphens, or underscores.")
        else
            local path = mapPath(cleanName)
            if fs.exists(path) then
                write("A map named '" .. cleanName .. "' exists. Type OVERWRITE: ")
                if read() == "OVERWRITE" then
                    return cleanName
                end
                print("Choose another name.")
            else
                return cleanName
            end
        end
    end
end

local function chooseMapOrCalibration()
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("ROOOMBA MAP LIBRARY")
        print("==================")
        print("N) Calibrate and save a new shape")

        local maps = listSavedMaps()
        for i, entry in ipairs(maps) do
            local suffix = entry.legacy and " (old map)" or ""
            print(i .. ") " .. entry.name .. suffix)
        end

        print("")
        write("Choose N or a map number: ")
        local choice = read()

        if choice:lower() == "n" then
            local name = askForNewMapName()
            return "calibrate", name
        end

        local index = tonumber(choice)
        local entry = index and maps[index] or nil
        if entry then
            local loaded, result = loadMapFile(entry.path, entry.name)
            if loaded then
                print("")
                print("Selected map: " .. selectedMapName)
                print("Cells: " .. countCells(interior))
                print(
                    "Bounds: X=" .. bounds.minX .. ".." .. bounds.maxX ..
                    ", Z=" .. bounds.minZ .. ".." .. bounds.maxZ
                )
                return "load", entry
            end

            print("Could not load that map: " .. tostring(result))
            print("Press Enter to return to the menu.")
            read()
        else
            print("Invalid selection. Press Enter.")
            read()
        end
    end
end

local function calibrate(mapName)
    wall = {}
    interior = {}

    bounds = {
        minX = 0,
        maxX = 0,
        minZ = 0,
        maxZ = 0,
    }

    driveToNorthWall()
    tracePerimeter()
    buildInteriorMap()
    returnToCenterAfterCalibration()
    saveMap(mapName)
end

-----------------------------------------------------------------------
-- Fast sweep route generation
-----------------------------------------------------------------------

local function directionBetween(x1, z1, x2, z2)
    if x2 == x1 and z2 == z1 - 1 then return NORTH end
    if x2 == x1 + 1 and z2 == z1 then return EAST end
    if x2 == x1 and z2 == z1 + 1 then return SOUTH end
    if x2 == x1 - 1 and z2 == z1 then return WEST end
    return nil
end

-- Produces boustrophedon targets, row by row. Within a normal circle,
-- nearly every consecutive target is adjacent. BFS is used only for gaps
-- or row transitions that are not directly connected.
local function buildSweepTargets()
    local rows = {}

    for coordinate in pairs(interior) do
        local x, z = parseKey(coordinate)
        rows[z] = rows[z] or {}
        rows[z][#rows[z] + 1] = x
    end

    local zValues = {}
    for z in pairs(rows) do zValues[#zValues + 1] = z end
    table.sort(zValues)

    local targets = {}
    local leftToRight = true

    for _, z in ipairs(zValues) do
        local xs = rows[z]
        table.sort(xs)

        if leftToRight then
            for _, x in ipairs(xs) do
                targets[#targets + 1] = { x = x, z = z }
            end
        else
            for i = #xs, 1, -1 do
                targets[#targets + 1] = { x = xs[i], z = z }
            end
        end

        leftToRight = not leftToRight
    end

    return targets
end

local function appendRouteMove(route, direction)
    local last = route[#route]
    if last and last.direction == direction then
        last.count = last.count + 1
    else
        route[#route + 1] = { direction = direction, count = 1 }
    end
end

local function buildFastRoute(targets)
    local route = {}
    local moveCount = 0
    local vx, vz = 0, 0

    for _, target in ipairs(targets) do
        if vx ~= target.x or vz ~= target.z then
            local direct = directionBetween(vx, vz, target.x, target.z)

            if direct then
                appendRouteMove(route, direct)
                moveCount = moveCount + 1
            else
                local path, reason = findPath(
                    vx, vz, target.x, target.z, interior
                )

                if not path then
                    emergencyStop(
                        "Cannot build sweep route to X=" .. target.x ..
                        " Z=" .. target.z .. ": " .. tostring(reason)
                    )
                end

                for _, direction in ipairs(path) do
                    appendRouteMove(route, direction)
                    moveCount = moveCount + 1
                end
            end

            vx, vz = target.x, target.z
        end
    end

    return route, moveCount
end

-----------------------------------------------------------------------
-- Chest unloading and vertical travel
-----------------------------------------------------------------------

local function routeToCenterOnCarvedCells()
    if pos.x == 0 and pos.z == 0 then
        return
    end

    local path, reason = findPath(
        pos.x,
        pos.z,
        0,
        0,
        carved
    )

    if not path then
        emergencyStop(
            "Cannot find an already-carved path back to center: " ..
            tostring(reason)
        )
    end

    followOpenPath(path)
end

local function ascendToSurface()
    if pos.x ~= 0 or pos.z ~= 0 then
        emergencyStop("Vertical travel attempted away from center shaft.")
    end

    while pos.y < 0 do
        moveUp()
    end

    if pos.y ~= 0 then
        emergencyStop("Unexpected Y-coordinate while ascending.")
    end
end

local function descendToDepth(depth)
    if pos.x ~= 0 or pos.z ~= 0 or pos.y ~= 0 then
        emergencyStop(
            "Depth descent must begin at the surface center."
        )
    end

    for _ = 1, depth do
        moveDown()
    end

    if pos.y ~= -depth then
        emergencyStop("Depth tracking mismatch after descent.")
    end
end

local function waitForOutputInventory()
    while not topIsInventory() do
        term.setTextColor(colors.yellow)
        print("No compatible output inventory detected above the origin.")
        print("Place/fix the chest, crate, or other inventory, then press Enter.")
        term.setTextColor(colors.white)
        read()
    end
end

local function dumpInventoryUp()
    if pos.x ~= 0 or pos.z ~= 0 or pos.y ~= 0 then
        emergencyStop(
            "Inventory dumping must occur at surface origin X=0 Y=0 Z=0."
        )
    end

    waitForOutputInventory()
    print("Unloading into overhead inventory...")

    for slot = FIRST_STORAGE_SLOT, LAST_STORAGE_SLOT do
        while turtle.getItemCount(slot) > 0 do
            turtle.select(slot)
            local before = turtle.getItemCount(slot)
            turtle.dropUp()
            local after = turtle.getItemCount(slot)

            if after >= before then
                term.setTextColor(colors.yellow)
                print("Output inventory is full or cannot accept slot " .. slot .. ".")
                print("Make space or repair it, then press Enter to retry.")
                term.setTextColor(colors.white)
                read()
                waitForOutputInventory()
            end
        end
    end

    turtle.select(FUEL_SLOT)

    if storageHasItems() then
        emergencyStop("Storage slots still contain items after unloading.")
    end
end

local function unloadAndReturnToCheckpoint(depth, checkpointX, checkpointZ)
    routeToCenterOnCarvedCells()
    ascendToSurface()
    dumpInventoryUp()
    descendToDepth(depth)

    carved[key(0, 0)] = true

    if checkpointX ~= 0 or checkpointZ ~= 0 then
        local path, reason = findPath(
            0, 0, checkpointX, checkpointZ, carved
        )

        if not path then
            emergencyStop(
                "Cannot return to excavation checkpoint X=" ..
                checkpointX .. " Z=" .. checkpointZ .. ": " ..
                tostring(reason)
            )
        end

        followOpenPath(path)
    end
end

local function requiredFuelForUnloadAndReturn(depth)
    if fuelLevel() == "unlimited" then return 0 end

    local path, reason = findPath(pos.x, pos.z, 0, 0, carved)
    if not path then
        emergencyStop(
            "Cannot calculate emergency fuel reserve: " .. tostring(reason)
        )
    end

    return (#path * 2) + (depth * 2) + FUEL_SAFETY_MARGIN
end

local function maintainReturnFuelReserve(depth)
    ensureFuel(requiredFuelForUnloadAndReturn(depth))
end

-----------------------------------------------------------------------
-- Fast route execution
-----------------------------------------------------------------------

local function excavateLayer(depth, route, routeMoveCount, interiorCount)
    print("")
    print(
        "Excavating layer " .. (depth + 1) .. "/" .. totalLayers ..
        " at Y=" .. (-depth)
    )

    carved = { [key(0, 0)] = true }

    local uniqueVisited = 1
    local visited = { [key(0, 0)] = true }
    local movementSinceInventoryCheck = 0
    local completedMoves = 0

    for _, run in ipairs(route) do
        turnTo(run.direction)

        for _ = 1, run.count do
            local moved, reason, dugBlock = forwardMining()

            if not moved then
                emergencyStop(
                    "Could not follow precomputed route: " .. tostring(reason)
                )
            end

            completedMoves = completedMoves + 1
            local currentKey = key(pos.x, pos.z)
            if not visited[currentKey] then
                visited[currentKey] = true
                uniqueVisited = uniqueVisited + 1
            end

            movementSinceInventoryCheck = movementSinceInventoryCheck + 1

            if dugBlock or movementSinceInventoryCheck >= INVENTORY_CHECK_INTERVAL then
                movementSinceInventoryCheck = 0
                maintainReturnFuelReserve(depth)

                if inventoryNeedsUnload() then
                    local checkpointX, checkpointZ = pos.x, pos.z
                    print("Storage slots occupied; unloading and returning to checkpoint.")
                    unloadAndReturnToCheckpoint(depth, checkpointX, checkpointZ)
                    turnTo(run.direction)
                end
            end

            if completedMoves % 250 == 0 or completedMoves == routeMoveCount then
                print(
                    "Route progress: " .. completedMoves .. "/" ..
                    routeMoveCount .. " moves; mapped cells " ..
                    math.min(uniqueVisited, interiorCount) .. "/" ..
                    interiorCount
                )
            end
        end
    end

    for coordinate in pairs(interior) do
        if not carved[coordinate] then
            emergencyStop(
                "Layer verification failed; cell " .. coordinate ..
                " was not reached."
            )
        end
    end

    print("Layer fully completed.")
    routeToCenterOnCarvedCells()
    ascendToSurface()
    dumpInventoryUp()
    turnTo(NORTH)
end

-----------------------------------------------------------------------
-- Fuel estimate
-----------------------------------------------------------------------

local function countInteriorCells()
    local count = 0

    for _ in pairs(interior) do
        count = count + 1
    end

    return count
end

local function prepareFuelForJob()
    -- Fuel is checked before every movement. Requiring the whole job's
    -- estimated fuel up front can exceed what slot 1 can physically hold.
    ensureFuel(DEFAULT_FUEL_TARGET)
end

-----------------------------------------------------------------------
-- Main
-----------------------------------------------------------------------

local function confirmSavedMapPlacement()
    print("")
    print("SAVED MAP PLACEMENT CHECK")
    print("-------------------------")
    print("The turtle must currently be:")
    print("1. At the exact same X/Z center as calibration.")
    print("2. Facing NORTH.")
    print("3. Directly below a compatible output inventory.")
    if ALLOW_CENTER_DIG_DOWN then
        print("4. Center-only digDown is enabled for layer transitions.")
    else
        print("4. Above a pre-cleared vertical center shaft.")
    end
    print("")
    write("Type YES to continue: ")

    local response = read()

    if response ~= "YES" then
        error("Startup cancelled by user.", 0)
    end
end

local function main()
    term.clear()
    term.setCursorPos(1, 1)

    print("CC:Tweaked Fast Roomba Excavator")
    print("===========================")
    print("Requested layers: " .. totalLayers)
    print("")
    print("Do not rotate or move the turtle after starting.")
    print("Slot 1 is reserved for fuel; slots 2-16 hold mined items.")
    print("")

    ensureFuel(DEFAULT_FUEL_TARGET)

    local action, selection = chooseMapOrCalibration()

    if action == "calibrate" then
        print("")
        print("New calibration: " .. selection)
        print("The turtle must be at the shape center and face NORTH.")
        print("The closed wall outline must be present on this level.")
        write("Type CALIBRATE to begin: ")
        if read() ~= "CALIBRATE" then
            error("Startup cancelled by user.", 0)
        end
        calibrate(selection)
    else
        print("Loaded saved map '" .. selectedMapName .. "' from " .. selectedMapFile)
        confirmSavedMapPlacement()
    end

    prepareFuelForJob()

    local targets = buildSweepTargets()
    local route, routeMoveCount = buildFastRoute(targets)
    local interiorCount = countInteriorCells()
    local width = bounds.maxX - bounds.minX + 1
    local length = bounds.maxZ - bounds.minZ + 1
    local maxBlocks = interiorCount * totalLayers

    print("")
    print("JOB SUMMARY")
    print("-----------")
    print("Map: " .. tostring(selectedMapName))
    print("Dimensions: " .. width .. " x " .. length)
    print("Mapped cells per layer: " .. interiorCount)
    print("Requested layers: " .. totalLayers)
    print("Maximum blocks/cells: " .. maxBlocks)
    print("Compact route runs: " .. #route)
    print("Route moves per layer: " .. routeMoveCount)
    print("Center dig-down: " .. (ALLOW_CENTER_DIG_DOWN and "ENABLED" or "disabled"))
    print("")
    waitForOutputInventory()
    write("Type START to begin excavation: ")
    if read() ~= "START" then
        error("Startup cancelled by user.", 0)
    end

    for depth = 0, totalLayers - 1 do
        -- Every completed layer leaves the turtle at surface origin.
        -- Descend through the pre-cleared shaft to the next work level.
        if depth > 0 then
            descendToDepth(depth)
        end

        excavateLayer(depth, route, routeMoveCount, interiorCount)
    end

    print("")
    term.setTextColor(colors.lime)
    print("Excavation complete.")
    print("All requested layers were swept and unloaded.")
    print("Turtle is at X=0 Y=0 Z=0 facing north.")
    term.setTextColor(colors.white)
end

local ok, failure = pcall(main)

if not ok then
    term.setTextColor(colors.red)
    print("")
    print("Program terminated:")
    print(tostring(failure))
    term.setTextColor(colors.white)
end