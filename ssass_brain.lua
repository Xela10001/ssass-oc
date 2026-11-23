-- ssass_brain.lua - the one computer you edit. Runs under OpenOS with a tier 2 wireless card, within
-- 400 blocks of every SSASS, on a cable that touches no SSASS unit.
--   ssass_brain 71296000   set the target (total antimatter per SSASS, L) for every SSASS and run
--   ssass_brain            run with the last target
-- It broadcasts the target every 2 s, hands ssass_node.lua to unit computers when they boot, and
-- prints their status and errors. After editing ssass_node.lua, restart this and reboot the units.

local component = require("component")
local computer = require("computer")
local event = require("event")

local PORT = 4211
local TARGET_FILE, NODE_FILE = "/home/ssass_target", "/home/ssass_node.lua"

local target = tonumber((...))
if target then
  local f = assert(io.open(TARGET_FILE, "w"))
  f:write(tostring(target))
  f:close()
else
  local f = io.open(TARGET_FILE)
  if f then target = tonumber(f:read("*a")); f:close() end
end
if not target then error("usage: ssass_brain <total antimatter per SSASS in L>", 0) end

local f = assert(io.open(NODE_FILE), "missing " .. NODE_FILE)
local code = f:read("*a")
f:close()
local parts = {}
for i = 1, #code, 4000 do parts[#parts + 1] = code:sub(i, i + 3999) end -- packets are capped at 8 KB

local modem = component.modem
modem.open(PORT)
modem.setStrength(400)
print(("target %d L per SSASS (%d L per hatch). Press q or Ctrl+C to stop."):format(target, target // 16))

local nextT = 0
while true do
  if computer.uptime() >= nextT then
    modem.broadcast(PORT, "T", target)
    nextT = computer.uptime() + 2
  end
  local ev, _, from, port, _, kind, a, b, c, d, e = event.pull(1)
  if ev == "interrupted" or ev == "key_down" and from == string.byte("q") then
    print("stopped. Units hold their level until the brain runs again.")
    return
  end
  if ev == "modem_message" and port == PORT then
    local who = from:sub(1, 8)
    if kind == "get" then
      for i, p in ipairs(parts) do modem.send(from, PORT, "code", i, #parts, p) end
      print(who .. " booted")
    elseif kind == "status" then
      print(("%s  %d L/hatch = %d L (target %d), spare %d L, ME ran dry %d times: %s")
        :format(who, a, a * 16, b, c, d, tostring(e)))
    elseif kind == "note" then
      print(who .. "  " .. tostring(a))
    elseif kind == "err" then
      print(who .. " error: " .. tostring(a))
    end
  end
end
