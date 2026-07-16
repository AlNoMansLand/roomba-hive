-- Roomba Hive transactional boot/rollback helper v0.3.6

local boot = {}
local ROOT = "/roomba"
local MANIFEST = fs.combine(ROOT, "update_manifest.db")

local function readTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local value = textutils.unserialize(handle.readAll())
    handle.close()
    return type(value) == "table" and value or nil
end

local function writeTable(path, value)
    local temporary = path .. ".tmp"
    local handle = assert(fs.open(temporary, "w"))
    handle.write(textutils.serialize(value))
    handle.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(temporary, path)
end

local function restoreFiles(manifest)
    for _, path in ipairs(manifest.files or {}) do
        local backup = path .. ".old"
        if fs.exists(backup) then
            if fs.exists(path) then fs.delete(path) end
            fs.move(backup, path)
        end
    end
end

function boot.prepare(role)
    local manifest = readTable(MANIFEST)
    if not manifest or manifest.role ~= role then return end

    manifest.attempts = tonumber(manifest.attempts or 0)
    if manifest.attempts >= 2 then
        term.clear()
        term.setCursorPos(1, 1)
        term.setTextColor(colors.red)
        print("ROOMBA HIVE UPDATE ROLLBACK")
        term.setTextColor(colors.white)
        print("The new " .. tostring(role) .. " release failed to start twice.")
        print("Restoring the previous files...")
        restoreFiles(manifest)
        fs.delete(MANIFEST)
        sleep(2)
        os.reboot()
    end

    manifest.attempts = manifest.attempts + 1
    manifest.lastAttempt = os.epoch("utc")
    writeTable(MANIFEST, manifest)
end

function boot.markHealthy(role, version)
    local manifest = readTable(MANIFEST)
    if not manifest or manifest.role ~= role then return false end
    manifest.healthyAt = os.epoch("utc")
    manifest.healthyVersion = version
    fs.delete(MANIFEST)
    return true
end

function boot.writeManifest(role, version, files)
    if not fs.exists(ROOT) then fs.makeDir(ROOT) end
    writeTable(MANIFEST, {
        role = role,
        targetVersion = version,
        files = files,
        attempts = 0,
        installedAt = os.epoch("utc"),
    })
end

function boot.clearManifest()
    if fs.exists(MANIFEST) then fs.delete(MANIFEST) end
end

return boot
