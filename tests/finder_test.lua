--[[
  Tests for src/finder.lua, against a fake file system.
]]

local t = require "tests.helper"
local finder = require "src.finder"

---Fake file system from a list of file paths. Folders are implied.
---@param files string[]
---@param sep string
local function fake_fs(files, sep)
  local dirs, contents = {}, {}
  local function norm(p)
    return (p:gsub("[/\\]+$", ""):lower():gsub("/", "\\"))
  end
  local function add_child(parent, name, is_dir)
    local k = norm(parent)
    contents[k] = contents[k] or { dirs = {}, files = {}, seen = {} }
    local c = contents[k]
    if not c.seen[name] then
      c.seen[name] = true
      table.insert(is_dir and c.dirs or c.files, name)
    end
  end
  for _, f in ipairs(files) do
    local parts = {}
    for part in f:gmatch("[^" .. sep .. "]+") do
      parts[#parts + 1] = part
    end
    local path = sep == "/" and "" or parts[1]
    local start = sep == "/" and 1 or 2
    for i = start, #parts do
      local parent = path == "" and "/" or path
      add_child(parent, parts[i], i < #parts)
      path = (path == "/" and "" or path) .. sep .. parts[i]
      if sep ~= "/" and i == start then
        path = parts[1] .. sep .. parts[i]
      end
      dirs[norm(path)] = i < #parts
    end
  end
  local listed = {}
  return {
    dirnames = function(p)
      local c = contents[norm(p)]
      if not c then
        error "no such folder"
      end
      listed[#listed + 1] = p
      return c.dirs
    end,
    filenames = function(p)
      local c = contents[norm(p)]
      if not c then
        error "no such folder"
      end
      return c.files
    end,
    listed = listed,
  }
end

local function never()
  return false
end

-- Windows: programs that bundle ffmpeg, a skipped folder, depth limit -------------

local win = fake_fs({
  [[C:\Program Files\Kdenlive\bin\ffmpeg.exe]],
  [[C:\Program Files\Steinberg\Cubase 15\Externals\FFmpeg\8.0.1\ffmpeg.exe]],
  [[C:\Program Files\Microsoft\Hidden\ffmpeg.exe]],
  [[C:\Program Files\Deep\a\b\c\d\e\f\ffmpeg.exe]],
  [[C:\Users\u\Downloads\oggenc2.88\oggenc2.exe]],
  [[C:\Program Files\Kdenlive\bin\kdenlive.exe]],
}, "\\")

local roots = {
  { path = [[C:\Program Files]], depth = 5 },
  { path = [[C:\Users\u\Downloads]], depth = 3 },
}
local found, visited = finder.search("WINDOWS", roots, win, never)
t.eq(#found, 3, "windows: found count")
t.eq(found[1], [[C:\Users\u\Downloads\oggenc2.88\oggenc2.exe]], "windows: oggenc ranks first")
t.eq(found[2], [[C:\Program Files\Kdenlive\bin\ffmpeg.exe]], "windows: shallow ffmpeg next")
t.eq(
  found[3],
  [[C:\Program Files\Steinberg\Cubase 15\Externals\FFmpeg\8.0.1\ffmpeg.exe]],
  "windows: ffmpeg five levels down"
)
t.check(visited > 5, "windows: counts folders")
for _, p in ipairs(win.listed) do
  t.check(not p:find "Microsoft", "windows: Microsoft folder skipped: " .. p)
end

-- Upper-case file names match on Windows.
local upper = fake_fs({ [[D:\Tools\FFMPEG.EXE]] }, "\\")
found = finder.search("WINDOWS", { { path = [[D:\Tools]], depth = 0 } }, upper, never)
t.eq(found[1], [[D:\Tools\FFMPEG.EXE]], "windows: case-insensitive names")

-- The same folder through two roots is searched once and reported once.
found = finder.search("WINDOWS", {
  { path = [[C:\Program Files\Kdenlive\bin]], depth = 0 },
  { path = [[C:\Program Files]], depth = 2 },
}, win, never)
t.eq(#found, 1, "windows: no duplicates")

-- macOS: inside application bundles only Contents/MacOS is searched ----------------

local mac = fake_fs({
  "/Applications/Kdenlive.app/Contents/MacOS/ffmpeg",
  "/Applications/Big.app/Contents/Resources/deep/ffmpeg",
  "/opt/homebrew/Cellar/vorbis-tools/1.4.2/bin/oggenc",
}, "/")
found = finder.search("MACINTOSH", {
  { path = "/Applications", depth = 2 },
  { path = "/opt/homebrew", depth = 4 },
}, mac, never)
t.eq(#found, 2, "mac: found count")
t.eq(found[1], "/opt/homebrew/Cellar/vorbis-tools/1.4.2/bin/oggenc", "mac: oggenc first")
t.eq(found[2], "/Applications/Kdenlive.app/Contents/MacOS/ffmpeg", "mac: app bundle")

-- Linux: names are case-sensitive ---------------------------------------------------

local linux = fake_fs({ "/opt/x/FFMPEG", "/opt/y/sox" }, "/")
found = finder.search("LINUX", { { path = "/opt", depth = 2 } }, linux, never)
t.eq(#found, 1, "linux: case-sensitive")
t.eq(found[1], "/opt/y/sox", "linux: sox")

-- Missing and unreadable folders are ignored; pause can stop the search -------------

found = finder.search("LINUX", { { path = "/nowhere", depth = 3 } }, linux, never)
t.eq(#found, 0, "missing root: nothing, no error")

local calls = 0
found, visited = finder.search("WINDOWS", roots, win, function()
  calls = calls + 1
  return calls >= 2
end)
t.eq(visited, 2, "pause returning true stops the search")

-- roots and label ---------------------------------------------------------------------

local env = {
  PATH = [[C:\Windows]],
  USERPROFILE = [[C:\Users\u]],
  LOCALAPPDATA = [[C:\Users\u\AppData\Local]],
  ProgramFiles = [[C:\Program Files]],
  ["ProgramFiles(x86)"] = [[C:\Program Files (x86)]],
}
local r = finder.roots("WINDOWS", function(n)
  return env[n]
end)
local by_path = {}
for _, root in ipairs(r) do
  by_path[root.path] = root.depth
end
t.eq(by_path[ [[C:\Windows]] ], 0, "roots: PATH entries at depth 0")
t.eq(by_path[ [[C:\Program Files]] ], 5, "roots: Program Files deep")
t.eq(by_path[ [[C:\Users\u\AppData\Local\Microsoft\WinGet\Packages]] ], 4, "roots: WinGet packages")
t.eq(by_path[ [[C:\Users\u\Downloads]] ], 3, "roots: Downloads")

local mr = finder.roots("MACINTOSH", function(n)
  return ({ HOME = "/Users/u", PATH = "/usr/bin" })[n]
end)
local has_apps = false
for _, root in ipairs(mr) do
  has_apps = has_apps or root.path == "/Applications"
end
t.check(has_apps, "roots: macOS Applications")

t.eq(
  finder.label [[C:\Program Files\Kdenlive\bin\ffmpeg.exe]],
  [[ffmpeg · C:\Program Files\Kdenlive\bin]],
  "label: kind and folder"
)

t.done()
