--[[
  Tests for src/song_file.lua: entry names, the replace-or-keep rule, FLAC headers.
]]

local t = require "tests.helper"
local sf = require "src.song_file"

local p = sf.parse "SampleData/Instrument00 (Kick)/Sample00 (Kick).flac"
t.eq(p and p.instrument, 1, "parse: instrument index is 1-based")
t.eq(p and p.sample, 1, "parse: sample index is 1-based")
t.eq(p and p.ext, "flac", "parse: extension")

p = sf.parse "SampleData/Instrument12 (Pad (old) [v2])/Sample07 (C-4 (soft)).FLAC"
t.eq(p and p.instrument, 13, "parse: parentheses in instrument name")
t.eq(p and p.sample, 8, "parse: parentheses in sample name")
t.eq(p and p.ext, "flac", "parse: extension lower-cased")

p = sf.parse "SampleData/Instrument03/Sample00.wav"
t.eq(p and p.instrument, 4, "parse: no names")
t.eq(p and p.ext, "wav", "parse: wav")

p = sf.parse "SampleData/Instrument100 (x.y)/Sample120 (a.b.c).flac"
t.eq(p and p.instrument, 101, "parse: three digits")
t.eq(p and p.sample, 121, "parse: dots in names")

t.eq(sf.parse "Song.xml", nil, "parse: Song.xml")
t.eq(sf.parse "SampleData/", nil, "parse: folder")
t.eq(sf.parse "SampleData/Instrument00 (Kick)/", nil, "parse: instrument folder")
t.eq(sf.parse "SampleData/Instrument00 (a)/b/Sample00 (c).flac", nil, "parse: nested folder")
t.eq(sf.parse "Other/Instrument00 (a)/Sample00 (c).flac", nil, "parse: other folder")

t.check(sf.is_encodable "SampleData/Instrument00 (a)/Sample00 (b).flac", "encodable: flac")
t.check(sf.is_encodable "SampleData/Instrument00 (a)/Sample00 (b).wav", "encodable: wav")
t.check(not sf.is_encodable "SampleData/Instrument00 (a)/Sample00 (b).ogg", "encodable: ogg")
t.check(not sf.is_encodable "Song.xml", "encodable: Song.xml")

t.eq(
  sf.ogg_name "SampleData/Instrument00 (Kick)/Sample00 (Kick).flac",
  "SampleData/Instrument00 (Kick)/Sample00 (Kick).ogg",
  "ogg_name: flac"
)
t.eq(
  sf.ogg_name "SampleData/Instrument00 (a.b)/Sample00 (c.d).wav",
  "SampleData/Instrument00 (a.b)/Sample00 (c.d).ogg",
  "ogg_name: dots in names"
)

t.check(sf.should_replace(10000, 4000), "replace: smaller ogg")
t.check(not sf.should_replace(287, 4094), "replace: tiny flac stays")
t.check(not sf.should_replace(5000, 5000), "replace: equal stays")
t.check(not sf.should_replace(5000, nil), "replace: failed encode stays")
t.check(not sf.should_replace(5000, 0), "replace: empty ogg stays")

-- FLAC STREAMINFO --------------------------------------------------------------

---Build "fLaC" + STREAMINFO header for the given values.
local function flac_header(rate, channels, bits, frames)
  local bytes = { 0, 16, 0, 16, 0, 0, 0, 0, 0, 0 } -- block sizes, frame sizes
  local hi = math.floor(frames / 4294967296)
  local lo = frames % 4294967296
  bytes[11] = math.floor(rate / 4096) % 256
  bytes[12] = math.floor(rate / 16) % 256
  bytes[13] = (rate % 16) * 16 + (channels - 1) * 2 + math.floor((bits - 1) / 16)
  bytes[14] = ((bits - 1) % 16) * 16 + hi
  bytes[15] = math.floor(lo / 16777216) % 256
  bytes[16] = math.floor(lo / 65536) % 256
  bytes[17] = math.floor(lo / 256) % 256
  bytes[18] = lo % 256
  for i = 19, 34 do
    bytes[i] = 0
  end
  return "fLaC" .. string.char(0x80, 0, 0, 34) .. string.char(unpack(bytes))
end

local info = sf.flac_info(flac_header(44100, 2, 16, 123456))
t.eq(info and info.sample_rate, 44100, "flac: rate")
t.eq(info and info.channels, 2, "flac: channels")
t.eq(info and info.bits, 16, "flac: bits")
t.eq(info and info.frames, 123456, "flac: frames")

info = sf.flac_info(flac_header(96000, 1, 24, 69))
t.eq(info and info.sample_rate, 96000, "flac: 96 kHz")
t.eq(info and info.channels, 1, "flac: mono")
t.eq(info and info.bits, 24, "flac: 24 bit")
t.eq(info and info.frames, 69, "flac: short")

info = sf.flac_info(flac_header(48000, 2, 32, 2 ^ 33 + 5))
t.eq(info and info.frames, 2 ^ 33 + 5, "flac: frames above 32 bits")
t.eq(info and info.bits, 32, "flac: 32 bit")

t.eq(sf.flac_info "RIFF0000WAVEfmt ", nil, "flac: not flac")
t.eq(sf.flac_info "fLaC", nil, "flac: too short")

local shape = { sample_rate = 44100, channels = 2, frames = 123456 }
t.check(sf.matches(sf.flac_info(flac_header(44100, 2, 16, 123456)), shape), "matches: same")
t.check(not sf.matches(sf.flac_info(flac_header(44100, 1, 16, 123456)), shape), "matches: channels")
t.check(not sf.matches(sf.flac_info(flac_header(48000, 2, 16, 123456)), shape), "matches: rate")
t.check(not sf.matches(sf.flac_info(flac_header(44100, 2, 16, 99)), shape), "matches: frames")
t.check(sf.matches(sf.flac_info(flac_header(44100, 2, 16, 0)), shape), "matches: unknown length")
t.check(not sf.matches(nil, shape), "matches: no info")

t.done()
