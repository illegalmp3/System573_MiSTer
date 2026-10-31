-- SPU / DIO-MP3 event log through a played credit (MAME reference run).
-- Env: OUT (log path), PLAY=1 to insert coin/start and mash arrows, SNAP=secs between snapshots
local out = assert(io.open(os.getenv("OUT") or "/root/m573/study.log", "w"))
local SNAP = tonumber(os.getenv("SNAP") or "5")
local i2c_w
local subs, taps = {}, {}
local m = manager.machine
local function now() return m.time:as_double() end
local function log(fmt, ...) out:write(string.format("%9.3f ", now()) .. string.format(fmt, ...) .. "\n") end

local reg = {}            -- shadow of SPU regs (16-bit, by address)
local function spu16(a, v)
  reg[a] = v
  local o = a - 0x1f801c00
  if a == 0x1f801d88 or a == 0x1f801d8a then
    local base = (a == 0x1f801d8a) and 16 or 0
    for b = 0, 15 do
      if (v >> b) & 1 == 1 then
        local vo = base + b
        local va = 0x1f801c00 + vo * 16
        log("KON v%02d addr=%05x rep=%05x volL=%04x volR=%04x pitch=%04x adsr=%04x%04x",
          vo, (reg[va+6] or 0) * 8, (reg[va+14] or 0) * 8, reg[va] or 0, reg[va+2] or 0,
          reg[va+4] or 0, reg[va+10] or 0, reg[va+8] or 0)
      end
    end
  elseif a == 0x1f801d8c or a == 0x1f801d8e then
    if v ~= 0 then log("KOFF %s=%04x", a == 0x1f801d8c and "lo" or "hi", v) end
  elseif a == 0x1f801d80 or a == 0x1f801d82 then
    log("MVOL %s=%04x", a == 0x1f801d80 and "L" or "R", v)
  elseif a == 0x1f801da6 then
    log("XFERADDR %05x", v * 8)
  elseif o >= 0 and o < 0x180 and (o % 16 == 0 or o % 16 == 2) then
    -- per-voice volume write: log only while that voice is playing a sound (skip zero-writes storms)
    if os.getenv("VOLLOG") == "1" then log("VVOL v%02d %s=%04x", o // 16, (o % 16 == 0) and "L" or "R", v) end
  end
end
local dio, mp3len, mp3st, T0 = {}, 0, -1, nil
-- I2C decoder (master writes only; the game bit-bangs SCL/SDA through DIO 0xac)
local scl, sda, inx, bits, byte, bytes = 1, 1, false, 0, 0, {}
i2c_w = function(c, d)
  if c == 1 and scl == 1 and sda == 1 and d == 0 then inx = true; bits = 0; byte = 0; bytes = {}       -- START
  elseif c == 1 and scl == 1 and sda == 0 and d == 1 then                                            -- STOP
    if inx and #bytes > 0 then
      local t = {}; for i, b in ipairs(bytes) do t[i] = string.format("%02x", b) end
      if bytes[1] == 0x3a and bytes[2] == 0x68 then log("I2C %s", table.concat(t, " ")) end
    end
    inx = false
  elseif inx and c == 1 and scl == 0 then                                                            -- SCL rising: sample
    if bits < 8 then byte = (byte << 1) | d; bits = bits + 1
    else bytes[#bytes + 1] = byte; bits = 0; byte = 0 end                                            -- 9th = ACK slot
  end
  scl, sda = c, d
end
local function dio16(a, v)
  local o = a - 0x1f640000
  if o >= 0xa0 and o <= 0xaa then dio[o] = v end
  if o == 0xae then
    if v == 0xe000 then
      local st = ((dio[0xa0] or 0) << 16) | (dio[0xa2] or 0)
      local en = ((dio[0xa4] or 0) << 16) | (dio[0xa6] or 0)
      mp3len = en - st; mp3st = st
      if st == tonumber(os.getenv("STYLE_BGM") or "0x031ae4c") and not T0 then T0 = now(); log("T0 style select") end
      log("MP3PLAY start=%07x len=%d", st, mp3len)
    else log("DIO ae=%04x", v) end
  end
  if o == 0xac then i2c_w((v >> 13) & 1, (v >> 12) & 1) end
end
local function split(offset, data, mask, f)
  for h = 0, 1 do
    if ((mask >> (16 * h)) & 0xffff) ~= 0 then f(offset + 2 * h, (data >> (16 * h)) & 0xffff) end
  end
end
local prog = m.devices[":maincpu"].spaces["program"]
taps[#taps+1] = prog:install_write_tap(0x1f801c00, 0x1f801dff, "spu", function(o, d, mk) split(o, d, mk, spu16) end)
taps[#taps+1] = prog:install_write_tap(0x1f640000, 0x1f6400ff, "dio", function(o, d, mk) split(o, d, mk, dio16) end)

-- inputs
local ports = m.ioport.ports
for tag, p in pairs(ports) do for name, f in pairs(p.fields) do out:write("FIELD " .. tag .. " | " .. name .. "\n") end end
local function fld(name)
  for _, p in pairs(ports) do local f = p.fields[name]; if f then return f end end
end
local coin, start, start2 = fld("Coin 1"), fld("1 Player Start"), fld("2 Players Start")
local arrows = { fld("P1 Left"), fld("P1 Right"), fld("P1 Up"), fld("P1 Down"), fld("P2 Left"), fld("P2 Right"), fld("P2 Up"), fld("P2 Down") }
local rights = { fld("P1 Right"), fld("P2 Right") }
local MENU = { [0x017f400]=true, [0x031ae4c]=true, [0x0d53262]=true }
local PLAY = os.getenv("PLAY") == "1"
local sud = fld("Start Up Device"); if sud then sud.user_value = 0 end
local t_snap, frame = -100, 0
local last_st = -1
local svc = fld("Service Mode")
subs[#subs+1] = emu.register_periodic(function()
  frame = frame + 1
  local t = now()
  if frame % 6 == 0 then for _, tp in ipairs(taps) do tp:reinstall() end end
  local st = (prog:read_u16(0x1f6400ae) >> 12) & 1
  if st ~= last_st then log("STREAMING %d", st); last_st = st end
  if t - t_snap >= SNAP then t_snap = t; m.video:snapshot(); log("SNAP") end
  if svc then svc:set_value((t > 12 and t < 12.3) and 1 or 0) end
  if PLAY and t > 100 then
    local cyc = t % 10
    if coin then coin:set_value((cyc > 0.5 and cyc < 0.7) and 1 or 0) end
    local c5 = t % 5
    local inwin = T0 and (t > T0 and t < T0 + 7)
    local st_on = (c5 > 2 and c5 < 2.6) and not inwin and not (T0 and t > T0 + 7 and os.getenv("NOSTART_AFTER") == "1")
    if T0 and t > T0 + 1 and t < T0 + 1.4 then st_on = true end
    if T0 and t > T0 + 5.5 and t < T0 + 5.9 then st_on = true end
    if start then start:set_value(st_on and 1 or 0) end
    if start2 then start2:set_value(st_on and 1 or 0) end
    local gp = (mp3len > 640000)
    local on = gp and (math.floor(t / 0.0334) % 2 == 0)
    for _, a in ipairs(arrows) do if a then a:set_value(on and 1 or 0) end end
    if T0 and not gp then
      local r = (t > T0 + 3 and t < T0 + 3.3) or (t > T0 + 4 and t < T0 + 4.3)
      for _, a in ipairs(rights) do if a then a:set_value(r and 1 or 0) end end
    end
  end
end)
log("study start PLAY=%s coin=%s start=%s arrows=%d", tostring(PLAY), tostring(coin ~= nil), tostring(start ~= nil), #arrows)
