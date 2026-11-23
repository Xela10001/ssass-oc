-- ssass_node.lua - keeps the 16 antimatter hatches of one GTNH SSASS at the same level.
--
-- Runs without OpenOS on each of the 4 unit computers of an SSASS. Their EEPROM (ssass_boot.lua)
-- downloads this file from the brain computer (ssass_brain.lua), which also broadcasts the target.
-- Each computer balances the transposers on its own cable. The 4 cables meet at a Relay, which passes
-- messages but not components; the lowest-addressed computer is the master and picks the level.
--
-- Every transposer touches three things: its hatch's front, its own private tank, and an ME dual
-- interface. A hatch's excess is drained into its private tank and its fills come from there, so no
-- other hatch can take that antimatter. The interface is the overflow (it injects straight into ME) and
-- the backup source. AE2 alone decides which interface gets ME's antimatter, and it can starve one.

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
  local found, others = 0, {}
  for side = 0, 5 do
    local cap = t.getTankCapacity(side)
    if cap == HATCH_CAP then x.h, found = side, found + 1
    elseif type(cap) == "number" and cap > 0 then others[#others + 1] = { side, cap } end
  end
  if found ~= 1 then
    error("transposer " .. x.id .. " must touch exactly one antimatter hatch front, it touches " .. found)
  end
  if #others ~= 2 then
    error("transposer " .. x.id .. " must touch its hatch, an ME dual interface and its own private tank; it touches "
      .. #others .. " tanks besides the hatch")
  end
  table.sort(others, function(a, b) return a[2] < b[2] end) -- interface: 16,000 L; private tank: millions
  x.me, x.tk = others[1][1], others[2][1]
  hatches[#hatches + 1] = x
end
if #hatches == 0 then error("no transposers on this computer's cable") end

local function xfer(x, from, to, n)
  if n <= 0 then return 0 end
  local ok, m = x.t.transferFluid(from, to, n)
  return ok and m or 0
end

-- Test every hatch once: 1 L into the hatch, from the hatch into its private tank, and from the
-- tank into the interface. Filling works through any face of a screwdrivered hatch, draining only
-- through its front; the private tank refuses input on its own front.
for _, x in ipairs(hatches) do
  local src = (x.t.getTankLevel(x.tk) >= 1 and x.tk) or (x.t.getTankLevel(x.me) >= 1 and x.me)
  if not src then
    note(x.id .. ": no antimatter in its private tank or ME dual interface yet; it can't be tested until there is")
  elseif xfer(x, src, x.h, 1) < 1 then
    note(x.id .. ": can't fill its hatch. The screwdriver TOGGLES front input: click until chat says 'Front face input enabled'.")
  elseif xfer(x, x.h, x.tk, 1) < 1 then
    note(x.id .. ": can't drain its hatch into its private tank. The transposer must touch the hatch's FRONT, "
      .. "and the tank's front (output face) must not face the transposer.")
  elseif xfer(x, x.tk, x.me, 1) < 1 then
    note(x.id .. ": can't move antimatter from its private tank into its ME dual interface.")
  end
  x.tank = x.t.getTankLevel(x.tk)
  x.last = x.t.getTankLevel(x.h)
end
note(("runs %d hatches"):format(#hatches)
  .. (#hatches ~= 4 and ". WARNING: expected 4. Cables of different unit computers must not touch." or ""))

-- A transfer pauses the computer once it moves more than 1/20 of the transposer's rate. Level steps
-- and tank housekeeping use half of that, leaving the other half for the per-cycle noise.
local step = math.max(1, math.floor(hatches[1].t.getFluidTransferRate() / 40))

local function refused(x)
  if uptime() - (x.warned or -math.huge) < 10 then return end
  x.warned = uptime()
  note(("%s: HATCH REFUSED A FILL with %d L in its private tank. Its front input got switched off: "
    .. "screwdriver it until chat says 'Front face input enabled', and keep its GUI closed."):format(x.id, x.tank))
end

-- signed move: > 0 drains the hatch, < 0 fills it; returns the signed amount moved. Own tank first,
-- the interface when the tank is full (drain) or empty (fill). x.tank tracks the private tank exactly:
-- nothing else touches it.
local function move(x, amount)
  if amount > 0 then
    local n = xfer(x, x.h, x.tk, amount)
    x.tank = x.tank + n
    if n < amount then n = n + xfer(x, x.h, x.me, amount - n) end
    return n
  end
  local want, n = -amount, 0
  if x.tank > 0 then
    local ask = math.min(want, x.tank)
    n = xfer(x, x.tk, x.h, ask)
    x.tank = x.tank - n
    if n < ask then
      x.tank = x.t.getTankLevel(x.tk)
      if x.tank > 0 then refused(x); return -n end
    end
  end
  if n < want then n = n + xfer(x, x.me, x.h, want - n) end
  return -n
end

local L, pending, pendingAt, sendAt -- level in effect; next level, when it was sent/received, when to send
local master, masterAddr, lastL, target, lastT, maxL = false, nil, nil, nil, -math.huge, nil
local noise, absd, short, cycles, drops, dryUntil = 0, 0, 0, 0, 0, 0
local lastCycle, lastQuiet, lastBeat, statusDue, sinceL = -math.huge, uptime(), 0, false, math.huge
local reported, nextHk, applied, why = true, 0, 0, "starting"
local units = {} -- master: latest report per unit computer

local function setLevel(v)
  if v ~= L then sinceL = uptime() end
  if L and v > L then applied = applied + v - L end -- total of all rises, to age the tank reports
  L = v
end

-- A private tank keeps at least `low` after every rise. A hatch whose interface AE2 starves lives on its
-- own production, which beats the per-cycle swing by only ~0.2 sigma; from `low` it runs empty with
-- probability ~exp(-0.4 low/sigma). 16 average swings is ~13 sigma, about 0.5%.
local function low() return math.max(2, math.ceil(16 * noise)) end

-- Called when a hatch changed without us touching it (the forge ran a cycle), or every 1.5 s if
-- nothing changes. Every computer switches to a new level at the first cycle it notices after the level
-- was sent. The master sends it 0.5 s after the cycle it decided in, by which time every computer has
-- noticed that cycle and none has noticed the next one, so all of them switch at the same cycle.
local function onCycle()
  local now = uptime()
  if now - lastCycle < 0.5 then return end -- several hatches changing in one cycle count once
  lastCycle = now
  local sample = absd / #hatches -- average change per hatch in the cycle before
  noise = noise == 0 and sample or noise * 0.9 + sample * 0.1
  absd = 0
  -- A hatch still below the level at the cycle start couldn't be filled (1 L short is free: the forge
  -- drains half of the difference, rounded down). Skip the cycle right after a level change: the fills
  -- may not have had a full window.
  if L and now - sinceL > 1.5 then
    for _, x in ipairs(hatches) do short = math.max(short, L - x.last) end
  end
  if pending and pendingAt and now > pendingAt then setLevel(pending); pending, pendingAt = nil, nil end
  reported = false
  if not master then return end

  maxL = (target and now - lastT < 30) and math.floor(target / 16) or L -- no brain: hold
  local room, worst, stale = math.huge, 0, nil
  for addr, u in pairs(units) do
    if now - u.at > 2.5 then stale = addr:sub(1, 8) end
    room = math.min(room, u.room - (applied - u.applied)) -- rises since the report haven't been paid yet
    worst = math.max(worst, u.short)
    u.short = 0
  end
  if worst > 1 and cycles >= dryUntil then
    -- A hatch's private tank and its interface were both empty. Lower `low` below that hatch: it drains
    -- `low` into its own tank, which covers its next bad cycles, and every other hatch drains into its
    -- own tank, so nothing more is lost. The next 3 cycles' reports are from before the drop.
    pending = math.max(0, L - math.min(step, worst + low()))
    drops, dryUntil = drops + 1, cycles + 3
    why = "a hatch couldn't be filled: lowered to it"
  elseif L > maxL then
    pending = math.max(maxL, L - step)
    why = "lowering to target"
  else
    local up = math.max(0, math.min(step, maxL - L, stale and 0 or math.floor(room)))
    if L < 1 and maxL >= 1 then up = 1 end -- an empty forge makes nothing; 1 L where it can be had starts it
    pending = L + up
    why = L >= maxL and "at target" or up > 0 and "rising"
      or stale and ("waiting for unit " .. stale .. " to report")
      or ("waiting for private tanks (poorest has %d L to spare)"):format(math.max(0, math.floor(room)))
  end
  pendingAt, sendAt = nil, lastQuiet + 0.5 -- the cycle happened after the last reading without a change
  cycles = cycles + 1
  if cycles % 30 == 0 then statusDue = true end
end

local function sendLevel()
  if master and pending and not pendingAt and uptime() >= sendAt then
    modem.broadcast(PORT, "L", pending)
    pendingAt, lastBeat = uptime(), uptime()
  end
end

local function onMessage(from, port, kind, a, b, c, d)
  local now = uptime()
  if port == WPORT and kind == "T" then
    target, lastT, brain = a, now, from
  elseif port == PORT and (kind == "L" or kind == "H") then -- level / heartbeat with the current level
    if master and from > self then return end -- the higher one steps down when it hears us
    if master or not masterAddr or from <= masterAddr or now - lastL > 2.5 then
      master, masterAddr, lastL = false, from, now
      if not L then setLevel(a) elseif kind == "L" and a ~= pending then pending, pendingAt = a, now end
    end
  elseif port == PORT and kind == "d" then -- unit report: room, short, level, private tank total
    if not L then setLevel(c) end -- just rebooted: the others know the level our hatches drifted from
    if master then units[from] = { room = a, short = b, spare = d, applied = applied, at = now } end
  end
end

-- One hatch per idle pass: keep its private tank between 2 and 4 times `low`. The excess goes into the
-- interface (straight into ME: that's your output); a shortfall is pulled from the interface.
local function housekeep()
  nextHk = nextHk % #hatches + 1
  local x, now, lo = hatches[nextHk], uptime(), low()
  if now - (x.readAt or 0) > 10 then -- resync now and then, in case someone touched the tank
    x.tank, x.readAt = x.t.getTankLevel(x.tk), now
  elseif x.tank > 4 * lo then
    x.tank = x.tank - xfer(x, x.tk, x.me, math.min(step, x.tank - 2 * lo))
  elseif x.tank < 2 * lo and now >= (x.pullAt or 0) then
    local n = xfer(x, x.me, x.tk, math.min(step, 2 * lo - x.tank))
    x.tank = x.tank + n
    if n == 0 then x.pullAt = now + 1 end -- interface empty: don't spend a tick on it every pass
  end
end

while true do
  local busy = false
  for _, x in ipairs(hatches) do
    local a = x.t.getTankLevel(x.h)
    if a ~= x.last then
      onCycle()
      absd = absd + math.abs(a - x.last)
    else
      lastQuiet = uptime()
    end
    if L and a ~= L then
      local moved = move(x, a - L)
      a = a - moved
      busy = busy or moved ~= 0 -- a hatch that can't be filled must not block messages
    end
    x.last = a
    sendLevel()
  end

  if not busy then -- spare ticks: elect, keep the tanks, report, read messages
    local now = uptime()
    if now - lastCycle > 1.5 then onCycle() end -- forge empty or stopped: levels still have to move
    if not master and now - born > 2.5 and (not lastL or now - lastL > 2.5) then
      master, masterAddr, pending, pendingAt = true, self, nil, nil
      if not L then
        local lo = math.huge
        for _, x in ipairs(hatches) do lo = math.min(lo, x.last) end
        setLevel(lo)
      end
    end
    if L then housekeep() end
    if L and not reported then -- once per cycle, after this cycle's fills
      reported = true
      local room, spare, lo = math.huge, 0, low()
      for _, x in ipairs(hatches) do
        room, spare = math.min(room, x.tank - lo), spare + x.tank
      end
      if master then
        units[self] = { room = room, short = short, spare = spare, applied = applied, at = now }
      elseif masterAddr then
        modem.send(masterAddr, PORT, "d", room, short, L, spare)
      end
      short = 0
    end
    if master then
      if now - lastBeat > 1.5 then
        modem.broadcast(PORT, "H", L)
        lastBeat = now
      end
      if statusDue and brain then
        local spare = 0
        for _, u in pairs(units) do spare = spare + u.spare end
        modem.setStrength(400)
        modem.send(brain, WPORT, "status", L, maxL and maxL * 16 or -1, spare, drops, why)
        modem.setStrength(0)
        statusDue, drops = false, 0
      end
    end
    repeat
      local ev, _, from, port, _, kind, a, b, c, d = computer.pullSignal(0)
      if ev == "modem_message" then onMessage(from, port, kind, a, b, c, d) end
    until not ev
  end
end
