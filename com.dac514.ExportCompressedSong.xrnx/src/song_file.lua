--[[
  Facts about the inside of a `.xrns` song file. Pure Lua, no `renoise.*`,
  unit-tested in `tests/song_file_test.lua`.

  Renoise names sample entries `SampleData/InstrumentNN (name)/SampleNN (name).flac`,
  with zero-based numbers (API index minus one). `Song.xml` does not refer to
  these names, so an entry can become `.ogg` with the same base name.
]]

local M = {}

---@class SampleEntryName
---@field instrument integer 1-based API index.
---@field sample integer 1-based API index.
---@field ext string Lower-case extension without the dot.

---Parse a sample entry name. Nil for anything else (Song.xml, folders, other files).
---@param name string
---@return SampleEntryName|nil
function M.parse(name)
  local i, s, ext = name:match "^SampleData/Instrument(%d+)[^/]*/Sample(%d+)[^/]*%.([%w]+)$"
  if not i then
    return nil
  end
  return { instrument = tonumber(i) + 1, sample = tonumber(s) + 1, ext = ext:lower() }
end

---Whether an entry is a sample that the tool can encode.
---@param name string
---@return boolean
function M.is_encodable(name)
  local p = M.parse(name)
  return p ~= nil and (p.ext == "flac" or p.ext == "wav")
end

---The entry name with its extension replaced by `.ogg`.
---@param name string
---@return string
function M.ogg_name(name)
  local base = name:match "^(.*)%.[^./]+$" or name
  return base .. ".ogg"
end

---Replace the entry only when the OGG file is smaller. Very short samples
---(single-cycle loops) end up larger as OGG and lose the most, so they stay.
---@param original_size integer
---@param ogg_size integer|nil Nil when encoding failed.
---@return boolean
function M.should_replace(original_size, ogg_size)
  return ogg_size ~= nil and ogg_size > 0 and ogg_size < original_size
end

---@class FlacInfo
---@field sample_rate integer
---@field channels integer
---@field bits integer
---@field frames integer Total frames (0 when unknown).

---Read the STREAMINFO block at the start of FLAC data (needs 42 bytes).
---@param data string
---@return FlacInfo|nil
function M.flac_info(data)
  if #data < 42 or data:sub(1, 4) ~= "fLaC" then
    return nil
  end
  -- Metadata block header: 1 bit last flag, 7 bits type (0 = STREAMINFO), 24 bits length.
  if data:byte(5) % 128 ~= 0 then
    return nil
  end
  local b = { data:byte(9 + 10, 9 + 17) } -- STREAMINFO bytes 10..17
  local rate = b[1] * 4096 + b[2] * 16 + math.floor(b[3] / 16)
  local channels = math.floor(b[3] / 2) % 8 + 1
  local bits = (b[3] % 2) * 16 + math.floor(b[4] / 16) + 1
  local frames = (b[4] % 16) * 4294967296 + b[5] * 16777216 + b[6] * 65536 + b[7] * 256 + b[8]
  return { sample_rate = rate, channels = channels, bits = bits, frames = frames }
end

---@class SampleShape
---@field sample_rate integer
---@field channels integer
---@field frames integer

---Whether an entry's FLAC header describes the sample the API reports, which
---confirms that the name maps to the right sample.
---@param info FlacInfo|nil
---@param shape SampleShape
---@return boolean
function M.matches(info, shape)
  return info ~= nil
    and info.sample_rate == shape.sample_rate
    and info.channels == shape.channels
    and (info.frames == 0 or info.frames == shape.frames)
end

return M
