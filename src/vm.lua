-- vm.lua
-- Generates the runtime VM as a Lua string
-- This VM deserializes + executes the encrypted bytecode at runtime

local Compiler = require("src.compiler")
local Utils    = require("src.utils")

local VM = {}

function VM.generateRuntime(encryptedBlob, keyString, config)
    -- Randomize all internal variable names
    local N = {}
    local usedNames = {}
    for i = 1, 80 do
        local name
        repeat name = Utils.randName() until not usedNames[name]
        usedNames[name] = true
        N[i] = name
    end

    local blob = table.concat(encryptedBlob, ",")

    local code = {}
    local function w(s) table.insert(code, s) end

    w("local function " .. N[1] .. "(...)")

    -- Keys
    w("local " .. N[2] .. "={" .. keyString .. "}")

    -- XOR decode helper
    w("local function " .. N[3] .. "(" .. N[4] .. "," .. N[5] .. ")")
    w("  return bit32.bxor(" .. N[4] .. "," .. N[2] .. "[((" .. N[5] .. "-1)%256)+1])")
    w("end")

    -- Blob
    w("local " .. N[6] .. "={" .. blob .. "}")

    -- Decrypt blob
    w("for " .. N[7] .. "=1,#" .. N[6] .. " do")
    w("  " .. N[6] .. "[" .. N[7] .. "]=" .. N[3] .. "(" .. N[6] .. "[" .. N[7] .. "]," .. N[7] .. ")")
    w("end")

    -- Reader state
    w("local " .. N[8] .. "=1")  -- read cursor

    -- readU8
    w("local function " .. N[9] .. "()")
    w("  local v=" .. N[6] .. "[" .. N[8] .. "];" .. N[8] .. "=" .. N[8] .. "+1; return v or 0")
    w("end")

    -- readU16
    w("local function " .. N[10] .. "()")
    w("  local lo=" .. N[9] .. "(); local hi=" .. N[9] .. "()")
    w("  return lo + hi*256")
    w("end")

    -- readU32
    w("local function " .. N[11] .. "()")
    w("  local a=" .. N[9] .. "(); local b=" .. N[9] .. "(); local c=" .. N[9] .. "(); local d=" .. N[9] .. "()")
    w("  return a + b*256 + c*65536 + d*16777216")
    w("end")

    -- readDouble (number stored as string)
    w("local function " .. N[12] .. "()")
    w("  local len=" .. N[9] .. "()")
    w("  local s=''")
    w("  for i=1,len do s=s..string.char(" .. N[9] .. "()) end")
    w("  return tonumber(s)")
    w("end")

    -- readString
    w("local function " .. N[13] .. "()")
    w("  local len=" .. N[10] .. "()")
    w("  local s=''")
    w("  for i=1,len do s=s..string.char(" .. N[9] .. "()) end")
    w("  return s")
    w("end")

    -- readProto (recursive)
    w("local " .. N[14])  -- forward decl
    w(N[14] .. "=function()")
    w("  local p={}")
    w("  p.params=" .. N[9] .. "()")
    w("  p.hasVararg=" .. N[9] .. "()==1")
    w("  p.maxStack=" .. N[9] .. "()")
    -- constants
    w("  local kn=" .. N[10] .. "()")
    w("  p.k={}")
    w("  for i=1,kn do")
    w("    local t=" .. N[9] .. "()")
    w("    if t==0 then p.k[i]=" .. N[12] .. "()")
    w("    elseif t==1 then p.k[i]=" .. N[13] .. "()")
    w("    elseif t==2 then p.k[i]=(" .. N[9] .. "()==1)")
    w("    else p.k[i]=nil end")
    w("  end")
    -- instructions
    w("  local cn=" .. N[10] .. "()")
    w("  p.code={}")
    w("  for i=1,cn do")
    w("    local op=" .. N[9] .. "()")
    w("    local A=" .. N[9] .. "()")
    w("    local B=" .. N[10] .. "()")
    w("    if B>=32768 then B=B-65536 end")  -- sign extend
    w("    local C=" .. N[9] .. "()")
    w("    p.code[i]={op,A,B,C}")
    w("  end")
    -- child protos
    w("  local pn=" .. N[9] .. "()")
    w("  p.protos={}")
    w("  for i=1,pn do p.protos[i]=" .. N[14] .. "() end")
    w("  return p")
    w("end")

    -- Parse the proto tree
    w("local " .. N[15] .. "=" .. N[14] .. "()")

    -- OP constants (must match compiler exactly)
    local OP = Compiler.OP
    w("local " .. N[16] .. "=" .. N[15])  -- root proto

    -- execute(proto, env, upvals, ...)
    w("local " .. N[17])  -- forward decl execute
    w(N[17] .. "=function(" .. N[18] .. "," .. N[19] .. "," .. N[20] .. ",...)")
    w("  local " .. N[21] .. "={}")  -- registers
    w("  local " .. N[22] .. "={...}")  -- varargs
    -- load params
    w("  for i=1," .. N[18] .. ".params do " .. N[21] .. "[i-1]=" .. N[22] .. "[i] end")
    w("  local " .. N[23] .. "=1")  -- PC (1-indexed)
    w("  local " .. N[24] .. "=" .. N[18] .. ".code")
    w("  local " .. N[25] .. "=" .. N[18] .. ".k")
    w("  local " .. N[26] .. "=" .. N[18] .. ".protos")

    w("  while true do")
    w("    local " .. N[27] .. "=" .. N[24] .. "[" .. N[23] .. "]")
    w("    if not " .. N[27] .. " then break end")
    w("    local op,A,B,C=" .. N[27] .. "[1]," .. N[27] .. "[2]," .. N[27] .. "[3]," .. N[27] .. "[4]")
    w("    " .. N[23] .. "=" .. N[23] .. "+1")

    -- Dispatch table
    -- LOADK=0
    w("    if op==" .. OP.LOADK .. " then " .. N[21] .. "[A]=" .. N[25] .. "[B+1]")
    -- LOADNIL=1
    w("    elseif op==" .. OP.LOADNIL .. " then " .. N[21] .. "[A]=nil")
    -- LOADBOOL=2
    w("    elseif op==" .. OP.LOADBOOL .. " then " .. N[21] .. "[A]=(B~=0)")
    w("      if C~=0 then " .. N[23] .. "=" .. N[23] .. "+1 end")
    -- MOVE=3
    w("    elseif op==" .. OP.MOVE .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]")
    -- GETGLOBAL=4
    w("    elseif op==" .. OP.GETGLOBAL .. " then " .. N[21] .. "[A]=" .. N[19] .. "[" .. N[25] .. "[B+1]]")
    -- SETGLOBAL=5
    w("    elseif op==" .. OP.SETGLOBAL .. " then " .. N[19] .. "[" .. N[25] .. "[B+1]]=" .. N[21] .. "[A]")
    -- GETUPVAL=6
    w("    elseif op==" .. OP.GETUPVAL .. " then " .. N[21] .. "[A]=" .. N[20] .. "[B+1][1]")
    -- SETUPVAL=7
    w("    elseif op==" .. OP.SETUPVAL .. " then " .. N[20] .. "[B+1][1]=" .. N[21] .. "[A]")
    -- GETTABLE=8
    w("    elseif op==" .. OP.GETTABLE .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B][" .. N[21] .. "[C]]")
    -- SETTABLE=9
    w("    elseif op==" .. OP.SETTABLE .. " then " .. N[21] .. "[A][" .. N[21] .. "[B]]=" .. N[21] .. "[C]")
    -- NEWTABLE=10
    w("    elseif op==" .. OP.NEWTABLE .. " then " .. N[21] .. "[A]={}")
    -- ADD=11
    w("    elseif op==" .. OP.ADD .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]+" .. N[21] .. "[C]")
    -- SUB=12
    w("    elseif op==" .. OP.SUB .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]-" .. N[21] .. "[C]")
    -- MUL=13
    w("    elseif op==" .. OP.MUL .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]*" .. N[21] .. "[C]")
    -- DIV=14
    w("    elseif op==" .. OP.DIV .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]/" .. N[21] .. "[C]")
    -- MOD=15
    w("    elseif op==" .. OP.MOD .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]%" .. N[21] .. "[C]")
    -- POW=16
    w("    elseif op==" .. OP.POW .. " then " .. N[21] .. "[A]=" .. N[21] .. "[B]^" .. N[21] .. "[C]")
    -- IDIV=17
    w("    elseif op==" .. OP.IDIV .. " then " .. N[21] .. "[A]=math.floor(" .. N[21] .. "[B]/" .. N[21] .. "[C])")
    -- CONCAT=18
    w("    elseif op==" .. OP.CONCAT .. " then")
    w("      local s=" .. N[21] .. "[B]")
    w("      for i=B+1,C do s=s.." .. N[21] .. "[i] end")
    w("      " .. N[21] .. "[A]=s")
    -- UNM=19
    w("    elseif op==" .. OP.UNM .. " then " .. N[21] .. "[A]=-" .. N[21] .. "[B]")
    -- NOT=20
    w("    elseif op==" .. OP.NOT .. " then " .. N[21] .. "[A]=not " .. N[21] .. "[B]")
    -- LEN=21
    w("    elseif op==" .. OP.LEN .. " then " .. N[21] .. "[A]=#" .. N[21] .. "[B]")
    -- EQ=22
    w("    elseif op==" .. OP.EQ .. " then")
    w("      if (" .. N[21] .. "[B]==" .. N[21] .. "[C])~=(A~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    -- LT=23
    w("    elseif op==" .. OP.LT .. " then")
    w("      if (" .. N[21] .. "[B]<" .. N[21] .. "[C])~=(A~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    -- LE=24
    w("    elseif op==" .. OP.LE .. " then")
    w("      if (" .. N[21] .. "[B]<=" .. N[21] .. "[C])~=(A~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    -- JMP=25
    w("    elseif op==" .. OP.JMP .. " then " .. N[23] .. "=" .. N[23] .. "+B")
    -- TEST=26
    w("    elseif op==" .. OP.TEST .. " then")
    w("      if (not not " .. N[21] .. "[A])~=(C~=0) then " .. N[23] .. "=" .. N[23] .. "+1 end")
    -- TESTSET=27
    w("    elseif op==" .. OP.TESTSET .. " then")
    w("      if (not not " .. N[21] .. "[B])==(C~=0) then " .. N[21] .. "[A]=" .. N[21] .. "[B]")
    w("      else " .. N[23] .. "=" .. N[23] .. "+1 end")
    -- CALL=28
    w("    elseif op==" .. OP.CALL .. " then")
    w("      local fn=" .. N[21] .. "[A]")
    w("      local args={}")
    w("      for i=1,B-1 do args[i]=" .. N[21] .. "[A+i] end")
    w("      local rets={fn(table.unpack(args))}")
    w("      for i=1,C-1 do " .. N[21] .. "[A+i-1]=rets[i] end")
    -- TAILCALL=29
    w("    elseif op==" .. OP.TAILCALL .. " then")
    w("      local fn=" .. N[21] .. "[A]")
    w("      local args={}")
    w("      for i=1,B-1 do args[i]=" .. N[21] .. "[A+i] end")
    w("      return fn(table.unpack(args))")
    -- RETURN=30
    w("    elseif op==" .. OP.RETURN .. " then")
    w("      local rets={}")
    w("      for i=0,B-2 do rets[i+1]=" .. N[21] .. "[A+i] end")
    w("      return table.unpack(rets)")
    -- FORPREP=31
    w("    elseif op==" .. OP.FORPREP .. " then")
    w("      " .. N[21] .. "[A]=" .. N[21] .. "[A]-" .. N[21] .. "[A+2]")
    w("      " .. N[23] .. "=" .. N[23] .. "+B")
    -- FORLOOP=32
    w("    elseif op==" .. OP.FORLOOP .. " then")
    w("      " .. N[21] .. "[A]=" .. N[21] .. "[A]+" .. N[21] .. "[A+2]")
    w("      if " .. N[21] .. "[A+2]>0 then")
    w("        if " .. N[21] .. "[A]<=" .. N[21] .. "[A+1] then")
    w("          " .. N[21] .. "[A+3]=" .. N[21] .. "[A]; " .. N[23] .. "=" .. N[23] .. "+B")
    w("        end")
    w("      else")
    w("        if " .. N[21] .. "[A]>=" .. N[21] .. "[A+1] then")
    w("          " .. N[21] .. "[A+3]=" .. N[21] .. "[A]; " .. N[23] .. "=" .. N[23] .. "+B")
    w("        end")
    w("      end")
    -- TFORLOOP=33
    w("    elseif op==" .. OP.TFORLOOP .. " then")
    w("      local fn=" .. N[21] .. "[A]")
    w("      local state=" .. N[21] .. "[A+1]")
    w("      local ctrl=" .. N[21] .. "[A+2]")
    w("      local rets={fn(state,ctrl)}")
    w("      if rets[1]==nil then " .. N[23] .. "=" .. N[23] .. "+1")
    w("      else")
    w("        " .. N[21] .. "[A+2]=rets[1]")
    w("        for i=1,C do " .. N[21] .. "[A+2+i]=rets[i] end")
    w("      end")
    -- SETLIST=34 (simplified)
    w("    elseif op==" .. OP.SETLIST .. " then")
    w("      local t=" .. N[21] .. "[A]")
    w("      for i=1,B do t[i]=" .. N[21] .. "[A+i] end")
    -- CLOSURE=36
    w("    elseif op==" .. OP.CLOSURE .. " then")
    w("      local cp=" .. N[26] .. "[B+1]")
    w("      " .. N[21] .. "[A]=function(...)")
    w("        return " .. N[17] .. "(cp," .. N[19] .. ",{},...)")
    w("      end")
    -- VARARG=37
    w("    elseif op==" .. OP.VARARG .. " then")
    w("      for i=0,B-2 do " .. N[21] .. "[A+i]=" .. N[22] .. "[i+1] end")
    -- SELF=38
    w("    elseif op==" .. OP.SELF .. " then")
    w("      " .. N[21] .. "[A+1]=" .. N[21] .. "[B]")
    w("      " .. N[21] .. "[A]=" .. N[21] .. "[B][" .. N[21] .. "[C]]")
    w("    end")
    w("  end")
    w("end")

    -- Build env from _G or getfenv
    w("local " .. N[28] .. "=_G or getfenv(0)")
    w(N[17] .. "(" .. N[16] .. "," .. N[28] .. ",{}, ...)")
    w("end")
    w(N[1] .. "(...)")

    return table.concat(code, "\n")
end

return VM
