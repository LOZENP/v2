-- obfuscator.lua
-- Main pipeline: source -> lexer -> parser -> compiler -> encoder -> vm runtime

local Lexer    = require("src.lexer")
local Parser   = require("src.parser")
local Compiler = require("src.compiler")
local Encoder  = require("src.encoder")
local VM       = require("src.vm")
local Utils    = require("src.utils")

local Obfuscator = {}

function Obfuscator.obfuscate(source, config)
    config = config or {}
    Utils.randomSeed()

    -- 1. Lex
    local lexer  = Lexer.new(source)
    local tokens = lexer.tokenize()

    -- 2. Parse
    local parser = Parser.new(tokens)
    local ast    = parser.parse()

    -- 3. Compile AST -> proto tree
    local compiler = Compiler.new()
    local proto    = compiler.compileAST(ast)

    -- 4. Encode / encrypt proto tree
    local encoder = Encoder.new(config)
    local blob    = encoder.serializeProto(proto)
    local keyStr  = encoder.getKeyString()

    -- 5. Generate VM runtime string
    local output = VM.generateRuntime(blob, keyStr, config)

    return output
end

function Obfuscator.obfuscateFile(inputPath, outputPath, config)
    local f = io.open(inputPath, "r")
    if not f then error("Cannot open: " .. inputPath) end
    local src = f:read("*all"); f:close()

    local result = Obfuscator.obfuscate(src, config)

    local out = io.open(outputPath, "w")
    if not out then error("Cannot write: " .. outputPath) end
    out:write(result); out:close()

    return true
end

return Obfuscator
