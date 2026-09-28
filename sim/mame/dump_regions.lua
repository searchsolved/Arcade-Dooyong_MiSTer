-- Dump every memory region of the running machine as MAME sees it, then exit.
--
-- Usage:
--   DUMP_DIR=<outdir> mame <set> -rompath roms -video none -sound none \
--     -nothrottle -autoboot_script sim/mame/dump_regions.lua
--
-- Writes <outdir>/<tag>.bin in the project's logical byte order: 16-bit
-- big-endian regions are read with read_u16 (the logical word value, host
-- byte swapping undone by MAME) and written high byte first; 8-bit regions
-- are written byte for byte. Compare with tools/compare_regions.py.

local outdir = os.getenv("DUMP_DIR") or "out/regions"
os.execute("mkdir -p '" .. outdir .. "'")
local m = manager.machine

local function dump(tag, r)
  local name = tag:gsub("^:", ""):gsub(":", "_")
  local f = assert(io.open(outdir .. "/" .. name .. ".bin", "wb"))
  local parts, n = {}, 0
  local char = string.char
  if r.bitwidth == 16 and r.endianness == "big" then
    for a = 0, r.size - 1, 2 do
      local w = r:read_u16(a)
      n = n + 1
      parts[n] = char(w >> 8, w & 0xff)
      if n == 4096 then f:write(table.concat(parts)); parts, n = {}, 0 end
    end
  else
    for a = 0, r.size - 1 do
      n = n + 1
      parts[n] = char(r:read_u8(a))
      if n == 8192 then f:write(table.concat(parts)); parts, n = {}, 0 end
    end
  end
  f:write(table.concat(parts))
  f:close()
  print(string.format("region %s %d bytes width %d %s", tag, r.size, r.bitwidth, r.endianness))
end

_G._dump_regions_cb = emu.add_machine_frame_notifier(function()
  for tag, r in pairs(m.memory.regions) do dump(tag, r) end
  m:exit()
end)
