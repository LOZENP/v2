-- compiler.lua
-- Walks AST and emits custom VM instructions

local Compiler = {}

-- Opcodes
local OP = {
    LOADK     = 0,   -- R(A) = K(Bx)
    LOADNIL   = 1,   -- R(A) = nil
    LOADBOOL  = 2,   -- R(A) = (B != 0), if C skip next
    MOVE      = 3,   -- R(A) = R(B)
    GETGLOBAL = 4,   -- R(A) = Gbl[K(Bx)]
    SETGLOBAL = 5,   -- Gbl[K(Bx)] = R(A)
    GETUPVAL  = 6,   -- R(A) = UpVal[B]
    SETUPVAL  = 7,   -- UpVal[B] = R(A)
    GETTABLE  = 8,   -- R(A) = R(B)[RK(C)]
    SETTABLE  = 9,   -- R(A)[RK(B)] = RK(C)
    NEWTABLE  = 10,  -- R(A) = {} 
    ADD       = 11,  -- R(A) = RK(B) + RK(C)
    SUB       = 12,
    MUL       = 13,
    DIV       = 14,
    MOD       = 15,
    POW       = 16,
    IDIV      = 17,  -- floor division
    CONCAT    = 18,  -- R(A) = R(B) .. ... .. R(C)
    UNM       = 19,  -- R(A) = -R(B)
    NOT       = 20,  -- R(A) = not R(B)
    LEN       = 21,  -- R(A) = #R(B)
    EQ        = 22,  -- if (RK(B) == RK(C)) ~= A then skip
    LT        = 23,
    LE        = 24,
    JMP       = 25,  -- pc += sBx
    TEST      = 26,  -- if (bool(R(A)) ~= C) then skip
    TESTSET   = 27,  -- if (bool(R(B)) == C) then R(A)=R(B) else skip
    CALL      = 28,  -- R(A)..R(A+B-2) = R(A)(R(A+1)..R(A+C-1))
    TAILCALL  = 29,
    RETURN    = 30,  -- return R(A)..R(A+B-2)
    FORPREP   = 31,  -- R(A) -= R(A+2); pc += sBx
    FORLOOP   = 32,  -- R(A) += R(A+2); if R(A) <= R(A+1) then pc += sBx
    TFORLOOP  = 33,  -- generic for
    SETLIST   = 34,  -- R(A)[Bx+i] = R(A+i)
    CLOSE     = 35,
    CLOSURE   = 36,  -- R(A) = closure(Proto[Bx])
    VARARG    = 37,  -- R(A)..R(A+B-2) = vararg
    SELF      = 38,  -- R(A+1) = R(B); R(A) = R(B)[RK(C)]
}

Compiler.OP = OP

-- Constant type tags
local KTAG = { NUMBER=0, STRING=1, BOOL=2, NIL=3 }

function Compiler.new()
    local self = {}

    -- Compile source into a Proto tree
    function self.compileAST(ast)
        return self.compileBlock(ast, nil, {}, {})
    end

    function self.newProto(parent)
        return {
            code      = {},   -- instructions {op,A,B,C}
            consts    = {},   -- constant pool
            protos    = {},   -- child protos (closures)
            upvals    = {},   -- upvalue names
            params    = 0,
            hasVararg = false,
            maxStack  = 2,
            parent    = parent,
            -- scratch
            _locals   = {},   -- {name, reg}
            _upvals   = {},
            _freeReg  = 0,
            _breaks   = {},
            _conts    = {},
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

    function self.emit(proto, op, A, B, C)
        A = A or 0; B = B or 0; C = C or 0
        table.insert(proto.code, {op=op, A=A, B=B, C=C})
        local reg = A + 1
        if reg > proto.maxStack then proto.maxStack = reg end
        return #proto.code - 1  -- 0-indexed pc
    end

    function self.emitsBx(proto, op, A, sBx)
        -- sBx stored as B field, will be sign-offset at runtime
        table.insert(proto.code, {op=op, A=A, B=sBx, C=0, isBx=true})
        return #proto.code - 1
    end

    function self.patchJump(proto, instrIdx, target)
        -- target is absolute pc; store offset
        proto.code[instrIdx + 1].B = target - instrIdx - 1
    end

    function self.allocReg(proto)
        local r = proto._freeReg
        proto._freeReg = proto._freeReg + 1
        if proto._freeReg > proto.maxStack then
            proto.maxStack = proto._freeReg
        end
        return r
    end

    function self.freeReg(proto, n)
        proto._freeReg = proto._freeReg - (n or 1)
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
        for i, uv in ipairs(proto._upvals) do
            if uv.name == name then return i - 1 end
        end
        return nil
    end

    function self.addLocal(proto, name)
        local reg = self.allocReg(proto)
        table.insert(proto._locals, {name=name, reg=reg})
        return reg
    end

    -- Compile expression, result goes into dest register
    -- returns the register that holds the result
    function self.compileExpr(proto, node, dest)
        if dest == nil then
            dest = proto._freeReg
        end

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
                    if dest >= proto._freeReg then proto._freeReg = dest + 1 end
                end
            else
                local uv = self.findUpval(proto, node.name)
                if uv then
                    self.emit(proto, OP.GETUPVAL, dest, uv)
                else
                    local kx = self.addStringConst(proto, node.name)
                    self.emit(proto, OP.GETGLOBAL, dest, kx)
                end
                if dest >= proto._freeReg then proto._freeReg = dest + 1 end
            end

        elseif tag == "Paren" then
            self.compileExpr(proto, node.expr, dest)

        elseif tag == "UnOp" then
            local rSrc = proto._freeReg
            self.compileExpr(proto, node.operand, rSrc)
            local opmap = {["-"]=OP.UNM, ["not"]=OP.NOT, ["#"]=OP.LEN}
            self.emit(proto, opmap[node.op] or OP.UNM, dest, rSrc)
            proto._freeReg = rSrc
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "BinOp" then
            local op = node.op
            -- comparison → result is bool via TEST trick
            local cmpOps = {["=="]=OP.EQ, ["~="]=OP.EQ, ["<"]=OP.LT, ["<="]=OP.LE,
                            [">"]=OP.LT, [">="]=OP.LE}
            if cmpOps[op] then
                local rL = proto._freeReg
                local rR = rL + 1
                local leftNode  = node.left
                local rightNode = node.right
                if op == ">" or op == ">=" then
                    leftNode, rightNode = rightNode, leftNode
                end
                self.compileExpr(proto, leftNode,  rL)
                self.compileExpr(proto, rightNode, rR)
                local inv = (op == "~=") and 0 or 1
                self.emit(proto, cmpOps[op], inv, rL, rR)
                self.emit(proto, OP.JMP, 0, 1) -- skip LOADBOOL false
                self.emit(proto, OP.LOADBOOL, dest, 1, 1) -- true, skip next
                self.emit(proto, OP.LOADBOOL, dest, 0, 0) -- false
                proto._freeReg = rL
                if dest >= proto._freeReg then proto._freeReg = dest + 1 end
            elseif op == "and" then
                self.compileExpr(proto, node.left, dest)
                self.emit(proto, OP.TEST, dest, 0, 0)
                local jmp = self.emit(proto, OP.JMP, 0, 0)
                self.compileExpr(proto, node.right, dest)
                self.patchJump(proto, jmp, #proto.code)
            elseif op == "or" then
                self.compileExpr(proto, node.left, dest)
                self.emit(proto, OP.TEST, dest, 0, 1)
                local jmp = self.emit(proto, OP.JMP, 0, 0)
                self.compileExpr(proto, node.right, dest)
                self.patchJump(proto, jmp, #proto.code)
            elseif op == ".." then
                local rL = proto._freeReg
                local rR = rL + 1
                self.compileExpr(proto, node.left,  rL)
                self.compileExpr(proto, node.right, rR)
                self.emit(proto, OP.CONCAT, dest, rL, rR)
                proto._freeReg = rL
                if dest >= proto._freeReg then proto._freeReg = dest + 1 end
            else
                local opmap = {
                    ["+"]=OP.ADD, ["-"]=OP.SUB, ["*"]=OP.MUL,
                    ["/"]=OP.DIV, ["%"]=OP.MOD, ["^"]=OP.POW,
                    ["//"]=OP.IDIV,
                }
                local rL = proto._freeReg
                local rR = rL + 1
                self.compileExpr(proto, node.left,  rL)
                self.compileExpr(proto, node.right, rR)
                self.emit(proto, opmap[op] or OP.ADD, dest, rL, rR)
                proto._freeReg = rL
                if dest >= proto._freeReg then proto._freeReg = dest + 1 end
            end

        elseif tag == "Index" then
            local rObj = proto._freeReg
            local rKey = rObj + 1
            self.compileExpr(proto, node.obj, rObj)
            self.compileExpr(proto, node.key, rKey)
            self.emit(proto, OP.GETTABLE, dest, rObj, rKey)
            proto._freeReg = rObj
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Call" then
            local rFunc = proto._freeReg
            self.compileExpr(proto, node.func, rFunc)
            local argBase = rFunc + 1
            proto._freeReg = argBase
            for _, arg in ipairs(node.args) do
                local r = proto._freeReg
                self.compileExpr(proto, arg, r)
                proto._freeReg = r + 1
            end
            local nArgs = #node.args + 1
            local nRet  = 2 -- 1 return value by default
            self.emit(proto, OP.CALL, rFunc, nArgs, nRet)
            if dest ~= rFunc then
                self.emit(proto, OP.MOVE, dest, rFunc)
            end
            proto._freeReg = rFunc + 1
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "MethodCall" then
            local rBase = proto._freeReg
            local rKey  = rBase + 1
            self.compileExpr(proto, node.obj, rBase)
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
            proto._freeReg = rBase + 1
            if dest >= proto._freeReg then proto._freeReg = dest + 1 end

        elseif tag == "Function" then
            local childProto = self.compileFunction(proto, node)
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
                    self.compileExpr(proto, field.value, rVal)
                    local rKey = proto._freeReg
                    self.emit(proto, OP.LOADK, rKey, self.addNumberConst(proto, arrIdx))
                    proto._freeReg = rKey + 1
                    self.emit(proto, OP.SETTABLE, dest, rKey, rVal)
                    proto._freeReg = rVal
                    arrIdx = arrIdx + 1
                elseif field.tag == "NamedField" then
                    local rVal = proto._freeReg
                    self.compileExpr(proto, field.value, rVal)
                    local rKey = proto._freeReg
                    self.emit(proto, OP.LOADK, rKey, self.addStringConst(proto, field.name))
                    proto._freeReg = rKey + 1
                    self.emit(proto, OP.SETTABLE, dest, rKey, rVal)
                    proto._freeReg = rVal
                elseif field.tag == "IndexedField" then
                    local rVal = proto._freeReg
                    self.compileExpr(proto, field.value, rVal)
                    local rKey = proto._freeReg
                    self.compileExpr(proto, field.key, rKey)
                    proto._freeReg = rKey + 1
                    self.emit(proto, OP.SETTABLE, dest, rKey, rVal)
                    proto._freeReg = rVal
                end
            end
        end

        return dest
    end

    function self.compileFunction(parentProto, node)
        local proto = self.newProto(parentProto)
        proto.params = #node.params
        proto.hasVararg = node.hasVararg

        -- allocate param registers
        for _, p in ipairs(node.params) do
            self.addLocal(proto, p)
        end

        self.compileBlock(node.body, proto, {}, {})

        -- ensure return
        if #proto.code == 0 or proto.code[#proto.code].op ~= OP.RETURN then
            self.emit(proto, OP.RETURN, 0, 1)
        end

        return proto
    end

    function self.compileBlock(block, proto, breakList, contList)
        if proto == nil then
            -- top-level: create main proto
            proto = self.newProto(nil)
            proto.hasVararg = true
        end

        local savedLocals = #proto._locals
        local savedFreeReg = proto._freeReg

        for _, stmt in ipairs(block.stmts) do
            self.compileStmt(proto, stmt, breakList, contList)
        end

        -- pop locals out of scope
        while #proto._locals > savedLocals do
            table.remove(proto._locals)
        end
        proto._freeReg = savedFreeReg

        return proto
    end

    function self.compileStmt(proto, node, breakList, contList)
        local tag = node.tag

        if tag == "Local" then
            local regs = {}
            for i, name in ipairs(node.names) do
                local val = node.values[i]
                local reg = proto._freeReg
                if val then
                    self.compileExpr(proto, val, reg)
                    proto._freeReg = reg + 1
                else
                    self.emit(proto, OP.LOADNIL, reg)
                    proto._freeReg = reg + 1
                end
                table.insert(proto._locals, {name=name, reg=reg})
                table.insert(regs, reg)
            end

        elseif tag == "LocalFunc" then
            local reg = proto._freeReg
            table.insert(proto._locals, {name=node.name, reg=reg})
            proto._freeReg = reg + 1
            local childProto = self.compileFunction(proto, node.func)
            local protoIdx = #proto.protos
            table.insert(proto.protos, childProto)
            self.emit(proto, OP.CLOSURE, reg, protoIdx)

        elseif tag == "Assign" then
            local tmpRegs = {}
            for i, val in ipairs(node.values) do
                local r = proto._freeReg
                self.compileExpr(proto, val, r)
                proto._freeReg = r + 1
                tmpRegs[i] = r
            end
            for i, target in ipairs(node.targets) do
                local valReg = tmpRegs[i] or (function()
                    local r = proto._freeReg
                    self.emit(proto, OP.LOADNIL, r)
                    proto._freeReg = r + 1
                    return r
                end)()

                if target.tag == "Name" then
                    local localReg = self.findLocal(proto, target.name)
                    if localReg then
                        self.emit(proto, OP.MOVE, localReg, valReg)
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
                    self.compileExpr(proto, target.obj, rObj)
                    self.compileExpr(proto, target.key, rKey)
                    proto._freeReg = rObj
                    self.emit(proto, OP.SETTABLE, rObj, rKey, valReg)
                end
            end
            -- free temp regs
            for _, r in ipairs(tmpRegs) do
                if r >= proto._freeReg then
                    -- already freed by scope restore
                end
            end
            proto._freeReg = tmpRegs[1] or proto._freeReg

        elseif tag == "CallStmt" then
            local savedFR = proto._freeReg
            local r = proto._freeReg
            self.compileExpr(proto, node.expr, r)
            proto._freeReg = savedFR

        elseif tag == "Do" then
            local saved = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, breakList, contList)
            while #proto._locals > saved do table.remove(proto._locals) end
            proto._freeReg = savedFR

        elseif tag == "If" then
            local exitJmps = {}

            local function compileIf(cond, body)
                local rCond = proto._freeReg
                self.compileExpr(proto, cond, rCond)
                self.emit(proto, OP.TEST, rCond, 0, 0)
                local jmpFalse = self.emit(proto, OP.JMP, 0, 0)
                local saved = #proto._locals
                local savedFR = proto._freeReg
                self.compileBlock(body, proto, breakList, contList)
                while #proto._locals > saved do table.remove(proto._locals) end
                proto._freeReg = savedFR
                local jmpExit = self.emit(proto, OP.JMP, 0, 0)
                table.insert(exitJmps, jmpExit)
                self.patchJump(proto, jmpFalse, #proto.code)
            end

            compileIf(node.cond, node.body)
            for _, ei in ipairs(node.elseifs) do
                compileIf(ei.cond, ei.body)
            end
            if node.elsebody then
                local saved = #proto._locals
                local savedFR = proto._freeReg
                self.compileBlock(node.elsebody, proto, breakList, contList)
                while #proto._locals > saved do table.remove(proto._locals) end
                proto._freeReg = savedFR
            end
            for _, j in ipairs(exitJmps) do
                self.patchJump(proto, j, #proto.code)
            end

        elseif tag == "While" then
            local loopStart = #proto.code
            local rCond = proto._freeReg
            self.compileExpr(proto, node.cond, rCond)
            self.emit(proto, OP.TEST, rCond, 0, 0)
            local jmpExit = self.emit(proto, OP.JMP, 0, 0)
            local myBreaks = {}
            local myCont = loopStart
            local saved = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, {loopStart})
            while #proto._locals > saved do table.remove(proto._locals) end
            proto._freeReg = savedFR
            -- patch continues
            self.emitsBx(proto, OP.JMP, 0, loopStart - #proto.code)
            self.patchJump(proto, jmpExit, #proto.code)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code)
            end

        elseif tag == "Repeat" then
            local loopStart = #proto.code
            local myBreaks = {}
            local saved = #proto._locals
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, {loopStart})
            while #proto._locals > saved do table.remove(proto._locals) end
            proto._freeReg = savedFR
            local rCond = proto._freeReg
            self.compileExpr(proto, node.cond, rCond)
            self.emit(proto, OP.TEST, rCond, 0, 0)
            self.emitsBx(proto, OP.JMP, 0, loopStart - #proto.code)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code)
            end

        elseif tag == "NumFor" then
            local rBase = proto._freeReg
            -- R(rBase)   = start (internal counter)
            -- R(rBase+1) = limit
            -- R(rBase+2) = step
            -- R(rBase+3) = loop var (visible)
            self.compileExpr(proto, node.start, rBase)
            self.compileExpr(proto, node.stop,  rBase+1)
            if node.step then
                self.compileExpr(proto, node.step, rBase+2)
            else
                self.emit(proto, OP.LOADK, rBase+2, self.addNumberConst(proto, 1))
            end
            proto._freeReg = rBase + 4
            local forPrep = self.emitsBx(proto, OP.FORPREP, rBase, 0)
            local loopStart = #proto.code
            -- bind loop var
            table.insert(proto._locals, {name=node.var, reg=rBase+3})
            local saved = #proto._locals
            local savedFR = proto._freeReg
            local myBreaks = {}
            self.compileBlock(node.body, proto, myBreaks, {})
            while #proto._locals > saved do table.remove(proto._locals) end
            -- remove loop var
            for i = #proto._locals, 1, -1 do
                if proto._locals[i].name == node.var then
                    table.remove(proto._locals, i); break
                end
            end
            proto._freeReg = savedFR
            local forLoop = self.emitsBx(proto, OP.FORLOOP, rBase, loopStart - #proto.code)
            self.patchJump(proto, forPrep, #proto.code - 1)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code)
            end
            proto._freeReg = rBase

        elseif tag == "GenFor" then
            local rBase = proto._freeReg
            -- R(rBase)   = iterator func
            -- R(rBase+1) = state
            -- R(rBase+2) = control
            local iters = node.iters
            self.compileExpr(proto, iters[1] or {tag="Nil"}, rBase)
            self.compileExpr(proto, iters[2] or {tag="Nil"}, rBase+1)
            self.compileExpr(proto, iters[3] or {tag="Nil"}, rBase+2)
            proto._freeReg = rBase + 2 + #node.names + 1
            local myBreaks = {}
            local loopJmp = self.emitsBx(proto, OP.JMP, 0, 0)
            local loopStart = #proto.code
            -- bind iter vars
            local savedLocCount = #proto._locals
            for i, name in ipairs(node.names) do
                table.insert(proto._locals, {name=name, reg=rBase+2+i})
            end
            local savedFR = proto._freeReg
            self.compileBlock(node.body, proto, myBreaks, {})
            while #proto._locals > savedLocCount do table.remove(proto._locals) end
            proto._freeReg = savedFR
            self.patchJump(proto, loopJmp, #proto.code)
            self.emit(proto, OP.TFORLOOP, rBase, 0, #node.names)
            self.emitsBx(proto, OP.JMP, 0, loopStart - #proto.code)
            for _, b in ipairs(myBreaks) do
                self.patchJump(proto, b, #proto.code)
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
            -- jump to loop start (patched by caller)
            local jmp = self.emit(proto, OP.JMP, 0, 0)
            if contList and contList[1] then
                self.patchJump(proto, jmp, contList[1])
            end
        end
    end

    return self
end

Compiler.KTAG = KTAG

return Compiler
