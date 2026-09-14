-- zs01_detect_tap.lua -- capture the REAL ddrusa cassette-detection transaction.
--
-- Purpose: the core emits the ZS01 response-to-reset correctly (proven in sim vs
-- MAME zs01.cpp) yet ddrusa reports "cassette does not match" (error 121-3 = never
-- identified). The one thing sim cannot supply is the game's exact CLOCKING and
-- READ PHASE. This tap records, in cycle order, every write to the security latch
-- (0x1f6a0000: D1=SCL D2=CS D3=RST) and the control reg (0x1f500000 bit6 = ZS01
-- SDA drive), and every read of the status dword (0x1f400004..7; bit18 =
-- 0x1f400006[2] = read_line_secflash_sda = the SDA level a CORRECT chip returns).
--
-- The output is the ground truth for a cycle-accurate detector replay against the
-- core's full read-back path: it shows how many times the game clocks, whether it
-- samples during SCL-high or right after SCL-low, and the exact id bits it reads.
--
-- Run (on the dell MAME box, via the project wrapper):
--   MAME573_SET=ddrusa tools/mame573.sh tools/trace/zs01_detect_tap.lua 40 zs01_detect.log
--   -> pulls local/zs01_detect.log back here.
-- (If ddrusa needs its CHD/nvram staged on dell like ddrsbm, see mame573.sh.)

local PREFIX = os.getenv("CASS_PREFIX") or "/tmp/zs01_detect"
local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local f = io.open(PREFIX .. ".log", "w")
f:setvbuf("line")

local function pc()
  local ok,v = pcall(function() return cpu.state["CURPC"].value end)
  if ok then return v end
  local ok2,v2 = pcall(function() return cpu.state["PC"].value end)
  if ok2 then return v2 end
  return 0
end
local function cyc()
  local ok,v = pcall(function() return cpu:total_cycles() end)
  if ok then return v end
  return math.floor((machine.time.seconds + machine.time.attoseconds/1e18) * 33868800)
end

_G.taps = {}
local taps = _G.taps
local n = 0
local CAP = 6000

local function log(kind, addr, val, extra)
  if n < CAP then
    n = n + 1
    f:write(string.format("%12d %s addr=%08X val=%08X %s pc=%08X\n",
                          cyc(), kind, addr, val, extra or "", pc()))
  end
end

-- security latch writes 0x1f6a0000 (16-bit): decode SCL/CS/RST + D0
taps[#taps+1] = mem:install_write_tap(0x1f6a0000, 0x1f6a0001, "seclatch", function(off,data,mask)
  local d0  = data & 1
  local scl = (data >> 1) & 1
  local cs  = (data >> 2) & 1
  local rst = (data >> 3) & 1
  log("LATCHW", 0x1f6a0000, data & 0xffff,
      string.format("D0=%d SCL=%d CS=%d RST=%d", d0, scl, cs, rst))
end)

-- control reg writes 0x1f500000: bit6 = ZS01 SDA drive (active-low), bit6dir
taps[#taps+1] = mem:install_write_tap(0x1f500000, 0x1f500001, "ctrl", function(off,data,mask)
  local sda6 = (data >> 6) & 1
  log("CTRLW", 0x1f500000, data & 0xffff, string.format("SDA(bit6)=%d", sda6))
end)

-- status dword reads 0x1f400004..7: bit18 = 0x1f400006[2] = secflash SDA read-back
taps[#taps+1] = mem:install_read_tap(0x1f400004, 0x1f400007, "statrd", function(off,data,mask)
  local sda = (data >> 18) & 1
  log("STATRD", 0x1f400004, data, string.format("SDAr=%d", sda))
end)

f:write(string.format("# zs01_detect_tap installed machine=%s cap=%d\n", machine.system.name, CAP))
print("zs01_detect_tap installed prefix=" .. PREFIX)
