-- Roomba Hive command utility v0.2.1

local VERSION = "0.2.1"
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

if command == "reset" then
    factoryReset()
elseif command == "version" then
    print("Roomba Hive v" .. VERSION)
elseif command == "help" then
    print("Roomba Hive commands:")
    print("  roomba reset    Factory-reset this device")
    print("  roomba version  Show the installed release")
    print("  roomba help     Show this help")
else
    printError("Unknown command: " .. tostring(command))
    print("Run: roomba help")
end
