-- Roomba Hive Pocket v0.3.5
-- Secure remote dashboard for an Advanced Wireless/Ender Pocket Computer.

local VERSION = "0.3.5"
local PROTOCOL_VERSION = 2
local REMOTE_PROTOCOL = "roomba_hive_remote_v1"
local REMOTE_HOSTNAME = "roomba-hive-remote"
local INSTALL_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua"
local ROOT = "/roomba"
local STATE_FILE = fs.combine(ROOT, "pocket_state.db")
local CRYPTO_FILE = fs.combine(ROOT, "crypto.lua")
local BOOT_FILE = fs.combine(ROOT, "boot.lua")
local REQUEST_TIMEOUT = 8
local DEFAULT_IDLE_LOCK = 300

if not fs.exists(ROOT) then fs.makeDir(ROOT) end
assert(fs.exists(CRYPTO_FILE), "Missing /roomba/crypto.lua. Reinstall the pocket program.")
local crypto = dofile(CRYPTO_FILE)

local modem = peripheral.find("modem", function(_, device)
    return device.isWireless and device.isWireless()
end)
assert(modem, "Roomba Pocket requires a wireless or ender modem.")
local modemSide = peripheral.getName(modem)
rednet.open(modemSide)

local function saveTable(path, value)
    local temporary = path .. ".tmp"
    local handle = assert(fs.open(temporary, "w"))
    handle.write(textutils.serialize(value))
    handle.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(temporary, path)
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
state.controllers = state.controllers or {}
state.activeController = state.activeController or nil
state.alerts = state.alerts or {}
state.idleLockSeconds = state.idleLockSeconds or DEFAULT_IDLE_LOCK
state.alertSettings = state.alertSettings or {
    error = true,
    warning = true,
    success = true,
    info = true,
    sound = true,
}

local alertSpeaker = peripheral.find("speaker")
local pendingResponses = {}
local running = true
local locked = false
local lastActivity = os.epoch("utc")
local pairing = nil
local statusCache = nil
local statusCacheAt = 0

local function persist()
    state.version = VERSION
    saveTable(STATE_FILE, state)
end

local function activeController()
    return state.activeController and state.controllers[tostring(state.activeController)] or nil
end

local function roleRank(role)
    if role == "administrator" then return 3 end
    if role == "operator" then return 2 end
    return 1
end

local function trim(value, width)
    value = tostring(value or "")
    if #value <= width then return value end
    return value:sub(1, math.max(1, width - 3)) .. "..."
end

local function clear(title)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear(); term.setCursorPos(1, 1)
    if title then
        term.setTextColor(colors.yellow)
        print(title)
        term.setTextColor(colors.white)
        print(string.rep("=", math.min(#title, select(1, term.getSize()))))
    end
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

local function allLayers(totalLayers)
    local output = {}
    for layer = 1, totalLayers do output[#output + 1] = layer end
    return output
end

local function normalizeLayerList(layers, totalLayers)
    totalLayers = tonumber(totalLayers)
    if not totalLayers or totalLayers < 1 or totalLayers % 1 ~= 0 then return nil, "Total layers must be a positive whole number." end
    if type(layers) ~= "table" then return nil, "Layer selection must be a list." end
    local seen, output = {}, {}
    for index, value in ipairs(layers) do
        local layer = tonumber(value)
        if not layer or layer % 1 ~= 0 then return nil, "Layer entry " .. tostring(index) .. " is not a whole number." end
        if layer < 1 or layer > totalLayers then return nil, "Layer " .. tostring(layer) .. " is outside 1-" .. tostring(totalLayers) .. "." end
        if not seen[layer] then seen[layer] = true; output[#output + 1] = layer end
    end
    table.sort(output)
    if #output == 0 then return nil, "At least one layer must be scheduled." end
    return output
end

local function parseLayerSpec(spec, totalLayers, allowNone)
    local trimmed = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if allowNone and (trimmed == "" or trimmed:lower() == "none") then return {} end
    if trimmed == "" then return nil, "Enter at least one layer." end
    local output, tokenNumber = {}, 0
    for rawToken in (trimmed .. ","):gmatch("(.-),") do
        tokenNumber = tokenNumber + 1
        local token = rawToken:gsub("^%s+", ""):gsub("%s+$", "")
        if token == "" then return nil, "Entry " .. tostring(tokenNumber) .. " is empty. Remove extra commas." end
        local first, last = token:match("^(%d+)%s*%-%s*(%d+)$")
        if first then
            first, last = tonumber(first), tonumber(last)
            if first > last then return nil, "Range " .. token .. " runs backwards." end
            for layer = first, last do output[#output + 1] = layer end
        else
            local single = token:match("^(%d+)$")
            if not single then return nil, "Entry '" .. token .. "' is invalid." end
            output[#output + 1] = tonumber(single)
        end
    end
    if #output == 0 and allowNone then return {} end
    return normalizeLayerList(output, totalLayers)
end

local function layerSet(layers)
    local output = {}
    for _, layer in ipairs(layers or {}) do output[tonumber(layer)] = true end
    return output
end

local function complementLayers(selectedLayers, totalLayers)
    local selected, output = layerSet(selectedLayers), {}
    for layer = 1, totalLayers do if not selected[layer] then output[#output + 1] = layer end end
    return output
end

local function compactLayerList(layers)
    if type(layers) ~= "table" or #layers == 0 then return "none" end
    local copy = {}
    for _, layer in ipairs(layers) do copy[#copy + 1] = tonumber(layer) end
    table.sort(copy)
    local parts, index = {}, 1
    while index <= #copy do
        local first, last = copy[index], copy[index]
        while index < #copy and copy[index + 1] == last + 1 do index = index + 1; last = copy[index] end
        parts[#parts + 1] = first == last and tostring(first) or (tostring(first) .. "-" .. tostring(last))
        index = index + 1
    end
    return table.concat(parts, ", ")
end

local function friendlyLayerList(layers)
    if type(layers) ~= "table" or #layers == 0 then return "none" end
    if #layers <= 12 then
        local parts = {}
        for _, layer in ipairs(layers) do parts[#parts + 1] = tostring(layer) end
        return table.concat(parts, ", ")
    end
    return compactLayerList(layers)
end

local function printWrappedField(label, value)
    local width = select(1, term.getSize())
    label = tostring(label or "")
    local lines = wrapText(tostring(value or ""), math.max(1, width - #label))
    local continuation = string.rep(" ", #label)
    for index, line in ipairs(lines) do
        print((index == 1 and label or continuation) .. line)
    end
end

local function touchActivity()
    lastActivity = os.epoch("utc")
end

local unlock

local function prompt(text, secret)
    touchActivity()
    write(text)
    local value = secret and read("*") or read()
    if locked and unlock then
        while locked do
            if not unlock() then sleep(1) end
        end
    end
    touchActivity()
    return value
end

local function setPin()
    clear("SET POCKET PIN")
    print("The PIN protects this pocket if another player picks it up.")
    print("Use 4-12 characters.")
    local first = prompt("New PIN: ", true)
    if #first < 4 or #first > 12 then printError("PIN must be 4-12 characters."); sleep(2); return false end
    local second = prompt("Confirm PIN: ", true)
    if first ~= second then printError("PINs did not match."); sleep(2); return false end
    local salt = crypto.randomHex(16)
    state.pin = { salt = salt, hash = crypto.sha256(salt .. "|" .. first) }
    persist()
    return true
end

unlock = function()
    if not state.pin then return setPin() end
    clear("ROOMBA POCKET LOCKED")
    for attempt = 1, 5 do
        write("PIN: ")
        local pin = read("*")
        touchActivity()
        local hash = crypto.sha256(state.pin.salt .. "|" .. pin)
        if crypto.constantTimeEquals(hash, state.pin.hash) then
            locked = false; touchActivity(); return true
        end
        printError("Incorrect PIN.")
    end
    print("Too many attempts. Waiting 30 seconds.")
    sleep(30)
    return false
end

local function addAlert(message)
    local severity = tostring(message.severity or "info"):lower()
    if state.alertSettings[severity] == false then return end
    state.alerts[#state.alerts + 1] = message
    while #state.alerts > 50 do table.remove(state.alerts, 1) end
    persist()
    if state.alertSettings.sound and alertSpeaker and alertSpeaker.playSound then
        local pitch = severity == "error" and 0.7 or severity == "warning" and 0.9 or 1.2
        pcall(alertSpeaker.playSound, "minecraft:block.note_block.pling", 1, pitch)
    end
    os.queueEvent("roomba_alert")
end

local function acceptSignedMessage(sender, message)
    local controller = state.controllers[tostring(sender)]
    if not controller or not controller.key then return false end
    if tonumber(message.controllerId) ~= tonumber(sender) or tonumber(message.pocketId) ~= os.getComputerID() then return false end
    if not crypto.verify(controller.key, message) then return false end
    local serverSeq = tonumber(message.serverSeq)
    if not serverSeq or serverSeq <= tonumber(controller.lastServerSeq or 0) then return false end
    controller.lastServerSeq = serverSeq
    controller.lastSeen = os.epoch("utc")
    persist()
    return true
end

local function networkLoop()
    while running do
        local sender, message, protocol = rednet.receive(REMOTE_PROTOCOL, 1)
        if sender and protocol == REMOTE_PROTOCOL and type(message) == "table" then
            if pairing and (message.type == "pair_challenge" or message.type == "pair_accept" or message.type == "pair_rejected") then
                pairing.message = message
                pairing.sender = sender
                os.queueEvent("roomba_pair_message")
            elseif message.type == "remote_response" and acceptSignedMessage(sender, message) then
                pendingResponses[tostring(message.requestId)] = message
                os.queueEvent("roomba_remote_response", tostring(message.requestId))
            elseif message.type == "remote_alert" and acceptSignedMessage(sender, message) then
                addAlert({
                    time = message.createdAt or os.epoch("utc"),
                    severity = message.severity,
                    title = message.title,
                    message = message.message,
                    data = message.data,
                    read = false,
                })
            end
        end
    end
end

local function remoteRequest(action, params, timeout)
    local controller = activeController()
    if not controller then return false, nil, "No controller is paired." end
    controller.seq = tonumber(controller.seq or 0) + 1
    local requestId = tostring(os.epoch("utc")) .. "-" .. crypto.randomHex(4)
    local message = {
        type = "remote_request",
        version = VERSION,
        protocolVersion = PROTOCOL_VERSION,
        controllerId = controller.id,
        pocketId = os.getComputerID(),
        seq = controller.seq,
        requestId = requestId,
        action = action,
        params = params or {},
    }
    crypto.signed(controller.key, message)
    persist()
    rednet.send(controller.id, message, REMOTE_PROTOCOL)

    local deadline = os.epoch("utc") + (timeout or REQUEST_TIMEOUT) * 1000
    while os.epoch("utc") < deadline do
        local response = pendingResponses[requestId]
        if response then
            pendingResponses[requestId] = nil
            if response.ok then return true, response.result end
            return false, nil, response.error or "Controller rejected the request."
        end
        sleep(0.05)
    end
    return false, nil, "Controller did not respond."
end

local function refreshStatusCache(timeout)
    local ok, result = remoteRequest("status", {}, timeout or 4)
    if ok then
        statusCache = result
        statusCacheAt = os.epoch("utc")
        return true
    end
    return false
end

local function pairController()
    clear("PAIR ROOMBA POCKET")
    local found = rednet.lookup(REMOTE_PROTOCOL, REMOTE_HOSTNAME)
    local controllerId
    if found then
        print("Found controller #" .. tostring(found))
        local answer = prompt("Use it? [Y/n]: ")
        if answer:lower() ~= "n" then controllerId = found end
    end
    if not controllerId then
        controllerId = tonumber(prompt("Controller computer ID: "))
    end
    if not controllerId then printError("Invalid controller ID."); sleep(2); return false end

    local code = prompt("Pairing code: "):upper():gsub("[^A-Z0-9]", "")
    if #code ~= 12 then printError("Pairing code must contain 12 characters."); sleep(2); return false end
    local pocketNonce = crypto.randomHex(16)
    pairing = { controllerId = controllerId, code = code, pocketNonce = pocketNonce }
    rednet.send(controllerId, {
        type = "pair_hello",
        pocketId = os.getComputerID(),
        pocketNonce = pocketNonce,
        pocketName = os.getComputerLabel() or "Roomba Pocket",
        version = VERSION,
    }, REMOTE_PROTOCOL)

    print("Waiting for controller challenge...")
    local deadline = os.epoch("utc") + 10000
    while os.epoch("utc") < deadline and not (pairing.message and pairing.message.type == "pair_challenge") do sleep(0.05) end
    local challenge = pairing.message
    if not challenge or challenge.type ~= "pair_challenge" or pairing.sender ~= controllerId then
        pairing = nil; printError("The controller did not answer pairing."); sleep(2); return false
    end
    local key = crypto.derivePairKey(code, controllerId, os.getComputerID(), challenge.controllerNonce, pocketNonce)
    local proof = crypto.hmac(key, "roomba-hive-pair-proof-v1")
    pairing.message = nil
    rednet.send(controllerId, {
        type = "pair_proof",
        controllerId = controllerId,
        pocketId = os.getComputerID(),
        controllerNonce = challenge.controllerNonce,
        pocketNonce = pocketNonce,
        proof = proof,
    }, REMOTE_PROTOCOL)

    print("Verifying pairing...")
    deadline = os.epoch("utc") + 10000
    while os.epoch("utc") < deadline and not pairing.message do sleep(0.05) end
    local accepted = pairing.message
    pairing = nil
    if not accepted or accepted.type == "pair_rejected" then
        printError(accepted and accepted.message or "Pairing timed out."); sleep(2); return false
    end
    -- pair_accept is the first signed server message and uses server sequence 1.
    local temporary = {
        id = controllerId, key = key, seq = 0, lastServerSeq = 0,
        name = accepted.controllerName or ("Controller #" .. controllerId),
        role = accepted.role or "viewer",
    }
    state.controllers[tostring(controllerId)] = temporary
    state.activeController = controllerId
    if not acceptSignedMessage(controllerId, accepted) then
        state.controllers[tostring(controllerId)] = nil
        state.activeController = nil
        persist()
        printError("Pair acceptance signature was invalid."); sleep(2); return false
    end
    temporary.role = accepted.role or temporary.role
    temporary.name = accepted.controllerName or temporary.name
    persist()
    if not state.pin then setPin() end
    print("Paired as " .. tostring(temporary.role) .. ".")
    sleep(2)
    return true
end

local function ensureConnection()
    if activeController() then return true end
    while not activeController() do
        clear("ROOMBA HIVE POCKET")
        print("No controller is paired.")
        print("Open S > Pair new pocket on the controller first.")
        local answer = prompt("Pair now? [Y/n]: ")
        if answer:lower() == "n" then return false end
        pairController()
    end
    return true
end

local function statusLine(worker)
    return string.format("%-5s #%-3s %-14s L%s F%s",
        tostring(worker.displayDock or worker.dock or "?"), tostring(worker.id or "?"),
        tostring(worker.status or "unknown"), tostring(worker.layer or "-"), tostring(worker.fuel or "?"))
end

local function showOverview()
    clear("HIVE OVERVIEW")
    local ok, result, err = remoteRequest("status")
    if not ok then printError(err); print("\nPress Enter."); read(); return end
    statusCache = result
    print("Controller #" .. tostring(result.controllerId) .. " | v" .. tostring(result.version))
    if result.job then
        print("Job: " .. tostring(result.job.mapName) .. " | " .. tostring(result.job.status))
        print("Layers: " .. tostring(result.job.completedCount or 0) .. "/" .. tostring(result.job.scheduledCount or result.job.layers))
    else print("Job: none") end
    print("Fuel lock: " .. tostring(result.fuelLock or "free"))
    print("Relocation: " .. tostring(result.relocationMode))
    print("")
    for _, worker in ipairs(result.workers or {}) do print(statusLine(worker)) end
    print("\nPress Enter."); read()
end

local function chooseWorker()
    local ok, workers, err = remoteRequest("workers")
    if not ok then printError(err); sleep(2); return nil end
    clear("WORKERS")
    for index, worker in ipairs(workers or {}) do printMenuOption(index, statusLine(worker)) end
    printMenuOption("0", "Back")
    local selected = tonumber(prompt("Worker: "))
    return selected and workers[selected] or nil
end

local function workerMenu()
    while true do
        local worker = chooseWorker()
        if not worker then return end
        clear("WORKER " .. tostring(worker.displayDock) .. " #" .. tostring(worker.id))
        print("Status: " .. tostring(worker.status))
        print("Version/protocol: " .. tostring(worker.version) .. "/" .. tostring(worker.protocolVersion))
        print("Position: " .. tostring(worker.positionConfidence))
        if worker.layerList and #worker.layerList > 0 then
            printWrappedField("Assigned: ", friendlyLayerList(worker.layerList))
        end
        print("Fuel: " .. tostring(worker.fuel) .. " | Slot 1: " .. tostring(worker.fuelItems))
        if worker.error then print("Problem: " .. tostring(worker.error.message or worker.error)) end
        print("")
        printMenuOption("1", "Refresh status")
        printMenuOption("2", "Pause worker")
        printMenuOption("3", "Resume worker")
        printMenuOption("4", "Return to dock")
        printMenuOption("5", "Recover and retry")
        printMenuOption("6", "Restart unfinished work")
        printMenuOption("7", "Recover saved checkpoint")
        printMenuOption("8", "Clear displayed error")
        printMenuOption("9", "Emergency vertical recovery")
        printMenuOption("0", "Back")
        local choice = prompt("Choose: ")
        if choice ~= "0" and choice ~= "" then
            local actions = {
                ["1"] = "refresh", ["2"] = "pause", ["3"] = "resume", ["4"] = "return",
                ["5"] = "recover_retry", ["6"] = "restart", ["7"] = "recover_checkpoint",
                ["8"] = "clear_error", ["9"] = "emergency_surface",
            }
            local action = actions[choice]
            if action then
                if action == "emergency_surface" then
                    print("This mines straight upward and stops at logical Y=-1.")
                    local confirmation = prompt("Type SURFACE: ")
                    if confirmation ~= "SURFACE" then action = nil end
                elseif action == "return" or action == "recover_retry" or action == "restart" or action == "recover_checkpoint" then
                    local confirmation = prompt("Type CONFIRM: ")
                    if confirmation ~= "CONFIRM" then action = nil end
                end
                if action then
                    local ok, _, err = remoteRequest("worker_action", { id = worker.id, action = action })
                    print(ok and "Command sent." or tostring(err)); sleep(2)
                end
            end
        end
    end
end

local function waitForPreflight(mapName, layers, selectedLayers, testRun)
    local ok, started, err = remoteRequest("preflight", { mapName = mapName, layers = layers, selectedLayers = selectedLayers, testRun = testRun == true })
    if not ok then return false, nil, err end
    clear("QUARRY PREFLIGHT")
    print("Map: " .. tostring(mapName) .. " | Depth: " .. tostring(layers))
    local estimate = started.estimate or {}
    print("Minimum: " .. tostring(estimate.minimumUnits) .. " fuel (~" .. tostring(estimate.minimumCoal) .. " coal)")
    print("Recommended: " .. tostring(estimate.recommendedUnits) .. " fuel (~" .. tostring(estimate.recommendedCoal) .. " coal)")
    print("Coal estimate uses " .. tostring(estimate.fuelPerItem or 80) .. " units/item.")
    printWrappedField("Mine: ", friendlyLayerList(started.selectedLayers or selectedLayers))
    printWrappedField("Skip: ", friendlyLayerList(started.skippedLayers or complementLayers(selectedLayers, layers)))
    if started.testRecommended then
        print("")
        print("Optional test not passed.")
        print("You may continue after preflight, but a one-layer test is recommended.")
    end
    local deadline = os.epoch("utc") + 12000
    while os.epoch("utc") < deadline do
        local statusOk, result = remoteRequest("preflight_status", {}, 3)
        if statusOk and result and not result.pending then
            print("")
            for _, row in ipairs(result.rows or {}) do
                print((row.ready and "READY " or "BLOCK ") .. tostring(row.dock or "?") .. " #" .. tostring(row.id))
                for _, check in ipairs(row.checks or {}) do if check ~= "READY" then print("  - " .. check) end end
            end
            if result.ready then return true, result end
            return false, result, table.concat(result.errors or {}, " ")
        end
        sleep(0.5)
    end
    return false, nil, "Preflight timed out."
end

local function choosePocketMap()
    local ok, maps, err = remoteRequest("map_details")
    if not ok then printError(err); sleep(2); return nil end
    clear("SELECT MAP")
    for index, map in ipairs(maps or {}) do
        printMenuOption(index, tostring(map.name) .. " | " .. (map.tested and "TESTED" or "UNTESTED"))
    end
    printMenuOption("0", "Back")
    local selected = tonumber(prompt("Map: "))
    if not selected or selected == 0 then return nil end
    return maps[selected] and maps[selected].name or nil
end

local function printPocketPlan(mapName, totalLayers, selectedLayers, resumedFromJobId)
    clear("JOB PLAN")
    print("Map: " .. tostring(mapName))
    print("Total depth: " .. tostring(totalLayers))
    printWrappedField("Mine (" .. tostring(#selectedLayers) .. "): ", friendlyLayerList(selectedLayers))
    local skipped = complementLayers(selectedLayers, totalLayers)
    printWrappedField("Skip (" .. tostring(#skipped) .. "): ", friendlyLayerList(skipped))
    if resumedFromJobId then print("Continue: " .. tostring(resumedFromJobId)) end
end

local function startPocketPlan(mapName, totalLayers, selectedLayers, testRun, resumedFromJobId)
    local normalized, problem = normalizeLayerList(selectedLayers, totalLayers)
    if not normalized then printError(problem); sleep(3); return end
    printPocketPlan(mapName, totalLayers, normalized, resumedFromJobId)
    local passed, _, preflightProblem = waitForPreflight(mapName, totalLayers, normalized, testRun)
    if not passed then
        printError(preflightProblem or "Preflight failed.")
        print("Press Enter.")
        read()
        return
    end
    local word = testRun and "TEST" or "START"
    if prompt("Type " .. word .. ": ") ~= word then return end
    local started, _, startError = remoteRequest("start_job", {
        mapName = mapName,
        layers = totalLayers,
        selectedLayers = normalized,
        testRun = testRun == true,
        resumedFromJobId = resumedFromJobId,
    })
    print(started and "Job started." or tostring(startError))
    sleep(2)
    return started == true
end

local function startQuarryMenu()
    while true do
        local unfinishedOk, unfinished = remoteRequest("unfinished_job")
        if not unfinishedOk then unfinished = nil end
        clear("START A JOB")
        printMenuOption("1", "Continue unfinished job" .. (unfinished and " - available" or " - none available"))
        printMenuOption("2", "Start from a chosen layer")
        printMenuOption("3", "Choose layers to skip")
        printMenuOption("4", "Choose exact layers to mine")
        printMenuOption("5", "Mine every layer")
        printMenuOption("0", "Back")
        local choice = prompt("Choose: ")
        if choice == "0" or choice == "" then return end

        if choice == "1" then
            if not unfinished then
                printError("No unfinished job with remaining layers was found.")
                sleep(3)
            else
                clear("CONTINUE JOB")
                print("Map: " .. tostring(unfinished.mapName))
                print("Previous status: " .. tostring(unfinished.priorStatus))
                printWrappedField("Completed: ", friendlyLayerList(unfinished.completedLayers))
                printWrappedField("Partially attempted: ", friendlyLayerList(unfinished.partialLayers))
                printWrappedField("Not started: ", friendlyLayerList(unfinished.notStartedLayers))
                printWrappedField("Will mine: ", friendlyLayerList(unfinished.remainingLayers))
                if prompt("Type CONTINUE: ") == "CONTINUE" then
                    if startPocketPlan(
                        unfinished.mapName,
                        unfinished.totalLayers,
                        unfinished.remainingLayers,
                        false,
                        unfinished.sourceJobId
                    ) then return end
                end
            end
        elseif choice == "2" or choice == "3" or choice == "4" or choice == "5" then
            local mapName = choosePocketMap()
            if mapName then
                local totalLayers = tonumber(prompt("Total quarry layers: "))
                if not totalLayers or totalLayers < 1 or totalLayers % 1 ~= 0 then
                    printError("Enter a positive whole number.")
                    sleep(3)
                else
                    local selected, problem
                    if choice == "2" then
                        local first = tonumber(prompt("First layer to mine: "))
                        if not first or first % 1 ~= 0 or first < 1 or first > totalLayers then
                            problem = "Starting layer must be from 1 to " .. tostring(totalLayers) .. "."
                        else
                            selected = {}
                            for layer = first, totalLayers do selected[#selected + 1] = layer end
                        end
                    elseif choice == "3" then
                        clear("SKIP LAYERS")
                        print("Separate numbers: 1,2,3,6,8")
                        print("Ranges: 1-3,6,8")
                        print("Mixed: 1,2,5-8,11")
                        local skipped
                        skipped, problem = parseLayerSpec(prompt("Skip (or none): "), totalLayers, true)
                        if skipped then
                            selected = complementLayers(skipped, totalLayers)
                            if #selected == 0 then problem = "At least one layer must remain." end
                        end
                    elseif choice == "4" then
                        clear("EXACT LAYERS")
                        print("Separate numbers: 4,5,7,9")
                        print("Ranges: 4-5,7,9-25")
                        print("Mixed input is accepted.")
                        selected, problem = parseLayerSpec(prompt("Mine: "), totalLayers, false)
                    else
                        selected = allLayers(totalLayers)
                    end
                    if problem then printError(problem); sleep(4)
                    elseif selected and startPocketPlan(mapName, totalLayers, selected, false, nil) then return end
                end
            end
        end
    end
end

local function jobsMenu()
    while true do
        clear("JOBS AND MAPS")
        printMenuOption("1", "Start quarry job")
        printMenuOption("2", "Optional one-layer test")
        printMenuOption("3", "View maps")
        printMenuOption("4", "Job history")
        printMenuOption("0", "Back")
        local choice = prompt("Choose: ")
        if choice == "0" or choice == "" then return
        elseif choice == "1" then
            startQuarryMenu()
        elseif choice == "2" then
            local mapName = choosePocketMap()
            if mapName then startPocketPlan(mapName, 1, { 1 }, true, nil) end
        elseif choice == "3" then
            local ok, maps, err = remoteRequest("map_details")
            clear("MAP LIBRARY")
            if not ok then printError(err) else
                for _, map in ipairs(maps or {}) do
                    print(tostring(map.name) .. " | " .. tostring(map.cellCount or "?") .. " cells | " .. (map.tested and "TESTED" or "UNTESTED"))
                end
            end
            print("Press Enter."); read()
        elseif choice == "4" then
            local ok, history, err = remoteRequest("history")
            clear("JOB HISTORY")
            if not ok then printError(err) else
                for index = #(history or {}), math.max(1, #(history or {}) - 19), -1 do
                    local job = history[index]
                    print(tostring(job.mapName) .. " | " .. tostring(job.status) .. " | "
                        .. tostring(job.completedCount) .. "/" .. tostring(job.scheduledCount or job.layers))
                end
            end
            print("Press Enter."); read()
        end
    end
end

local function pauseResumeMenu()
    clear("PAUSE / RESUME")
    printMenuOption("1", "Pause entire hive")
    printMenuOption("2", "Resume entire hive")
    local action = ({ ["1"] = "pause_hive", ["2"] = "resume_hive" })[prompt("Choose: ")]
    if action then
        local ok, _, err = remoteRequest(action)
        print(ok and "Command sent." or tostring(err)); sleep(2)
    end
end

local function safeAbort()
    clear("SAFE ABORT")
    print("All active workers will return through known paths, unload, and dock.")
    if prompt("Type ABORT: ") ~= "ABORT" then return end
    local ok, _, err = remoteRequest("abort_hive")
    print(ok and "Abort requested." or tostring(err)); sleep(2)
end

local function safeUpdate()
    clear("SAFE HIVE UPDATE")
    print("This aborts active work, waits for every worker to dock, then updates workers, controller, and this pocket.")
    if prompt("Type PREPARE: ") ~= "PREPARE" then return end
    local ok, _, err = remoteRequest("safe_update_prepare")
    if not ok then printError(err); sleep(2); return end

    while true do
        local statusOk, update, statusError = remoteRequest("safe_update_status", {}, 4)
        clear("SAFE HIVE UPDATE")
        if not statusOk then printError(statusError); sleep(2); return end
        update = update or {}
        print("Stage: " .. tostring(update.stage))
        if update.stage == "aborting" then print("Workers are returning and unloading...")
        elseif update.stage == "waiting_docked" then print("Waiting for dock confirmations...")
        elseif update.stage == "blocked" then
            print("Update blocked:")
            for _, issue in ipairs(update.issues or {}) do print("- " .. issue) end
            print("Resolve the issue; this screen will recheck.")
        elseif update.stage == "ready" then
            print("All workers are safely docked and ready.")
            if prompt("Type UPDATE: ") ~= "UPDATE" then remoteRequest("safe_update_cancel"); return end
            local committed, _, commitError = remoteRequest("safe_update_commit")
            if not committed then printError(commitError); sleep(2); return end
            print("Controller update committed. Updating this pocket last...")
            sleep(3)
            local separator = INSTALL_URL:find("?", 1, true) and "&" or "?"
            shell.run("wget", "run", INSTALL_URL .. separator .. "launch=" .. tostring(os.epoch("utc")), "pocket")
            return
        elseif update.stage == "failed" or update.stage == "cancelled" then
            print("Update ended: " .. tostring(update.error or update.stage)); sleep(3); return
        end
        sleep(1)
    end
end

local function alertSettingsMenu()
    while true do
        clear("ALERT SETTINGS")
        printMenuOption("1", "Errors: " .. (state.alertSettings.error and "ON" or "OFF"))
        printMenuOption("2", "Warnings: " .. (state.alertSettings.warning and "ON" or "OFF"))
        printMenuOption("3", "Success: " .. (state.alertSettings.success and "ON" or "OFF"))
        printMenuOption("4", "Info: " .. (state.alertSettings.info and "ON" or "OFF"))
        printMenuOption("5", "Sound: " .. (state.alertSettings.sound and "ON" or "OFF") .. (alertSpeaker and "" or " - no speaker"))
        printMenuOption("0", "Back")
        local choice = prompt("Choose: ")
        local keys = { ["1"] = "error", ["2"] = "warning", ["3"] = "success", ["4"] = "info", ["5"] = "sound" }
        if choice == "0" or choice == "" then persist(); return end
        local key = keys[choice]
        if key then state.alertSettings[key] = not state.alertSettings[key]; persist() end
    end
end

local function alertsMenu()
    while true do
        clear("ALERTS")
        if #state.alerts == 0 then print("No alerts.") end
        for index = #state.alerts, math.max(1, #state.alerts - 19), -1 do
            local alert = state.alerts[index]
            print(index .. ") [" .. tostring(alert.severity or "info"):upper() .. "] " .. trim(alert.message, select(1, term.getSize()) - 8))
        end
        print("C) Clear all   L) Controller logs")
        print("S) Alert settings   0) Back")
        local choice = prompt("Choose: ")
        if choice == "0" or choice == "" then return
        elseif choice:lower() == "c" then state.alerts = {}; persist()
        elseif choice:lower() == "s" then alertSettingsMenu()
        elseif choice:lower() == "l" then
            local ok, logs, err = remoteRequest("logs")
            clear("CONTROLLER LOG")
            if not ok then printError(err) else
                for index = math.max(1, #(logs or {}) - 29), #(logs or {}) do
                    local entry = logs[index]
                    print("[" .. tostring(entry.severity):upper() .. "] " .. tostring(entry.message))
                end
            end
            print("Press Enter."); read()
        else
            local alert = state.alerts[tonumber(choice)]
            if alert then clear(tostring(alert.title or "ALERT")); print(tostring(alert.message)); alert.read = true; persist(); print("\nPress Enter."); read() end
        end
    end
end

local function emergencySurfaceRecovery()
    clear("EMERGENCY SURFACE")
    print("Connected workers mine straight upward and stop at logical Y=-1.")
    print("")
    print("Recovery stops before lava, computers, turtles, inventories, and unbreakable blocks.")
    print("Unfinished quarry work will be abandoned.")
    if prompt("Type SURFACE: ") ~= "SURFACE" then return end

    local ok, result, err = remoteRequest("emergency_surface_hive")
    if ok then
        print("Recovery started.")
        print("Use Workers or Overview to monitor progress.")
    else
        printError(err)
    end
    sleep(3)
end

local function adminMenu()
    local controller = activeController()
    if not controller or roleRank(controller.role) < 3 then printError("Administrator permission required."); sleep(2); return end
    while true do
        clear("ADMIN TOOLS")
        printMenuOption("1", "Prepare hive relocation")
        printMenuOption("2", "Create controller backup")
        printMenuOption("3", "Restore controller backup")
        printMenuOption("4", "Safe update hive")
        printMenuOption("5", "Emergency surface recovery")
        printMenuOption("0", "Back")
        local choice = prompt("Choose: ")
        if choice == "0" or choice == "" then return
        elseif choice == "1" then
            print("All workers must be idle and docked. This clears old dock assignments but preserves maps and pairings.")
            if prompt("Type RELOCATE: ") == "RELOCATE" then
                local ok, _, err = remoteRequest("relocate")
                print(ok and "Relocation mode started. Move the hive, then use Detect on the controller." or tostring(err)); sleep(3)
            end
        elseif choice == "2" then
            local name = prompt("Backup name (blank automatic): ")
            local ok, result, err = remoteRequest("backup_create", { name = name })
            print(ok and ("Backup created: " .. tostring(result)) or tostring(err)); sleep(2)
        elseif choice == "3" then
            local ok, backups, err = remoteRequest("backup_list")
            if not ok then printError(err); sleep(2)
            elseif #(backups or {}) == 0 then print("No backups found."); sleep(2)
            else
                clear("RESTORE CONTROLLER BACKUP")
                for index, name in ipairs(backups) do print(index .. ") " .. tostring(name)) end
                local selected = backups[tonumber(prompt("Backup: "))]
                if selected then
                    print("This restores maps, configuration, pairings, history, and saved assignments.")
                    print("The active job and physical dock occupancy are never restored.")
                    if prompt("Type RESTORE: ") == "RESTORE" then
                        local restored, _, restoreError = remoteRequest("backup_restore", { name = selected })
                        print(restored and "Backup restored. Run Detect docks on the controller." or tostring(restoreError)); sleep(3)
                    end
                end
            end
        elseif choice == "4" then safeUpdate()
        elseif choice == "5" then emergencySurfaceRecovery() end
    end
end

local function managePairedPockets()
    local controller = activeController()
    if not controller or roleRank(controller.role) < 3 then printError("Administrator permission required."); sleep(2); return end
    while true do
        local ok, pockets, err = remoteRequest("security_list")
        clear("PAIRED POCKETS")
        if not ok then printError(err); sleep(2); return end
        for index, pocket in ipairs(pockets or {}) do
            printMenuOption(index, "#" .. tostring(pocket.id) .. " " .. tostring(pocket.name)
                .. " | " .. tostring(pocket.role) .. (pocket.isCurrent and " | THIS" or ""))
        end
        printMenuOption("0", "Back")
        local selected = tonumber(prompt("Pocket: "))
        if not selected or selected == 0 then return end
        local pocket = pockets[selected]
        if pocket then
            clear("MANAGE POCKET #" .. tostring(pocket.id))
            printMenuOption("1", "Rename")
            printMenuOption("2", "Change role")
            printMenuOption("3", "Revoke")
            printMenuOption("0", "Back")
            local choice = prompt("Choose: ")
            if choice == "1" then
                local name = prompt("New name: ")
                local changed, _, problem = remoteRequest("security_rename", { id = pocket.id, name = name })
                print(changed and "Pocket renamed." or tostring(problem)); sleep(2)
            elseif choice == "2" then
                printMenuOption("1", "Viewer")
                printMenuOption("2", "Operator")
                printMenuOption("3", "Administrator")
                local role = ({ "viewer", "operator", "administrator" })[tonumber(prompt("Role: "))]
                if role then
                    local changed, _, problem = remoteRequest("security_set_role", { id = pocket.id, role = role })
                    print(changed and "Role changed." or tostring(problem)); sleep(2)
                end
            elseif choice == "3" then
                if prompt("Type REVOKE: ") == "REVOKE" then
                    local revoked, _, problem = remoteRequest("security_revoke", { id = pocket.id })
                    print(revoked and "Pocket revoked." or tostring(problem)); sleep(2)
                end
            end
        end
    end
end

local function securityMenu()
    while true do
        local controller = activeController()
        clear("POCKET SECURITY")
        print("Pocket ID: #" .. os.getComputerID())
        print("Controller: " .. (controller and ("#" .. controller.id .. " " .. tostring(controller.name)) or "none"))
        print("Role: " .. tostring(controller and controller.role or "-"))
        printMenuOption("1", "Change local PIN")
        printMenuOption("2", "Pair another controller")
        printMenuOption("3", "Forget active controller")
        printMenuOption("4", "Lock now")
        printMenuOption("5", "Idle lock: " .. tostring(state.idleLockSeconds) .. " seconds")
        if controller and roleRank(controller.role) >= 3 then
            printMenuOption("6", "Manage controller paired pockets")
        end
        printMenuOption("0", "Back")
        local choice = prompt("Choose: ")
        if choice == "0" or choice == "" then return
        elseif choice == "1" then setPin()
        elseif choice == "2" then pairController()
        elseif choice == "3" and controller then
            if prompt("Type FORGET: ") == "FORGET" then
                state.controllers[tostring(controller.id)] = nil; state.activeController = nil; persist(); return
            end
        elseif choice == "4" then locked = true; return
        elseif choice == "5" then
            local seconds = tonumber(prompt("Idle seconds (30-3600): "))
            if seconds and seconds >= 30 and seconds <= 3600 then
                state.idleLockSeconds = math.floor(seconds)
                persist()
            else
                printError("Enter a value from 30 to 3600."); sleep(2)
            end
        elseif choice == "6" and controller and roleRank(controller.role) >= 3 then
            managePairedPockets()
        end
    end
end

local function unreadAlertCount()
    local count = 0
    for _, alert in ipairs(state.alerts) do if not alert.read then count = count + 1 end end
    return count
end

local function cachedWorkerSummary()
    local total, online, docked = 0, 0, 0
    local fuelState = "OK"
    for _, worker in ipairs(statusCache and statusCache.workers or {}) do
        total = total + 1
        local status = tostring(worker.status or "unknown")
        if not status:find("^offline") then online = online + 1 end
        if status == "docked" or status == "parked" or status == "aborted" or status == "fuel_station_empty" then
            docked = docked + 1
        end
        if status == "fuel_station_empty" or status == "waiting_for_fuel" then fuelState = "RESTOCK" end
    end
    return total, online, docked, fuelState
end

local function renderHome()
    clear("ROOMBA HIVE")
    local controller = activeController()
    print("Pocket #" .. os.getComputerID() .. " | " .. tostring(controller and controller.role or "unpaired"))
    print("Controller: " .. tostring(controller and ("#" .. controller.id) or "none"))

    if statusCache and statusCache.job then
        print("Job: " .. tostring(statusCache.job.status) .. " " .. tostring(statusCache.job.completedCount or 0) .. "/" .. tostring(statusCache.job.scheduledCount or statusCache.job.layers))
    elseif statusCache then
        print("Job: idle")
    else
        print("Job: connecting...")
    end

    local total, online, docked, fuelState = cachedWorkerSummary()
    print("Workers: " .. online .. "/" .. total .. " online")
    print("Docked: " .. docked .. " | Fuel: " .. fuelState)
    print("Alerts: " .. unreadAlertCount())
    print("")
    printMenuOption("1", "Quick Actions")
    printMenuOption("2", "Workers")
    printMenuOption("3", "Jobs & Maps")
    printMenuOption("4", "Alerts & Logs")
    printMenuOption("5", "System")
    printMenuOption("0", "Lock Pocket")
end

local function quickActionsMenu()
    while true do
        refreshStatusCache(4)
        clear("QUICK ACTIONS")
        local controller = activeController()
        local role = controller and controller.role or "viewer"
        local jobStatus = statusCache and statusCache.job and statusCache.job.status or nil
        local options = {}

        local function add(label, action)
            options[#options + 1] = { label = label, action = action }
        end

        add("View live overview", "overview")
        if roleRank(role) >= 2 and jobStatus == "running" then add("Pause hive", "pause") end
        if roleRank(role) >= 2 and jobStatus == "paused" then add("Resume hive", "resume") end
        if roleRank(role) >= 2 and (jobStatus == "running" or jobStatus == "paused" or jobStatus == "aborting") then
            add("Safe abort", "abort")
        end
        if roleRank(role) >= 3 then
            add("Safe update hive", "update")
            add("Emergency surface recovery", "surface")
        end

        for index, option in ipairs(options) do printMenuOption(index, option.label) end
        printMenuOption("0", "Back")
        local choice = tonumber(prompt("Choose: "))
        if not choice or choice == 0 then return end
        local selected = options[choice]
        if selected then
            if selected.action == "overview" then showOverview()
            elseif selected.action == "pause" then
                local ok, _, err = remoteRequest("pause_hive")
                print(ok and "Pause requested." or tostring(err)); sleep(2)
            elseif selected.action == "resume" then
                local ok, _, err = remoteRequest("resume_hive")
                print(ok and "Resume requested." or tostring(err)); sleep(2)
            elseif selected.action == "abort" then safeAbort()
            elseif selected.action == "update" then safeUpdate()
            elseif selected.action == "surface" then emergencySurfaceRecovery() end
        end
    end
end

local function systemMenu()
    while true do
        local controller = activeController()
        clear("SYSTEM")
        local options = {}
        local function add(label, action)
            options[#options + 1] = { label = label, action = action }
        end
        if controller and roleRank(controller.role) >= 3 then add("Administrator tools", "admin") end
        add("Pocket security", "security")
        add("Exit program", "exit")
        for index, option in ipairs(options) do printMenuOption(index, option.label) end
        printMenuOption("0", "Back")
        local choice = tonumber(prompt("Choose: "))
        if not choice or choice == 0 then return end
        local selected = options[choice]
        if selected then
            if selected.action == "admin" then adminMenu()
            elseif selected.action == "security" then securityMenu()
            elseif selected.action == "exit" then running = false; return end
        end
    end
end

local function uiLoop()
    while running do
        if locked then
            if not unlock() then sleep(1) end
        elseif not ensureConnection() then
            running = false
        else
            if not statusCache or os.epoch("utc") - statusCacheAt >= 5000 then refreshStatusCache(4) end
            renderHome()
            local refreshTimer = os.startTimer(5)
            local event, value = os.pullEvent()
            if event == "char" and not locked then
                touchActivity()
                if value == "1" then quickActionsMenu()
                elseif value == "2" then workerMenu()
                elseif value == "3" then jobsMenu()
                elseif value == "4" then alertsMenu()
                elseif value == "5" then systemMenu()
                elseif value == "0" then locked = true end
            elseif event == "timer" and value == refreshTimer then
                refreshStatusCache(4)
            end
        end
    end
end

local function lockLoop()
    while running do
        if state.pin and not locked and os.epoch("utc") - lastActivity >= tonumber(state.idleLockSeconds or DEFAULT_IDLE_LOCK) * 1000 then
            locked = true
            os.queueEvent("roomba_lock")
        end
        sleep(1)
    end
end

local function healthLoop()
    sleep(8)
    if fs.exists(BOOT_FILE) then
        local ok, boot = pcall(dofile, BOOT_FILE)
        if ok and boot and boot.markHealthy then boot.markHealthy("pocket", VERSION) end
    end
    while running do sleep(3600) end
end

persist()
if state.pin then locked = true end
local ok, err = pcall(function()
    parallel.waitForAny(uiLoop, networkLoop, lockLoop, healthLoop)
end)
if not ok then clear("ROOMBA POCKET ERROR"); printError(err) end
