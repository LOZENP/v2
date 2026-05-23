-- encoder.lua
local Utils = require("src.utils")
local bit32 = Utils.bit32

local Encoder = {}

function Encoder.new(config)
    local self = {
        config = config,
        key    = Utils.generateKey(256),
    }

    function self.xorByte(byte, pos)
        local k = self.key[((pos - 1) % 256) + 1]
        return bit32.bxor(byte, k)
    end

    function self.serializeProto(proto)
        local buf = {}

        local function writeU8(v)
            table.insert(buf, math.floor(v) % 256)
        end

        local function writeU16(v)
            v = math.floor(v) % 65536
            writeU8(bit32.band(v, 0xFF))
            writeU8(bit32.band(bit32.rshift(v, 8), 0xFF))
        end

        local function writeDouble(n)
            local s = tostring(n)
            writeU8(#s)
            for i = 1, #s do
                writeU8(string.byte(s, i))
            end
        end

        local function writeString(s)
            writeU16(#s)
            for i = 1, #s do
                writeU8(string.byte(s, i))
            end
        end

        local function writeProto(p)
            writeU8(p.params)
            writeU8(p.hasVararg and 1 or 0)
            writeU8(p.maxStack)

            -- Constants
            writeU16(#p.consts)
            for _, k in ipairs(p.consts) do
                writeU8(k.tag)
                if k.tag == 0 then
                    writeDouble(k.value)
                elseif k.tag == 1 then
                    writeString(k.value)
                elseif k.tag == 2 then
                    writeU8(k.value and 1 or 0)
                end
            end

            -- Instructions
            writeU16(#p.code)
            for _, instr in ipairs(p.code) do
                writeU8(instr.op)
                writeU8(instr.A % 256)
                local B = instr.B
                if B < 0 then B = B + 65536 end
                writeU16(B % 65536)
                writeU8(instr.C % 256)
            end

            -- Child protos
            writeU8(#p.protos)
            for _, child in ipairs(p.protos) do
                writeProto(child)
            end
        end

        writeProto(proto)

        -- Encrypt
        local encrypted = {}
        for i, byte in ipairs(buf) do
            encrypted[i] = self.xorByte(byte, i)
        end

        return encrypted
    end

    function self.getKeyString()
        return table.concat(self.key, ",")
    end

    return self
end

return Encoder
