-- Roomba Hive v0.1.2 runtime patcher
-- This patches the installed v0.1.1 controller or worker in-place.
-- Usage: patch_v012.lua controller|worker

local args = { ... }
local role = args[1] and args[1]:lower() or nil

local paths = {
    controller = "/roomba/controller.lua",
    worker = "/roomba/worker.lua",
}

local path = paths[role]
if not path then error("Usage: patch_v012.lua controller|worker", 0) end
if not fs.exists(path) then error("Missing installed file: " .. path, 0) end

local h = assert(fs.open(path, "r"))
local source = h.readAll()
h.close()

local function whitespacePattern(text)
    local parts = {}
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        if c:match("%s") then
            while i <= #text and text:sub(i, i):match("%s") do i = i + 1 end
            parts[#parts + 1] = "%s+"
        else
            if c:match("[%^%$%(%)%%%.%[%]%*%+%-%?]") then
                parts[#parts + 1] = "%" .. c
            else
                parts[#parts + 1] = c
            end
            i = i + 1
        end
    end
    return table.concat(parts)
end

local function replaceOnce(old, new, label)
    local pattern = whitespacePattern(old)
    local firstStart, firstEnd = source:find(pattern)
    if not firstStart then
        error("Patch failed (" .. label .. "): expected source structure was not found.", 0)
    end
    if source:find(pattern, firstEnd + 1) then
        error("Patch failed (" .. label .. "): source structure appeared more than once.", 0)
    end
    source = source:sub(1, firstStart - 1) .. new .. source:sub(firstEnd + 1)
end

local function replacePattern(pattern, new, label)
    local firstStart, firstEnd = source:find(pattern)
    if not firstStart then
        error("Patch failed (" .. label .. "): flexible source pattern was not found.", 0)
    end
    source = source:sub(1, firstStart - 1) .. new .. source:sub(firstEnd + 1)
end

if role == "controller" then
    replaceOnce(
        '-- Roomba Hive Controller v0.1.1',
        '-- Roomba Hive Controller v0.1.2',
        "controller header"
    )
    replaceOnce(
        'local VERSION = "0.1.1"',
        'local VERSION = "0.1.2"',
        "controller version"
    )
    replaceOnce(
        '    print("[W] Workers       [P] Pause      [R] Resume")\n    print("[M] Maps          [Q] Quit UI")',
        '    print("[W] Workers       [P] Pause      [R] Resume")\n    print("[A] Abort job     [M] Maps       [Q] Quit UI")',
        "controller menu"
    )

    local abortFunction = [[
local function abortJob()
    if not state.job or (state.job.status ~= "running" and state.job.status ~= "paused") then
        print("\nNo running or paused job to abort.")
        sleep(2)
        return
    end

    print("\nABORT ACTIVE JOB")
    print("Workers will stop at the next safe movement boundary,")
    print("return through already carved paths, unload, and remain docked.")
    print("A worker whose program has already crashed cannot receive Abort.")
    write("Type ABORT to confirm: ")
    if read() ~= "ABORT" then return end

    state.job.status = "aborting"
    state.job.abortAcks = {}
    if state.job.layerState then
        for layer, layerStatus in pairs(state.job.layerState) do
            if layerStatus ~= "complete" then state.job.layerState[layer] = "aborted" end
        end
    end
    saveState()
    broadcast("abort", { jobId = state.job.id })
    print("Abort sent. Workers are returning when safe.")
    sleep(2)
end

]]
    replaceOnce(
        'local function workersView()',
        abortFunction .. 'local function workersView()',
        "controller abort function"
    )

    replaceOnce(
        '    elseif msg.type == "section_complete" then\n        w.status = "docked"; w.layer=nil',
        '    elseif msg.type == "worker_aborted" then\n'
        .. '        w.status = "aborted"; w.layer = nil\n'
        .. '        if state.job then\n'
        .. '            state.job.abortAcks = state.job.abortAcks or {}\n'
        .. '            state.job.abortAcks[tostring(sender)] = true\n'
        .. '            local allAcknowledged = true\n'
        .. '            for _, section in ipairs(state.job.sections or {}) do\n'
        .. '                if not state.job.abortAcks[tostring(section.worker)] then allAcknowledged = false break end\n'
        .. '            end\n'
        .. '            if allAcknowledged then state.job.status = "aborted" end\n'
        .. '        end\n'
        .. '        if validDock(w.dock) and tostring(state.docks[w.dock]) == tostring(sender) then\n'
        .. '            state.dockOccupancy[w.dock] = sender\n'
        .. '        end\n'
        .. '    elseif msg.type == "section_complete" then\n'
        .. '        w.status = "docked"; w.layer=nil',
        "controller abort acknowledgement"
    )

    replaceOnce(
        '        elseif ch == "w" then workersView()\n        elseif ch == "m" then mapsView()',
        '        elseif ch == "w" then workersView()\n'
        .. '        elseif ch == "a" then abortJob()\n'
        .. '        elseif ch == "m" then mapsView()',
        "controller abort key"
    )

elseif role == "worker" then
    replaceOnce(
        '-- Roomba Hive Worker v0.1.1',
        '-- Roomba Hive Worker v0.1.2',
        "worker header"
    )
    replaceOnce(
        'local VERSION = "0.1.1"',
        'local VERSION = "0.1.2"',
        "worker version"
    )
    replaceOnce(
        'local FUEL_TARGET = 2048',
        'local FUEL_TARGET = 2048\nlocal FUEL_ITEM_RESERVE = 5',
        "fuel reserve constant"
    )
    replaceOnce(
        'local paused=false',
        'local paused=false\nlocal abortRequested=false\nlocal fuelLockHeld=false',
        "worker control flags"
    )

    replacePattern(
        '%s+while fuelLevel%(%)[<]target and turtle%.getItemCount%(FUEL_SLOT%)[>]0 do',
        '\n  while fuelLevel()<target and turtle.getItemCount(FUEL_SLOT)>FUEL_ITEM_RESERVE do',
        "preserve five fuel items"
    )

    local storageHelpers = [[
local function findStorageSlot()
 for s=FIRST_STORAGE_SLOT,LAST_STORAGE_SLOT do
  local detail=turtle.getItemDetail(s)
  if not detail then return s end
  local limit=detail.maxCount or 64
  if turtle.getItemCount(s)<limit then return s end
 end
 return nil
end

local function selectStorageSlotOrFail()
 local slot=findStorageSlot()
 if not slot then reportError("Storage slots 2-16 are full before digging.") end
 turtle.select(slot)
 return slot
end

]]
    replaceOnce(
        'local function protectedBlock(data)',
        storageHelpers .. 'local function protectedBlock(data)',
        "storage slot helpers"
    )

    replaceOnce(
        '    local ok,reason=turtle.dig()',
        '    selectStorageSlotOrFail()\n    local ok,reason=turtle.dig()',
        "front dig storage selection"
    )
    replaceOnce(
        '   local ok,reason=turtle.digDown();if not ok then reportError("Cannot dig shaft downward: "..tostring(reason)) end',
        '   selectStorageSlotOrFail()\n'
        .. '   local ok,reason=turtle.digDown();if not ok then reportError("Cannot dig shaft downward: "..tostring(reason)) end',
        "down dig storage selection"
    )

    local controlHelpers = [[
local function applyControlMessage(msg)
 if type(msg)~="table" then return end
 if msg.type=="pause" then
  paused=true
 elseif msg.type=="resume" then
  paused=false
 elseif msg.type=="abort" then
  abortRequested=true
  paused=false
 end
end

local function pollControl()
 while true do
  local id,msg,proto=rednet.receive(PROTOCOL,0)
  if not id then return end
  if id==controller and proto==PROTOCOL then applyControlMessage(msg) end
 end
end

]]
    replaceOnce(
        'local function requestFuelLock()',
        controlHelpers .. 'local function requestFuelLock()',
        "live control polling"
    )

    replaceOnce(
        ' if fuelLevel()=="unlimited" then return end\n requestFuelLock();state.status="refueling";persist()',
        ' if fuelLevel()=="unlimited" then return end\n'
        .. ' requestFuelLock();fuelLockHeld=true;state.status="refueling";persist()',
        "track fuel lock"
    )

    replaceOnce(
        '  while fuelLevel()<math.max(required,FUEL_TARGET) do\n'
        .. '   if turtle.getItemCount(FUEL_SLOT)==0 then\n'
        .. '    if not turtle.suck(64) then state.status="waiting_for_fuel";persist();send("heartbeat",{status="waiting_for_fuel",fuel=fuelLevel()});sleep(5) end\n'
        .. '   end\n'
        .. '   if turtle.getItemCount(FUEL_SLOT)>0 and not turtle.refuel(1) then send("fuel_lock_release",{});reportError("Fuel chest supplied a non-fuel item. Fuel chest must contain fuel only.") end\n'
        .. '  end',
        '  while fuelLevel()<math.max(required,FUEL_TARGET) or turtle.getItemCount(FUEL_SLOT)<=FUEL_ITEM_RESERVE do\n'
        .. '   pollControl()\n'
        .. '   if abortRequested then break end\n'
        .. '   if turtle.getItemCount(FUEL_SLOT)<=FUEL_ITEM_RESERVE then\n'
        .. '    if not turtle.suck(64) then state.status="waiting_for_fuel";persist();send("heartbeat",{status="waiting_for_fuel",fuel=fuelLevel(),dock=dock});sleep(2) end\n'
        .. '   end\n'
        .. '   if turtle.getItemCount(FUEL_SLOT)>FUEL_ITEM_RESERVE then\n'
        .. '    if not turtle.refuel(1) then send("fuel_lock_release",{});fuelLockHeld=false;reportError("Fuel chest supplied a non-fuel item. Fuel chest must contain fuel only.") end\n'
        .. '   end\n'
        .. '  end',
        "fuel station reserve loop"
    )

    replaceOnce(
        ' send("fuel_lock_release",{});state.status="docked";persist()',
        ' send("fuel_lock_release",{});fuelLockHeld=false;state.status="docked";persist()',
        "release fuel lock flag"
    )

    local abortHelpers = [[
local function abortFromMining()
 state.status="aborting";persist()
 if pos.y<0 then
  routeCenter()
  returnToDockFromCenter()
 end
 if fuelLockHeld then send("fuel_lock_release",{});fuelLockHeld=false end
 if pos.y==0 then dumpUp() end
 state.status="aborted"
 state.layer=nil
 state.jobId=nil
 state.firstLayer=nil
 state.lastLayer=nil
 persist()
 send("worker_aborted",{dock=dock,position=pos})
 error("__ROOMBA_ABORTED__",0)
end

]]
    replaceOnce(
        'local function handleControlNonblocking()',
        abortHelpers .. 'local function handleControlNonblocking()',
        "worker abort return"
    )

    replaceOnce(
        'local function waitIfPaused()\n'
        .. ' while paused do state.status="paused";persist();send("heartbeat",{status="paused",layer=state.layer,fuel=fuelLevel(),position=pos});local id,msg,proto=rednet.receive(PROTOCOL,2);if id==controller and type(msg)=="table" and msg.type=="resume" then paused=false end end\n'
        .. 'end',
        'local function waitIfPaused()\n'
        .. ' pollControl()\n'
        .. ' if abortRequested then abortFromMining() end\n'
        .. ' while paused do\n'
        .. '  state.status="paused";persist();send("heartbeat",{status="paused",layer=state.layer,fuel=fuelLevel(),position=pos,dock=dock})\n'
        .. '  local id,msg,proto=rednet.receive(PROTOCOL,1)\n'
        .. '  if id==controller and proto==PROTOCOL then applyControlMessage(msg) end\n'
        .. '  if abortRequested then abortFromMining() end\n'
        .. ' end\n'
        .. ' state.status="mining";persist()\n'
        .. 'end',
        "working pause and abort"
    )

    replaceOnce(
        '  for layer=msg.firstLayer,msg.lastLayer do goCenterForLayer(layer);excavateLayer(layer,route,moves) end',
        '  if turtle.getItemCount(FUEL_SLOT)<=FUEL_ITEM_RESERVE then refuelAtStation(msg.lastLayer*2+FUEL_MARGIN) end\n'
        .. '  for layer=msg.firstLayer,msg.lastLayer do\n'
        .. '   pollControl()\n'
        .. '   if abortRequested then abortFromMining() end\n'
        .. '   goCenterForLayer(layer);excavateLayer(layer,route,moves)\n'
        .. '  end',
        "section control and initial fuel reserve"
    )

    replaceOnce(
        '    elseif msg.type=="pause" then paused=true\n'
        .. '    elseif msg.type=="resume" then paused=false',
        '    elseif msg.type=="pause" then paused=true\n'
        .. '    elseif msg.type=="resume" then paused=false\n'
        .. '    elseif msg.type=="abort" then abortRequested=true;paused=false',
        "command loop abort"
    )

    replaceOnce(
        '    if fuelLevel()~="unlimited" and fuelLevel()<reserve then',
        '    if fuelLevel()~="unlimited" and (fuelLevel()<reserve or turtle.getItemCount(FUEL_SLOT)<=FUEL_ITEM_RESERVE) then',
        "return when five fuel items remain"
    )
end

local backup = path .. ".v011"
if not fs.exists(backup) then fs.copy(path, backup) end

local tmp = path .. ".v012.new"
local out = assert(fs.open(tmp, "w"))
out.write(source)
out.close()
fs.delete(path)
fs.move(tmp, path)

print("Roomba Hive v0.1.2 patch applied to " .. role .. ".")
