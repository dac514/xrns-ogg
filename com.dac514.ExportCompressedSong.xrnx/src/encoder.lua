--[[
  Encoder command lines and the job script that runs them. Pure Lua, no
  `renoise.*`, unit-tested in `tests/encoder_test.lua`.

  The job script runs in its work folder, so sample files are plain relative
  names like `0001.wav`. For every sample it checks for a `cancel` file, runs
  the encoder (output into `NNNN.log`), and writes the exit code into
  `NNNN.done`. It writes `started` first and `finished` last (also when
  cancelled), so the tool can poll progress by looking at files only.
]]

local M = {}

---@alias EncoderKind "oggenc"|"ffmpeg"|"sox"
---@alias Platform "WINDOWS"|"MACINTOSH"|"LINUX"

---Kind of encoder from its file name, or nil when the name is not one we know.
---@param path string
---@return EncoderKind|nil
function M.kind(path)
  local name = (path:match "[^/\\]+$" or ""):lower():gsub("%.exe$", "")
  if name:match "^oggenc" then
    return "oggenc"
  elseif name:match "^ffmpeg" then
    return "ffmpeg"
  elseif name == "sox" or name:match "^sox[%-_%.%d]" then
    return "sox"
  end
  return nil
end

---Quote one argument for the job script of `platform`.
---POSIX: single quotes. Windows batch: double quotes (Windows paths cannot
---contain them), and `%` doubled so cmd does not expand it.
---@param s string
---@param platform Platform
---@return string
function M.quote(s, platform)
  if platform == "WINDOWS" then
    return '"' .. s:gsub("%%", "%%%%") .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

---@param q number
---@return string
local function quality_arg(q)
  q = math.max(-1, math.min(10, q))
  return ("%g"):format(q)
end

---One encoder command line.
---@param kind EncoderKind
---@param encoder_path string
---@param quality number Vorbis quality, -1 to 10.
---@param wav string Input file.
---@param ogg string Output file.
---@param platform Platform
---@return string
function M.command(kind, encoder_path, quality, wav, ogg, platform)
  local function q(s)
    return M.quote(s, platform)
  end
  local exe, Q = q(encoder_path), quality_arg(quality)
  if kind == "oggenc" then
    return ("%s -Q -q %s -o %s %s"):format(exe, Q, q(ogg), q(wav))
  elseif kind == "ffmpeg" then
    return ("%s -nostdin -v error -y -i %s -c:a libvorbis -q:a %s %s"):format(
      exe,
      q(wav),
      Q,
      q(ogg)
    )
  elseif kind == "sox" then
    return ("%s %s -C %s %s"):format(exe, q(wav), Q, q(ogg))
  end
  error("unknown encoder kind: " .. tostring(kind))
end

---@class EncodeStep
---@field command string Encoder command (from `M.command`).
---@field id string File stem, like "0001": log goes to id.log, exit code to id.done.

---File name of the job script on `platform`.
---@param platform Platform
---@return string
function M.script_name(platform)
  return platform == "WINDOWS" and "job.bat" or "job.sh"
end

---Text of the job script.
---@param steps EncodeStep[]
---@param platform Platform
---@param work_dir string Absolute path of the work folder.
---@return string
function M.script(steps, platform, work_dir)
  local lines = {}
  local function add(line)
    lines[#lines + 1] = line
  end
  if platform == "WINDOWS" then
    add "@echo off"
    add "chcp 65001 >nul"
    add("cd /d " .. M.quote(work_dir, platform) .. " || exit /b 1")
    add ">started echo 1"
    for _, s in ipairs(steps) do
      add "if exist cancel goto cancelled"
      add(("%s >%s.log 2>&1"):format(s.command, s.id))
      add((">%s.done echo %%errorlevel%%"):format(s.id))
    end
    add ">finished echo ok"
    add "exit /b 0"
    add ":cancelled"
    add ">finished echo cancelled"
    add "exit /b 0"
    return table.concat(lines, "\r\n") .. "\r\n"
  end
  add "#!/bin/sh"
  add("cd " .. M.quote(work_dir, platform) .. " || exit 1")
  add "echo 1 >started"
  for _, s in ipairs(steps) do
    add "if [ -f cancel ]; then echo cancelled >finished; exit 0; fi"
    add(("%s </dev/null >%s.log 2>&1"):format(s.command, s.id))
    add(("echo $? >%s.done"):format(s.id))
  end
  add "echo ok >finished"
  return table.concat(lines, "\n") .. "\n"
end

---Command that starts the job script in the background, without a console
---window and without inheriting Renoise's sockets.
---Windows: PowerShell's Start-Process goes through the Windows shell, so the
---script's cmd window is hidden and inherits nothing; run this with io.popen
---(os.execute would block Renoise while a console opens). Elsewhere: run with
---os.execute; `&` returns at once.
---@param platform Platform
---@param work_dir string
---@return string
function M.launch_command(platform, work_dir)
  if platform == "WINDOWS" then
    local function ps(s)
      return "'" .. s:gsub("'", "''") .. "'"
    end
    return (
      'powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "Start-Process'
      .. " -FilePath 'cmd.exe' -ArgumentList '/c','job.bat'"
      .. ' -WorkingDirectory %s -WindowStyle Hidden"'
    ):format(ps(work_dir))
  end
  local sep = work_dir:sub(-1) == "/" and "" or "/"
  return ("sh %s >/dev/null 2>&1 &"):format(M.quote(work_dir .. sep .. "job.sh", platform))
end

---Readable reason for a failed encode, from the encoder's output.
---@param log string What the encoder printed.
---@param code string|nil Exit code written by the job script.
---@return string
function M.reason(log, code)
  if log:find "Unknown encoder 'libvorbis'" or log:find "Unknown encoder 'vorbis'" then
    return "This ffmpeg was built without the Vorbis encoder (libvorbis). Choose another one."
  end
  if
    log:lower():find "no handler for file extension" or log:find "FAIL formats: can't open output"
  then
    return "This sox cannot write OGG files. Choose another encoder."
  end
  local line = log:match "[^\r\n]*%S[^\r\n]*"
  if line then
    line = line:gsub("^%s*%[[^%]]*%]%s*", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #line > 160 then
      line = line:sub(1, 157) .. "..."
    end
    return line
  end
  return "It stopped with exit code " .. tostring(code or "?") .. "."
end

-- Finding an encoder ----------------------------------------------------------

---Program names to look for, best first.
---@param platform Platform
---@return string[]
function M.program_names(platform)
  local names = { "oggenc", "oggenc2", "ffmpeg", "sox" }
  if platform == "WINDOWS" then
    for i, n in ipairs(names) do
      names[i] = n .. ".exe"
    end
  end
  return names
end

---Folders to search: the PATH entries, then the usual install folders that a
---program started from the Dock or the Start menu may not have on its PATH.
---@param platform Platform
---@param getenv fun(name: string): string|nil
---@return string[]
function M.search_dirs(platform, getenv)
  local dirs, seen = {}, {}
  local function add(d)
    if d and d ~= "" then
      d = d:gsub('^"(.*)"$', "%1"):gsub("[/\\]+$", "")
      local key = platform == "LINUX" and d or d:lower()
      if d ~= "" and not seen[key] then
        seen[key] = true
        dirs[#dirs + 1] = d
      end
    end
  end
  local sep = platform == "WINDOWS" and ";" or ":"
  for d in ((getenv "PATH" or "") .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
    add(d)
  end
  if platform == "WINDOWS" then
    local local_app = getenv "LOCALAPPDATA"
    local home = getenv "USERPROFILE"
    if local_app then
      add(local_app .. "\\Microsoft\\WinGet\\Links")
    end
    if home then
      add(home .. "\\scoop\\shims")
    end
    add((getenv "ProgramData" or "C:\\ProgramData") .. "\\chocolatey\\bin")
  else
    local home = getenv "HOME"
    add "/opt/homebrew/bin"
    add "/usr/local/bin"
    add "/opt/local/bin"
    add "/usr/bin"
    if home then
      add(home .. "/.local/bin")
    end
  end
  return dirs
end

---First encoder found, or nil.
---@param platform Platform
---@param getenv fun(name: string): string|nil
---@param exists fun(path: string): boolean
---@return string|nil
function M.find(platform, getenv, exists)
  local sep = platform == "WINDOWS" and "\\" or "/"
  local dirs = M.search_dirs(platform, getenv)
  for _, name in ipairs(M.program_names(platform)) do
    for _, d in ipairs(dirs) do
      local p = d .. sep .. name
      if exists(p) then
        return p
      end
    end
  end
  return nil
end

---@class EncoderHint
---@field text string What to install.
---@field url string Where to read more.

---Where to get an encoder on `platform`.
---@param platform Platform
---@return EncoderHint
function M.download_hint(platform)
  if platform == "WINDOWS" then
    return {
      text = "Get oggenc2 from RareWares, or run: winget install Gyan.FFmpeg",
      url = "https://www.rarewares.org/ogg-oggenc.php",
    }
  elseif platform == "MACINTOSH" then
    return {
      text = "Install it with Homebrew: brew install vorbis-tools (or ffmpeg)",
      url = "https://formulae.brew.sh/formula/vorbis-tools",
    }
  end
  return {
    text = "Install vorbis-tools, ffmpeg or sox with your package manager.",
    url = "https://xiph.org/vorbis/",
  }
end

return M
