--[[
  "Find" for the encoder: look through the folders where programs usually end
  up, including other applications that bundle their own ffmpeg (Kdenlive,
  Krita, Cubase, Shotcut, ...). Pure Lua, no `renoise.*`: the file system is
  passed in, so `tests/finder_test.lua` runs it against a fake one.

  The search is breadth-first per root, limited in depth and in the number of
  folders, skips folders that never hold such programs, and calls `pause`
  after every folder so the caller can spread it over several timer ticks.
]]

local encoder = require "src.encoder"
local labels = require "src.labels"

local M = {}

---@class FinderRoot
---@field path string
---@field depth integer How many folder levels below `path` to look into.

---@class FinderFs
---@field dirnames fun(path: string): string[] Folder names in `path` (may raise).
---@field filenames fun(path: string): string[] File names in `path` (may raise).

M.MAX_DIRS = 40000

---Folder names (lower case) that are never searched below a root.
local SKIP = {}
for _, name in ipairs {
  "windows",
  "windowsapps",
  "modifiablewindowsapps",
  "windows defender",
  "windows defender advanced threat protection",
  "windows kits",
  "windows nt",
  "windows mail",
  "windows media player",
  "windows photo viewer",
  "windows portable devices",
  "windows security",
  "windows sidebar",
  "windowspowershell",
  "internet explorer",
  "microsoft",
  "microsoft office",
  "microsoft sdks",
  "microsoft visual studio",
  "microsoft.net",
  "reference assemblies",
  "common files",
  "dotnet",
  "nvidia corporation",
  "msbuild",
  "node_modules",
  ".git",
  "__pycache__",
  "$recycle.bin",
  "system volume information",
  "steamapps",
  "cache",
  "caches",
  "temp",
  "tmp",
  "locale",
  "locales",
  "translations",
  "include",
  "share",
  "doc",
  "docs",
  "man",
  "site-packages",
} do
  SKIP[name] = true
end

---Program file names to look for (lower case), best first.
---@param platform Platform
---@return string[]
function M.program_names(platform)
  return encoder.program_names(platform)
end

---@param platform Platform
---@return string
local function sep(platform)
  return platform == "WINDOWS" and "\\" or "/"
end

---@param dir string
---@param name string
---@param platform Platform
---@return string
local function join(dir, name, platform)
  local last = dir:sub(-1)
  if last == "/" or last == "\\" then
    return dir .. name
  end
  return dir .. sep(platform) .. name
end

---Where to look, most likely first. PATH and the usual bin folders are checked
---without going deeper (depth 0).
---@param platform Platform
---@param getenv fun(name: string): string|nil
---@return FinderRoot[]
function M.roots(platform, getenv)
  local roots = {}
  for _, d in ipairs(encoder.search_dirs(platform, getenv)) do
    roots[#roots + 1] = { path = d, depth = 0 }
  end
  local function add(path, depth)
    if path and path ~= "" then
      roots[#roots + 1] = { path = path, depth = depth }
    end
  end
  if platform == "WINDOWS" then
    local home = getenv "USERPROFILE"
    local local_app = getenv "LOCALAPPDATA"
    local drive = getenv "SystemDrive" or "C:"
    add(getenv "ProgramFiles" or (drive .. "\\Program Files"), 5)
    add(getenv "ProgramFiles(x86)" or (drive .. "\\Program Files (x86)"), 5)
    if local_app then
      add(local_app .. "\\Programs", 4)
      add(local_app .. "\\Microsoft\\WinGet\\Packages", 4)
    end
    if home then
      add(home .. "\\scoop\\apps", 4)
    end
    add((getenv "ProgramData" or (drive .. "\\ProgramData")) .. "\\chocolatey\\lib", 4)
    if home then
      add(home .. "\\Downloads", 3)
      add(home .. "\\Desktop", 2)
      add(home .. "\\Documents", 2)
    end
    add(drive .. "\\", 2) -- C:\ffmpeg\bin, C:\Tools\oggenc2.exe
  else
    local home = getenv "HOME"
    if platform == "MACINTOSH" then
      add("/Applications", 2)
      if home then
        add(home .. "/Applications", 2)
      end
      add("/opt/homebrew", 4)
      add("/usr/local", 4)
    end
    add("/opt", 4)
    if home then
      add(home .. "/.local", 4)
      add(home .. "/bin", 1)
      add(home .. "/Downloads", 3)
    end
  end
  return roots
end

---@param path string
---@param platform Platform
---@return string
local function key(path, platform)
  local k = path:gsub("[/\\]+$", "")
  if platform ~= "LINUX" then
    k = k:lower():gsub("/", "\\")
  end
  return k
end

---@param path string
---@return integer
local function rank(path)
  local kind = encoder.kind(path)
  return kind == "oggenc" and 1 or kind == "ffmpeg" and 2 or 3
end

---Search for encoders. Returns every one found, best kind first (oggenc,
---ffmpeg, sox), and otherwise in the order of `roots`.
---@param platform Platform
---@param roots FinderRoot[]
---@param fs FinderFs
---@param pause fun(visited: integer): boolean|nil Called after every folder; return true to stop.
---@return string[] found, integer visited
function M.search(platform, roots, fs, pause)
  local wanted = {}
  for _, name in ipairs(M.program_names(platform)) do
    wanted[name] = true
  end
  local found, found_keys, seen = {}, {}, {}
  local visited = 0
  local stop = false

  local function look(dir)
    local ok, files = pcall(fs.filenames, dir)
    if not ok or type(files) ~= "table" then
      return
    end
    for _, f in ipairs(files) do
      local name = platform == "LINUX" and f or f:lower()
      if wanted[name] then
        local p = join(dir, f, platform)
        local k = key(p, platform)
        if not found_keys[k] then
          found_keys[k] = true
          found[#found + 1] = p
        end
      end
    end
  end

  for _, root in ipairs(roots) do
    if stop then
      break
    end
    local queue = { { path = root.path, depth = 0 } }
    local head = 1
    while head <= #queue do
      local item = queue[head]
      head = head + 1
      local k = key(item.path, platform)
      if not seen[k] then
        seen[k] = true
        look(item.path)
        visited = visited + 1
        if pause(visited) or visited >= M.MAX_DIRS then
          stop = true
          break
        end
        if item.depth < root.depth then
          local ok, dirs = pcall(fs.dirnames, item.path)
          if ok and type(dirs) == "table" then
            for _, d in ipairs(dirs) do
              local lower = d:lower()
              if lower:match "%.app$" then
                -- macOS application bundle: its programs are in Contents/MacOS.
                queue[#queue + 1] = {
                  path = join(join(item.path, d, platform), "Contents/MacOS", platform),
                  depth = root.depth,
                }
              elseif not SKIP[lower] and d:sub(1, 1) ~= "." then
                queue[#queue + 1] = { path = join(item.path, d, platform), depth = item.depth + 1 }
              end
            end
          end
        end
      end
    end
  end

  local order = {}
  for i, p in ipairs(found) do
    order[p] = i
  end
  table.sort(found, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then
      return ra < rb
    end
    return order[a] < order[b]
  end)
  return found, visited
end

---Short label for a found encoder, for the drop-down:
---"ffmpeg · C:\Program Files\Kdenlive\bin".
---@param path string
---@return string
function M.label(path)
  local dir = path:match "^(.*)[/\\][^/\\]+$" or path
  return (encoder.kind(path) or "?") .. " · " .. labels.ellipsize(dir, 56)
end

return M
