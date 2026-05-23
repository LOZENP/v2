-- parser.lua
-- Builds an AST from token stream

local Lexer = require("src.lexer")
local TOKEN = Lexer.TOKEN

local Parser = {}

function Parser.new(tokens)
    local self = {
        tokens = tokens,
        pos    = 1,
    }

    local function peek(offset)
        local idx = self.pos + (offset or 0)
        return self.tokens[idx] or {type=TOKEN.EOF, value="<eof>"}
    end
    local function cur() return peek(0) end
    local function advance()
        local t = cur()
        self.pos = self.pos + 1
        return t
    end
    local function check(type, value)
        local t = cur()
        if t.type ~= type then return false end
        if value and t.value ~= value then return false end
        return true
    end
    local function expect(type, value)
        if not check(type, value) then
            local t = cur()
            error(("expected %s %q but got %s %q at line %d"):format(
                type, tostring(value), t.type, tostring(t.value), t.line or 0))
        end
        return advance()
    end
    local function match(type, value)
        if check(type, value) then return advance() end
    end

    -- Forward declarations
    local parseExpr, parseStmt, parseBlock

    -- ==================== EXPRESSIONS ====================

    local function parseArgs()
        if check(TOKEN.OP, "(") then
            advance()
            local args = {}
            if not check(TOKEN.OP, ")") then
                table.insert(args, parseExpr())
                while match(TOKEN.OP, ",") do
                    table.insert(args, parseExpr())
                end
            end
            expect(TOKEN.OP, ")")
            return args
        elseif check(TOKEN.STRING) then
            local t = advance()
            return {{tag="String", value=t.value}}
        elseif check(TOKEN.OP, "{") then
            return {parseExpr()}
        else
            error("expected function arguments at line " .. (cur().line or 0))
        end
    end

    local function parsePrimaryExpr()
        local t = cur()
        local node

        if t.type == TOKEN.NAME then
            advance()
            node = {tag="Name", name=t.value, line=t.line}
        elseif check(TOKEN.OP, "(") then
            advance()
            node = parseExpr()
            expect(TOKEN.OP, ")")
            node = {tag="Paren", expr=node}
        else
            error(("unexpected token %q at line %d"):format(t.value, t.line or 0))
        end

        -- suffixes: . [] : ()
        while true do
            local s = cur()
            if s.value == "." then
                advance()
                local field = expect(TOKEN.NAME)
                node = {tag="Index", obj=node, key={tag="String", value=field.value}, line=field.line}
            elseif s.value == "[" then
                advance()
                local key = parseExpr()
                expect(TOKEN.OP, "]")
                node = {tag="Index", obj=node, key=key}
            elseif s.value == ":" then
                advance()
                local method = expect(TOKEN.NAME)
                local args = parseArgs()
                node = {tag="MethodCall", obj=node, method=method.value, args=args, line=method.line}
            elseif s.value == "(" or s.type == TOKEN.STRING or s.value == "{" then
                local args = parseArgs()
                node = {tag="Call", func=node, args=args, line=s.line}
            else
                break
            end
        end

        return node
    end

    local function parseSimpleExpr()
        local t = cur()

        if t.type == TOKEN.NUMBER then
            advance()
            return {tag="Number", value=t.value}
        elseif t.type == TOKEN.STRING then
            advance()
            return {tag="String", value=t.value}
        elseif t.value == "true" then
            advance(); return {tag="Bool", value=true}
        elseif t.value == "false" then
            advance(); return {tag="Bool", value=false}
        elseif t.value == "nil" then
            advance(); return {tag="Nil"}
        elseif t.value == "..." then
            advance(); return {tag="Vararg"}
        elseif t.value == "function" then
            advance()
            return parseFuncBody()
        elseif t.value == "{" then
            return parseTableConstructor()
        else
            return parsePrimaryExpr()
        end
    end

    local UNARY_OPS = {["-"]=true, ["not"]=true, ["#"]=true, ["~"]=true}
    local BINARY_PRIORITY = {
        ["or"]  = {1,1},
        ["and"] = {2,2},
        ["<"]   = {3,3}, [">"]={3,3}, ["<="]={3,3}, [">="]={3,3},
        ["=="]  = {3,3}, ["~="]={3,3},
        [".."]  = {5,4}, -- right assoc
        ["+"]   = {6,6}, ["-"]={6,6},
        ["*"]   = {7,7}, ["/"]={7,7}, ["%"]={7,7}, ["//"]={7,7},
        ["^"]   = {9,8}, -- right assoc
    }

    parseExpr = function(minPriority)
        minPriority = minPriority or 0
        local node

        local t = cur()
        if UNARY_OPS[t.value] then
            advance()
            local operand = parseExpr(8) -- unary priority
            node = {tag="UnOp", op=t.value, operand=operand}
        else
            node = parseSimpleExpr()
        end

        while true do
            local op = cur().value
            local prio = BINARY_PRIORITY[op]
            if not prio or prio[1] <= minPriority then break end
            advance()
            local right = parseExpr(prio[2])
            node = {tag="BinOp", op=op, left=node, right=right}
        end

        return node
    end

    function parseTableConstructor()
        expect(TOKEN.OP, "{")
        local fields = {}
        while not check(TOKEN.OP, "}") do
            if check(TOKEN.OP, "[") then
                advance()
                local key = parseExpr()
                expect(TOKEN.OP, "]")
                expect(TOKEN.OP, "=")
                local val = parseExpr()
                table.insert(fields, {tag="IndexedField", key=key, value=val})
            elseif check(TOKEN.NAME) and peek(1).value == "=" then
                local name = advance()
                advance() -- =
                local val = parseExpr()
                table.insert(fields, {tag="NamedField", name=name.value, value=val})
            else
                local val = parseExpr()
                table.insert(fields, {tag="ValueField", value=val})
            end
            if not match(TOKEN.OP, ",") then match(TOKEN.OP, ";") end
        end
        expect(TOKEN.OP, "}")
        return {tag="Table", fields=fields}
    end

    function parseFuncBody()
        expect(TOKEN.OP, "(")
        local params = {}
        local hasVararg = false
        if not check(TOKEN.OP, ")") then
            if check(TOKEN.OP, "...") then
                hasVararg = true
                advance()
            else
                local p = expect(TOKEN.NAME)
                table.insert(params, p.value)
                while match(TOKEN.OP, ",") do
                    if check(TOKEN.OP, "...") then
                        hasVararg = true
                        advance()
                        break
                    end
                    local p2 = expect(TOKEN.NAME)
                    table.insert(params, p2.value)
                end
            end
        end
        expect(TOKEN.OP, ")")
        local body = parseBlock()
        expect(TOKEN.KEYWORD, "end")
        return {tag="Function", params=params, hasVararg=hasVararg, body=body}
    end

    -- ==================== STATEMENTS ====================

    local function parseAssignOrCall(first)
        -- first is already parsed primary expr
        -- check if it's an assignment
        if check(TOKEN.OP, ",") or check(TOKEN.OP, "=") then
            local targets = {first}
            while match(TOKEN.OP, ",") do
                table.insert(targets, parsePrimaryExpr())
            end
            expect(TOKEN.OP, "=")
            local values = {parseExpr()}
            while match(TOKEN.OP, ",") do
                table.insert(values, parseExpr())
            end
            return {tag="Assign", targets=targets, values=values}
        -- compound assignment (Luau)
        elseif cur().value == "+=" or cur().value == "-=" or
               cur().value == "*=" or cur().value == "/=" then
            local op = advance().value
            local val = parseExpr()
            local binOp = op:sub(1,1)
            return {tag="Assign", targets={first},
                values={{tag="BinOp", op=binOp, left=first, right=val}}}
        else
            -- must be a call statement
            if first.tag ~= "Call" and first.tag ~= "MethodCall" then
                error("syntax error: expected assignment or call at line " .. (cur().line or 0))
            end
            return {tag="CallStmt", expr=first}
        end
    end

    parseStmt = function()
        local t = cur()

        if t.value == "local" then
            advance()
            if check(TOKEN.KEYWORD, "function") then
                advance()
                local name = expect(TOKEN.NAME)
                local func = parseFuncBody()
                return {tag="LocalFunc", name=name.value, func=func}
            else
                local names = {expect(TOKEN.NAME).value}
                while match(TOKEN.OP, ",") do
                    table.insert(names, expect(TOKEN.NAME).value)
                end
                local values = {}
                if match(TOKEN.OP, "=") then
                    table.insert(values, parseExpr())
                    while match(TOKEN.OP, ",") do
                        table.insert(values, parseExpr())
                    end
                end
                return {tag="Local", names=names, values=values}
            end

        elseif t.value == "function" then
            advance()
            local name = expect(TOKEN.NAME)
            local nameNode = {tag="Name", name=name.value}
            while check(TOKEN.OP, ".") do
                advance()
                local field = expect(TOKEN.NAME)
                nameNode = {tag="Index", obj=nameNode, key={tag="String", value=field.value}}
            end
            local isMethod = false
            if check(TOKEN.OP, ":") then
                advance()
                local method = expect(TOKEN.NAME)
                nameNode = {tag="Index", obj=nameNode, key={tag="String", value=method.value}}
                isMethod = true
            end
            local func = parseFuncBody()
            if isMethod then
                table.insert(func.params, 1, "self")
            end
            return {tag="Assign", targets={nameNode}, values={func}}

        elseif t.value == "if" then
            advance()
            local cond = parseExpr()
            expect(TOKEN.KEYWORD, "then")
            local body = parseBlock()
            local elseifs = {}
            local elsebody
            while check(TOKEN.KEYWORD, "elseif") do
                advance()
                local econd = parseExpr()
                expect(TOKEN.KEYWORD, "then")
                local ebody = parseBlock()
                table.insert(elseifs, {cond=econd, body=ebody})
            end
            if match(TOKEN.KEYWORD, "else") then
                elsebody = parseBlock()
            end
            expect(TOKEN.KEYWORD, "end")
            return {tag="If", cond=cond, body=body, elseifs=elseifs, elsebody=elsebody}

        elseif t.value == "while" then
            advance()
            local cond = parseExpr()
            expect(TOKEN.KEYWORD, "do")
            local body = parseBlock()
            expect(TOKEN.KEYWORD, "end")
            return {tag="While", cond=cond, body=body}

        elseif t.value == "repeat" then
            advance()
            local body = parseBlock()
            expect(TOKEN.KEYWORD, "until")
            local cond = parseExpr()
            return {tag="Repeat", body=body, cond=cond}

        elseif t.value == "for" then
            advance()
            local first = expect(TOKEN.NAME).value
            if match(TOKEN.OP, "=") then
                -- numeric for
                local start = parseExpr()
                expect(TOKEN.OP, ",")
                local stop = parseExpr()
                local step
                if match(TOKEN.OP, ",") then step = parseExpr() end
                expect(TOKEN.KEYWORD, "do")
                local body = parseBlock()
                expect(TOKEN.KEYWORD, "end")
                return {tag="NumFor", var=first, start=start, stop=stop, step=step, body=body}
            else
                -- generic for
                local names = {first}
                while match(TOKEN.OP, ",") do
                    table.insert(names, expect(TOKEN.NAME).value)
                end
                expect(TOKEN.KEYWORD, "in")
                local iters = {parseExpr()}
                while match(TOKEN.OP, ",") do
                    table.insert(iters, parseExpr())
                end
                expect(TOKEN.KEYWORD, "do")
                local body = parseBlock()
                expect(TOKEN.KEYWORD, "end")
                return {tag="GenFor", names=names, iters=iters, body=body}
            end

        elseif t.value == "do" then
            advance()
            local body = parseBlock()
            expect(TOKEN.KEYWORD, "end")
            return {tag="Do", body=body}

        elseif t.value == "return" then
            advance()
            local values = {}
            if not check(TOKEN.KEYWORD, "end") and
               not check(TOKEN.KEYWORD, "else") and
               not check(TOKEN.KEYWORD, "elseif") and
               not check(TOKEN.KEYWORD, "until") and
               not check(TOKEN.EOF) then
                table.insert(values, parseExpr())
                while match(TOKEN.OP, ",") do
                    table.insert(values, parseExpr())
                end
            end
            match(TOKEN.OP, ";")
            return {tag="Return", values=values}

        elseif t.value == "break" then
            advance()
            return {tag="Break"}

        elseif t.value == "continue" then
            advance()
            return {tag="Continue"}

        elseif t.value == ";" then
            advance()
            return nil

        else
            local expr = parsePrimaryExpr()
            return parseAssignOrCall(expr)
        end
    end

    parseBlock = function()
        local stmts = {}
        local endTokens = {
            ["end"]=true, ["else"]=true, ["elseif"]=true, ["until"]=true
        }
        while true do
            local t = cur()
            if t.type == TOKEN.EOF then break end
            if endTokens[t.value] then break end
            local s = parseStmt()
            if s then
                table.insert(stmts, s)
                if s.tag == "Return" then break end
            end
        end
        return {tag="Block", stmts=stmts}
    end

    function self.parse()
        local block = parseBlock()
        expect(TOKEN.EOF)
        return block
    end

    return self
end

return Parser
