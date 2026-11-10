--[[
  Tests for src/zip.lua. Archives are built here, byte by byte; no fixture files.
]]

local t = require "tests.helper"
local zip = require "src.zip"

t.eq(zip.crc32 "123456789", 0xCBF43926, "crc32 check value")
t.eq(zip.crc32 "", 0, "crc32 of nothing")
t.eq(zip.crc32("6789", zip.crc32 "12345"), 0xCBF43926, "crc32 continues from previous")

-- Helpers ----------------------------------------------------------------------

local function w16(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

local function w32(n)
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

local dir = (os.getenv "TEMP" or os.getenv "TMPDIR" or "/tmp"):gsub("[/\\]$", "")
local made = {}
local function tmp(name)
  local p = dir .. "/zip_test_" .. name
  made[#made + 1] = p
  return p
end

local function write_file(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local data = f:read "*a"
  f:close()
  return data
end

---Build a ZIP archive. Entries: { name, data, method?, descriptor?, flags?, local_extra?, comment? }.
---With `descriptor`, the local header has zero CRC/sizes and a data descriptor follows the data.
local function build(entries, archive_comment)
  local out, central = {}, {}
  local pos = 0
  local function put(s)
    out[#out + 1] = s
    pos = pos + #s
  end
  for _, e in ipairs(entries) do
    local crc, size = zip.crc32(e.data), #e.data
    local flags = (e.flags or 0) + (e.descriptor and 8 or 0)
    local method = e.method or 0
    local extra = e.local_extra or ""
    local offset = pos
    put "PK\3\4"
    put(w16(20) .. w16(flags) .. w16(method) .. w16(0x6000) .. w16(0x5A21))
    if e.descriptor then
      put(w32(0) .. w32(0) .. w32(0))
    else
      put(w32(crc) .. w32(size) .. w32(size))
    end
    put(w16(#e.name) .. w16(#extra) .. e.name .. extra)
    put(e.data)
    if e.descriptor then
      put("PK\7\8" .. w32(crc) .. w32(size) .. w32(size))
    end
    local c = e.comment or ""
    central[#central + 1] = table.concat {
      "PK\1\2",
      w16(0x031E),
      w16(20),
      w16(flags),
      w16(method),
      w16(0x6000),
      w16(0x5A21),
      w32(crc),
      w32(size),
      w32(size),
      w16(#e.name),
      w16(4),
      w16(#c),
      w16(0),
      w16(0),
      w32(0x81A40000),
      w32(offset),
      e.name,
      "\254\202\0\0", -- 4-byte central extra field (id 0xCAFE, no data)
      c,
    }
  end
  local cd_offset = pos
  local cd = table.concat(central)
  put(cd)
  local ac = archive_comment or ""
  put("PK\5\6" .. w16(0) .. w16(0) .. w16(#entries) .. w16(#entries))
  put(w32(#cd) .. w32(cd_offset) .. w16(#ac) .. ac)
  return table.concat(out)
end

-- read_entries -----------------------------------------------------------------

local source = tmp "source.zip"
local xml = ("<Song>" .. ("x"):rep(500) .. "</Song>")
local flac = "fLaC" .. ("\1\2\3"):rep(700)
local wav = "RIFF" .. ("\0"):rep(100)
write_file(
  source,
  build({
    { name = "Song.xml", data = xml, method = 8 }, -- bytes are not real deflate; copied raw
    { name = "SampleData/Instrument00 (Kick)/Sample00 (Kick).flac", data = flac, flags = 0x0800 },
    { name = "SampleData/Instrument01 (Pad)/Sample00 (Pad).wav", data = wav, descriptor = true },
    { name = "Extra.txt", data = "hello", local_extra = "\1\0\2\0ab", comment = "note" },
  }, "archive comment")
)

local archive = zip.read_entries(source)
t.eq(#archive.entries, 4, "read: entry count")
t.eq(archive.comment, "archive comment", "read: archive comment")
t.eq(archive.entries[1].name, "Song.xml", "read: first name")
t.eq(archive.entries[1].method, 8, "read: method")
t.eq(archive.entries[2].flags, 0x0800, "read: UTF-8 flag")
t.eq(archive.entries[2].compressed_size, #flac, "read: size")
t.eq(archive.entries[2].crc, zip.crc32(flac), "read: crc")
t.eq(archive.entries[3].crc, zip.crc32(wav), "read: crc of descriptor entry from central dir")
t.eq(archive.entries[4].comment, "note", "read: entry comment")
t.eq(zip.read_raw(source, archive.entries[2]), flac, "read_raw: whole entry")
t.eq(zip.read_raw(source, archive.entries[2], 4), "fLaC", "read_raw: prefix")

-- rewrite ----------------------------------------------------------------------

local ogg = tmp "replacement.ogg"
local ogg_data = "OggS" .. ("\9"):rep(300)
write_file(ogg, ogg_data)

local target = tmp "target.zip"
local calls = 0
local result = zip.rewrite(source, target, {
  ["SampleData/Instrument00 (Kick)/Sample00 (Kick).flac"] = {
    name = "SampleData/Instrument00 (Kick)/Sample00 (Kick).ogg",
    path = ogg,
  },
}, function()
  calls = calls + 1
end)
t.eq(result.entries, 4, "rewrite: entries")
t.eq(result.replaced, 1, "rewrite: replaced")
t.eq(result.size, #read_file(target), "rewrite: reported size matches file")
t.check(calls > 0, "rewrite: progress called")

local out = zip.read_entries(target)
t.eq(#out.entries, 4, "rewritten: entry count")
t.eq(out.comment, "archive comment", "rewritten: archive comment kept")
local names = {}
for i, e in ipairs(out.entries) do
  names[i] = e.name
end
t.eq(
  table.concat(names, "|"),
  "Song.xml|SampleData/Instrument00 (Kick)/Sample00 (Kick).ogg"
    .. "|SampleData/Instrument01 (Pad)/Sample00 (Pad).wav|Extra.txt",
  "rewritten: names and order"
)

local r = out.entries[2]
t.eq(r.method, 0, "replacement: stored")
t.eq(r.flags, 0x0800, "replacement: UTF-8 flag kept")
t.eq(r.compressed_size, #ogg_data, "replacement: compressed size")
t.eq(r.uncompressed_size, #ogg_data, "replacement: size")
t.eq(r.crc, zip.crc32(ogg_data), "replacement: crc")
t.eq(r.time, 0x6000, "replacement: time kept")
t.eq(r.date, 0x5A21, "replacement: date kept")
t.eq(zip.read_raw(target, r), ogg_data, "replacement: bytes")

local d = out.entries[3]
t.eq(d.flags, 0, "descriptor entry: flag cleared")
t.eq(d.crc, zip.crc32(wav), "descriptor entry: crc")
t.eq(d.compressed_size, #wav, "descriptor entry: size")
t.eq(zip.read_raw(target, d), wav, "descriptor entry: bytes")

t.eq(out.entries[1].method, 8, "copied: method kept")
t.eq(zip.read_raw(target, out.entries[1]), xml, "copied: raw bytes")
t.eq(out.entries[1].extra, "\254\202\0\0", "copied: central extra kept")
t.eq(out.entries[4].comment, "note", "copied: entry comment kept")
t.eq(zip.read_raw(target, out.entries[4]), "hello", "copied: bytes after local extra")

-- The local header of a rewritten descriptor entry carries the real sizes.
local bytes = read_file(target)
local lh = d.offset + 1
t.eq(bytes:sub(lh, lh + 3), "PK\3\4", "descriptor entry: local header")
t.eq(bytes:sub(lh + 14, lh + 25), w32(zip.crc32(wav)) .. w32(#wav) .. w32(#wav), "local sizes")

-- Every local offset in the central directory points at a local header.
for _, e in ipairs(out.entries) do
  t.eq(bytes:sub(e.offset + 1, e.offset + 4), "PK\3\4", "offset of " .. e.name)
end

-- The job runs rewrite in a coroutine and yields from the progress callback,
-- through rewrite's pcall (LuaJIT allows that).
local big = tmp "big.zip"
local big_data = ("0123456789abcdef"):rep(200000) -- 3.2 MB: several 1 MB chunks
write_file(
  big,
  build { { name = "SampleData/Instrument00 (a)/Sample00 (b).flac", data = big_data } }
)
local yields = 0
local co = coroutine.create(function()
  return zip.rewrite(big, tmp "big_out.zip", {}, function()
    coroutine.yield()
  end)
end)
local ok, res
repeat
  ok, res = coroutine.resume(co)
  if coroutine.status(co) == "suspended" then
    yields = yields + 1
  end
until not ok or coroutine.status(co) == "dead"
t.check(ok, "coroutine rewrite: no error (" .. tostring(res) .. ")")
t.check(yields >= 3, "coroutine rewrite: yielded per chunk")
t.eq(
  zip.read_raw(tmp "big_out.zip", zip.read_entries(tmp "big_out.zip").entries[1]),
  big_data,
  "coroutine rewrite: bytes"
)

-- Cancelling stops with an error and leaves the caller to delete the target.
t.fails(function()
  zip.rewrite(source, tmp "cancelled.zip", {}, function()
    return true
  end)
end, "^cancelled$", "rewrite: progress returning true cancels")

-- Errors -----------------------------------------------------------------------

local bad = tmp "bad.zip"
write_file(bad, ("x"):rep(100))
t.fails(function()
  zip.read_entries(bad)
end, "not a ZIP", "not a zip")

local z64 = tmp "z64.zip"
write_file(
  z64,
  "PK\5\6" .. w16(0) .. w16(0) .. w16(0xFFFF) .. w16(0xFFFF) .. w32(0) .. w32(0xFFFFFFFF) .. w16(0)
)
t.fails(function()
  zip.read_entries(z64)
end, "^zip64", "zip64 refused")

t.fails(function()
  zip.read_entries(tmp "missing.zip")
end, "cannot open", "missing file")

for _, p in ipairs(made) do
  os.remove(p)
end

t.done()
