--[[
  Text for the dialog and the status line. Pure Lua on purpose: no `renoise.*`,
  no Renoise additions to the standard library, so `just test` can run it under
  plain LuaJIT. Tested in `tests/labels_test.lua`.
]]

local M = {}

---Approximate Vorbis nominal bitrates for 44.1 kHz stereo, by quality.
local KBPS = {
  [-1] = 45,
  [0] = 64,
  [1] = 80,
  [2] = 96,
  [3] = 112,
  [4] = 128,
  [5] = 160,
  [6] = 192,
  [7] = 224,
  [8] = 256,
  [9] = 320,
  [10] = 500,
}

---Round to the nearest whole quality step and clamp to -1..10.
---@param q number
---@return integer
function M.quality_step(q)
  local r = math.floor(q + 0.5)
  return math.max(-1, math.min(10, r))
end

---Short description of a quality value, like "6 · good · ~192 kbps".
---@param q number
---@return string
function M.quality(q)
  local step = M.quality_step(q)
  local word
  if step <= 0 then
    word = "smallest"
  elseif step <= 2 then
    word = "small"
  elseif step <= 4 then
    word = "balanced"
  elseif step <= 6 then
    word = "good"
  elseif step <= 8 then
    word = "high"
  else
    word = "highest"
  end
  return ("%d · %s · ~%d kbps"):format(step, word, KBPS[step])
end

---Human-readable file size: "812 bytes", "4.1 KB", "3.97 MB", "1.20 GB".
---@param bytes integer
---@return string
function M.size(bytes)
  if bytes < 1024 then
    return ("%d bytes"):format(bytes)
  elseif bytes < 1024 * 1024 then
    return ("%.1f KB"):format(bytes / 1024)
  elseif bytes < 1024 * 1024 * 1024 then
    return ("%.2f MB"):format(bytes / (1024 * 1024))
  end
  return ("%.2f GB"):format(bytes / (1024 * 1024 * 1024))
end

---Two sizes in the unit of the larger one, so they compare at a glance:
---"3.97 MB → 0.59 MB".
---@param from integer
---@param to integer
---@return string
function M.size_change(from, to)
  local big = math.max(from, to)
  local function in_unit(n)
    if big < 1024 then
      return ("%d bytes"):format(n)
    elseif big < 1024 * 1024 then
      return ("%.1f KB"):format(n / 1024)
    elseif big < 1024 * 1024 * 1024 then
      return ("%.2f MB"):format(n / (1024 * 1024))
    end
    return ("%.2f GB"):format(n / (1024 * 1024 * 1024))
  end
  return in_unit(from) .. " → " .. in_unit(to)
end

---@param n integer
---@param one string
---@param many string|nil Default: `one` .. "s".
---@return string
function M.count(n, one, many)
  return ("%d %s"):format(n, n == 1 and one or (many or one .. "s"))
end

---Line describing the open song, like "Song: Demo.xrns · 3.97 MB · 52 samples".
---@param file_name string Full path; empty when the song was never saved.
---@param bytes integer|nil Size of the song file on disk.
---@param samples integer Samples with data.
---@return string
function M.song(file_name, bytes, samples)
  if file_name == "" then
    return "Song: not saved yet · " .. M.count(samples, "sample")
  end
  local name = file_name:match "[^/\\]+$" or file_name
  if bytes then
    return ("Song: %s · %s · %s"):format(name, M.size(bytes), M.count(samples, "sample"))
  end
  return ("Song: %s · %s"):format(name, M.count(samples, "sample"))
end

---@class ExportReport
---@field old_size integer
---@field new_size integer
---@field replaced integer Samples now stored as OGG.
---@field kept integer Samples kept as they were (OGG not smaller).
---@field failed integer Samples the encoder could not convert (kept too).
---@field skipped integer Samples not encoded (could not be matched to the song).

---Shorten `text` to at most `max` characters (UTF-8 aware), keeping both ends.
---@param text string
---@param max integer
---@return string
function M.ellipsize(text, max)
  local chars = {}
  for ch in text:gmatch "[%z\1-\127\194-\244][\128-\191]*" do
    chars[#chars + 1] = ch
  end
  if #chars <= max then
    return text
  end
  local head = math.ceil((max - 1) / 2)
  local tail = max - 1 - head
  return table.concat(chars, "", 1, head) .. "…" .. table.concat(chars, "", #chars - tail + 1)
end

---Split a message over two lines of at most `max` characters: break after a
---sentence when one fits, else at a space. The second line is shortened if
---needed.
---@param text string
---@param max integer
---@return string first, string second
function M.split_lines(text, max)
  local chars = {}
  for ch in text:gmatch "[%z\1-\127\194-\244][\128-\191]*" do
    chars[#chars + 1] = ch
  end
  if #chars <= max then
    return text, ""
  end
  local cut, sentence = nil, nil
  for i = 1, max + 1 do
    if chars[i] == " " then
      cut = i
      if chars[i - 1] == "." then
        sentence = i
      end
    end
  end
  cut = sentence or cut or max
  local first = table.concat(chars, "", 1, cut):gsub("%s+$", "")
  local second = table.concat(chars, "", cut + 1):gsub("^%s+", "")
  return first, M.ellipsize(second, max)
end

---First line of the result: "Saved Demo-ogg.xrns".
---@param target string
---@return string
function M.report_headline(target)
  local name = target:match "[^/\\]+$" or target
  return "Saved " .. M.ellipsize(name, 60)
end

---Second line of the result:
---"3.97 MB → 0.59 MB (15%) · 37 samples as OGG, 15 kept unchanged."
---@param r ExportReport
---@return string
function M.report_detail(r)
  local share = r.old_size > 0 and math.floor(r.new_size * 100 / r.old_size + 0.5) or 100
  local text = ("%s (%d%%) · %s as OGG"):format(
    M.size_change(r.old_size, r.new_size),
    share,
    M.count(r.replaced, "sample")
  )
  local kept = r.kept + r.failed + r.skipped
  if kept > 0 then
    text = text .. (", %d kept unchanged"):format(kept)
  end
  text = text .. "."
  if r.failed > 0 then
    text = text .. (" The encoder failed on %s."):format(M.count(r.failed, "sample"))
  end
  return text
end

---The whole result on one line, for the status bar.
---@param target string
---@param r ExportReport
---@return string
function M.report(target, r)
  return M.report_headline(target) .. ": " .. M.report_detail(r)
end

---A list of names for a message: "Kick", "Snare" and 3 more.
---@param names string[]
---@param max integer Names to show before "and N more".
---@return string
function M.names(names, max)
  local n = #names
  local shown = {}
  for i = 1, math.min(n, max) do
    shown[i] = '"' .. names[i] .. '"'
  end
  if n > max then
    return table.concat(shown, ", ") .. (" and %d more"):format(n - max)
  end
  if n <= 1 then
    return shown[1] or ""
  end
  local last = table.remove(shown)
  return table.concat(shown, ", ") .. " and " .. last
end

---Progress line for a phase: "Encoding 12 of 52 samples...".
---@param verb string
---@param done integer
---@param total integer
---@return string
function M.progress(verb, done, total)
  return ("%s %d of %s..."):format(verb, done, M.count(total, "sample"))
end

return M
