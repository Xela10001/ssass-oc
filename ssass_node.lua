-- ssass_node.lua - keeps the 16 antimatter hatches of one GTNH SSASS at the same level.
--
-- Runs without OpenOS on each of the 4 unit computers of an SSASS. Their EEPROM (ssass_boot.lua)
-- downloads this file from the brain computer (ssass_brain.lua), which also broadcasts the target.
-- Each computer balances the transposers on its own cable. The 4 cables meet at a Relay, which passes
-- messages but not components; the lowest-addressed computer is the master and picks the level.

local brain = ...
local PORT, WPORT = 4210, 4211 -- unit traffic (cable, through the relay), brain traffic (wireless)
local HATCH_CAP = 16384000

local uptime = computer.uptime
local born = uptime()
local modem = component.proxy(component.list("modem")())
local self = modem.address
modem.open(PORT)
modem.open(WPORT)
modem.setStrength(0) -- unit traffic must stay on the cable, or every other SSASS would hear it

-- Master's level rule. bank = production not yet turned into level (L, all hatches together), i.e.
-- spare antimatter in ME. Keep `reserve` of it so fills never wait on another computer's drains,
-- spend the rest on raising the level, lower the level if a deficit eats through the reserve, and
-- never move more than `step` per hatch per cycle. At or above the target, surplus is your output.
local function nextLevel(L, maxL, bank, reserve, step)
  local inc = math.floor((bank - reserve) / 16)
  if inc < 0 and bank >= -reserve then inc = 0 end
  local want = math.min(maxL, math.max(1, L + inc))
  local newL = math.max(L - step, math.min(L + step, want))
  bank = bank - 16 * (newL - L)
  if newL >= maxL then bank = math.min(bank, reserve) end
  return newL, bank
end

local hatches = {}
for addr in component.list("transposer") do
  local t = component.proxy(addr)
  local x = { t = t }
  for side = 0, 5 do
    local cap = t.getTankCapacity(side)
    if cap == HATCH_CAP then x.h = side elseif type(cap) == "number" and cap > 0 then x.me = side end
  end
  if not (x.h and x.me) then
    error("transposer " .. addr:sub(1, 8) .. " needs an antimatter hatch front and an ME dual interface next to it")
  end
  x.last = t.getTankLevel(x.h)
  hatches[#hatches + 1] = x
end
if #hatches == 0 then error("no transposers on this computer's cable") end

-- A transfer pauses the computer once it moves more than 1/20 of the transposer's rate. Level steps
-- use half of that, leaving the other half for the per-cycle noise.
local step = math.max(1, math.floor(hatches[1].t.getFluidTransferRate() / 40))

-- signed move: > 0 drains the hatch into ME, < 0 fills it from ME; returns the signed amount moved
local function move(x, amount)
  local from, to = x.h, x.me
  if amount < 0 then from, to, amount = x.me, x.h, -amount end
  local ok, n = x.t.transferFluid(from, to, amount)
  n = ok and n or 0
  return from == x.h and n or -n
end

local L, pending, masterAddr, lastL -- level in effect, level for the next cycle, who we follow
local master, target, lastT, maxL = false, nil, -math.huge, nil
local bank, produced, absd, noise, dry, dryCount, dryUntil, cycles = 0, 0, 0, 0, false, 0, 0, 0
local lastCycle, lastReport, lastBeat, statusDue, gotL = -math.huge, 0, 0, false, false

local function broadcastLevel()
  modem.broadcast(PORT, "L", pending or L)
  lastBeat = uptime()
end

-- Called when a hatch changed without us touching it (the forge ran a cycle), or every 1.5 s if
-- nothing changes. Levels switch only here, so every computer switches at the start of the same cycle.
local function onCycle()
  local now = uptime()
  if now - lastCycle < 0.75 then return end -- several hatches changing in one cycle count once
  lastCycle = now
  if pending then L, pending = pending, nil end
  if master then
    bank, produced = bank + produced, 0
    noise = noise * 0.9 + absd * 16 / #hatches * 0.1 -- average swing of all 16 hatches per cycle
    local reserve = math.max(math.floor(2 * math.sqrt(16 * L)), math.floor(3 * noise))
    maxL = (target and now - lastT < 30) and math.floor(target / 16) or L -- no brain: hold
    if dry and cycles >= dryUntil then
      -- ME ran dry (the float was taken, or a power loss voided 10%): the level is no longer funded
      -- and every short fill costs the imbalance penalty. Drop it once so the drains rebuild the float;
      -- the next 3 cycles' dry reports are from before the drop took effect.
      pending = math.min(maxL, math.max(1, L - math.min(step, math.ceil(3 * reserve / 16))))
      bank, dryCount, dryUntil = reserve, dryCount + 1, cycles + 3
    else
      pending, bank = nextLevel(L, maxL, bank, reserve, step)
    end
    dry = false
    broadcastLevel()
    cycles = cycles + 1
    if cycles % 30 == 0 then statusDue = true end
  end
  absd = 0
end

local function onMessage(from, port, kind, v, flag)
  local now = uptime()
  if port == WPORT and kind == "T" then
    target, lastT, brain = v, now, from
  elseif port == PORT and kind == "L" then
    if master and from > self then return end -- the higher one steps down when it hears us
    if master or not masterAddr or from <= masterAddr or now - lastL > 2.5 then
      master, masterAddr, lastL, gotL = false, from, now, true
      if L then pending = v else L = v end
    end
  elseif port == PORT and kind == "d" and master then
    bank = bank + v
    dry = dry or flag
  end
end

while true do
  local busy = false
  for _, x in ipairs(hatches) do
    local a = x.t.getTankLevel(x.h)
    if a ~= x.last then
      onCycle()
      produced = produced + a - x.last
      absd = absd + math.abs(a - x.last)
    end
    if L and a ~= L then
      local moved = move(x, a - L)
      if a < L and moved == 0 then dry = true end
      a = a - moved
      busy = busy or moved ~= 0 -- a stuck hatch (ME empty/full) must not block messages
    end
    x.last = a
  end

  if not busy then -- spare ticks: elect, report, read messages
    local now = uptime()
    if now - lastCycle > 1.5 then onCycle() end -- forge empty or stopped: levels still have to move
    if not master and now - born > 2.5 and (not lastL or now - lastL > 2.5) then
      master, masterAddr, pending, bank = true, self, nil, 0
      if not L then
        L = math.huge
        for _, x in ipairs(hatches) do L = math.min(L, x.last) end
      end
      broadcastLevel()
    end
    if master then
      bank, produced = bank + produced, 0
      if now - lastBeat > 1.5 then broadcastLevel() end
      if statusDue and brain then
        modem.setStrength(400)
        modem.send(brain, WPORT, "status", L, maxL and maxL * 16 or -1, bank, dryCount, #hatches)
        modem.setStrength(0)
        statusDue = false
      end
    elseif gotL and (dry or produced ~= 0 and now - lastReport > 5) then
      -- Report right after a level arrives: the relay forwards one packet per 5 ticks, and a report
      -- queued just before the master's next level would make that level arrive a cycle late.
      modem.send(masterAddr, PORT, "d", produced, dry)
      produced, dry, lastReport = 0, false, now
    end
    gotL = false
    repeat
      local ev, _, from, port, _, kind, v, flag = computer.pullSignal(0)
      if ev == "modem_message" then onMessage(from, port, kind, v, flag) end
    until not ev
  end
end
