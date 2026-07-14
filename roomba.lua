-- Roomba Hive command utility v0.2.3

local VERSION = "0.2.3"
local INSTALL_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main/install.lua"
local args = { ... }
local command = args[1] and args[1]:lower() or "help"

local function factoryReset()
    term.clear()
    term.setCursorPos(1, 1)
    print("ROOMBA HIVE FACTORY RESET")
    print("==========================")
    print("This permanently deletes:")
    print("- Roomba programs")
    print("- controller maps and state")
    print("- worker dock, position, and job state")
    print("- startup.lua and the computer label")
    write("Type RESET to continue: ")
    if read() ~= "RESET" then print("Cancelled."); return end

    if fs.exists("/roomba") then fs.delete("/roomba") end
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    os.setComputerLabel(nil)
    if fs.exists("/roomba.lua") then fs.delete("/roomba.lua") end

    print("Factory reset complete. Rebooting...")
    sleep(2)
    os.reboot()
end

local function detectRole()
    if fs.exists("/roomba/controller.lua") then return "controller" end
    if fs.exists("/roomba/worker.lua") then return "worker" end
    return nil
end

local function update()
    local role = detectRole()
    if not role then
        printError("No Roomba controller or worker installation was found.")
        return
    end

    local separator = INSTALL_URL:find("?", 1, true) and "&" or "?"
    local url = INSTALL_URL .. separator .. "launch=" .. tostring(os.epoch("utc"))
    print("Updating Roomba Hive " .. role .. "...")
    local ok = shell.run("wget", "run", url, role)
    if not ok then printError("Update did not complete.") end
end

if command == "reset" then
    factoryReset()
elseif command == "update" then
    update()
elseif command == "version" then
    print("Roomba Hive v" .. VERSION)
elseif command == "help" then
    print("Roomba Hive commands:")
    print("  roomba update   Update this device")
    print("                  Controller updates also update connected workers")
    print("  roomba reset    Factory-reset this device")
    print("  roomba version  Show the installed release")
    print("  roomba help     Show this help")
else
    printError("Unknown command: " .. tostring(command))
    print("Run: roomba help")
end
