# ssass-oc

OpenComputers automation for the GTNH 2.9 Semi-Stable Antimatter Stabilization Sequencer (SSASS). It keeps all 16 antimatter hatches at the same level every cycle and ramps each SSASS to a target you set once, on one computer, for every SSASS you build.

## Install

On the brain computer (OpenOS, internet card, tier 2 wireless card), run:

```
wget -f https://raw.githubusercontent.com/Xela10001/ssass-oc/main/install.lua /tmp/i.lua && /tmp/i.lua 71296000
```

The number is the target: total antimatter per SSASS in L, across all 16 hatches. The installer:

- downloads the programs into `/home`,
- stores the target,
- makes the brain start when the computer boots,
- offers to flash unit EEPROMs,
- starts the brain.

For each EEPROM, swap this computer's own EEPROM for a blank one when it asks. It refuses to overwrite anything except a blank EEPROM or an earlier SSASS unit EEPROM. Put the Lua BIOS back before this computer reboots.

Running the same command again updates the programs and keeps the stored target. After an update, reboot the unit computers so they download the new code.

## Changing the target

Stop the brain with Ctrl+C, then run:

```
/home/ssass_brain.lua 60000000
```

Every SSASS follows within a few seconds. Going down, the level drops by at most 16,384 L per hatch per second with LuV transposers. Going up, it only rises as fast as the forge produces antimatter, because it never borrows antimatter it hasn't made.

## Building one SSASS

Build one, then copy-paste it to the others with the Matter Manipulator. It copies the EEPROMs, the transposer tiers and the hatch screwdriver setting.

- **Hatches:** screwdriver each of the 16 antimatter hatches so its front face accepts input. The screwdriver toggles the setting, so read the chat: it must say "Front face input enabled". Keep the hatch GUIs closed while the system runs. A GregTech bug switches front input off when a hatch's contents change while its GUI is open.
- **Transposers:** one transposer per hatch, upgraded with a LuV or better fluid regulator in the assembler. Each transposer touches exactly three things:
  - its hatch's front face,
  - its own private tank,
  - an ME Dual Interface.

  Never put a tank against a hatch's front face: the hatch dumps its whole contents into it every tick.
- **Private tanks:** one per transposer, never shared, touching nothing but its transposer. A GT Super Tank I (4,000,000 L) is plenty; at Stage 4 a tank holds about 170,000 L at most.
  - Its front (output face) must not face the transposer, because a Super Tank refuses input on its front.
  - Keep auto-output, void overflow and void full off.
  - Antimatter in the tank is yours. The script only moves it between its hatch, the tank and the interface.
- **ME Dual Interfaces:** set antimatter in one fluid slot, on every interface. One interface may serve at most 2 transposers.
  - Antimatter put into an interface goes straight into ME. That's your output.
  - Taking from an interface comes out of its own 16,000 L tank, which restocks from ME. AE2 decides which interface gets ME's antimatter, and it can starve one completely, which is why each hatch needs its own tank.
- **Unit computers:** 4 per SSASS, each with:
  - a tier 2 CPU,
  - any RAM,
  - a flashed unit EEPROM,
  - a tier 2 wireless card,
  - no hard drive or screen.

  Each one gets its own cable to the transposers of 4 hatches. The 4 cables must not touch each other.
- **Relay:** one per SSASS, joining the 4 cables. It **must** have a tier 3 CPU and tier 3.5 RAM. A stock relay forwards one message per 5 ticks. The level changes then arrive a cycle late, and the simulation lost more than the whole production to imbalance penalties.
- **Power:** every cable needs OpenComputers power.

The brain must be within 400 blocks of every SSASS, and its own cable must not touch any unit computer.

The 4 unit computers of an SSASS pick a master among themselves. There's nothing to configure per SSASS.

## How it works

Each unit computer reads its 4 hatches every tick or two. When the forge runs a cycle, the unit brings each hatch back to the level:
- **Above the level:** it drains the excess into the hatch's private tank.
- **Below the level:** it fills the shortfall from that tank.
- **Fallback:** it uses the interface only when the tank is full (drain) or empty (fill).

Nothing else touches a private tank, so the unit knows its contents without reading them.

Between hatch reads, the unit keeps each private tank between 2 and 4 times `low`, where `low` is 16 times the average per-cycle swing of a hatch.
- **Excess** goes into the interface, which means into ME.
- **A shortfall** is pulled from the interface when it has antimatter.

The master raises the level only by what the poorest private tank can pay while keeping `low` in reserve. So the level never rises on antimatter a hatch can't actually reach.

The master works out the cycle's exact tick from its readings and sends the next level 10 ticks after it. Every computer switches at the next cycle, so the hatches stay equal while the level moves.

- **A hatch is still short when a cycle starts:** its tank and its interface were both empty. The master lowers the level to `low` below that hatch. The hatch drains `low` into its own tank and is covered again, and every other hatch drains into its own tank, so nothing more is lost. Then the level climbs back.
- **Brain unreachable:** the units hold their current level.

The brain prints the total in the private tanks every 30 seconds per SSASS. At Stage 4 that's about 1.5 to 2 million L per SSASS, roughly 2–3% of what's in the hatches. Everything above that goes to ME for your SLAMs.

## Starting from nothing

The forge produces nothing from 0 L. Put the antimatter you have into ME (at least 16 L, from the Hyper-Intensity Laser Engraver) and start the brain.

The interfaces pull it from ME, and the private tanks pull it from the interfaces. The master puts 1 L in every hatch that can get it, and the forge's own production fills the rest. From there it ramps by itself, at about the rate the forge produces.

In the simulation, 17 L grew to about 17,600 L in 20 minutes, with imbalance penalties of 0.1% of production. Starting at 1 L per hatch with about 28,000 L stranded in the interfaces and one interface starved, it reached 60,000 L in 30 minutes, with no measurable penalty.

## Simulation

`ssass_sim.py` runs the real Lua files against a tick-level copy of the forge code. It covers:

- every indirect OpenComputers call costing a tick,
- the transposer pause,
- relay delay,
- ME dual interfaces (16,000 L tank, AE2 restock schedule),
- private tanks,
- forge and computer tick order.

The scenarios are:

- two Stage 4 SSASSs with a target change and a master reboot,
- a ramp from 64 L,
- recovery from a power loss with ME and every tank emptied,
- a kickstart from 17 L,
- one interface starved by AE2 while the others hold the spare (the collapse seen in game).

```
pip install lupa
python ssass_sim.py
```

None of this has been tested in game yet.
