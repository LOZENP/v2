-- cli.lua
local Obfuscator = require("src.obfuscator")

local input  = arg[1]
local output = arg[2] or (input and input:gsub("%.lua$", ".obf.lua"))

if not input then
    print("Usage: lua cli.lua <input.lua> [output.lua]")
    os.exit(1)
end

local ok, err = pcall(function()
    Obfuscator.obfuscateFile(input, output)
end)

if ok then
    print("Done -> " .. output)
else
    print("Error: " .. tostring(err))
end
