-- Roomba Hive cryptographic helpers v0.3.4
-- Pure Lua SHA-256/HMAC-SHA256 for CC:Tweaked's Lua 5.2 environment.

local crypto = {}

local band, bor, bxor = bit32.band, bit32.bor, bit32.bxor
local bnot, rshift, lshift, rrotate = bit32.bnot, bit32.rshift, bit32.lshift, bit32.rrotate
local UINT32 = 0xffffffff

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add32(...)
    local sum = 0
    for index = 1, select("#", ...) do sum = (sum + select(index, ...)) % 4294967296 end
    return band(math.floor(sum), UINT32)
end

local function wordToBytes(word)
    return string.char(
        band(rshift(word, 24), 0xff),
        band(rshift(word, 16), 0xff),
        band(rshift(word, 8), 0xff),
        band(word, 0xff)
    )
end

local function sha256Raw(message)
    message = tostring(message or "")
    local bitLength = #message * 8
    message = message .. string.char(0x80)
    local padding = (56 - (#message % 64)) % 64
    message = message .. string.rep("\0", padding)

    local high = math.floor(bitLength / 4294967296)
    local low = bitLength % 4294967296
    message = message .. wordToBytes(high) .. wordToBytes(low)

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local words = {}

    for chunkStart = 1, #message, 64 do
        for index = 0, 15 do
            local offset = chunkStart + index * 4
            local a, b, c, d = message:byte(offset, offset + 3)
            words[index] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
        end
        for index = 16, 63 do
            local x = words[index - 15]
            local y = words[index - 2]
            local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
            local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
            words[index] = add32(words[index - 16], s0, words[index - 7], s1)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7
        for index = 0, 63 do
            local sum1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
            local choice = bxor(band(e, f), band(bnot(e), g))
            local temp1 = add32(h, sum1, choice, K[index + 1], words[index])
            local sum0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
            local majority = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = add32(sum0, majority)

            h, g, f, e = g, f, e, add32(d, temp1)
            d, c, b, a = c, b, a, add32(temp1, temp2)
        end

        h0, h1, h2, h3 = add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d)
        h4, h5, h6, h7 = add32(h4, e), add32(h5, f), add32(h6, g), add32(h7, h)
    end

    return wordToBytes(h0) .. wordToBytes(h1) .. wordToBytes(h2) .. wordToBytes(h3)
        .. wordToBytes(h4) .. wordToBytes(h5) .. wordToBytes(h6) .. wordToBytes(h7)
end

local function toHex(raw)
    return (raw:gsub(".", function(character) return string.format("%02x", character:byte()) end))
end

function crypto.sha256(message)
    return toHex(sha256Raw(message))
end

function crypto.hmac(secret, message)
    secret = tostring(secret or "")
    if #secret > 64 then secret = sha256Raw(secret) end
    secret = secret .. string.rep("\0", 64 - #secret)

    local inner, outer = {}, {}
    for index = 1, 64 do
        local byte = secret:byte(index)
        inner[index] = string.char(bxor(byte, 0x36))
        outer[index] = string.char(bxor(byte, 0x5c))
    end

    return toHex(sha256Raw(table.concat(outer) .. sha256Raw(table.concat(inner) .. tostring(message or ""))))
end

local function canonicalValue(value, seen)
    local valueType = type(value)
    if valueType == "nil" then return "n;" end
    if valueType == "boolean" then return value and "b1;" or "b0;" end
    if valueType == "number" then return "d" .. string.format("%.17g", value) .. ";" end
    if valueType == "string" then return "s" .. #value .. ":" .. value end
    if valueType ~= "table" then return "u" .. valueType .. ":" .. tostring(value) end

    seen = seen or {}
    if seen[value] then error("Cannot canonicalise cyclic table", 0) end
    seen[value] = true

    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(left, right)
        local leftKey = type(left) .. ":" .. tostring(left)
        local rightKey = type(right) .. ":" .. tostring(right)
        return leftKey < rightKey
    end)

    local output = { "t{" }
    for _, key in ipairs(keys) do
        if key ~= "sig" then
            output[#output + 1] = canonicalValue(key, seen)
            output[#output + 1] = canonicalValue(value[key], seen)
        end
    end
    output[#output + 1] = "}"
    seen[value] = nil
    return table.concat(output)
end

function crypto.canonical(value)
    return canonicalValue(value, {})
end

function crypto.sign(secret, message)
    return crypto.hmac(secret, crypto.canonical(message))
end

function crypto.constantTimeEquals(left, right)
    left, right = tostring(left or ""), tostring(right or "")
    if #left ~= #right then return false end
    local difference = 0
    for index = 1, #left do difference = bor(difference, bxor(left:byte(index), right:byte(index))) end
    return difference == 0
end

function crypto.verify(secret, message)
    if type(message) ~= "table" or type(message.sig) ~= "string" then return false end
    return crypto.constantTimeEquals(message.sig, crypto.sign(secret, message))
end

function crypto.signed(secret, message)
    message.sig = crypto.sign(secret, message)
    return message
end

local seeded = false
local function ensureSeeded()
    if seeded then return end
    seeded = true
    local seed = (os.epoch("utc") or 0) + (os.getComputerID() or 0) * 104729 + math.floor((os.clock() or 0) * 100000)
    math.randomseed(seed % 2147483647)
    for _ = 1, 8 do math.random() end
end

function crypto.randomHex(byteCount)
    ensureSeeded()
    local output = {}
    for index = 1, byteCount do output[index] = string.format("%02x", math.random(0, 255)) end
    return table.concat(output)
end

function crypto.randomCode(length)
    ensureSeeded()
    local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    local output = {}
    for index = 1, length do
        local position = math.random(1, #alphabet)
        output[index] = alphabet:sub(position, position)
    end
    return table.concat(output)
end

function crypto.derivePairKey(code, controllerId, pocketId, controllerNonce, pocketNonce)
    local material = table.concat({
        "roomba-hive-pair-v1",
        tostring(controllerId), tostring(pocketId),
        tostring(controllerNonce), tostring(pocketNonce),
    }, "|")
    return crypto.hmac(tostring(code), material)
end

return crypto
