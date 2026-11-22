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

- **Hatches:** screwdriver each of the 16 antimatter hatches once, so its front face accepts input.
- **Transposers:** one transposer per hatch, upgraded with a LuV or better fluid regulator in the assembler. It touches the hatch's front face and an ME Dual Interface. Never put a tank against a hatch's front face: the hatch dumps its whole contents into it every tick.
- **Unit computers:** 4 per SSASS, each with:
  - a tier 2 CPU,
  - any RAM,
  - a flashed unit EEPROM,
  - a tier 2 wireless card,
  - no hard drive or screen.

  Each one gets its own cable to the transposers of 4 hatches. The 4 cables must not touch each other.
- **Relay:** one per SSASS, joining the 4 cables. Put a tier 3 CPU and tier 3.5 RAM in it. A stock relay forwards one message per 5 ticks, which makes level changes arrive a cycle late.
- **Power:** every cable needs OpenComputers power.

The brain must be within 400 blocks of every SSASS, and its own cable must not touch any unit computer.

The 4 unit computers of an SSASS pick a master among themselves. There's nothing to configure per SSASS.

## How it works

Each unit computer reads its 4 hatches every few ticks. When the forge runs a cycle, the unit drains or fills each hatch to the same level through the transposers. The production goes into ME.

The master tracks how much the forge made. It raises the level from that antimatter only and always keeps a spare float in ME, so fills never fail. The float is the larger of 2·√total and three times the observed per-cycle swing.

Level changes take effect at the start of a cycle on all 4 computers at once, so the hatches stay equal while the level moves.

- **ME runs dry:** for example, something exported the float, or a power loss voided 10%. The master drops the level once so the drains rebuild the float, then climbs back.
- **Brain unreachable:** the units hold their current level.

Leave the float in ME when you automate antimatter out to SLAMs. The brain prints it every 30 seconds per SSASS.

## Starting from nothing

The forge produces nothing from 0 L. Put at least 16 L of antimatter into ME (from the Hyper-Intensity Laser Engraver) before the first start. The master starts each hatch at 1 L and grows from there.

## Simulation

`ssass_sim.py` runs the real Lua files against a tick-level copy of the forge code. It covers:

- every indirect OpenComputers call costing a tick,
- the transposer pause,
- relay delay,
- forge and computer tick order.

The scenarios are:

- two Stage 4 SSASSs with a target change and a master reboot,
- a ramp from 64 L,
- recovery from a power loss with ME emptied.

```
pip install lupa
python ssass_sim.py
```

None of this has been tested in game yet.
