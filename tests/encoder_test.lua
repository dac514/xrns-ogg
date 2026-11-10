--[[
  Tests for src/encoder.lua: command lines, quoting, job scripts, encoder lookup.
]]

local t = require "tests.helper"
local enc = require "src.encoder"

-- kind -------------------------------------------------------------------------

t.eq(enc.kind "/usr/bin/oggenc", "oggenc", "kind: oggenc")
t.eq(enc.kind [[C:\Tools\oggenc2.exe]], "oggenc", "kind: oggenc2.exe")
t.eq(enc.kind [[C:\Program Files\FFmpeg\bin\FFMPEG.EXE]], "ffmpeg", "kind: ffmpeg upper case")
t.eq(enc.kind "/opt/homebrew/bin/sox", "sox", "kind: sox")
t.eq(enc.kind "/usr/bin/sox-14.4", "sox", "kind: versioned sox")
t.eq(enc.kind "/usr/bin/soxi", nil, "kind: soxi is not sox")
t.eq(enc.kind "/usr/bin/lame", nil, "kind: unknown")
t.eq(enc.kind "", nil, "kind: empty")

-- quote ------------------------------------------------------------------------

t.eq(enc.quote("/a b/c", "LINUX"), "'/a b/c'", "quote: posix spaces")
t.eq(enc.quote("it's", "MACINTOSH"), [['it'\''s']], "quote: posix single quote")
t.eq(enc.quote([[C:\My Tools\x.exe]], "WINDOWS"), [["C:\My Tools\x.exe"]], "quote: windows")
t.eq(enc.quote([[C:\100% done]], "WINDOWS"), [["C:\100%% done"]], "quote: windows percent")

-- command ----------------------------------------------------------------------

t.eq(
  enc.command("oggenc", "/usr/bin/oggenc", 6, "0001.wav", "0001.ogg", "LINUX"),
  "'/usr/bin/oggenc' -Q -q 6 -o '0001.ogg' '0001.wav'",
  "command: oggenc"
)
t.eq(
  enc.command("ffmpeg", "/usr/bin/ffmpeg", 3, "0001.wav", "0001.ogg", "LINUX"),
  "'/usr/bin/ffmpeg' -nostdin -v error -y -i '0001.wav' -c:a libvorbis -q:a 3 '0001.ogg'",
  "command: ffmpeg"
)
t.eq(
  enc.command("sox", "/usr/bin/sox", -1, "0001.wav", "0001.ogg", "LINUX"),
  "'/usr/bin/sox' '0001.wav' -C -1 '0001.ogg'",
  "command: sox"
)
t.eq(
  enc.command("oggenc", [[C:\Program Files\oggenc2.exe]], 10, "a b.wav", "a b.ogg", "WINDOWS"),
  [["C:\Program Files\oggenc2.exe" -Q -q 10 -o "a b.ogg" "a b.wav"]],
  "command: windows quoting with spaces"
)
t.eq(
  enc.command("oggenc", "/my tools/oggenc", 4.5, "x.wav", "x.ogg", "MACINTOSH"),
  "'/my tools/oggenc' -Q -q 4.5 -o 'x.ogg' 'x.wav'",
  "command: posix quoting with spaces, fractional quality"
)
t.eq(
  enc.command("sox", "/s", 12, "x.wav", "x.ogg", "LINUX"),
  "'/s' 'x.wav' -C 10 'x.ogg'",
  "command: quality clamped"
)
t.fails(function()
  ---@diagnostic disable-next-line: param-type-mismatch
  enc.command("lame", "/l", 6, "x.wav", "x.ogg", "LINUX")
end, "unknown encoder", "command: unknown kind")

-- script -----------------------------------------------------------------------

local steps = {
  { id = "0001", command = "ENC1" },
  { id = "0002", command = "ENC2" },
}

local sh = enc.script(steps, "LINUX", "/tmp/work dir")
t.eq(enc.script_name "LINUX", "job.sh", "script name: posix")
t.eq(
  sh,
  table.concat({
    "#!/bin/sh",
    "cd '/tmp/work dir' || exit 1",
    "echo 1 >started",
    "if [ -f cancel ]; then echo cancelled >finished; exit 0; fi",
    "ENC1 </dev/null >0001.log 2>&1",
    "echo $? >0001.done",
    "if [ -f cancel ]; then echo cancelled >finished; exit 0; fi",
    "ENC2 </dev/null >0002.log 2>&1",
    "echo $? >0002.done",
    "echo ok >finished",
    "",
  }, "\n"),
  "script: posix"
)

local bat = enc.script(steps, "WINDOWS", [[C:\Temp\work]])
t.eq(enc.script_name "WINDOWS", "job.bat", "script name: windows")
t.eq(
  bat,
  table.concat({
    "@echo off",
    "chcp 65001 >nul",
    [[cd /d "C:\Temp\work" || exit /b 1]],
    ">started echo 1",
    "if exist cancel goto cancelled",
    "ENC1 >0001.log 2>&1",
    ">0001.done echo %errorlevel%",
    "if exist cancel goto cancelled",
    "ENC2 >0002.log 2>&1",
    ">0002.done echo %errorlevel%",
    ">finished echo ok",
    "exit /b 0",
    ":cancelled",
    ">finished echo cancelled",
    "exit /b 0",
    "",
  }, "\r\n"),
  "script: windows"
)

t.eq(enc.launch_command("LINUX", "/tmp/w"), "sh '/tmp/w/job.sh' >/dev/null 2>&1 &", "launch: posix")
t.eq(
  enc.launch_command("WINDOWS", [[C:\Users\O'Neil\w]]),
  [[powershell -NoProfile -NonInteractive -WindowStyle Hidden -Command "Start-Process]]
    .. [[ -FilePath 'cmd.exe' -ArgumentList '/c','job.bat' -WorkingDirectory 'C:\Users\O''Neil\w']]
    .. [[ -WindowStyle Hidden"]],
  "launch: windows"
)

-- reason ---------------------------------------------------------------------

t.eq(
  enc.reason("[aost#0:0 @ 000002437ec72b00] Unknown encoder 'libvorbis'\nError ...", "8"),
  "This ffmpeg was built without the Vorbis encoder (libvorbis). Choose another one.",
  "reason: ffmpeg without libvorbis"
)
t.eq(
  enc.reason("\n\n[in#0 @ 0000] Error opening input: No such file\r\nmore", "1"),
  "Error opening input: No such file",
  "reason: first line, ffmpeg prefix removed"
)
t.eq(
  enc.reason("sox FAIL formats: no handler for file extension `ogg'", "2"),
  "This sox cannot write OGG files. Choose another encoder.",
  "reason: sox without ogg"
)
t.eq(enc.reason("", "2"), "It stopped with exit code 2.", "reason: no output")
t.eq(enc.reason("  \n", nil), "It stopped with exit code ?.", "reason: blank output")

-- find -------------------------------------------------------------------------

local function env(vars)
  return function(name)
    return vars[name]
  end
end

local function exists_in(set)
  return function(p)
    return set[p] == true
  end
end

t.eq(
  enc.find(
    "LINUX",
    env { PATH = "/usr/local/bin:/usr/bin:/bin", HOME = "/home/u" },
    exists_in { ["/usr/bin/ffmpeg"] = true, ["/bin/oggenc"] = true }
  ),
  "/bin/oggenc",
  "find: oggenc wins over ffmpeg"
)
t.eq(
  enc.find(
    "MACINTOSH",
    env { PATH = "/usr/bin:/bin", HOME = "/Users/u" },
    exists_in { ["/opt/homebrew/bin/ffmpeg"] = true }
  ),
  "/opt/homebrew/bin/ffmpeg",
  "find: Homebrew folder outside PATH"
)
t.eq(
  enc.find(
    "WINDOWS",
    env {
      PATH = [[C:\Windows;"C:\Tools\";C:\Windows]],
      LOCALAPPDATA = [[C:\Users\u\AppData\Local]],
    },
    exists_in { [ [[C:\Tools\oggenc2.exe]] ] = true }
  ),
  [[C:\Tools\oggenc2.exe]],
  "find: windows, quoted PATH entry with trailing slash"
)
t.eq(
  enc.find(
    "WINDOWS",
    env { PATH = "", LOCALAPPDATA = [[C:\L]] },
    exists_in { [ [[C:\L\Microsoft\WinGet\Links\ffmpeg.exe]] ] = true }
  ),
  [[C:\L\Microsoft\WinGet\Links\ffmpeg.exe]],
  "find: WinGet links"
)
t.eq(enc.find("LINUX", env {}, exists_in {}), nil, "find: nothing")

local dirs = enc.search_dirs("WINDOWS", env { PATH = [[C:\A;c:\a\;C:\B]] })
t.eq(dirs[1] .. "|" .. dirs[2], [[C:\A|C:\B]], "search_dirs: windows duplicates ignore case")

for _, p in ipairs { "WINDOWS", "MACINTOSH", "LINUX" } do
  local h = enc.download_hint(p)
  t.check(h.text ~= "" and h.url:match "^https://", "download hint: " .. p)
end

t.done()
