-- hw_audit_tap.lua -- MAME oracle for docs/2026-10-23-hw-audit-573in1-sources.md
--
-- Logs exactly the Konami-side traffic the audit's open items need, nothing else:
--   CTL  0x1f400000 writes, bits 5..8 (amp / CD-DA(aux) in / SPU DAC / H8 clock)   [O3]
--   BNK  0x1f500000 writes (bank + bit 6 = cassette SDA output enable + bit 7)     [F1]
--   CAS  0x1f6a0000 writes (cassette latch D0..D7)                                  [F1]
--   SDA  0x1f400006 bit 2 reads (cassette SDA read-back) while a cassette is busy   [F1]
--   DIO  0x1f6400f4/f6 writes, 0xf6 reads, 0xf8 bitstream burst summary            [O1]
--   IDE  0x1f48000c/e (device, command), PACKET opcode, 0x1f4c000c, 0x1f560000      [F2/O4]
--
-- Output: /tmp/hw_audit_<system>.log (override with env HWA_OUT).
--
-- Run (one game per run; MAME 0.26x+, non-merged romsets, CHDs in <rompath>/<game>/):
--   mame <game> -rompath <dir> -autoboot_script hw_audit_tap.lua \
--        -seconds_to_run 90 -nothrottle -skip_gameinfo -window \
--        -nvram_directory /tmp/hwa_nvram
--
-- LESSONS carried over from tools/mame_dio_regs.lua (read its header):
--   * every tap / notifier handle lives in a GLOBAL (HWA.*) or MAME GC removes it;
--   * the PSX bus is 32-bit: a 16-bit register at base+2 arrives in the UPPER half
--     of `data` with `mask` 0xffff0000 -- split on mask, never `data & 0xffff`;
--   * write + flush every line (print() is lost on SIGTERM).

HWA = {}
local sysname = manager.machine.system.name
local OUT = os.getenv("HWA_OUT") or ("/tmp/hw_audit_" .. sysname .. ".log")
HWA.f = io.open(OUT, "w")
HWA.lines = 0
local CAP = 600000
local function say(s)
  HWA.lines = HWA.lines + 1
  if HWA.lines > CAP then
    if not HWA.capped then
      HWA.capped = true
      HWA.f:write("# LINE CAP HIT\n"); HWA.f:flush()
    end
    return
  end
  HWA.f:write(s .. "\n"); HWA.f:flush()
end

HWA.cpu   = manager.machine.devices[":maincpu"]
HWA.space = HWA.cpu.spaces["program"]
local function now()
  local ok, t = pcall(function() return manager.machine.time:as_double() end)
  if ok and t then return t end
  return -1
end
local function pc()
  local ok, v = pcall(function() return HWA.cpu.state["pc"].value end)
  if ok and v then return v end
  return 0
end

say("# hw_audit_tap system=" .. sysname .. " out=" .. OUT)

-- split a 32-bit tap hit into its live 16-bit halves: { {off, val}, ... }
local function halves(base_off, data, mask)
  local h = {}
  if (mask & 0x0000ffff) ~= 0 then h[#h + 1] = { base_off,     data & 0xffff } end
  if (mask & 0xffff0000) ~= 0 then h[#h + 1] = { base_off + 2, (data >> 16) & 0xffff } end
  if #h == 0 then h[1] = { base_off, data & 0xffff } end
  return h
end

HWA.taps = {}
local function wtap(lo, hi, name, fn)
  local ok, t = pcall(function()
    return HWA.space:install_write_tap(lo, hi, name, function(off, data, mask)
      local b = off - lo                       -- MAME passes the absolute address;
      if b < 0 or b > hi - lo then b = off & (hi - lo) end   -- tolerate an offset too
      for _, x in ipairs(halves(b, data, mask)) do fn(x[1], x[2]) end
      return data
    end)
  end)
  if ok and t then HWA.taps[#HWA.taps + 1] = t; say("# write tap " .. name)
  else say("FATAL: write tap " .. name .. " failed: " .. tostring(t)) end
end
local function rtap(lo, hi, name, fn)
  local ok, t = pcall(function()
    return HWA.space:install_read_tap(lo, hi, name, function(off, data, mask)
      local b = off - lo                       -- MAME passes the absolute address;
      if b < 0 or b > hi - lo then b = off & (hi - lo) end   -- tolerate an offset too
      for _, x in ipairs(halves(b, data, mask)) do fn(x[1], x[2]) end
      return data
    end)
  end)
  if ok and t then HWA.taps[#HWA.taps + 1] = t; say("# read tap " .. name)
  else say("FATAL: read tap " .. name .. " failed: " .. tostring(t)) end
end

-- ------------------------------------------------------------------ CTL [O3]
HWA.ctl = -1
wtap(0x1f400000, 0x1f400003, "ctl", function(off, v)
  if off ~= 0 then return end
  local b = v & 0x1e0
  if b ~= HWA.ctl then
    HWA.ctl = b
    say(string.format("%10.6f pc=%08x CTL %04x amp=%d cdda=%d spu=%d h8clk=%d",
      now(), pc(), v, (v >> 5) & 1, (v >> 6) & 1, (v >> 7) & 1, (v >> 8) & 1))
  end
end)

-- ------------------------------------------------------- cassette [F1]
-- Every BNK/CAS write is logged with the resulting pin state, plus what the chip's
-- SDA input would be under the three candidate wirings:
--   new = bit6 ? D0 : 1      (s573_seccart host_sda, this audit)
--   x76 = D0                 (old X76 wiring = MAME k573cass X/Y)
--   zs  = ~bit6              (old ZS01 wiring = MAME k573cass ZI)
HWA.bank, HWA.cas = 0, 0
HWA.last_cas_t = -10
local function pins(tag, v)
  local d0  = HWA.cas & 1
  local b6  = (HWA.bank >> 6) & 1
  local new = (b6 == 1) and d0 or 1
  local zs  = 1 - b6
  say(string.format("%10.6f pc=%08x %s %04x | D0=%d SCL=%d CS=%d RST=%d DS=%d oe6=%d b7=%d | sda new=%d x76=%d zs=%d",
    now(), pc(), tag, v, d0, (HWA.cas >> 1) & 1, (HWA.cas >> 2) & 1, (HWA.cas >> 3) & 1,
    (HWA.cas >> 4) & 1, b6, (HWA.bank >> 7) & 1, new, d0, zs))
end
wtap(0x1f500000, 0x1f500003, "bnk", function(off, v)
  if off ~= 0 then return end
  local changed = ((v ~ HWA.bank) & 0xc0) ~= 0
  HWA.bank = v
  if changed or (now() - HWA.last_cas_t) < 0.01 then pins("BNK", v) end
end)
wtap(0x1f6a0000, 0x1f6a0003, "cas", function(off, v)
  if off ~= 0 then return end
  HWA.cas = v & 0xff
  HWA.last_cas_t = now()
  pins("CAS", v)
end)
-- read-back sampled while a cassette transaction is live (10 ms after the last latch write)
rtap(0x1f400004, 0x1f400007, "in1", function(off, v)
  if off ~= 2 then return end
  if (now() - HWA.last_cas_t) < 0.01 then
    say(string.format("%10.6f pc=%08x SDA rd=%d", now(), pc(), (v >> 2) & 1))
  end
end)

-- ------------------------------------------------------------ DIO [O1]
HWA.f8n, HWA.f8first, HWA.f8t0 = 0, {}, 0
local function f8_flush()
  if HWA.f8n > 0 then
    say(string.format("%10.6f   DIO f8 burst: %d writes since t=%.6f, first: %s",
      now(), HWA.f8n, HWA.f8t0, table.concat(HWA.f8first, " ")))
    HWA.f8n, HWA.f8first = 0, {}
  end
end
wtap(0x1f6400f0, 0x1f6400ff, "dio_cpld", function(off, v)
  local reg = 0xf0 + off
  if reg == 0xf8 then
    if HWA.f8n == 0 then HWA.f8t0 = now() end
    HWA.f8n = HWA.f8n + 1
    if #HWA.f8first < 32 then HWA.f8first[#HWA.f8first + 1] = string.format("%04x", v) end
  elseif reg == 0xf4 or reg == 0xf6 then
    f8_flush()
    say(string.format("%10.6f pc=%08x DIO W%02x=%04x", now(), pc(), reg, v))
  end
end)
HWA.f6last, HWA.f6rep = -1, 0
rtap(0x1f6400f4, 0x1f6400f7, "dio_stat", function(off, v)
  if off ~= 2 then return end
  f8_flush()
  if v == HWA.f6last then HWA.f6rep = HWA.f6rep + 1; return end
  if HWA.f6rep > 0 then say(string.format("           (DIO Rf6 repeated x%d)", HWA.f6rep)) end
  HWA.f6last, HWA.f6rep = v, 0
  say(string.format("%10.6f pc=%08x DIO Rf6=%04x", now(), pc(), v))
end)
-- the magic/ID read some titles do first
rtap(0x1f640080, 0x1f640083, "dio_magic", function(off, v)
  if off == 0 then say(string.format("%10.6f pc=%08x DIO R80=%04x", now(), pc(), v)) end
end)

-- ------------------------------------------------------- IDE [F2/O4]
HWA.want_pkt = false
HWA.pkt = {}
wtap(0x1f480000, 0x1f48000f, "ide_cs0", function(off, v)
  if off == 0x0 then
    if HWA.want_pkt then
      HWA.pkt[#HWA.pkt + 1] = string.format("%02x %02x", v & 0xff, (v >> 8) & 0xff)
      if #HWA.pkt == 6 then
        say(string.format("%10.6f pc=%08x IDE packet %s", now(), pc(), table.concat(HWA.pkt, " ")))
        HWA.want_pkt, HWA.pkt = false, {}
      end
    end
  elseif off == 0xc then
    say(string.format("%10.6f pc=%08x IDE DEV=%02x", now(), pc(), v & 0xff))
  elseif off == 0xe then
    say(string.format("%10.6f pc=%08x IDE CMD=%02x", now(), pc(), v & 0xff))
    HWA.want_pkt = ((v & 0xff) == 0xa0); HWA.pkt = {}
  end
end)
wtap(0x1f4c0000, 0x1f4c000f, "ide_cs1", function(off, v)
  if off == 0xc then say(string.format("%10.6f pc=%08x IDE DEVCTL=%02x", now(), pc(), v & 0xff)) end
end)
wtap(0x1f560000, 0x1f560003, "ide_rst", function(off, v)
  if off == 0 then say(string.format("%10.6f pc=%08x IDE RESET=%04x", now(), pc(), v)) end
end)
-- status reads, collapsed: only changes are logged
HWA.stlast, HWA.strep = -1, 0
rtap(0x1f48000c, 0x1f48000f, "ide_st", function(off, v)
  if off ~= 2 then return end
  local s = v & 0xff
  if s == HWA.stlast then HWA.strep = HWA.strep + 1; return end
  if HWA.strep > 0 then say(string.format("           (IDE ST repeated x%d)", HWA.strep)) end
  HWA.stlast, HWA.strep = s, 0
  say(string.format("%10.6f pc=%08x IDE ST=%02x", now(), pc(), s))
end)

-- --------------------------------------------- liveness (positive control)
HWA.frames = 0
HWA.frame_sub = emu.add_machine_frame_notifier(function()
  HWA.frames = HWA.frames + 1
  if HWA.frames % 600 == 0 then
    f8_flush()
    say(string.format("%10.6f   alive frame=%d pc=%08x lines=%d", now(), HWA.frames, pc(), HWA.lines))
  end
end)
HWA.stop_sub = emu.add_machine_stop_notifier(function()
  f8_flush()
  say(string.format("# end t=%.3f frames=%d lines=%d", now(), HWA.frames, HWA.lines))
  HWA.f:close()
end)
say("# armed")
