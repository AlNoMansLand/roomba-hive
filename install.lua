-- Roomba Hive one-command installer v0.1.0
-- Usage: wget run <raw-install-url> controller
--        wget run <raw-install-url> worker

local args = { ... }
local role = args[1] and args[1]:lower() or nil

-- Change this after uploading the package to GitHub or another raw-file host.
local BASE_URL = "https://raw.githubusercontent.com/AlNoMansLand/roomba-hive/main"

local files = {
    controller = {
        { remote = "roomba_controller.lua", localPath = "/roomba/controller.lua" },
        { remote = "startup_controller.lua", localPath = "/startup.lua" },
    },
    worker = {
        { remote = "roomba_worker.lua", localPath = "/roomba/worker.lua" },
        { remote = "startup_worker.lua", localPath = "/startup.lua" },
    },
}

local function fail(message)
    printError(message)
    error(message, 0)
end

if not files[role] then
    fail("Usage: install.lua controller|worker")
end
if not http then
    fail("HTTP is disabled. Enable it in the CC:Tweaked server/client configuration.")
end

if not fs.exists("/roomba") then fs.makeDir("/roomba") end

local function download(url, path)
    print("Downloading " .. path .. "...")
    local response, err = http.get(url)
    if not response then fail("Download failed: " .. tostring(err)) end
    local body = response.readAll()
    response.close()
    if not body or body == "" then fail("Downloaded an empty file: " .. url) end

    local tmp = path .. ".new"
    local h, openErr = fs.open(tmp, "w")
    if not h then fail("Cannot write " .. tmp .. ": " .. tostring(openErr)) end
    h.write(body)
    h.close()

    if fs.exists(path .. ".old") then fs.delete(path .. ".old") end
    if fs.exists(path) then fs.move(path, path .. ".old") end
    fs.move(tmp, path)
end

term.clear()
term.setCursorPos(1, 1)
print("Roomba Hive Installer")
print("======================")
print("Role: " .. role)
print("")

for _, entry in ipairs(files[role]) do
    download(BASE_URL .. "/" .. entry.remote, entry.localPath)
end

if role == "controller" then
    os.setComputerLabel("Roomba Hive Controller")
else
    os.setComputerLabel("Roomba Worker (unassigned)")
end

print("")
term.setTextColor(colors.lime)
print("Installation complete.")
term.setTextColor(colors.white)
print("Rebooting in 3 seconds...")
sleep(3)
os.reboot()
