-- ssass_boot.lua: flash onto the EEPROM of every SSASS unit computer (case + CPU + RAM + EEPROM +
-- tier 2 wireless card, nothing else). Downloads ssass_node.lua from the brain and runs it; on any
-- error it reports to the brain and starts over 5 s later.
local m = component.proxy(component.list("modem")())
local P = 4211
m.open(P)

local function fetch()
  m.setStrength(400)
  local parts, n, asked = {}, 0, -math.huge
  while true do
    if computer.uptime() - asked > 3 then
      m.broadcast(P, "get")
      asked = computer.uptime()
    end
    local ev, _, from, port, _, kind, i, count, chunk = computer.pullSignal(1)
    if ev == "modem_message" and port == P and kind == "code" then
      parts[i], n = chunk, count
      local got = 0
      for j = 1, n do if parts[j] then got = got + 1 end end
      if got == n then
        m.setStrength(0)
        return table.concat(parts, "", 1, n), from
      end
    end
  end
end

while true do
  local ok, err = pcall(function()
    local code, brain = fetch()
    assert(load(code, "=ssass_node"))(brain)
  end)
  pcall(function()
    m.setStrength(400)
    m.broadcast(P, "err", tostring(err))
    m.setStrength(0)
  end)
  computer.pullSignal(5)
end
