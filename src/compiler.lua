-- compiler.lua
local Compiler = {}

local OP = {
    LOADK     = 0,
    LOADNIL   = 1,
    LOADBOOL  = 2,
    MOVE      = 3,
    GETGLOBAL = 4,
    SETGLOBAL = 5,
    GETUPVAL  = 6,
    SETUPVAL  = 7,
    GETTABLE  = 8,
    SETTABLE  = 9,
    NEWTABLE  = 10,
    ADD       = 11,
    SUB       = 12,
    MUL       = 13,
    DIV       = 14,
    MOD       = 15,
    POW       = 16,
    IDIV      = 17,
    CONCAT    = 18,
    UNM       = 19,
    NOT       = 20,
    LEN       = 21,
    EQ        = 22,
    LT        = 23,
    LE        = 24,
    JMP       = 25,
    TEST      = 26,
    TESTSET   = 27,
    CALL      = 28,
    TAILCALL  = 29,
    RETURN    = 30,
    FORPREP   = 31,
    FORLOOP   = 32,
    TFORLOOP  = 33,
    SETLIST   = 34,
    CLOSE     = 35,
    CLOSURE   = 36,
    VARARG    = 37,
    SELF      = 38,
}

Compiler.OP = OP
Compiler.OP_COUNT = 39

local KTAG = { NUMBER=0, STRING=1, BOOL=2, NIL=3 }
Compiler.KTAG = KTAG

-- Junk string pool for fake constants
local JUNK_STRINGS = {
    "handler","dispatch","context","resolver","buffer",
    "stream","pipeline","registry","factory","provider",
    "module","service","adapter","wrapper","proxy",
    "scheduler","executor","listener","observer","emitter",
    "cache","store","loader","builder","parser",
    "encoder","decoder","serializer","formatter","validator",
}

local JUNK_NUMBERS = {
    0,1,2,3,4,5,10,16,32,64,100,128,255,256,512,1024,
    3.14159,2.71828,1.41421,0.5,0.25,0.125,
    math.huge, -- won't matter, never executed
}

function Compiler.new()
    local self = {}

    function self.newProto(parent)
        return {
            code      = {},
            consts    = {},
            protos    = {},
            upvals    = {},
            params    = 0,
            hasVararg = false,
            maxStack  = 2,
            parent    = parent,
            _locals   = {},
            _freeReg  = 0,
        }
    end

    function self.addConst(proto, value, tag)
        for i, k in ipairs(proto.consts) do
            if k.tag == tag and k.value == value then
                return i - 1
            end
        end
        table.insert(proto.consts, {tag=tag, value=value})
        return #proto.consts - 1
    end

    function self.addStringConst(proto, s)
        return self.addConst(proto, s, KTAG.STRING)
    end

    function self.addNumberConst(proto, n)
        return self.addConst(proto, n, KTAG.NUMBER)
    end

    -- Inject junk constants to bloat the pool
    function self.injectJunkConsts(proto, count)
        count = count or math.random(4, 10)
        for i = 1, count do
            if math.random(2) == 1 then
                local s = JUNK_STRINGS[math.random(#JUNK_STRINGS)]
                    .. tostring(math.random(100,999))
                self.addStringConst(proto, s)
            else
                local n = JUNK_NUMBERS[math.random(#JUNK_NUMBERS)]
                self.addNumberConst(proto, n)
            end
        end
    end

    -- Emit a real instruction
    function self.emit(proto, op, A, B, C)
        A = A or 0; B = B or 0; C = C or 0
        table.insert(proto.code, {op=op, A=A, B=B, C=C, junk=false})
        local top = A + 1
        if top > proto.maxStack then proto.maxStack = top end
        return #proto.code
    end

    -- Emit junk instructions that are unreachable (after a JMP or RETURN)
    -- or that write to a scratch register and get overwritten
    function self.emitJunk(proto, count)
        count = count or math.random(2, 6)
        -- Use a high scratch register that real code won't touch
        local scratchReg = proto.maxStack + math.random(5, 15)
        for i = 1, count do
            local r = math.random(6)
            if r == 1 then
                -- LOADNIL scratch
                table.insert(proto.code, {op=OP.LOADNIL, A=scratchReg, B=0, C=0, junk=true})
            elseif r == 2 then
                -- LOADBOOL scratch
                table.insert(proto.code, {op=OP.LOADBOOL, A=scratchReg, B=math.random(0,1), C=0, junk=true})
            elseif r == 3 then
                -- LOADK scratch with a junk const
                local kx = self.addStringConst(proto,
                    JUNK_STRINGS[math.random(#JUNK_STRINGS)] .. math.random(9999))
                table.insert(proto.code, {op=OP.LOADK, A=scratchReg, B=kx, C=0, junk=true})
            elseif r == 4 then
                -- MOVE scratch <- scratch
                table.insert(proto.code, {op=OP.MOVE, A=scratchReg, B=scratchReg, C=0, junk=true})
            elseif r == 5 then
                -- ADD scratch <- scratch + scratch (scratch+scratch is 0+0 but never read)
                table.insert(proto.code, {op=OP.ADD, A=scratchReg, B=scratchReg, C=scratchReg, junk=true})
            else
                -- UNM scratch
                table.insert(proto.code, {op=OP.UNM, A=scratchReg, B=scratchReg, C=0, junk=true})
            end
            local top = scratchReg + 1
            if top > proto.maxStack then proto.maxStack = top end
        end
    end

    -- Wrap a real emit with junk before/after
    function self.emitWithNoise(proto, op, A, B, C)
        self.emitJunk(proto, math.random(1, 3))
        local pc = self.emit(proto, op, A, B, C)
        self.emitJunk(proto, math.random(1, 3))
        return pc
    end

    function self.emitsBx(proto, op, A, sBx)
        table.insert(proto.code, {op=op, A=A, B=sBx, C=0, isBx=true, junk=false})
        return #proto.code
    end

    function self.patchJump(proto, instrIdx, target)
        proto.code[instrIdx].B = target - instrIdx
    end

    function self.allocReg(proto)
        local r = proto._freeReg
        proto._freeReg = proto._freeReg + 1
        if proto._freeReg > proto.maxStack then
            proto.maxStack = proto._freeReg
        end
        return r
    end

    function self.freeRegsTo(proto, r)
        proto._freeReg = r
    end

    function self.findLocal(proto, name)
        for i = #proto._locals, 1, -1 do
            if proto._locals[i].name == name then
                return proto._locals[i].reg
            end
        end
        return nil
    end

    function self.findUpval(proto, name)
        for i, uv in ipairs(proto._upvals or {}) do
            if uv.name == name then return i - 1 end
        end
        return nil
    end

    -- Inject a dead proto (never called) to bloat proto list
    function self.injectDeadProto(proto)
        local dead = self.newProto(proto)
        dead.params = math.random(0, 3)
        dead.hasVararg = false
        self.injectJunkConsts(dead, math.random(3, 8))
        -- emit some junk instructions
        local sr = 0
        for i = 1, math.random(4, 10) do
            local kx = self.addStringConst(dead,
                JUNK_STRINGS[math.random(#JUNK_STRINGS)])
            table.insert(dead.code, {op=OP.LOADK, A=sr, B=kx, C=0, junk=false})
        end
        table.insert(dead.code, {op=OP.RETURN, A=0, B=1, C=0, junk=false})
        dead.maxStack = 4
        table.insert(proto.protos, dead)
    end

    -- ===================== EXPRESSION COMPILER =====================

    function self.compileExpr(proto, node, dest)
        if dest == nil then dest = proto._freeReg end
        local savedFR = proto._freeReg
        local tag = node.tag

        if tag == "Number" then
            local kx = self.addNumberConst(proto, node.value)
            self.emit(proto, OP.LOADK, dest, kx)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "String" then
            local kx = self.addStringConst(proto, node.value)
            self.emit(proto, OP.LOADK, dest, kx)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Bool" then
            self.emit(proto, OP.LOADBOOL, dest, node.value and 1 or 0, 0)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Nil" then
            self.emit(proto, OP.LOADNIL, dest)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Vararg" then
            self.emit(proto, OP.VARARG, dest, 1)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Name" then
            local reg = self.findLocal(proto, node.name)
            if reg then
                if dest ~= reg then
                    self.emit(proto, OP.MOVE, dest, reg)
                end
            else
                local uv = self.findUpval(proto, node.name)
                if uv then
                    self.emit(proto, OP.GETUPVAL, dest, uv)
                else
                    local kx = self.addStringConst(proto, node.name)
                    self.emit(proto, OP.GETGLOBAL, dest, kx)
                end
            end
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Paren" then
            self.compileExpr(proto, node.expr, dest)

        elseif tag == "UnOp" then
            local rSrc = proto._freeReg
            if rSrc == dest then rSrc = dest + 1 end
            proto._freeReg = rSrc + 1
            self.compileExpr(proto, node.operand, rSrc)
            local opmap = {["-"]=OP.UNM, ["not"]=OP.NOT, ["#"]=OP.LEN}
            self.emit(proto, opmap[node.op] or OP.UNM, dest, rSrc)
            proto._freeReg = dest + 1

        elseif tag == "BinOp" then
            local op = node.op
            local cmpOps = {
                ["=="]=OP.EQ,  ["~="]=OP.EQ,
                ["<"] =OP.LT,  ["<="] =OP.LE,
                [">"] =OP.LT,  [">="] =OP.LE,
            }
            if cmpOps[op] then
                local rL = proto._freeReg
                local rR = rL + 1
                proto._freeReg = rR + 1
                local leftNode  = node.left
                local rightNode = node.right
                if op == ">" or op == ">=" then
                    leftNode, rightNode = rightNode, leftNode
                end
                self.compileExpr(proto, leftNode,  rL)
                self.compileExpr(proto, rightNode, rR)
                local inv = (op == "~=") and 0 or 1
                self.emit(proto, cmpOps[op], inv, rL, rR)
                self.emit(proto, OP.JMP, 0, 1)
                self.emit(proto, OP.LOADBOOL, dest, 1, 1)
                self.emit(proto, OP.LOADBOOL, dest, 0, 0)
                proto._freeReg = dest + 1

            elseif op == "and" then
                self.compileExpr(proto, node.left, dest)
                self.emit(proto, OP.TEST, dest, 0, 0)
                local jmp = self.emit(proto, OP.JMP, 0, 0)
                self.compileExpr(proto, node.right, dest)
                self.patchJump(proto, jmp, #proto.code + 1)
                proto._freeReg = dest + 1

            elseif op == "or" then
                self.compileExpr(proto, node.left, dest)
                self.emit(proto, OP.TEST, dest, 0, 1)
                local jmp = self.emit(proto, OP.JMP, 0, 0)
                self.compileExpr(proto, node.right, dest)
                self.patchJump(proto, jmp, #proto.code + 1)
                proto._freeReg = dest + 1

            elseif op == ".." then
                local rL = proto._freeReg
                local rR = rL + 1
                proto._freeReg = rR + 1
                self.compileExpr(proto, node.left,  rL)
                self.compileExpr(proto, node.right, rR)
                self.emit(proto, OP.CONCAT, dest, rL, rR)
                proto._freeReg = dest + 1

            else
                local opmap = {
                    ["+"]=OP.ADD, ["-"]=OP.SUB, ["*"]=OP.MUL,
                    ["/"]=OP.DIV, ["%"]=OP.MOD, ["^"]=OP.POW,
                    ["//"]=OP.IDIV,
                }
                local rL = proto._freeReg
                local rR = rL + 1
                proto._freeReg = rR + 1
                self.compileExpr(proto, node.left,  rL)
                self.compileExpr(proto, node.right, rR)
                self.emit(proto, opmap[op] or OP.ADD, dest, rL, rR)
                proto._freeReg = dest + 1
            end

        elseif tag == "Index" then
            local rObj = proto._freeReg
            local rKey = rObj + 1
            proto._freeReg = rKey + 1
            self.compileExpr(proto, node.obj, rObj)
            self.compileExpr(proto, node.key, rKey)
            self.emit(proto, OP.GETTABLE, dest, rObj, rKey)
            proto._freeReg = dest + 1

        elseif tag == "Call" then
            local rFunc = proto._freeReg
            proto._freeReg = rFunc + 1
            self.compileExpr(proto, node.func, rFunc)
            local argBase = rFunc + 1
            proto._freeReg = argBase
            for _, arg in ipairs(node.args) do
                local r = proto._freeReg
                self.compileExpr(proto, arg, r)
                proto._freeReg = r + 1
            end
            local nArgs = #node.args + 1
            self.emit(proto, OP.CALL, rFunc, nArgs, 2)
            if dest ~= rFunc then
                self.emit(proto, OP.MOVE, dest, rFunc)
            end
            proto._freeReg = dest + 1

        elseif tag == "MethodCall" then
            local rBase = proto._freeReg
            proto._freeReg = rBase + 1
            self.compileExpr(proto, node.obj, rBase)
            local rKey = proto._freeReg
            proto._freeReg = rKey + 1
            local kx = self.addStringConst(proto, node.method)
            self.emit(proto, OP.LOADK, rKey, kx)
            self.emit(proto, OP.SELF, rBase, rBase, rKey)
            local argBase = rBase + 2
            proto._freeReg = argBase
            for _, arg in ipairs(node.args) do
                local r = proto._freeReg
                self.compileExpr(proto, arg, r)
                proto._freeReg = r + 1
            end
            local nArgs = #node.args + 2 + 1
            self.emit(proto, OP.CALL, rBase, nArgs, 2)
            if dest ~= rBase then
                self.emit(proto, OP.MOVE, dest, rBase)
            end
            proto._freeReg = dest + 1

        elseif tag == "Function" then
            local childProto = self.compileFunction(proto, node)
            -- inject dead protos alongside real ones for bulk
            for i = 1, math.random(1, 3) do
                self.injectDeadProto(proto)
            end
            local protoIdx = #proto.protos
            table.insert(proto.protos, childProto)
            self.emit(proto, OP.CLOSURE, dest, protoIdx)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Table" then
            self.emit(proto, OP.NEWTABLE, dest, 0, 0)
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end
            local arrIdx = 1
            for _, field in ipairs(node.fields) do
                if field.tag == "ValueField" then
                    local rVal = proto._freeReg
                    proto._freeReg = rVal + 1
                    self.compileExpr(proto, field.value, rVal)
                    local rKey = proto._freeReg
                    proto._freeReg = rKey + 1
                    self.emit(proto, OP.LOADK, rKey,
                        self.addNumberConst(proto, arrIdx))
                    self.emit(proto, OP.SETTABLE, dest, rKey, rVal)
                    proto._freeReg = dest + 1
                    arrIdx = arrIdx + 1
                elseif field.tag == "NamedField" then
                    local rVal = proto._freeReg
                    proto._freeReg = rVal + 1
                    self.compileExpr(proto, field.value, rVal)
                    local rKey = proto._freeReg
                    proto._freeReg = rKey + 1
                    self.emit(proto, OP.LOADK, rKey,
                        self.addStringConst(proto, field.name))
                    self.emit(proto, OP.SETTABLE, dest, rKey, rVal)
                    proto._freeReg = dest + 1
                elseif field.tag == "IndexedField" then
                    local rVal = proto._freeReg
                    proto._freeReg = rVal + 1
                    self.compileExpr(proto, field.value, rVal)
                    local rKey = proto._freeReg
                    proto._freeReg = rKey + 1
                    self.compileExpr(proto, field.key, rKey)
                    self.emit(proto, OP.SETTABLE, dest, rKey, rVal)
                    proto._freeReg = dest + 1
                end
            end
        end

        return dest
    end

    -- ===================== STATEMENT COMPILER =====================

    function self.compileStmt(proto, node, breakList, contTarget)
        local tag = node.tag

        -- inject junk constants + dead instructions before each real statement
        self.injectJunkConsts(proto, math.random(2, 5))
        self.emitJunk(proto, math.random(2, 5))

        if tag == "Local" then
            for i, name in ipairs(node.names) do
                local reg = proto._freeReg
                proto._freeReg = reg + 1
                local val = node.values[i]
                if val then
                    self.compileExpr(proto, val, reg)
                else
                    self.emit(proto, OP.LOADNIL, reg)
                end
                table.insert(proto._locals, {name=name, reg=reg})
            end

        elseif tag == "LocalFunc" then
            local reg = proto._freeReg
            proto._freeReg = reg + 1
            table.insert(proto._locals, {name=node.name, reg=reg})
            for i = 1, math.random(1, 2) do
                self.injectDeadProto(proto)
            end
            local childProto = self.compileFunction(proto, node.func)
            local protoIdx = #proto.protos
            table.insert(proto.protos, childProto)
            self.emit(proto, OP.CLOSURE, reg, protoIdx)

        elseif tag == "Assign" then
            local tmpRegs = {}
            local savedFR = proto._freeReg
            for i, val in ipairs(node.values) do
                local r = proto._freeReg
                proto._freeReg = r + 1
                self.compileExpr(proto, val, r)
                tmpRegs[i] = r
            end
            for i, target in ipairs(node.targets) do
                local valReg = tmpRegs[i]
                if not valReg then
                    valReg = proto._freeReg
                    proto._freeReg = valReg + 1
                    self.emit(proto, OP.LOADNIL, valReg)
                end
                if target.tag == "Name" then
                    local localReg = self.findLocal(proto, target.name)
                    if localReg then
                        if localReg ~= valReg then
                            self.emit(proto, OP.MOVE, localReg, valReg)
                        end
                    else
                        local uv = self.findUpval(proto, target.name)
                        if uv then
                            self.emit(proto, OP.SETUPVAL, valReg, uv)
                        else
                            local kx = self.addStringConst(proto, target.name)
                            self.emit(proto, OP.SETGLOBAL, valReg, kx)
                        end
                    end
                elseif target.tag == "Index" then
                    local rObj = proto._freeReg
                    local rKey = rObj + 1
                    proto._freeReg = rKey + 1
                    self.compileExpr(proto, target.obj, rObj)
                    self.compileExpr(proto, target.key, rKey)
                    self.emit(proto, OP.SETTABLE, rObj, rKey, valReg)
                    proto._freeReg = savedFR
                end
            end
            proto._freeReg = savedFR

        elseif tag == "CallStmt" then
            local savedFR = proto._freeReg
            self.compileExpr(proto, node.expr, proto._freeReg)
            proto._freeReg = savedFR

        elseif tag == "Do" then
            local savedLocals = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, breakList, contTarget)
            while #proto._locals > savedLocals do
                table.remove(proto._locals)
            end
            proto._freeReg = savedFR

        elseif tag == "If" then
            local exitJmps = {}
            local function compileIf(cond, body)
                local rCond = proto._freeReg
                proto._freeReg = rCond + 1
                self.compileExpr(proto, cond, rCond)
                self.emit(proto, OP.TEST, rCond, 0, 0)
                local jmpFalse = self.emit(proto, OP.JMP, 0, 0)
                local savedLocals = #proto._locals
                local savedFR = proto._freeReg
                self.compileBlock(body, proto, breakList, contTarget)
                while #proto._locals > savedLocals do
                    table.remove(proto._locals)
                end
                proto._freeReg = savedFR
                local jmpExit = self.emit(proto, OP.JMP, 0, 0)
                table.insert(exitJmps, jmpExit)
                self.patchJump(proto, jmpFalse, #proto.code + 1)
            end
            compileIf(node.cond, node.body)
            for _, ei in ipairs(node.elseifs) do
                compileIf(ei.cond, ei.body)
            end
            if node.elsebody then
                local savedLocals = #proto._locals
                local savedFR = proto._freeReg
                self.compileBlock(node.elsebody, proto, breakList, contTarget)
                while #proto._locals > savedLocals do
                    table.remove(proto._locals)
                end
                proto._freeReg = savedFR
            end
            for _, j in ipairs(exitJmps) do
                self.patchJump(proto, j, #proto.code + 1)
            end

        elseif tag == "While" then
            local loopStart = #proto.code + 1
            local rCond = proto._freeReg
            proto._freeReg = rCond + 1
            self.compileExpr(proto, node.cond, rCond)
            self.emit(proto, OP.TEST, rCond, 0, 0)
            local jmpExit = self.emit(proto, OP.JMP, 0, 0)
            local myBreaks = {}
            local savedLocals = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, loopStart)
            while #proto._locals > savedLocals do
                table.remove(proto._locals)
            end
            proto._freeReg = savedFR
            -- jump back to loop start
            local backJmp = self.emit(proto, OP.JMP, 0, 0)
            self.patchJump(proto, backJmp, loopStart)
            self.patchJump(proto, jmpExit, #proto.code + 1)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code + 1)
            end

        elseif tag == "Repeat" then
            local loopStart = #proto.code + 1
            local myBreaks = {}
            local savedLocals = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, loopStart)
            while #proto._locals > savedLocals do
                table.remove(proto._locals)
            end
            proto._freeReg = savedFR
            local rCond = proto._freeReg
            proto._freeReg = rCond + 1
            self.compileExpr(proto, node.cond, rCond)
            self.emit(proto, OP.TEST, rCond, 0, 0)
            local backJmp = self.emit(proto, OP.JMP, 0, 0)
            self.patchJump(proto, backJmp, loopStart)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code + 1)
            end

        elseif tag == "NumFor" then
            local rBase = proto._freeReg
            proto._freeReg = rBase + 4
            self.compileExpr(proto, node.start, rBase)
            self.compileExpr(proto, node.stop,  rBase + 1)
            if node.step then
                self.compileExpr(proto, node.step, rBase + 2)
            else
                self.emit(proto, OP.LOADK, rBase + 2,
                    self.addNumberConst(proto, 1))
            end
            local forPrep = self.emit(proto, OP.FORPREP, rBase, 0)
            local loopStart = #proto.code + 1
            table.insert(proto._locals, {name=node.var, reg=rBase + 3})
            local myBreaks = {}
            local savedLocals = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, nil)
            while #proto._locals > savedLocals do
                table.remove(proto._locals)
            end
            -- remove loop var
            for i = #proto._locals, 1, -1 do
                if proto._locals[i].name == node.var then
                    table.remove(proto._locals, i); break
                end
            end
            proto._freeReg = savedFR
            local forLoop = self.emit(proto, OP.FORLOOP, rBase, 0)
            self.patchJump(proto, forPrep, #proto.code)   -- FORPREP jumps to after FORLOOP
            self.patchJump(proto, forLoop, loopStart)     -- FORLOOP jumps back to body start
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code + 1)
            end
            proto._freeReg = rBase

        elseif tag == "GenFor" then
            local rBase = proto._freeReg
            proto._freeReg = rBase + 3 + #node.names
            local iters = node.iters
            self.compileExpr(proto, iters[1] or {tag="Nil"}, rBase)
            self.compileExpr(proto, iters[2] or {tag="Nil"}, rBase + 1)
            self.compileExpr(proto, iters[3] or {tag="Nil"}, rBase + 2)
            local myBreaks = {}
            local loopJmp = self.emit(proto, OP.JMP, 0, 0)
            local loopStart = #proto.code + 1
            local savedLocals = #proto._locals
            for i, name in ipairs(node.names) do
                table.insert(proto._locals, {name=name, reg=rBase + 2 + i})
            end
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, nil)
            while #proto._locals > savedLocals do
                table.remove(proto._locals)
            end
            proto._freeReg = savedFR
            self.patchJump(proto, loopJmp, #proto.code + 1)
            self.emit(proto, OP.TFORLOOP, rBase, 0, #node.names)
            local backJmp = self.emit(proto, OP.JMP, 0, 0)
            self.patchJump(proto, backJmp, loopStart)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code + 1)
            end
            proto._freeReg = rBase

        elseif tag == "Return" then
            local rBase = proto._freeReg
            for i, val in ipairs(node.values) do
                self.compileExpr(proto, val, rBase + i - 1)
            end
            self.emit(proto, OP.RETURN, rBase, #node.values + 1)

        elseif tag == "Break" then
            local jmp = self.emit(proto, OP.JMP, 0, 0)
            table.insert(breakList, jmp)

        elseif tag == "Continue" then
            if contTarget then
                local jmp = self.emit(proto, OP.JMP, 0, 0)
                self.patchJump(proto, jmp, contTarget)
            end
        end
    end

    function self.compileBlock(block, proto, breakList, contTarget)
        local savedLocals = #proto._locals
        local savedFR = proto._freeReg
        for _, stmt in ipairs(block.stmts) do
            self.compileStmt(proto, stmt, breakList, contTarget)
        end
        while #proto._locals > savedLocals do
            table.remove(proto._locals)
        end
        proto._freeReg = savedFR
        return proto
    end

    function self.compileFunction(parentProto, node)
        local proto = self.newProto(parentProto)
        proto.params    = #node.params
        proto.hasVararg = node.hasVararg
        -- inject junk constants into every function proto
        self.injectJunkConsts(proto, math.random(4, 8))
        for _, p in ipairs(node.params) do
            local reg = proto._freeReg
            proto._freeReg = reg + 1
            table.insert(proto._locals, {name=p, reg=reg})
        end
        self.compileBlock(node.body, proto, {}, nil)
        if #proto.code == 0 or
           proto.code[#proto.code].op ~= OP.RETURN then
            self.emit(proto, OP.RETURN, 0, 1)
        end
        return proto
    end

    function self.compileAST(ast)
        local proto = self.newProto(nil)
        proto.hasVararg = true
        -- bulk-inject junk constants at top level
        self.injectJunkConsts(proto, math.random(8, 16))
        -- inject some dead protos at top level for bulk
        for i = 1, math.random(2, 4) do
            self.injectDeadProto(proto)
        end
        self.compileBlock(ast, proto, {}, nil)
        if #proto.code == 0 or
           proto.code[#proto.code].op ~= OP.RETURN then
            self.emit(proto, OP.RETURN, 0, 1)
        end
        return proto
    end

    return self
end

return Compiler
