-- utils.lua

local Utils = {}

-- bit32 compat shim (works on LuaJIT, Lua5.1, Luau)
local bit32 = bit32 or (function()
    local b = {}

    function b.bxor(a, x)
        local r, m = 0, 1
        while a > 0 or x > 0 do
            if (a % 2) ~= (x % 2) then r = r + m end
            a = math.floor(a / 2)
            x = math.floor(x / 2)
            m = m * 2
        end
        return r
    end

    function b.band(a, x)
        local r, m = 0, 1
        while a > 0 and x > 0 do
            if (a % 2 == 1) and (x % 2 == 1) then r = r + m end
            a = math.floor(a / 2)
            x = math.floor(x / 2)
            m = m * 2
        end
        return r
    end

    function b.bor(a, x)
        local r, m = 0, 1
        while a > 0 or x > 0 do
            if (a % 2 == 1) or (x % 2 == 1) then r = r + m end
            a = math.floor(a / 2)
            x = math.floor(x / 2)
            m = m * 2
        end
        return r
    end

    function b.bnot(a)
        return b.bxor(a, 0xFFFFFFFF)
    end

    function b.rshift(a, n)
        return math.floor(a / (2 ^ n))
    end

    function b.lshift(a, n)
        return (a * (2 ^ n)) % (2 ^ 32)
    end

    return b
end)()

Utils.bit32 = bit32

function Utils.randomSeed()
    math.randomseed(os.time())
end

function Utils.randName(len)
    len = len or math.random(8, 14)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local name = chars:sub(math.random(27, 52), math.random(27, 52))
    for i = 1, len - 1 do
        local pos = math.random(1, #chars)
        name = name .. chars:sub(pos, pos)
    end
    return name
end

function Utils.generateKey(len)
    local key = {}
    for i = 1, len do
        key[i] = math.random(1, 255)
    end
    return key
end

function Utils.deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[Utils.deepCopy(k)] = Utils.deepCopy(v)
    end
    return copy
end

function Utils.xorBytes(a, b)
    return bit32.bxor(a, b)
end

function Utils.serializeTable(tbl)
    local parts = {}
    for i, v in ipairs(tbl) do
        parts[i] = tostring(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

return Utils
