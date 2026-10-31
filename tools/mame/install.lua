-- ddrextrm (or $SET) first-boot install in MAME: Start Up Device = CD-ROM, snapshot every 20 s
local subs = {}
local t_last = -100
local done_cfg = false
subs[#subs+1] = emu.register_periodic(function()
  local m = manager.machine
  if not done_cfg then
    local f = m.ioport.ports[":IN1"].fields["Start Up Device"]
    f.user_value = tonumber(os.getenv("BOOTDEV") or "8")
    done_cfg = true
    print(string.format("BOOTDEV set to %d", f.user_value))
  end
  local t = m.time:as_double()
  local svc = m.ioport.ports[":IN3"].fields["Service Mode"]
  local p = t % 30
  svc:set_value((t > 15 and p > 15 and p < 15.3) and 1 or 0)   -- NOTE 604 (CD drive update) waits for TEST
  if t - t_last >= 20 then
    t_last = t
    m.video:snapshot()
    print(string.format("snap t=%.1f", t))
  end
end)
