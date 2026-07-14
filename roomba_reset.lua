-- Roomba Hive one-command factory reset v0.1.2
term.clear()
term.setCursorPos(1,1)
print("ROOMBA HIVE FACTORY RESET")
print("==========================")
print("This permanently deletes:")
print("- /roomba (program, maps, and saved state)")
print("- /startup.lua")
print("- the computer/turtle label")
write("Type RESET to continue: ")
if read() ~= "RESET" then
    print("Cancelled.")
    return
end

if fs.exists("/roomba") then fs.delete("/roomba") end
if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
os.setComputerLabel(nil)

print("Factory reset complete. Rebooting...")
sleep(2)
os.reboot()
