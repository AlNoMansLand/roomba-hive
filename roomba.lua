-- Roomba Hive command utility v0.3.1

local VERSION = "0.3.1"
local PROTOCOL_VERSION = 2
local INSTALL_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua"
local args = { ... }
local command = args[1] and args[1]:lower() or "help"

local function factoryReset()
    term.clear(); term.setCursorPos(1, 1)
    print("ROOMBA HIVE FACTORY RESET")
    print("==========================")
    print("This permanently deletes the installed Roomba programs and all local state.")
    print("On a controller this includes maps, jobs, logs, backups, and pocket pairings.")
    print("On a worker this includes its dock, position, checkpoint, and assignment.")
    print("On a pocket this includes its PIN and paired-controller keys.")
    write("Type RESET to continue: ")
    if read() ~= "RESET" then print("Cancelled."); return end
    if fs.exists("/roomba") then fs.delete("/roomba") end
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    os.setComputerLabel(nil)
    if fs.exists("/roomba.lua") then fs.delete("/roomba.lua") end
    print("Factory reset complete. Rebooting...")
    sleep(2); os.reboot()
end

local function detectRole()
    if fs.exists("/roomba/controller.lua") then return "controller" end
    if fs.exists("/roomba/worker.lua") then return "worker" end
    if fs.exists("/roomba/pocket.lua") then return "pocket" end
    return nil
end

local function update()
    local role = detectRole()
    if not role then printError("No Roomba installation was found."); return end
    if role == "controller" then
        print("For the safest update, use U in the controller UI or Safe Update on a paired pocket.")
        write("Type DIRECT to run the installer immediately: ")
        if read() ~= "DIRECT" then return end
    end
    local separator = INSTALL_URL:find("?", 1, true) and "&" or "?"
    local url = INSTALL_URL .. separator .. "launch=" .. tostring(os.epoch("utc"))
    print("Updating Roomba Hive " .. role .. "...")
    local ok = shell.run("wget", "run", url, role)
    if not ok then printError("Update did not complete.") end
end

if command == "reset" then factoryReset()
elseif command == "update" then update()
elseif command == "version" then print("Roomba Hive v" .. VERSION .. " | protocol " .. PROTOCOL_VERSION)
elseif command == "help" then
    print("Roomba Hive commands:")
    print("  roomba update   Update this device")
    print("  roomba reset    Factory-reset this device")
    print("  roomba version  Show release/protocol")
    print("  roomba help     Show this help")
    print("")
    print("Controller safe updates are best started from U or the pocket app.")
else
    printError("Unknown command: " .. tostring(command))
    print("Run: roomba help")
end
