-- Dooyong MAME oracle: write logs plus per-frame state dumps.
--
-- Usage (normally via sim/Makefile, which calls sim/mame/run_mame.sh):
--   DUMP_DIR=<outdir> DUMP_FRAMES=<list> TOTAL=<n> \
--     sim/mame/run_mame.sh <set> sim/mame/dy_oracle.lua
--
-- Environment:
--   DUMP_DIR     output directory (default sim/mame/out/<set>)
--   DUMP_FRAMES  comma list of frames and ranges "a-b" or "a-b/step" to dump
--   TOTAL        last frame of the run (default: last dump frame); MAME
--                exits one frame later so the last dump gets its pixels
--   NO_SNAP      1 = skip snap.png (the primary frame capture, see below)
--   HEAVY_LOG    1 = log every palette/text/sprite RAM write row by row
--                (default: per-frame per-class summaries only)
--   INPUTS       "frame:PORT:Field name:value;..." input events (value 1 =
--                pressed), e.g. "900:SYSTEM:Coin 1:1;905:SYSTEM:Coin 1:0"
--   FIELDS       "PORT:Field name:value;..." DIP/config user values at start
--
-- Frame numbering: the frame notifier runs inside screen vblank_begin, after
-- MAME has rendered the frame and before the vblank callbacks (sprite buffer
-- copy, Z80 IRQ). Frame N = the N-th notifier call (first call is 1). A dump
-- at frame N is therefore exactly the state MAME rendered frame N from
-- (no Dooyong write forces a partial update), and screen.argb is that frame
-- (captured one notifier later, see dump_frame).
--
-- Beam position of a write: from screen:time_until_pos (see beam()), in
-- MAME's 512x256 @ 60 Hz geometry. line 0-255, hpos 0-511. scan_frame = the
-- frame whose scan-out (or vblank, lines 248-255) the write falls in.
--
-- Byte order of every .bin written here: 8-bit data as is; 16-bit values
-- high byte first (the same logical big-endian convention as the region
-- images, tools/romdefs.py).
--
-- All tap and notifier handles are pinned in _G (Hyper Duel lost taps to
-- garbage collection, docs/audio_bug_ym_irq_storm.md in that project); each
-- tap counts its hits and the counts are reported in summary.txt.

local m = manager.machine
local setname = emu.romname()
local outdir = os.getenv("DUMP_DIR") or ("sim/mame/out/" .. setname)
os.execute("mkdir -p '" .. outdir .. "'")

local function parse_frames(s)
  local t, maxf = {}, 0
  for tok in string.gmatch(s or "", "([^,]+)") do
    local a, b, st = tok:match("^(%d+)-(%d+)/(%d+)$")
    if not a then a, b = tok:match("^(%d+)-(%d+)$"); st = 1 end
    if a then
      for f = tonumber(a), tonumber(b), tonumber(st) do t[f] = true; if f > maxf then maxf = f end end
    elseif tonumber(tok) then
      t[tonumber(tok)] = true; if tonumber(tok) > maxf then maxf = tonumber(tok) end
    end
  end
  return t, maxf
end

local dump_frames, maxdump = parse_frames(os.getenv("DUMP_FRAMES") or "")
local no_snap = os.getenv("NO_SNAP") == "1"
local total = tonumber(os.getenv("TOTAL") or "0")
if total == 0 then total = maxdump end
if total == 0 then total = 600 end
local heavy = os.getenv("HEAVY_LOG") == "1"

---------------------------------------------------------------------------
-- per-parent address maps (spec 3 and 4). Tilemap device tags are MAME's:
-- bg0 = :bg1, fg0 = :fg1, bg1 = :bg2, fg1 = :fg2.
---------------------------------------------------------------------------
local Z80 = {
  flytiger = { regs = { { ":bg1", 0xe030 }, { ":fg1", 0xe040 } },
    ctrl = 0xe010, bank = 0xe000, latch = 0xe020,
    pal = { 0xe800, 0xefff }, tx = { 0xf000, 0xffff }, spr = { 0xc000, 0xcfff } },
  bluehawk = { regs = { { ":bg1", 0xc040 }, { ":fg1", 0xc048 }, { ":fg2", 0xc018 } },
    ctrl = 0xc000, bank = 0xc008, latch = 0xc010,
    pal = { 0xc800, 0xcfff }, tx = { 0xd000, 0xdfff }, spr = { 0xe000, 0xefff } },
  lastday = { regs = { { ":bg1", 0xc000 }, { ":fg1", 0xc008 } },
    ctrl = 0xc010, bank = 0xc011, latch = 0xc012,
    pal = { 0xc800, 0xcfff }, tx = { 0xd000, 0xdfff }, spr = { 0xf000, 0xffff },
    snd = { { 0xf000, 0xf003, "ym2203x2" } } },
  gulfstrm = { regs = { { ":bg1", 0xf018 }, { ":fg1", 0xf020 } },
    ctrl = 0xf008, bank = 0xf000, latch = 0xf010,
    pal = { 0xf800, 0xffff }, tx = { 0xe000, 0xefff }, spr = { 0xd000, 0xdfff },
    snd = { { 0xf000, 0xf003, "ym2203x2" } } },
  primella = { regs = { { ":bg1", 0xfc00 }, { ":fg1", 0xfc08 } },
    ctrl = 0xf800, latch = 0xf810,
    pal = { 0xf000, 0xf7ff }, tx = { 0xe000, 0xefff } },
}
Z80.pollux = Z80.gulfstrm
local M68K = {
  rshark = { regs = { { ":bg1", 0x0c4000 }, { ":bg2", 0x0c4010 }, { ":fg1", 0x0cc000 }, { ":fg2", 0x0cc010 } },
    ctrl = 0x0c0015, latch = 0x0c0013, pal = { 0x0c8000, 0x0c8fff }, spr = { 0x04d000, 0x04dfff },
    unk = { { 0x0c0018, 0x0c001b } } },
  superx = { regs = { { ":bg1", 0x084000 }, { ":bg2", 0x084010 }, { ":fg1", 0x08c000 }, { ":fg2", 0x08c010 } },
    ctrl = 0x080015, latch = 0x080013, pal = { 0x088000, 0x088fff }, spr = { 0x0dd000, 0x0ddfff },
    unk = { { 0x080018, 0x08001b } } },
  popbingo = { regs = { { ":bg1", 0x0c4000 }, { ":bg2", 0x0c4010 } },
    ctrl = 0x0c0015, latch = 0x0c0013, pal = { 0x0c8000, 0x0c8fff }, spr = { 0x04d000, 0x04dfff },
    unk = { { 0x0c0018, 0x0c001b }, { 0x0dc000, 0x0dc01f } } },
}

-- set -> parent machine config
local PARENT = {
  lastday = "lastday", lastdaya = "lastday", ddaydoo = "lastday",
  gulfstrm = "gulfstrm", gulfstrma = "gulfstrm", gulfstrmb = "gulfstrm", gulfstrmm = "gulfstrm", gulfstrmk = "gulfstrm",
  pollux = "pollux", polluxa = "pollux", polluxa2 = "pollux", polluxn = "pollux",
  flytiger = "flytiger", flytigera = "flytiger",
  bluehawk = "bluehawk", bluehawkn = "bluehawk", bluehawkna = "bluehawk",
  sadari = "primella", gundl94 = "primella", primella = "primella",
  superx = "superx", superxm = "superx", rshark = "rshark", rsharka = "rshark", popbingo = "popbingo",
}
local machine_name = PARENT[setname]
local is68k = M68K[machine_name] ~= nil
local cfg = is68k and M68K[machine_name] or Z80[machine_name]
assert(cfg, "unknown set " .. setname)

local main = m.devices[":maincpu"].spaces["program"]
local audio = m.devices[":audiocpu"].spaces["program"]
local screen = m.screens[":screen"]

---------------------------------------------------------------------------
-- timing
---------------------------------------------------------------------------
-- MAME 0.288 Lua has no screen:vpos()/hpos() (screen:vpos() is a nil
-- method; Hyper Duel saw the same), but screen:time_until_pos(v, h) works
-- inside taps and returns seconds (double) until the beam next reaches
-- (v, h). Position in the frame = frame_period - time_until_pos(0, 0).
-- Checked: inside the notifier it returns exactly 8 lines, i.e. the
-- notifier runs at the start of line 248.
local FRAME_S = screen.frame_period
local LINE_S = screen.scan_period
local PIX_S = screen.pixel_period
local frame = 0
-- first line after the visible area = where the notifier runs: 248, or 0
-- on the primella config whose visible area is lines 0-255 (spec 5.3)
local VB_LINE = (machine_name == "primella") and 256 or 248
local VIS_TOP, VIS_BOT = 8, 247
if machine_name == "primella" then VIS_TOP, VIS_BOT = 0, 255 end

local function beam()
  local pos = FRAME_S - screen:time_until_pos(0, 0)
  local line = math.floor(pos / LINE_S + 1e-6)
  if line > 255 then line = 255 end
  local hpos = math.floor((pos - line * LINE_S) / PIX_S + 1e-6)
  if hpos < 0 then hpos = 0 end
  -- lines 248-255 after notifier N belong to frame N's vblank; lines 0-247
  -- are the scan-out of frame N+1
  local scan = (line >= VB_LINE) and frame or (frame + 1)
  return line, hpos, scan
end

---------------------------------------------------------------------------
-- logs
---------------------------------------------------------------------------
local wlog = assert(io.open(outdir .. "/writes.csv", "w"))
wlog:write("frame,line,hpos,scan_frame,visible,cpu,class,addr,data,mask\n")
local hits = {}
local summ = {}          -- per-frame summaries for heavy classes
local sumlog = assert(io.open(outdir .. "/heavy_summary.csv", "w"))
sumlog:write("frame,class,count,visible_count,first_line,last_line\n")

local function logw(cpu, class, addr, data, mask)
  hits[class] = (hits[class] or 0) + 1
  local line, hpos, scan = beam()
  local vis = (line >= VIS_TOP and line <= VIS_BOT) and 1 or 0
  wlog:write(string.format("%d,%d,%d,%d,%d,%s,%s,%06x,%x,%x\n",
    frame, line, hpos, scan, vis, cpu, class, addr, data, mask or 0))
end

local function heavyw(class, addr, data, mask)
  hits[class] = (hits[class] or 0) + 1
  local line, hpos, scan = beam()
  local vis = (line >= VIS_TOP and line <= VIS_BOT)
  local s = summ[class]
  if not s then s = { n = 0, v = 0, first = nil, last = nil }; summ[class] = s end
  s.n = s.n + 1
  if vis then s.v = s.v + 1 end
  if not s.first then s.first = line end
  s.last = line
  if heavy then
    wlog:write(string.format("%d,%d,%d,%d,%d,main,%s,%06x,%x,%x\n",
      frame, line, hpos, scan, vis and 1 or 0, class, addr, data, mask or 0))
  end
end

_G._dy_taps = {}
local function tap(space, lo, hi, name, fn)
  local h = space:install_write_tap(lo, hi, name, function(offset, data, mask)
    fn(offset, data, mask)
  end)
  table.insert(_G._dy_taps, h)
end

local last_ctrl = -1
for i, r in ipairs(cfg.regs) do
  local tag, base = r[1], r[2]
  local span = is68k and 0x0f or 0x07
  tap(main, base, base + span, "regs" .. i, function(o, d, mk)
    logw("main", "tmreg" .. tag:sub(2), o, d, mk)
  end)
end
-- 68000 taps must cover whole words; the byte registers sit on the low lane
local function span(a) if is68k then return a & ~1, a | 1 end return a, a end
local c0, c1 = span(cfg.ctrl)
tap(main, c0, c1, "ctrl", function(o, d, mk)
  if is68k then d = d & 0xff end
  last_ctrl = d; logw("main", "ctrl", o, d, mk)
end)
if cfg.bank then tap(main, cfg.bank, cfg.bank, "bank", function(o, d, mk) logw("main", "bank", o, d, mk) end) end
local l0, l1 = span(cfg.latch)
tap(main, l0, l1, "latch", function(o, d, mk) logw("main", "latch", o, d, mk) end)
-- Palette entries the game has written since power-on. Until an entry is
-- first written MAME shows its power-on default pen colour (black, red, ...,
-- white pattern), not the RAM content, so the comparison needs to know which
-- entries are still in that state (dumped as palette_written.bin).
local pal_written = {}
local banked_item = nil
do
  local d = m.devices[":"]
  if d.items["0/m_paletteram_flytiger"] and d.items["0/m_palette_bank"] then
    banked_item = emu.item(d.items["0/m_palette_bank"])
  end
end
tap(main, cfg.pal[1], cfg.pal[2], "pal", function(o, d, mk)
  local byteoff = o - cfg.pal[1]
  if banked_item and banked_item:read(0) ~= 0 then byteoff = byteoff | 0x800 end
  pal_written[byteoff >> 1] = true
  heavyw("pal", o, d, mk)
end)
if cfg.tx then tap(main, cfg.tx[1], cfg.tx[2], "tx", function(o, d, mk) heavyw("tx", o, d, mk) end) end
if cfg.spr then tap(main, cfg.spr[1], cfg.spr[2], "spr", function(o, d, mk) heavyw("spr", o, d, mk) end) end
if cfg.unk then
  for i, u in ipairs(cfg.unk) do
    tap(main, u[1], u[2], "unk" .. i, function(o, d, mk) logw("main", "unk", o, d, mk) end)
  end
end
-- T2: main program writes into ROM space
if is68k then
  tap(main, 0x000000, 0x03ffff, "romw", function(o, d, mk) logw("main", "romw", o, d, mk) end)
else
  tap(main, 0x0000, 0x7fff, "romw", function(o, d, mk) logw("main", "romw", o, d, mk) end)
end
-- sound CPU: chip writes and T4 ROM-area writes
if cfg.snd then
  for _, s in ipairs(cfg.snd) do
    tap(audio, s[1], s[2], "snd", function(o, d, mk) logw("audio", s[3], o, d, mk) end)
  end
elseif machine_name == "pollux" then
  tap(audio, 0xf802, 0xf805, "snd", function(o, d, mk) logw("audio", "ym2203x2", o, d, mk) end)
else
  tap(audio, 0xf808, 0xf809, "ym", function(o, d, mk) logw("audio", "ym2151", o, d, mk) end)
  tap(audio, 0xf80a, 0xf80a, "oki", function(o, d, mk) logw("audio", "oki", o, d, mk) end)
end
local sndrom_hi = (machine_name == "lastday" or machine_name == "gulfstrm") and 0x7fff or 0xefff
tap(audio, 0x0000, sndrom_hi, "sndromw", function(o, d, mk) logw("audio", "romw", o, d, mk) end)

---------------------------------------------------------------------------
-- state dump
---------------------------------------------------------------------------
local function item_of(tag, name)
  local d = m.devices[tag]
  if not d then return nil end
  local idx = d.items[name]
  if not idx then return nil end
  return emu.item(idx)
end

local function item_bytes(it)
  local parts = {}
  local char = string.char
  for i = 0, it.count - 1 do
    local v = it:read(i)
    if it.size == 1 then parts[#parts + 1] = char(v & 0xff)
    elseif it.size == 2 then parts[#parts + 1] = char((v >> 8) & 0xff, v & 0xff)
    else
      local s = {}
      for b = it.size - 1, 0, -1 do s[#s + 1] = char((v >> (8 * b)) & 0xff) end
      parts[#parts + 1] = table.concat(s)
    end
  end
  return table.concat(parts)
end

local function share_bytes(tag)
  local s = m.memory.shares[tag]
  if not s then return nil end
  local parts = {}
  local char = string.char
  if s.bitwidth == 16 then
    for a = 0, s.size - 1, 2 do
      local v = s:read_u16(a)
      parts[#parts + 1] = char(v >> 8, v & 0xff)
    end
  else
    for a = 0, s.size - 1 do parts[#parts + 1] = char(s:read_u8(a)) end
  end
  return table.concat(parts)
end

local function wfile(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

-- small save items are written as JSON arrays; big ones as .bin
local SMALL = 32
local function items_json(tag, prefix, out)
  local d = m.devices[tag]
  if not d then return end
  for name, idx in pairs(d.items) do
    local short = name:gsub("^%d+/", "")
    if short ~= "m_unscaled_clock" and short ~= "m_clock_scale" then
      local it = emu.item(idx)
      if it.count <= SMALL then
        local vals = {}
        for i = 0, it.count - 1 do vals[#vals + 1] = tostring(it:read(i)) end
        out[#out + 1] = string.format('  "%s%s": [%s]', prefix, short, table.concat(vals, ","))
      end
    end
  end
end

local pending_pixels = nil
local scr_w, scr_h = 0, 0

local function dump_frame(n)
  local d = string.format("%s/frames/%06d", outdir, n)
  os.execute("mkdir -p '" .. d .. "'")
  -- Frame capture. snap.png (primary) is the MAME snapshot of frame N,
  -- taken here through the render texture: it holds frame N's pens with the
  -- palette as of this notifier, i.e. exactly what MAME displays. It is
  -- rotated like the game (ROT270: snap = numpy.rot90(native, 1)).
  -- screen.argb (secondary, native orientation) comes from screen:pixels()
  -- at the NEXT notifier: pixels() reads m_bitmap[m_curbitmap] and
  -- screen_device::update_quads() flips m_curbitmap right after rendering,
  -- so inside notifier N pixels() returns frame N-1's pens (measured:
  -- flytiger frame 840 matched the scroll state of 839), converted with the
  -- palette at the time of the call (saved as palette_next.bin).
  pending_pixels = d
  local _, w, h = screen:pixels()
  scr_w, scr_h = w, h
  -- palette RAM: banked games keep 4 KB in the driver, others in the share
  local pit = item_of(":", "0/m_paletteram_flytiger")
  if pit then wfile(d .. "/palette.bin", item_bytes(pit))
  else wfile(d .. "/palette.bin", share_bytes(":palette")) end
  -- text RAM (2048 16-bit entries)
  -- MAME's resolved pen colours (u32 0xAARRGGBB, little-endian) and the
  -- written flags, one byte per palette entry
  local pal = m.palettes[":palette"]
  local pw, pc = {}, {}
  for i = 0, pal.entries - 1 do
    pw[#pw + 1] = string.char(pal_written[i] and 1 or 0)
    local c = pal:pen_color(i)
    pc[#pc + 1] = string.char(c & 0xff, (c >> 8) & 0xff, (c >> 16) & 0xff, (c >> 24) & 0xff)
  end
  wfile(d .. "/palette_written.bin", table.concat(pw))
  wfile(d .. "/pens.bin", table.concat(pc))
  local tx = item_of(":tx", "0/m_tileram")
  if tx then wfile(d .. "/text.bin", item_bytes(tx)) end
  -- sprite RAM: live CPU share and the vblank-copied buffer used to draw
  local live = share_bytes(":spriteram")
  if live then wfile(d .. "/spriteram_live.bin", live) end
  local buf = item_of(":spriteram", "0/m_buffered")
  if buf then wfile(d .. "/spriteram_buf.bin", item_bytes(buf)) end
  -- registers and driver state
  local js = {}
  js[#js + 1] = string.format('  "set": "%s"', setname)
  js[#js + 1] = string.format('  "machine": "%s"', machine_name)
  js[#js + 1] = string.format('  "frame": %d', n)
  js[#js + 1] = string.format('  "width": %d', scr_w)
  js[#js + 1] = string.format('  "height": %d', scr_h)
  js[#js + 1] = string.format('  "last_ctrl_write": %d', last_ctrl)
  for _, tag in ipairs({ ":bg1", ":bg2", ":fg1", ":fg2", ":tx" }) do
    items_json(tag, tag:sub(2) .. ".", js)
  end
  items_json(":", "", js)
  local bank = m.memory.banks[":mainbank"]
  if bank then js[#js + 1] = string.format('  "mainbank": %d', bank.entry) end
  wfile(d .. "/state.json", "{\n" .. table.concat(js, ",\n") .. "\n}\n")
  if not no_snap then screen:snapshot(d .. "/snap.png") end
end

---------------------------------------------------------------------------
-- per-frame register trace (every frame, small)
---------------------------------------------------------------------------
local ftrace = assert(io.open(outdir .. "/frames.csv", "w"))
local reg_items = {}
local hdr = { "frame" }
for _, tag in ipairs({ ":bg1", ":fg1", ":bg2", ":fg2" }) do
  local it = item_of(tag, "0/m_registers")
  if it then
    reg_items[#reg_items + 1] = { tag:sub(2), it }
    for r = 0, 7 do hdr[#hdr + 1] = tag:sub(2) .. "_r" .. r end
  end
end
local root_small = {}
for _, nm in ipairs({ "m_palette_bank", "m_flytiger_pri", "m_tx_pri", "m_sprites_disabled",
                      "m_bg2_priority", "m_flip_screen_x", "m_flip_screen_y" }) do
  local it = item_of(":", "0/" .. nm)
  if it then root_small[#root_small + 1] = { nm, it }; hdr[#hdr + 1] = nm:sub(3) end
end
hdr[#hdr + 1] = "last_ctrl"
ftrace:write(table.concat(hdr, ",") .. "\n")

local function trace_frame(n)
  local row = { tostring(n) }
  for _, ri in ipairs(reg_items) do
    for r = 0, 7 do row[#row + 1] = string.format("%02x", ri[2]:read(r)) end
  end
  for _, rs in ipairs(root_small) do row[#row + 1] = tostring(rs[2]:read(0)) end
  row[#row + 1] = string.format("%x", last_ctrl & 0xffff)
  ftrace:write(table.concat(row, ",") .. "\n")
end

---------------------------------------------------------------------------
-- inputs and DIP fields
---------------------------------------------------------------------------
local events = {}
for tok in string.gmatch(os.getenv("INPUTS") or "", "([^;]+)") do
  local f, port, field, val = tok:match("^%s*(%d+):([^:]+):([^:]+):(%d+)%s*$")
  if f then
    local ev = events[tonumber(f)] or {}
    ev[#ev + 1] = { port, field, tonumber(val) }
    events[tonumber(f)] = ev
  end
end
local ilog = assert(io.open(outdir .. "/inputs.csv", "w"))
ilog:write("frame,port,field,value\n")
local function field_of(port, name)
  local p = m.ioport.ports[":" .. port]
  assert(p, "no port " .. port)
  local fl = p.fields[name]
  assert(fl, "no field '" .. name .. "' in " .. port)
  return fl
end
for tok in string.gmatch(os.getenv("FIELDS") or "", "([^;]+)") do
  local port, field, val = tok:match("^%s*([^:]+):([^:]+):(%d+)%s*$")
  if port then
    field_of(port, field).user_value = tonumber(val)
    ilog:write(string.format("0,%s,%s,user_value=%s\n", port, field, val))
  end
end

---------------------------------------------------------------------------
-- frame notifier
---------------------------------------------------------------------------
local vpos_check = "not checked"
_G._dy_frame = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == 2 then
    local l, h = beam()
    vpos_check = string.format("beam at notifier: line %d hpos %d (expected %d, 0); screen frame_number %d at notifier %d",
      l, h, VB_LINE % 256, screen:frame_number(), frame)
  end
  -- heavy-class summaries cover the writes since the previous notifier
  for class, s in pairs(summ) do
    sumlog:write(string.format("%d,%s,%d,%d,%d,%d\n", frame - 1, class, s.n, s.v, s.first, s.last))
  end
  summ = {}
  trace_frame(frame)
  if pending_pixels then
    -- native orientation, 32-bit 0xAARRGGBB little-endian per pixel
    wfile(pending_pixels .. "/screen.argb", (screen:pixels()))
    -- pixels() converts pens with the palette as it is NOW (frame N+1),
    -- so keep that palette too for the secondary pixels() comparison
    local pit = item_of(":", "0/m_paletteram_flytiger")
    if pit then wfile(pending_pixels .. "/palette_next.bin", item_bytes(pit))
    else wfile(pending_pixels .. "/palette_next.bin", share_bytes(":palette")) end
    pending_pixels = nil
  end
  if dump_frames[frame] then dump_frame(frame) end
  local ev = events[frame]
  if ev then
    for _, e in ipairs(ev) do
      field_of(e[1], e[2]):set_value(e[3])
      ilog:write(string.format("%d,%s,%s,%d\n", frame, e[1], e[2], e[3]))
    end
  end
  if frame > total then
    wlog:close(); sumlog:close(); ftrace:close(); ilog:close()
    local s = assert(io.open(outdir .. "/summary.txt", "w"))
    s:write(string.format("set %s machine %s frames %d\n", setname, machine_name, frame))
    s:write(vpos_check .. "\n")
    local keys = {}
    for k in pairs(hits) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do s:write(string.format("tap %s hits %d\n", k, hits[k])) end
    s:write(string.format("taps installed %d\n", #_G._dy_taps))
    s:close()
    m:exit()
  end
end)

print(string.format("dy_oracle: %s (%s) total %d frames -> %s", setname, machine_name, total, outdir))
