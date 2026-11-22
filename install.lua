-- install.lua - sets up (or updates) the SSASS brain computer. Needs OpenOS, an internet card and a
-- tier 2 wireless card. Run it again any time to update; it keeps the stored target.
--   wget -f https://raw.githubusercontent.com/Xela10001/ssass-oc/main/install.lua /tmp/i.lua && /tmp/i.lua 71296000
local component = require("component")
local internet = require("internet")
local shell = require("shell")

local REPO = "https://raw.githubusercontent.com/Xela10001/ssass-oc/main/"
local TARGET_FILE, SHRC = "/home/ssass_target", "/home/.shrc"
local BRAIN = "/home/ssass_brain.lua"

local function readFile(path)
  local f = io.open(path)
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function writeFile(path, s)
  local f = assert(io.open(path, "w"))
  f:write(s)
  f:close()
end

local function download(name)
  local parts = {}
  local ok, err = pcall(function()
    for chunk in internet.request(REPO .. name) do parts[#parts + 1] = chunk end
  end)
  if not ok or #parts == 0 then error("could not download " .. name .. ": " .. tostring(err), 0) end
  return table.concat(parts)
end

if not component.isAvailable("internet") then error("this computer needs an internet card", 0) end
if not component.isAvailable("modem") or not component.modem.isWireless()
  or component.modem.setStrength(400) < 400 then
  error("this computer needs a tier 2 wireless card", 0)
end

local boot
for _, name in ipairs({ "ssass_brain.lua", "ssass_node.lua", "ssass_boot.lua" }) do
  local code = download(name)
  writeFile("/home/" .. name, code)
  if name == "ssass_boot.lua" then boot = code end
  print("downloaded " .. name)
end

local target = tonumber((...)) or tonumber(readFile(TARGET_FILE) or "")
while not target do
  io.write("Target antimatter per SSASS in L (all 16 hatches together): ")
  target = tonumber(io.read())
end
writeFile(TARGET_FILE, tostring(math.floor(target)))

local shrc = readFile(SHRC) or ""
if not shrc:find(BRAIN, 1, true) then
  writeFile(SHRC, shrc .. BRAIN .. "\n")
  print("the brain now starts when this computer boots")
end

-- Unit EEPROMs. Only a blank EEPROM or an earlier SSASS unit EEPROM is written, so this computer's
-- own BIOS can't be overwritten by accident.
while true do
  io.write("\nFlash a unit EEPROM? Swap this computer's EEPROM for a blank one, then press Enter."
    .. "\nType s and Enter to skip: ")
  if (io.read() or "s"):lower():sub(1, 1) == "s" then break end
  local eeprom = component.isAvailable("eeprom") and component.eeprom
  if not eeprom then
    print("no EEPROM in this computer")
  elseif eeprom.get() ~= "" and eeprom.getLabel() ~= "SSASS unit" then
    print("that EEPROM is not blank (" .. eeprom.getLabel() .. "); swap in a blank one")
  else
    eeprom.set(boot)
    eeprom.setLabel("SSASS unit")
    print("flashed. Take it out, and put this computer's own EEPROM (Lua BIOS) back before it reboots.")
  end
end

print("\nstarting the brain; Ctrl+C stops it, `" .. BRAIN .. " <target>` changes the target")
shell.execute(BRAIN)
