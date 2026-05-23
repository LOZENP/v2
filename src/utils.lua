-- utils.lua
local Utils = {}

function Utils.randomSeed()
    math.randomseed(os.time())
end

function Utils.randName(len)
    len = len or math.random(8, 14)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local name = chars:sub(math.random(27, 52), math.random(27, 52)) -- start uppercase
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

function Utils.tableContains(tbl, val)
    for _, v in ipairs(tbl) do
        if v == val then return true end
    end
    return false
end

function Utils.serializeTable(tbl)
    local parts = {}
    for i, v in ipairs(tbl) do
        parts[i] = tostring(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

return Utils
