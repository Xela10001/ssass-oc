"""Tick-level simulation of the SSASS automation: ssass_brain.lua, ssass_boot.lua, ssass_node.lua.

Every unit computer runs the real EEPROM code, which downloads ssass_node.lua from the real brain
program over simulated wireless. Units of one SSASS talk through a simulated relay (5 tick delay,
1 packet per 5 ticks, 20 packet queue: the GTNH defaults). Every indirect OC call costs one tick;
transferFluid adds the transposer's pause. The forge is a copy of AntimatterForge.checkProcessing and
ticks before or after the computers at random, like an unknown tile-entity order.

usage: python ssass_sim.py   (needs `pip install lupa`)
"""
import math, os, random, sys, tempfile

sys.path.insert(0, os.path.join(os.environ.get("TEMP", ""), "opencode", "pylib"))
from lupa import lua53

HERE = os.path.dirname(os.path.abspath(__file__))
NODE_FILE = os.path.join(HERE, "ssass_node.lua")
CAP = 16384000
# Relay.updateLimits: stock relay waits 5 ticks and forwards 1 packet; a tier 3 CPU makes the wait
# max(1, 5 - 3 * 1.5) = 1 tick and tier 3.5 RAM forwards 1 + 6 = 7 packets each time.
RELAY_STOCK, RELAY_UPGRADED = (5, 1), (1, 7)
RELAY_QUEUE = 20
LUV = 655_360  # transposer upgraded with a LuV fluid regulator (NewHorizonsCoreMod ScriptOpenComputers)


def src(name):
    return open(os.path.join(HERE, name), encoding="utf-8").read()


class DualInterface:
    """AE2FC DualityFluidInterface with antimatter in one config slot, ticked like AE2's TickManagerCache.

    A fill (hatch -> interface) goes straight into the ME network. A drain (interface -> hatch) comes from a
    16,000 L tank. The interface tops the tank up on its grid tick: success sets the tick interval to the
    minimum (5), failure (ME empty) adds 1 up to 120, a full tank sleeps, and a drain wakes a sleeping one
    for the next tick."""

    TANK, MIN, MAX = 16000, 5, 120

    def __init__(self, world):
        self.world = world
        self.tank, self.rate, self.last, self.awake = 0, (self.MIN + self.MAX) // 2, 0, True

    def grid_tick(self):
        w = self.world
        if not self.awake or w.tick - self.last < self.rate:
            return
        got = min(self.TANK - self.tank, w.me)
        if got > 0:
            self.tank += got
            w.me -= got
            self.rate = self.MIN
        else:
            self.rate = min(self.MAX, self.rate + 1)
        self.last = w.tick
        if self.tank >= self.TANK:
            self.awake = False

    def drain(self, n):
        n = min(n, self.tank)
        if n > 0:
            self.tank -= n
            if not self.awake:  # alertDevice: tick on the next grid tick
                self.awake, self.rate, self.last = True, self.MIN, self.world.tick - self.MAX
        return n


class Forge:
    PTANK = 4_000_000  # Super Tank I

    def __init__(self, world, start, C, A, per_iface):
        self.world, self.C, self.A = world, C, A
        self.h = [start] * 16
        self.ptank = [0] * 16  # each transposer's private tank
        self.ifaces = [DualInterface(world) for _ in range(16 // per_iface)]
        self.iface_of = [self.ifaces[i // per_iface] for i in range(16)]
        self.phase = random.randrange(20)
        self.relay = []  # [ready_tick, sender, to, port, payload]
        self.relay_next = 0
        self.units = []
        self.log = []  # (second, lowest, highest) at each cycle start
        self.imbalanced = self.penalty = self.made = 0
        self.crash_at = None

    def cycle(self):  # AntimatterForge.checkProcessing
        w = self.world
        if self.crash_at is not None and w.tick >= self.crash_at:
            self.crash_at = None
            self.h = [a - a // 10 for a in self.h]  # power loss voids 10%
            w.me = 0  # ...and someone emptied ME, interface tanks and private tanks included
            for x in self.ifaces:
                x.tank = 0
            self.ptank = [0] * 16
        total, lo, hi = sum(self.h), min(self.h), max(self.h)
        self.log.append((w.tick // 20, lo, hi))
        if hi != lo and w.tick > w.settle:
            self.imbalanced += 1
        for i in range(16):
            loss = int((self.h[i] - lo) * 0.5)
            self.h[i] -= loss
            if w.tick > w.settle:
                self.penalty += loss
        coeff = total ** (0.5 + self.C)
        for i in range(16):
            c = math.ceil((random.gauss(0, 1) + 0.2 + self.A) * (coeff / 16))
            c = max(c, -self.h[i])
            self.h[i] += c
            if w.tick > w.settle:
                self.made += c

    def relay_tick(self):
        delay, amount = self.world.relay
        if self.world.tick < self.relay_next:
            return
        sent = 0
        while self.relay and sent < amount and self.world.tick >= self.relay[0][0]:
            _, sender, to, port, payload = self.relay.pop(0)
            for u in self.units:
                if u is not sender:
                    u.deliver(sender.addr, to, port, payload)
            sent += 1
        if sent:
            self.relay_next = self.world.tick + delay


class Endpoint:
    """A computer with one tier 2 wireless card."""

    def __init__(self, world, addr, forge=None):
        self.world, self.addr, self.forge = world, addr, forge
        self.inbox, self.ports, self.strength = [], set(), 0
        world.endpoints.append(self)

    def deliver(self, sender, to, port, payload):
        if port in self.ports and (to is None or to == self.addr):
            self.inbox.append((sender, port) + tuple(payload))

    def send(self, to, port, *payload):
        if self.strength > 0:  # wireless, everyone is in range
            for e in self.world.endpoints:
                if e is not self:
                    e.deliver(self.addr, to, port, payload)
        if self.forge is not None:  # tier 2 cards always send on the cable too; the relay forwards it
            if len(self.forge.relay) < RELAY_QUEUE:
                self.forge.relay.append([self.world.tick + self.world.relay[0], self, to, port, payload])

    def pull(self):
        return self.inbox.pop(0) if self.inbox else (None,)

    def reset(self):
        self.inbox, self.ports, self.strength = [], set(), 0


LUA_RUNTIME = r"""
function(py, code, arg, openos)
  local Y = coroutine.yield
  local function sync() Y() end -- an indirect call waits for the next tick
  local kinds, proxies = {}, {}
  for _, i in ipairs(py.ids) do
    local addr = ("transposer-%02d"):format(i)
    kinds[addr] = "transposer"
    proxies[addr] = {
      getTankCapacity = function(s) sync() return py.cap(s) end,
      getTankLevel = function(s) sync() return py.level(i, s) end,
      getFluidTransferRate = function() sync() return py.rate end,
      transferFluid = function(f, t, n)
        sync()
        local ok, moved, pause = py.transfer(i, f, t, n)
        for _ = 1, pause do Y() end
        return ok, moved
      end,
    }
  end
  local maddr = py.addr
  kinds[maddr] = "modem"
  proxies[maddr] = {
    address = maddr,
    open = function(p) py.open(p) return true end,
    isWireless = function() return true end,
    setStrength = function(s) sync() py.strength(s) return s end,
    broadcast = function(port, ...) sync() py.send(nil, port, ...) return true end,
    send = function(to, port, ...) sync() py.send(to, port, ...) return true end,
  }
  local function list(kind)
    local t, key = {}, nil
    for a, k in pairs(kinds) do if k == kind then t[a] = k end end
    return setmetatable(t, { __call = function() key = next(t, key) return key end })
  end
  local function nextMessage()
    local m = table.pack(py.pull())
    if m[1] then return "modem_message", maddr, m[1], m[2], 0, table.unpack(m, 3, m.n) end
  end
  local computer = {
    uptime = function() return py.uptime() end,
    pullSignal = function(timeout)
      local deadline = py.uptime() + (timeout or math.huge)
      repeat
        Y()
        local r = table.pack(nextMessage())
        if r[1] then return table.unpack(r, 1, r.n) end
      until py.uptime() >= deadline
    end,
  }
  local component = { list = list, proxy = function(a) return proxies[a] end, modem = proxies[maddr] }
  -- raw OC sandbox: no print, no require, no io; load() defaults to the sandbox
  local env = { component = component, computer = computer }
  for _, k in ipairs({ "assert", "error", "ipairs", "pairs", "next", "pcall", "xpcall", "select",
      "tonumber", "tostring", "type", "setmetatable", "getmetatable", "rawequal", "rawget", "rawset",
      "math", "string", "table", "coroutine" }) do env[k] = _G[k] end
  env.load = function(c, n, m, e) return load(c, n, m or "t", e or env) end
  if openos then -- the brain runs OpenOS
    local mods = {
      component = component,
      computer = computer,
      event = { pull = function(timeout, name) return computer.pullSignal(timeout) end },
    }
    env.require = function(n) return mods[n] end
    env.print = function(s) py.log(s) end
    env.io = { open = function(p, mode) return io.open(py.path(p), mode) end }
  end
  return assert(load(code, "=chunk", "t", env))(arg)
end"""


class Computer(Endpoint):
    def __init__(self, world, addr, code, arg=None, forge=None, ids=(), rate=LUV, openos=False):
        super().__init__(world, addr, forge)
        self.code, self.arg, self.ids, self.rate, self.openos = code, arg, list(ids), rate, openos
        self.start()

    def start(self):
        w, ep = self.world, self
        self.reset()
        lua = lua53.LuaRuntime(unpack_returned_tuples=True)
        pause = [0]

        HATCH, IFACE, PTANK = 2, 3, 4  # transposer sides

        def transfer(i, frm, to, n):
            f = ep.forge
            n = int(n)
            # how much the source can give
            avail = {HATCH: f.h[i], IFACE: f.iface_of[i].tank, PTANK: f.ptank[i]}.get(frm, 0)
            # how much the sink takes; the interface injects straight into ME, without limit
            room = {HATCH: CAP - f.h[i], IFACE: n, PTANK: Forge.PTANK - f.ptank[i]}.get(to, 0)
            n = max(0, min(n, avail, room))
            if frm == HATCH:
                f.h[i] -= n
            elif frm == IFACE:
                n = f.iface_of[i].drain(n)
            else:
                f.ptank[i] -= n
            if to == HATCH:
                f.h[i] += n
            elif to == IFACE:
                w.me += n
            else:
                f.ptank[i] += n
            delay = n / ep.rate - 0.05
            return n > 0, n, (math.ceil(delay * 20) if delay > 0 else 0)

        py = lua.table_from({
            "ids": lua.table_from(self.ids),
            "addr": self.addr,
            "rate": self.rate,
            "level": lambda i, side: {HATCH: ep.forge.h[i], IFACE: ep.forge.iface_of[i].tank,
                                      PTANK: ep.forge.ptank[i]}.get(side, 0),
            "cap": lambda side: {HATCH: CAP, IFACE: DualInterface.TANK, PTANK: Forge.PTANK}.get(side),
            "transfer": transfer,
            "open": lambda p: ep.ports.add(p),
            "strength": lambda s: setattr(ep, "strength", s),
            "send": lambda to, port, *payload: ep.send(to, port, *payload),
            "pull": ep.pull,
            "uptime": lambda: w.tick / 20,
            "log": lambda s: w.logs.append(f"[{w.tick / 20:7.1f}s] {s}"),
            "path": lambda p: w.files[p],
        })
        self.co = lua.eval(LUA_RUNTIME).coroutine(py, self.code, self.arg, self.openos)

    def step(self):
        self.co.send(None)


class World:
    def __init__(self, me, settle, relay=RELAY_UPGRADED):
        self.tick, self.me, self.settle, self.relay = 0, me, settle * 20, relay
        self.endpoints, self.forges, self.logs = [], [], []
        tmp = tempfile.mkdtemp()
        self.files = {"/home/ssass_node.lua": NODE_FILE, "/home/ssass_target": os.path.join(tmp, "target")}
        self.brain = None

    def start_brain(self, target):
        if self.brain is None:
            self.brain = Computer(self, "brain-00", src("ssass_brain.lua"), str(target), openos=True)
        else:  # Ctrl+C, then run again with the new number
            self.brain.arg = str(target)
            self.brain.start()

    def add_forge(self, start, C=0.0, A=0.0, rate=LUV, per_unit=4, per_iface=2):
        f = Forge(self, start, C, A, per_iface)
        for x in f.ifaces:  # interfaces stock up from ME before anything starts
            x.grid_tick()
        boot = src("ssass_boot.lua")
        for k in range(0, 16, per_unit):
            addr = f"{random.getrandbits(32):08x}-unit"
            f.units.append(Computer(self, addr, boot, forge=f, ids=range(k, k + per_unit), rate=rate))
        self.forges.append(f)
        return f

    def run(self, seconds, events=()):
        events = sorted(events)
        for self.tick in range(self.tick, self.tick + seconds * 20):
            while events and events[0][0] * 20 <= self.tick:
                events.pop(0)[1]()
            forge_first = random.random() < 0.5
            if forge_first:
                self.cycle_forges()
            for f in self.forges:
                f.relay_tick()
            for c in [self.brain] + [u for f in self.forges for u in f.units]:
                c.step()
            if not forge_first:
                self.cycle_forges()
            ifaces = [x for f in self.forges for x in f.ifaces]
            random.shuffle(ifaces)  # AE2 grid ticks; who restocks first depends on the queue
            for x in sorted(ifaces, key=lambda x: x.last + x.rate):
                x.grid_tick()
        self.tick += 1

    def cycle_forges(self):
        for f in self.forges:
            if self.tick % 20 == f.phase:
                f.cycle()


def last_level(f):
    _, lo, hi = f.log[-1]
    return lo, hi


def stage4(relay):
    """Wiki stage 4: 71,296,000 L per SSASS with MHDCSM (C=0.1) and Mk-VI (A=0.1), LuV transposers.
    Two SSASSs on one brain. At 80 s the target drops to 60M; at 150 s SSASS A's master reboots."""
    w = World(me=2_000_000, settle=12, relay=relay)
    w.start_brain(71_296_000)
    a = w.add_forge(4_456_000, C=0.1, A=0.1)
    b = w.add_forge(4_456_000, C=0.1, A=0.1)
    w.run(10)
    master = min(a.units, key=lambda u: u.addr)
    w.run(210, [(80, lambda: w.start_brain(60_000_000)), (150, master.start)])
    return w, a, b


if __name__ == "__main__":
    random.seed(7)
    w, a, b = stage4(RELAY_UPGRADED)
    for name, f in (("SSASS A", a), ("SSASS B", b)):
        lo, hi = last_level(f)
        print(f"stage 4 {name}: imbalanced {f.imbalanced}/{len(f.log)} cycles after 12 s, penalty "
              f"{f.penalty / f.made:.1%} of production, last cycle {lo}..{hi} L/hatch (target {60_000_000 // 16})")
        assert lo == hi == 60_000_000 // 16, "must settle exactly on the new target"
        # A's master reboots at 150 s: its 4 hatches drift for ~4 cycles while it boots and self-tests
        assert f.penalty < (0.05 if f is a else 0.01) * f.made, "imbalance penalty must stay small"
    print("  brain log:", *[l for l in w.logs if "error" in l or "L/hatch" in l][:4], sep="\n    ")
    assert not [l for l in w.logs if "error" in l], "no unit may crash"

    random.seed(7)
    w, a, b = stage4(RELAY_STOCK)
    print("stock relay (no CPU/RAM in it), for comparison:",
          *[f"imbalanced {f.imbalanced}, penalty {f.penalty / f.made:.1%}" for f in (a, b)], sep="  ")

    # Ramp: empty forge, 64 L seeded in ME, no stabilizers, target 160,000 L, 8 shared interfaces.
    random.seed(1)
    w = World(me=64, settle=0)
    w.start_brain(160_000)
    f = w.add_forge(0)
    w.run(1500)
    print(f"ramp: {sum(f.h)} L after {len(f.log)} cycles, imbalanced {f.imbalanced}, "
          f"penalty {f.penalty} L vs production {f.made} L")
    assert sum(f.h) > 16_000 and f.penalty < 0.05 * f.made, "ramp must grow without paying the penalty"

    # Hold 8,000 L; at 700 s a power loss voids 10% and ME is emptied. Must climb back, not spiral to 0.
    random.seed(1)
    w = World(me=64, settle=0)
    w.start_brain(8000)
    f = w.add_forge(0)
    f.crash_at = 700 * 20
    w.run(1100)
    lo, hi = last_level(f)
    print(f"crash at 700 s: {lo}..{hi} L/hatch at 1100 s (target {8000 // 16}), ME {w.me} L")
    assert lo == hi == 8000 // 16, "must rebuild the float and return to the target"

    # Your kickstart: 17 L in ME, 8 dual interfaces shared by 2 hatches each, target 400,000 L.
    random.seed(1)
    w = World(me=17, settle=0)
    w.start_brain(400_000)
    f = w.add_forge(0)
    w.run(1200)
    print(f"kickstart from 17 L: {sum(f.h)} L after 20 min, penalty {f.penalty / f.made:.1%} of production")
    assert sum(f.h) > 10_000 and f.penalty < 0.05 * f.made, "must start from 17 L"

    # The collapse seen in game: 1,755 L/hatch, ME empty, seven interfaces holding ~4,000 L and one
    # starved at 0 (AE2 keeps feeding the others), private tanks just placed and empty. Target 100,000 L.
    for seed in (1, 2, 3):
        random.seed(seed)
        w = World(me=0, settle=0)
        w.start_brain(100_000)
        f = w.add_forge(1755)
        for k, x in enumerate(f.ifaces):
            x.tank = 0 if k == 7 else 4000
        lows = []
        w.run(900, [(t, lambda: lows.append(min(f.h))) for t in range(60, 900, 30)])
        print(f"starved interface, seed {seed}: lowest level after 1 min {min(lows)} L/hatch, "
              f"{sum(f.h)} L after 15 min, penalty {f.penalty / f.made:.1%}, starved interface {f.ifaces[7].tank} L")
        assert min(lows) > 1000 and sum(f.h) > 28_000, "a starved interface must not collapse the level"
