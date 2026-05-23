-- lexer.lua
-- Tokenizer for Lua 5.1 / Luau

local Lexer = {}

local KEYWORDS = {
    ["and"]=true,["break"]=true,["do"]=true,["else"]=true,
    ["elseif"]=true,["end"]=true,["false"]=true,["for"]=true,
    ["function"]=true,["if"]=true,["in"]=true,["local"]=true,
    ["nil"]=true,["not"]=true,["or"]=true,["repeat"]=true,
    ["return"]=true,["then"]=true,["true"]=true,["until"]=true,
    ["while"]=true,
    -- Luau extras
    ["continue"]=true,["type"]=true,["export"]=true,
}

local TOKEN = {
    NUMBER   = "NUMBER",
    STRING   = "STRING",
    NAME     = "NAME",
    KEYWORD  = "KEYWORD",
    OP       = "OP",
    EOF      = "EOF",
}

function Lexer.new(source)
    local self = {
        src    = source,
        pos    = 1,
        line   = 1,
        tokens = {},
    }

    local src = self.src

    local function peek(offset)
        local p = self.pos + (offset or 0)
        return src:sub(p, p)
    end

    local function advance(n)
        n = n or 1
        self.pos = self.pos + n
    end

    local function cur() return peek(0) end

    local function isDigit(c) return c >= "0" and c <= "9" end
    local function isAlpha(c)
        return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
    end
    local function isAlNum(c) return isAlpha(c) or isDigit(c) end

    local function skipLineComment()
        while self.pos <= #src and cur() ~= "\n" do
            advance()
        end
    end

    local function skipBlockComment(level)
        -- already consumed --[=*[
        local closing = "]" .. string.rep("=", level) .. "]"
        local s, e = src:find(closing, self.pos, true)
        if s then
            -- count newlines
            for nl in src:sub(self.pos, e):gmatch("\n") do
                self.line = self.line + 1
            end
            self.pos = e + 1
        else
            error("unfinished long comment at line " .. self.line)
        end
    end

    local function readLongString(level)
        local closing = "]" .. string.rep("=", level) .. "]"
        local s, e = src:find(closing, self.pos, true)
        if not s then
            error("unfinished long string at line " .. self.line)
        end
        local val = src:sub(self.pos, s - 1)
        for _ in val:gmatch("\n") do self.line = self.line + 1 end
        self.pos = e + 1
        return val
    end

    local function readString(delim)
        advance() -- skip opening quote
        local result = {}
        while self.pos <= #src do
            local c = cur()
            if c == delim then
                advance()
                break
            elseif c == "\\" then
                advance()
                local e = cur()
                advance()
                local escapes = {
                    n="\n", t="\t", r="\r",
                    ["\\"]="\\", ['"']='"', ["'"]=  "'",
                    a="\a", b="\b", f="\f", v="\v",
                }
                if escapes[e] then
                    table.insert(result, escapes[e])
                elseif isDigit(e) then
                    local numStr = e
                    if isDigit(cur()) then numStr = numStr .. cur(); advance() end
                    if isDigit(cur()) then numStr = numStr .. cur(); advance() end
                    table.insert(result, string.char(tonumber(numStr)))
                else
                    table.insert(result, e)
                end
            elseif c == "\n" then
                self.line = self.line + 1
                table.insert(result, c)
                advance()
            else
                table.insert(result, c)
                advance()
            end
        end
        return table.concat(result)
    end

    local function readNumber()
        local start = self.pos
        -- hex
        if cur() == "0" and (peek(1) == "x" or peek(1) == "X") then
            advance(2)
            while isDigit(cur()) or (cur() >= "a" and cur() <= "f") or (cur() >= "A" and cur() <= "F") do
                advance()
            end
        else
            while isDigit(cur()) do advance() end
            if cur() == "." then
                advance()
                while isDigit(cur()) do advance() end
            end
            if cur() == "e" or cur() == "E" then
                advance()
                if cur() == "+" or cur() == "-" then advance() end
                while isDigit(cur()) do advance() end
            end
        end
        return tonumber(src:sub(start, self.pos - 1))
    end

    function self.tokenize()
        while self.pos <= #src do
            local c = cur()

            -- whitespace
            if c == " " or c == "\t" or c == "\r" then
                advance()

            elseif c == "\n" then
                self.line = self.line + 1
                advance()

            -- comments
            elseif c == "-" and peek(1) == "-" then
                advance(2)
                if cur() == "[" then
                    local level = 0
                    local p2 = self.pos + 1
                    while src:sub(p2, p2) == "=" do
                        level = level + 1
                        p2 = p2 + 1
                    end
                    if src:sub(p2, p2) == "[" then
                        self.pos = p2 + 1
                        skipBlockComment(level)
                    else
                        skipLineComment()
                    end
                else
                    skipLineComment()
                end

            -- long strings
            elseif c == "[" then
                local level = 0
                local p2 = self.pos + 1
                while src:sub(p2, p2) == "=" do
                    level = level + 1
                    p2 = p2 + 1
                end
                if src:sub(p2, p2) == "[" then
                    self.pos = p2 + 1
                    local val = readLongString(level)
                    table.insert(self.tokens, {type=TOKEN.STRING, value=val, line=self.line})
                else
                    table.insert(self.tokens, {type=TOKEN.OP, value="[", line=self.line})
                    advance()
                end

            -- strings
            elseif c == '"' or c == "'" then
                local line = self.line
                local val = readString(c)
                table.insert(self.tokens, {type=TOKEN.STRING, value=val, line=line})

            -- numbers
            elseif isDigit(c) or (c == "." and isDigit(peek(1))) then
                local line = self.line
                local val = readNumber()
                table.insert(self.tokens, {type=TOKEN.NUMBER, value=val, line=line})

            -- identifiers / keywords
            elseif isAlpha(c) then
                local line = self.line
                local start = self.pos
                while isAlNum(cur()) do advance() end
                local word = src:sub(start, self.pos - 1)
                if KEYWORDS[word] then
                    table.insert(self.tokens, {type=TOKEN.KEYWORD, value=word, line=line})
                else
                    table.insert(self.tokens, {type=TOKEN.NAME, value=word, line=line})
                end

            -- backtick interpolated strings (Luau) — treat as string literal (simplified)
            elseif c == "`" then
                local line = self.line
                local val = readString("`")
                table.insert(self.tokens, {type=TOKEN.STRING, value=val, line=line})

            -- multi-char operators
            elseif c == "." then
                if peek(1) == "." and peek(2) == "." then
                    table.insert(self.tokens, {type=TOKEN.OP, value="...", line=self.line})
                    advance(3)
                elseif peek(1) == "." then
                    table.insert(self.tokens, {type=TOKEN.OP, value="..", line=self.line})
                    advance(2)
                else
                    table.insert(self.tokens, {type=TOKEN.OP, value=".", line=self.line})
                    advance()
                end
            elseif c == "=" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="==", line=self.line}); advance(2)
            elseif c == "~" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="~=", line=self.line}); advance(2)
            elseif c == "<" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="<=", line=self.line}); advance(2)
            elseif c == ">" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value=">=", line=self.line}); advance(2)
            elseif c == "/" and peek(1) == "/" then
                table.insert(self.tokens, {type=TOKEN.OP, value="//", line=self.line}); advance(2)
            elseif c == "+" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="+=", line=self.line}); advance(2)
            elseif c == "-" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="-=", line=self.line}); advance(2)
            elseif c == "*" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="*=", line=self.line}); advance(2)
            elseif c == "/" and peek(1) == "=" then
                table.insert(self.tokens, {type=TOKEN.OP, value="/=", line=self.line}); advance(2)
            else
                table.insert(self.tokens, {type=TOKEN.OP, value=c, line=self.line})
                advance()
            end
        end

        table.insert(self.tokens, {type=TOKEN.EOF, value="<eof>", line=self.line})
        return self.tokens
    end

    return self
end

Lexer.TOKEN = TOKEN
Lexer.KEYWORDS = KEYWORDS

return Lexer
