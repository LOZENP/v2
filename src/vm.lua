-- vm.lua
local Compiler = require("src.compiler")
local Utils    = require("src.utils")
local bit32    = Utils.bit32

local VM = {}

function VM.generateRuntime(encryptedBlob, keyString, config)
    local N = {}
    local usedNames = {}
    for i = 1, 80 do
        local name
        repeat name = Utils.randName() until not usedNames[name]
        usedNames[name] = true
        N[i] = name
    end

    local blob = table.concat(encryptedBlob, ",")
    local OP   = Compiler.OP

    local code = {}
    local function w(s) table.insert(code, s) end

    w("local bit32=bit32 or (function() local b={} function b.bxor(a,x) local r,m=0,1 while a>0 or x>0 do if(a%2)~=(x%2)then r=r+m end a=math.floor(a/2) x=math.floor(x/2) m=m*2 end return r end function b.band(a,x) local r,m=0,1 while a>0 and x>0 do if a%2==1 and x%2==1 then r=r+m end a=math.floor(a/2) x=math.floor(x/2) m=m*2 end return r end function b.rshift(a,n) return math.floor(a/(2^n)) end function b.lshift(a,n) return(a*(2^n))%(2^32) end return b end)()")

    w("local function " .. N[1] .. "(...)")

    w("local " .. N[2] .. "={" .. keyString .. "}")

    w("local function " .. N[3] .. "(" .. N[4] .. "," .. N[5] .. ") return bit32.bxor(" .. N[4] .. "," .. N[2] .. "[((" .. N[5] .. "-1)%256)+1]) end")

    w("local " .. N[6] .. "={" .. blob .. "}")

    w("for " .. N[7] .. "=1,#" .. N[6] .. " do " .. N[6] .. "[" .. N[7] .. "]=" .. N[3] .. "(" .. N[6] .. "[" .. N[7] .. "]," .. N[7] .. ") end")

    w("local " .. N[8] .. "=1")

    w("local function " .. N[9] .. "() local v=" .. N[6] .. "[" .. N[8] .. "] " .. N[8] .. "=" .. N[8] .. "+1 return v or 0 end")

    w("local function " .. N[10] .. "() local lo=" .. N[9] .. "() local hi=" .. N[9] .. "() return lo+hi*256 end")

    w("local function " .. N[11] .. "() local a=" .. N[9] .. "() local b=" .. N[9] .. "() local c=" .. N[9] .. "() local d=" .. N[9] .. "() return a+b*256+c*65536+d*16777216 end")

    w("local function " .. N[12] .. "() local len=" .. N[9] .. "() local s='' for i=1,len do s=s..string.char(" .. N[9] .. "()) end return tonumber(s) end")

    w("local function " .. N[13] .. "() local len=" .. N[10] .. "() local s='' for i=1,len do s=s..string.char(" .. N[9] .. "()) end return s end")

    w("local " .. N[14])
    w(N[14] .. "=function()")
    w("local p={} p.params=" .. N[9] .. "() p.hasVararg=" .. N[9] .. "()==1 p.maxStack=" .. N[9] .. "()")
    w("local kn=" .. N[10] .. "() p.k={}")
    w("for i=1,kn do local t=" .. N[9] .. "() if t==0 then p.k[i]=" .. N[12] .. "() elseif t==1 then p.k[i]=" .. N[13] .. "() elseif t==2 then p.k[i]=(" .. N[9] .. "()==1) else p.k[i]=nil end end")
    w("local cn=" .. N[10] .. "() p.code={}")
    w("for i=1,cn do local op=" .. N[9] .. "() local A=" .. N[9] .. "() local B=" .. N[10] .. "() if B>=32768 then B=B-65536 end local C=" .. N[9] .. "() p.code[i]={op,A,B,C} end")
    w("local pn=" .. N[9] .. "() p.protos={}")
    w("for i=1,pn do p.protos[i]=" .. N[14] .. "() end")
    w("return p end")

    w("local " .. N[15] .. "=" .. N[14] .. "()")
    w("local " .. N[16] .. "=" .. N[15])

    w("local " .. N[17])
    w(N[17] .. "=function(" .. N[18] .. "," .. N[19] .. "," .. N[20] .. ",...)")
    w("local " .. N[21] .. "={}")
    w("local " .. N[22] .. "={...}")
    w("for i=1," .. N[18] .. ".params do " .. N[21] .. "[i-1]=" .. N[22] .. "[i] end")
    w("local " .. N[23] .. "=1")
    w("local " .. N[24] .. "=" .. N[18] .. ".code")
    w("local " .. N[25] .. "=" .. N[18] .. ".k")
    w("local " .. N[26] .. "=" .. N[18] .. ".protos")
    w("while true do")
    w("local " .. N[27] .. "=" .. N[24] .. "[" .. N[23] .. "] if not " .. N[27] .. " then break end")
    w("local op,A,B,C=" .. N[27] .. "[1]," .. N[27] .. "[2]," .. N[27] .. "[3]," .. N[27] .. "[4]")
    w(N[23] .. "=" .. N[23] .. "+1")

    w("if op==" .. OP.LOADK .. " then " .. N[21] .. "[A]=" .. N[25] .. "[B+1]")
    w("elseif op==" .. OP.LOADNIL .. " then " .. N[21] .. "[A]=nil")
    w("elseif op==" .. OP.LOADBOOL .. " then " .. N[21] .. "[A]=(B~=0) if C~=0 then " .. N[23] .. "=" .. N[23] .. "+1 end")
    w("elseif op==" .. OP.MOVE .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]")
    w("elseif op==" .. OP.GETGLOBAL .. " then " .. N[21] .. "[A]=" .. N[19] .. "[" .. N[25] .. "[B+1]]")
    w("elseif op==" .. OP.SETGLOBAL .. " then " .. N[19] .. "[" .. N[25] .. "[B+1]]=" .. N[21] .. "[A]")
    w("elseif op==" .. OP.GETUPVAL .. " then " .. N[21] .. "[A]=" .. N[20] .. "[B+1][1]")
    w("elseif op==" .. OP.SETUPVAL .. " then " .. N[20] .. "[B+1][1]=" .. N[21] .. "[A]")
    w("elseif op==" .. OP.GETTABLE .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B][" .. N[21] .. "[C]]")
    w("elseif op==" .. OP.SETTABLE .. " then " .. N[21] .. "[A][" .. N[21] .. "[B]]=" .. N[21] .. "[C]")
    w("elseif op==" .. OP.NEWTABLE .. " then " .. N[21] .. "[A]={}")
    w("elseif op==" .. OP.ADD .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]+" .. N[21] .. "[C]")
    w("elseif op==" .. OP.SUB .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]-" .. N[21] .. "[C]")
    w("elseif op==" .. OP.MUL .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]*" .. N[21] .. "[C]")
    w("elseif op==" .. OP.DIV .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]/" .. N[21] .. "[C]")
    w("elseif op==" .. OP.MOD .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]%" .. N[21] .. "[C]")
    w("elseif op==" .. OP.POW .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]^" .. N[21] .. "[C]")
    w("elseif op==" .. OP.IDIV .. " then " .. N[21] .. "[A]=math.floor(" .. N[21] .. "[B]/" .. N[21] .. "[C])")
    w("elseif op==" .. OP.CONCAT .. " then local s=" .. N[21] .. "[B] for i=B+1,C do s=s.." .. N[21] .. "[i] end " .. N[21] .. "[A]=s")
    w("elseif op==" .. OP.UNM .. " then " .. N[21] .. "[A]=-" .. N[21] .. "[B]")
    w("elseif op==" .. OP.NOT .. " then " .. N[21] .. "[A]=not " .. N[21] .. "[B]")
    w("elseif op==" .. OP.LEN .. " then " .. N[21] .. "[A]=#" .. N[21] .. "[B]")
    w("elseif op==" .. OP.EQ .. " then if (" .. N[21] .. "[B]==" .. N[21] .. "[C])~=(A~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    w("elseif op==" .. OP.LT .. " then if (" .. N[21] .. "[B]<" .. N[21] .. "[C])~=(A~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    w("elseif op==" .. OP.LE .. " then if (" .. N[21] .. "[B]<=" .. N[21] .. "[C])~=(A~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    w("elseif op==" .. OP.JMP .. " then " .. N[23] .. "=" .. N[23] .. "+B")
    w("elseif op==" .. OP.TEST .. " then if(not not " .. N[21] .. "[A])~=(C~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    w("elseif op==" .. OP.TESTSET .. " then if(not not " .. N[21] .. "[B])==(C~=0) then " .. N[21] .. "[A]=" .. N[21] .. "[B] else " .. N[23] .. "=" .. N[23] .. "+1 end")
    w("elseif op==" .. OP.CALL .. " then local fn=" .. N[21] .. "[A] local args={} for i=1,B-1 do args[i]=" .. N[21] .. "[A+i] end local rets={fn(table.unpack(args))} for i=1,C-1 do " .. N[21] .. "[A+i-1]=rets[i] end")
    w("elseif op==" .. OP.TAILCALL .. " then local fn=" .. N[21] .. "[A] local args={} for i=1,B-1 do args[i]=" .. N[21] .. "[A+i] end return fn(table.unpack(args))")
    w("elseif op==" .. OP.RETURN .. " then local rets={} for i=0,B-2 do rets[i+1]=" .. N[21] .. "[A+i] end return table.unpack(rets)")
    w("elseif op==" .. OP.FORPREP .. " then " .. N[21] .. "[A]=" .. N[21] .. "[A]-" .. N[21] .. "[A+2] " .. N[23] .. "=" .. N[23] .. "+B")
    w("elseif op==" .. OP.FORLOOP .. " then " .. N[21] .. "[A]=" .. N[21] .. "[A]+" .. N[21] .. "[A+2] if " .. N[21] .. "[A+2]>0 then if " .. N[21] .. "[A]<=" .. N[21] .. "[A+1] then " .. N[21] .. "[A+3]=" .. N[21] .. "[A] " .. N[23] .. "=" .. N[23] .. "+B end else if " .. N[21] .. "[A]>=" .. N[21] .. "[A+1] then " .. N[21] .. "[A+3]=" .. N[21] .. "[A] " .. N[23] .. "=" .. N[23] .. "+B end end")
    w("elseif op==" .. OP.TFORLOOP .. " then local fn=" .. N[21] .. "[A] local state=" .. N[21] .. "[A+1] local ctrl=" .. N[21] .. "[A+2] local rets={fn(state,ctrl)} if rets[1]==nil then " .. N[23] .. "=" .. N[23] .. "+1 else " .. N[21] .. "[A+2]=rets[1] for i=1,C do " .. N[21] .. "[A+2+i]=rets[i] end end")
    w("elseif op==" .. OP.SETLIST .. " then local t=" .. N[21] .. "[A] for i=1,B do t[i]=" .. N[21] .. "[A+i] end")
    w("elseif op==" .. OP.CLOSURE .. " then local cp=" .. N[26] .. "[B+1] " .. N[21] .. "[A]=function(...) return " .. N[17] .. "(cp," .. N[19] .. ",{},...) end")
    w("elseif op==" .. OP.VARARG .. " then for i=0,B-2 do " .. N[21] .. "[A+i]=" .. N[22] .. "[i+1] end")
    w("elseif op==" .. OP.SELF .. " then " .. N[21] .. "[A+1]=" .. N[21] .. "[B] " .. N[21] .. "[A]=" .. N[21] .. "[B][" .. N[21] .. "[C]]")
    w("end end end")

    w("local " .. N[28] .. "=_G or getfenv(0)")
    w(N[17] .. "(" .. N[16] .. "," .. N[28] .. ",{}, ...)")
    w("end")
    w(N[1] .. "(...)")

    -- Join as single line
    return table.concat(code, " ")
end

return VM
