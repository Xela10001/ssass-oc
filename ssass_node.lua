-- ssass_node.lua - keeps the 16 antimatter hatches of one GTNH SSASS at the same level.
--
-- Runs without OpenOS on each of the 4 unit computers of an SSASS. Their EEPROM (ssass_boot.lua)
-- downloads this file from the brain computer (ssass_brain.lua), which also broadcasts the target.
-- Each computer balances the transposers on its own cable. The 4 cables meet at a Relay, which passes
-- messages but not components; the lowest-addressed computer is the master and picks the level.

local brain = ...
local PORT, WPORT = 4210, 4211 -- unit traffic (cable, through the relay), brain traffic (wireless)
local HATCH_CAP = 16384000
local SHARE = 2 -- at most this many hatches draw from one ME dual interface

local uptime = computer.uptime
local born = uptime()
local modem = component.proxy(component.list("modem")())
local self = modem.address
modem.open(PORT)
modem.open(WPORT)
modem.setStrength(0) -- unit traffic must stay on the cable, or every other SSASS would hear it

-- Master's level rule. bank = production not yet turned into level (L, all hatches together), i.e.
-- spare antimatter in ME. Keep `reserve` of it so fills never wait on another computer's drains,
-- spend the rest on raising the level, lower the level if a deficit eats through the reserve, rise
-- by at most `up` and fall by at most `down` per hatch per cycle. At the target, surplus is output.
local function nextLevel(L, maxL, bank, reserve, up, down)
  local inc = math.floor((bank - reserve) / 16)
  if inc < 0 and bank >= -reserve then inc = 0 end
  local want = math.min(maxL, math.max(1, L + inc))
  local newL = math.max(L - down, math.min(L + math.max(0, up), want))
  bank = bank - 16 * (newL - L)
  if newL >= maxL then bank = math.min(bank, reserve) end
  return newL, bank
end

-- tell the brain something worth a human's attention (costs 3 ticks; keep it rare)
local function note(msg)
  if not brain then return end
  modem.setStrength(400)
  modem.send(brain, WPORT, "note", msg)
  modem.setStrength(0)
end

local hatches = {}
for addr in component.list("transposer") do
  local t = component.proxy(addr)
  local x = { t = t, id = addr:sub(1, 8) }
  local found = 0
  for side = 0, 5 do
    local cap = t.getTankCapacity(side)
    if cap == HATCH_CAP then x.h, found = side, found + 1
    elseif type(cap) == "number" and cap > 0 then x.me = side end
  end
  if not (x.h and x.me) then
    error("transposer " .. x.id .. " needs an antimatter hatch front and an ME dual interface next to it")
  end
  if found > 1 then error("transposer " .. x.id .. " touches " .. found .. " antimatter hatches; it must touch only one") end
  hatches[#hatches + 1] = x
end
if #hatches == 0 then error("no transposers on this computer's cable") end

-- Test every hatch once: 1 L in from the interface, 1 L back out. Filling works through any face of a
-- screwdrivered hatch, draining only through its front.
for _, x in ipairs(hatches) do
  if x.t.getTankLevel(x.me) < 1 then
    note(x.id .. ": its ME dual interface has no antimatter yet. If that stays, set antimatter in one of its fluid slots.")
  else
    local ok, n = x.t.transferFluid(x.me, x.h, 1)
    if not ok or n < 1 then
      note(x.id .. ": can't fill its hatch. Screwdriver the hatch so its front accepts input.")
    else
      ok, n = x.t.transferFluid(x.h, x.me, 1)
      if not ok or n < 1 then note(x.id .. ": can't drain its hatch. The transposer must touch the hatch's FRONT face.") end
    end
  end
  x.last = x.t.getTankLevel(x.h)
end
note(("runs %d hatches"):format(#hatches)
  .. (#hatches ~= 4 and ". WARNING: expected 4. Cables of different unit computers must not touch." or ""))

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

local L, pending, pendingAt, sendAt -- level in effect; next level, when it was sent/received, when to send
local master, masterAddr, lastL, target, lastT, maxL = false, nil, nil, nil, -math.huge, nil
local bank, produced, absd, noise, dry, dryCount, dryUntil, cycles = 0, 0, 0, 0, false, 0, 0, 0
local lastCycle, lastQuiet, lastBeat, statusDue, sinceL = -math.huge, uptime(), 0, false, math.huge
local reported, tankMin, tanks, nextTank = true, 0, {}, 0 -- lowest interface tank; master: per unit
local why, lastShort = "starting", -math.huge

local function setLevel(v)
  if v ~= L then sinceL = uptime() end
  L = v
end

-- Called when a hatch changed without us touching it (the forge ran a cycle), or every 1.5 s if
-- nothing changes. Every computer switches to a new level at the first cycle it notices after the level
-- was sent. The master sends it 0.5 s after the cycle it decided in, by which time every computer has
-- noticed that cycle and none has noticed the next one, so all of them switch at the same cycle.
local function onCycle()
  local now = uptime()
  if now - lastCycle < 0.5 then return end -- several hatches changing in one cycle count once
  lastCycle = now
  -- A hatch still below the level at the cycle start means its interface couldn't fund the fill (1 L
  -- short is free: the forge drains half of the difference, rounded down). Skip the cycle right after a
  -- level change: the fills may not have had a full window.
  if L and now - sinceL > 1.5 then
    for _, x in ipairs(hatches) do
      if x.last < L - 1 then
        dry = true
        if now - lastShort > 10 then
          lastShort = now
          note(("%s: hatch short at the cycle start (%d of %d L), its interface holds %d L")
            :format(x.id, x.last, L, x.tank or -1))
        end
      end
    end
  end
  local before = L
  if pending and pendingAt and now > pendingAt then setLevel(pending); pending, pendingAt = nil, nil end
  reported = false
  if master then
    bank, produced = bank + produced, 0
    noise = noise * 0.9 + absd * 16 / #hatches * 0.1 -- average swing of all 16 hatches per cycle
    local reserve = math.max(math.floor(2 * math.sqrt(16 * L)), math.floor(3 * noise))
    maxL = (target and now - lastT < 30) and math.floor(target / 16) or L -- no brain: hold
    -- A rise needs SHARE fills from every interface tank on top of this cycle's noise. Tank readings
    -- can be a cycle old, so the rise that starts now and the one before it may still be owed.
    local poorest = tankMin
    for addr, t in pairs(tanks) do
      if now - t[2] < 2.5 then poorest = math.min(poorest, t[1]) else tanks[addr] = nil end
    end
    poorest = poorest - 2 * SHARE * math.max(0, L - (before or L))
    local up = math.min(step, math.floor(poorest / SHARE - 3 * noise / 16))
    if L < 1 then up = 1 end -- an empty forge makes nothing; 1 L in whichever hatches can get it starts it
    -- why the level isn't rising, for the brain's status line
    if not (target and now - lastT < 30) then why = "holding: no target from the brain"
    elseif L >= maxL then why = "at target"
    elseif up <= 0 then why = ("waiting for interface tanks (poorest %d L)"):format(math.max(0, poorest))
    elseif bank - reserve < 16 then why = ("saving production (%d of %d L)"):format(bank, reserve + 16)
    else why = "rising" end
    if dry and cycles >= dryUntil then why = "a hatch was short: lowering to refill ME" end
    if dry and cycles >= dryUntil then
      -- ME ran dry (the float was taken, or a power loss voided 10%): the level is no longer funded
      -- and every short fill costs the imbalance penalty. Drop it once so the drains rebuild the float;
      -- the next 3 cycles' dry reports are from before the drop took effect.
      pending = math.min(maxL, math.max(1, L - math.min(step, math.ceil(3 * reserve / 16))))
      bank, dryCount, dryUntil = reserve, dryCount + 1, cycles + 3
    else
      pending, bank = nextLevel(L, maxL, bank, reserve, up, step)
    end
    -- The cycle happened after the last reading that showed no change.
    pendingAt, sendAt, dry = nil, lastQuiet + 0.5, false
    cycles = cycles + 1
    if cycles % 30 == 0 then statusDue = true end
  end
  absd = 0
end

local function sendLevel()
  if master and pending and not pendingAt and uptime() >= sendAt then
    modem.broadcast(PORT, "L", pending)
    pendingAt, lastBeat = uptime(), uptime()
  end
end

local function onMessage(from, port, kind, v, flag, tank, level)
  local now = uptime()
  if port == WPORT and kind == "T" then
    target, lastT, brain = v, now, from
  elseif port == PORT and (kind == "L" or kind == "H") then -- level / heartbeat with the current level
    if master and from > self then return end -- the higher one steps down when it hears us
    if master or not masterAddr or from <= masterAddr or now - lastL > 2.5 then
      master, masterAddr, lastL = false, from, now
      if not L then setLevel(v) elseif kind == "L" and v ~= pending then pending, pendingAt = v, now end
    end
  elseif port == PORT and kind == "d" then
    if not L then setLevel(level) end -- just rebooted: the others know the level our hatches drifted from
    if master then
      bank = bank + v
      dry = dry or flag
      tanks[from] = { tank, now }
    end
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
    else
      lastQuiet = uptime()
    end
    if L and a ~= L then
      local moved = move(x, a - L)
      a = a - moved
      busy = busy or moved ~= 0 -- a stuck hatch (ME empty/full) must not block messages
    end
    x.last = a
    sendLevel()
  end

  if not busy then -- spare ticks: elect, read one interface tank, report, read messages
    local now = uptime()
    if now - lastCycle > 1.5 then onCycle() end -- forge empty or stopped: levels still have to move
    if not master and now - born > 2.5 and (not lastL or now - lastL > 2.5) then
      master, masterAddr, pending, pendingAt, bank = true, self, nil, nil, 0
      if not L then
        local lo = math.huge
        for _, x in ipairs(hatches) do lo = math.min(lo, x.last) end
        setLevel(lo)
      end
    end
    if L then -- one tank per pass: reading all of them at once delays the balancing
      nextTank = nextTank % #hatches + 1
      local x = hatches[nextTank]
      x.tank = x.t.getTankLevel(x.me)
      tankMin = math.huge
      for _, y in ipairs(hatches) do tankMin = math.min(tankMin, y.tank or 0) end
    end
    if L and not reported then -- once per cycle, after this cycle's fills
      reported = true
      if master then
        bank, produced = bank + produced, 0
      elseif masterAddr then
        modem.send(masterAddr, PORT, "d", produced, dry, tankMin, L)
        produced, dry = 0, false
      end
    end
    if master then
      bank, produced = bank + produced, 0
      if now - lastBeat > 1.5 then
        modem.broadcast(PORT, "H", L)
        lastBeat = now
      end
      if statusDue and brain then
        modem.setStrength(400)
        modem.send(brain, WPORT, "status", L, maxL and maxL * 16 or -1, bank, dryCount, why)
        modem.setStrength(0)
        statusDue = false
      end
    end
    repeat
      local ev, _, from, port, _, kind, v, flag, tank, level = computer.pullSignal(0)
      if ev == "modem_message" then onMessage(from, port, kind, v, flag, tank, level) end
    until not ev
  end
end
