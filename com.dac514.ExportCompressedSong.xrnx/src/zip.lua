--[[
  Minimal ZIP reader and rewriter for song files. Pure Lua (LuaJIT `bit`), no
  `renoise.*`, unit-tested in `tests/zip_test.lua`.

  It never inflates: entries are copied as raw bytes, and replacement entries
  are written "stored" (method 0). Sizes and CRC values always come from the
  central directory, so entries that used a data descriptor (flag bit 3) are
  rewritten with complete local headers and without the descriptor.

  ZIP64 archives (4 GB and more, or 65535 entries and more) are refused with an
  error that starts with "zip64".
]]

local bit = require "bit"

local M = {}

local CHUNK = 1024 * 1024
local MAX32 = 4294967295
local FLAG_DESCRIPTOR = 0x0008
local FLAG_UTF8 = 0x0800

-- CRC-32 ----------------------------------------------------------------------

---@type integer[]
local crc_table = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if bit.band(c, 1) == 1 then
      c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
    else
      c = bit.rshift(c, 1)
    end
  end
  crc_table[i] = c
end

---@param n integer
---@return integer
local function unsigned(n)
  if n < 0 then
    return n + 4294967296
  end
  return n
end

---CRC-32 (IEEE, as used by ZIP) of `data`, continuing from `previous`.
---@param data string
---@param previous integer|nil CRC of the bytes before `data` (default 0).
---@return integer crc Unsigned 32-bit value.
function M.crc32(data, previous)
  local c = bit.bnot(previous or 0)
  local band, bxor, rshift, byte = bit.band, bit.bxor, bit.rshift, string.byte
  for i = 1, #data do
    c = bxor(crc_table[band(bxor(c, byte(data, i)), 0xFF)], rshift(c, 8))
  end
  return unsigned(bit.bnot(c))
end

-- Little-endian helpers -------------------------------------------------------

---@param s string
---@param pos integer 1-based offset.
---@return integer
local function u16(s, pos)
  local a, b = s:byte(pos, pos + 1)
  return a + b * 256
end

---@param s string
---@param pos integer 1-based offset.
---@return integer
local function u32(s, pos)
  local a, b, c, d = s:byte(pos, pos + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end

---@param n integer
---@return string
local function w16(n)
  return string.char(n % 256, math.floor(n / 256) % 256)
end

---@param n integer
---@return string
local function w32(n)
  return string.char(
    n % 256,
    math.floor(n / 256) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 16777216) % 256
  )
end

-- Reading ---------------------------------------------------------------------

---@class ZipEntry
---@field name string Entry name as stored (bytes, usually UTF-8).
---@field version_made integer
---@field version_needed integer
---@field flags integer General purpose bit flags.
---@field method integer 0 stored, 8 deflated.
---@field time integer DOS time.
---@field date integer DOS date.
---@field crc integer
---@field compressed_size integer
---@field uncompressed_size integer
---@field internal_attr integer
---@field external_attr integer
---@field offset integer Offset of the local header.
---@field extra string Central directory extra field.
---@field comment string

---@class ZipArchive
---@field entries ZipEntry[] In central directory order.
---@field comment string Archive comment.
---@field size integer File size in bytes.

---@param f file*
---@param pos integer 0-based offset.
---@param n integer
---@return string
local function read_at(f, pos, n)
  f:seek("set", pos)
  local data = f:read(n) or ""
  if #data ~= n then
    error(("zip: unexpected end of file at offset %d"):format(pos), 0)
  end
  return data
end

---@param f file*
---@return ZipArchive
local function read_directory(f)
  local size = f:seek "end"
  if size < 22 then
    error("zip: not a ZIP archive (file too small)", 0)
  end
  local tail_len = math.min(size, 22 + 65535 + 20)
  local tail = read_at(f, size - tail_len, tail_len)
  local eocd
  for i = tail_len - 21, 1, -1 do
    if tail:byte(i) == 0x50 and tail:sub(i, i + 3) == "PK\5\6" then
      eocd = i
      break
    end
  end
  if not eocd then
    error("zip: not a ZIP archive (no end of central directory record)", 0)
  end
  if eocd > 20 and tail:sub(eocd - 20, eocd - 17) == "PK\6\7" then
    error("zip64 archives are not supported", 0)
  end
  local disk, cd_disk = u16(tail, eocd + 4), u16(tail, eocd + 6)
  local count_disk, count = u16(tail, eocd + 8), u16(tail, eocd + 10)
  local cd_size, cd_offset = u32(tail, eocd + 12), u32(tail, eocd + 16)
  local comment_len = u16(tail, eocd + 20)
  if count == 0xFFFF or cd_size == MAX32 or cd_offset == MAX32 then
    error("zip64 archives are not supported", 0)
  end
  if disk ~= 0 or cd_disk ~= 0 or count_disk ~= count then
    error("zip: multi-disk archives are not supported", 0)
  end
  local comment = tail:sub(eocd + 22, eocd + 21 + comment_len)
  local cd = read_at(f, cd_offset, cd_size)
  ---@type ZipEntry[]
  local entries = {}
  local p = 1
  for _ = 1, count do
    if cd:sub(p, p + 3) ~= "PK\1\2" then
      error("zip: broken central directory", 0)
    end
    local name_len, extra_len, entry_comment_len = u16(cd, p + 28), u16(cd, p + 30), u16(cd, p + 32)
    local entry = {
      version_made = u16(cd, p + 4),
      version_needed = u16(cd, p + 6),
      flags = u16(cd, p + 8),
      method = u16(cd, p + 10),
      time = u16(cd, p + 12),
      date = u16(cd, p + 14),
      crc = u32(cd, p + 16),
      compressed_size = u32(cd, p + 20),
      uncompressed_size = u32(cd, p + 24),
      internal_attr = u16(cd, p + 36),
      external_attr = u32(cd, p + 38),
      offset = u32(cd, p + 42),
      name = cd:sub(p + 46, p + 45 + name_len),
      extra = cd:sub(p + 46 + name_len, p + 45 + name_len + extra_len),
      comment = cd:sub(
        p + 46 + name_len + extra_len,
        p + 45 + name_len + extra_len + entry_comment_len
      ),
    }
    if
      entry.compressed_size == MAX32
      or entry.uncompressed_size == MAX32
      or entry.offset == MAX32
    then
      error("zip64 archives are not supported", 0)
    end
    if bit.band(entry.flags, 0x0001) ~= 0 then
      error("zip: encrypted entries are not supported: " .. entry.name, 0)
    end
    entries[#entries + 1] = entry
    p = p + 46 + name_len + extra_len + entry_comment_len
  end
  return { entries = entries, comment = comment, size = size }
end

---Read the central directory of the archive at `path`.
---@param path string
---@return ZipArchive
function M.read_entries(path)
  local f, err = io.open(path, "rb")
  if not f then
    error("zip: cannot open " .. tostring(err), 0)
  end
  local ok, result = pcall(read_directory, f)
  f:close()
  if not ok then
    error(result, 0)
  end
  return result
end

---Offset of an entry's data and the local header's extra field.
---@param f file*
---@param entry ZipEntry
---@return integer data_offset, string local_extra
local function local_data(f, entry)
  local header = read_at(f, entry.offset, 30)
  if header:sub(1, 4) ~= "PK\3\4" then
    error("zip: broken local header for " .. entry.name, 0)
  end
  local name_len, extra_len = u16(header, 27), u16(header, 29)
  local extra = extra_len > 0 and read_at(f, entry.offset + 30 + name_len, extra_len) or ""
  return entry.offset + 30 + name_len + extra_len, extra
end

---Read an entry's raw (possibly compressed) bytes. Meant for small entries.
---@param path string Archive path.
---@param entry ZipEntry
---@param max_bytes integer|nil Read at most this many bytes from the start.
---@return string
function M.read_raw(path, entry, max_bytes)
  local f, err = io.open(path, "rb")
  if not f then
    error("zip: cannot open " .. tostring(err), 0)
  end
  local ok, result = pcall(function()
    local offset = local_data(f, entry)
    local n = entry.compressed_size
    if max_bytes and max_bytes < n then
      n = max_bytes
    end
    return read_at(f, offset, n)
  end)
  f:close()
  if not ok then
    error(result, 0)
  end
  return result
end

-- Writing ---------------------------------------------------------------------

---@param e ZipEntry
---@param extra string
---@return string
local function local_header(e, extra)
  return table.concat {
    "PK\3\4",
    w16(e.version_needed),
    w16(e.flags),
    w16(e.method),
    w16(e.time),
    w16(e.date),
    w32(e.crc),
    w32(e.compressed_size),
    w32(e.uncompressed_size),
    w16(#e.name),
    w16(#extra),
    e.name,
    extra,
  }
end

---@param e ZipEntry
---@return string
local function central_header(e)
  return table.concat {
    "PK\1\2",
    w16(e.version_made),
    w16(e.version_needed),
    w16(e.flags),
    w16(e.method),
    w16(e.time),
    w16(e.date),
    w32(e.crc),
    w32(e.compressed_size),
    w32(e.uncompressed_size),
    w16(#e.name),
    w16(#e.extra),
    w16(#e.comment),
    w16(0),
    w16(e.internal_attr),
    w32(e.external_attr),
    w32(e.offset),
    e.name,
    e.extra,
    e.comment,
  }
end

---@class ZipReplacement
---@field name string New entry name.
---@field path string File whose bytes become the entry, stored.

---Progress callback: called after every chunk. Return true to abort; `rewrite`
---then closes its files and raises "cancelled".
---@alias ZipProgress fun(done: integer, total: integer): boolean|nil

---@param out file*
---@param data string
local function write(out, data)
  local ok, err = out:write(data)
  if not ok then
    error("zip: write failed: " .. tostring(err), 0)
  end
end

---@param f file*
---@param out file*
---@param offset integer
---@param n integer
---@param step fun(n: integer)
local function copy_bytes(f, out, offset, n, step)
  f:seek("set", offset)
  local left = n
  while left > 0 do
    local chunk = f:read(math.min(CHUNK, left))
    if not chunk or #chunk == 0 then
      error("zip: unexpected end of file", 0)
    end
    write(out, chunk)
    left = left - #chunk
    step(#chunk)
  end
end

---@param path string
---@param step fun(n: integer)
---@return integer crc, integer size
local function crc_file(path, step)
  local f, err = io.open(path, "rb")
  if not f then
    error("zip: cannot open " .. tostring(err), 0)
  end
  local crc, size = 0, 0
  while true do
    local chunk = f:read(CHUNK)
    if not chunk or #chunk == 0 then
      break
    end
    crc = M.crc32(chunk, crc)
    size = size + #chunk
    step(0)
  end
  f:close()
  return crc, size
end

---Copy `source` to `target`, replacing the entries named in `replacements`.
---Entries keep their order. Replacements are written stored, keep the original
---timestamp and UTF-8 flag, and get the new name.
---@param source string
---@param target string
---@param replacements table<string, ZipReplacement> Keyed by original entry name.
---@param progress ZipProgress|nil
---@return { entries: integer, replaced: integer, size: integer }
function M.rewrite(source, target, replacements, progress)
  local archive = M.read_entries(source)
  local total = 0
  for _, e in ipairs(archive.entries) do
    local r = replacements[e.name]
    total = total + (r and 0 or e.compressed_size)
  end
  local done = 0
  local function step(n)
    done = done + n
    if progress and progress(done, total) then
      error("cancelled", 0)
    end
  end

  local f, err = io.open(source, "rb")
  if not f then
    error("zip: cannot open " .. tostring(err), 0)
  end
  local out, out_err = io.open(target, "wb")
  if not out then
    f:close()
    error("zip: cannot create " .. tostring(out_err), 0)
  end
  local replaced = 0
  local ok, result = pcall(function()
    ---@type ZipEntry[]
    local written = {}
    for _, e in ipairs(archive.entries) do
      local position = out:seek "cur"
      if position > MAX32 then
        error("zip64 archives are not supported (result too large)", 0)
      end
      local r = replacements[e.name]
      local new = {}
      for k, v in pairs(e) do
        new[k] = v
      end
      new.offset = position
      if r then
        local crc, size = crc_file(r.path, step)
        new.name = r.name
        new.flags = bit.band(e.flags, FLAG_UTF8)
        new.method = 0
        new.version_needed = 20
        new.crc = crc
        new.compressed_size = size
        new.uncompressed_size = size
        new.extra = ""
        write(out, local_header(new, ""))
        local rf = assert(io.open(r.path, "rb"))
        local copy_ok, copy_err = pcall(copy_bytes, rf, out, 0, size, function() end)
        rf:close()
        if not copy_ok then
          error(copy_err, 0)
        end
        replaced = replaced + 1
      else
        local data_offset, local_extra = local_data(f, e)
        new.flags = bit.band(e.flags, bit.bnot(FLAG_DESCRIPTOR))
        write(out, local_header(new, local_extra))
        copy_bytes(f, out, data_offset, e.compressed_size, step)
      end
      written[#written + 1] = new
    end
    local cd_offset = out:seek "cur"
    for _, e in ipairs(written) do
      write(out, central_header(e))
    end
    local cd_end = out:seek "cur"
    if cd_end > MAX32 then
      error("zip64 archives are not supported (result too large)", 0)
    end
    write(
      out,
      table.concat {
        "PK\5\6",
        w16(0),
        w16(0),
        w16(#written),
        w16(#written),
        w32(cd_end - cd_offset),
        w32(cd_offset),
        w16(#archive.comment),
        archive.comment,
      }
    )
    return { entries = #written, replaced = replaced, size = cd_end + 22 + #archive.comment }
  end)
  f:close()
  out:close()
  if not ok then
    error(result, 0)
  end
  return result
end

return M
