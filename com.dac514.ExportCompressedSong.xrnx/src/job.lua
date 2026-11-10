--[[
  One export run: save the song, export its samples as WAV, encode them with an
  external program in the background, and write the compressed copy.

  Renoise stays responsive throughout. Work that runs inside Renoise (WAV
  export, archive rewrite) runs in a coroutine that yields every few
  milliseconds; the encoder runs as a separate job script that the timer polls
  through marker files (see `src/encoder.lua`).

  Phases: "export" -> "encode" -> "pack" -> "done"
  and "cancelling" -> "cancelled", or "failed" from anywhere.
]]

local encoder = require "src.encoder"
local labels = require "src.labels"
local song_file = require "src.song_file"
local zip = require "src.zip"

local M = {}

local TICK_MS = 50
local BUDGET_S = 0.03 -- time per tick spent on work inside Renoise
local START_TIMEOUT_S = 20 -- the job script must write `started` within this
local CANCEL_TIMEOUT_S = 60

---@class JobOptions
---@field app table The application module (for `reg` and `guard`).
---@field target string Path of the compressed copy.
---@field encoder_path string
---@field quality number
---@field on_update fun(job: Job) Called whenever phase, message or progress change.
---@field keep_running fun(): boolean The job cancels itself when this returns false.
---@field on_log fun(text: string) Important messages for the dialog's log.

---@class JobTask
---@field id string File stem in the work folder, like "0001".
---@field entry ZipEntry
---@field sample renoise.Sample
---@field name string Sample name, for messages.

---@class Job
---@field phase string
---@field message string
---@field detail string Second line, used for the result.
---@field progress number 0..1 for the current run.
---@field report ExportReport|nil
---@field target string
---@field app table
---@field on_update fun(job: Job)
---@field keep_running fun(): boolean
---@field on_log fun(text: string)
---@field encoder_path string
---@field kind EncoderKind
---@field quality number
---@field source string The saved song file.
---@field tasks JobTask[]
---@field skipped integer
---@field work_dir string|nil
---@field part string|nil Temporary file next to the target.
---@field pipe file*|nil
---@field co thread|nil
---@field deadline number
---@field tick_fn function|nil
---@field launched_at number
---@field next_done integer
---@field cancel_requested boolean|nil
---@field cancel_started number
local Job = {}
Job.__index = Job

-- Files -------------------------------------------------------------------------

---@param dir string
---@param name string
---@return string
local function join(dir, name)
  local sep = os.platform() == "WINDOWS" and "\\" or "/"
  if dir:sub(-1) == "/" or dir:sub(-1) == "\\" then
    return dir .. name
  end
  return dir .. sep .. name
end

---@param path string
---@return string|nil
local function read_text(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read "*a"
  f:close()
  return s
end

---@param path string
---@param text string
local function write_text(path, text)
  local f, err = io.open(path, "wb")
  if not f then
    error("cannot write " .. path .. ": " .. tostring(err), 0)
  end
  f:write(text)
  f:close()
end

---@param path string
---@return integer|nil
local function file_size(path)
  local st = io.stat(path)
  return st and st.size or nil
end

---Normalised path for comparing two names of the same file.
---@param path string
---@return string
local function same_path_key(path)
  local p = path:gsub("\\", "/")
  if os.platform() ~= "LINUX" then
    p = p:lower()
  end
  return p
end

---A fresh, empty work folder in Renoise's temp folder (Renoise removes what is
---left there when it quits).
---@return string
local function make_work_dir()
  local base = os.tmpname ""
  local dir = base:gsub("[%.]+$", "") .. "_ogg"
  local ok, err = os.mkdir(dir)
  if not ok then
    error("cannot create the work folder " .. dir .. ": " .. tostring(err), 0)
  end
  return dir
end

---@param dir string|nil
local function remove_dir(dir)
  if not dir or not io.exists(dir) then
    return
  end
  for _, name in ipairs(os.filenames(dir)) do
    os.remove(join(dir, name))
  end
  os.remove(dir)
end

-- Lifecycle ---------------------------------------------------------------------

---@param phase string
---@param message string
---@param progress number|nil
---@param detail string|nil
function Job:set(phase, message, progress, detail)
  self.phase = phase
  self.message = message
  self.detail = detail or ""
  if progress then
    self.progress = progress
  end
  self.on_update(self)
end

---@return boolean
function Job:running()
  return self.phase == "export"
    or self.phase == "encode"
    or self.phase == "pack"
    or self.phase == "cancelling"
end

function Job:stop_timer()
  local tool = renoise.tool()
  if self.tick_fn and tool:has_timer(self.tick_fn) then
    tool:remove_timer(self.tick_fn)
  end
end

function Job:close_pipe()
  if self.pipe then
    pcall(function()
      self.pipe:close()
    end)
    self.pipe = nil
  end
end

function Job:cleanup()
  self:stop_timer()
  self:close_pipe()
  if self.part and io.exists(self.part) then
    os.remove(self.part)
  end
  remove_dir(self.work_dir)
  self.work_dir = nil
end

---@param text string
function Job:note(text)
  self.on_log(text)
end

---@param message string
function Job:fail(message)
  self:cleanup()
  self:note("Failed: " .. message)
  self:set("failed", message)
end

---Ask the job to stop. Encoding stops after the sample in progress.
function Job:cancel()
  if not self:running() or self.cancel_requested then
    return
  end
  self.cancel_requested = true
  if self.phase == "encode" then
    pcall(write_text, join(self.work_dir, "cancel"), "1")
    self.cancel_started = os.clock()
    self:set("cancelling", "Cancelling: waiting for the encoder to finish its current sample...")
  end
  -- export and pack notice the flag on their next step.
end

-- Steps -------------------------------------------------------------------------

---Find the sample behind each encodable entry, and check that it really is that
---sample: same rate, channels and length as the FLAC header.
---@param song renoise.Song
---@param archive ZipArchive
---@return JobTask[] tasks, integer skipped
function Job:collect(song, archive)
  local tasks, skipped = {}, 0
  for _, entry in ipairs(archive.entries) do
    local parsed = song_file.parse(entry.name)
    if parsed and song_file.is_encodable(entry.name) then
      local instrument = song.instruments[parsed.instrument]
      local sample = instrument and instrument.samples[parsed.sample]
      local buffer = sample and sample.sample_buffer
      local ok = buffer ~= nil and buffer.has_sample_data
      if ok and parsed.ext == "flac" then
        local shape = {
          sample_rate = buffer.sample_rate,
          channels = buffer.number_of_channels,
          frames = buffer.number_of_frames,
        }
        local info = nil
        if entry.method == 0 then
          info = song_file.flac_info(zip.read_raw(self.source, entry, 42))
        end
        ok = song_file.matches(info, shape)
      end
      if ok then
        tasks[#tasks + 1] = {
          id = ("%04d"):format(#tasks + 1),
          entry = entry,
          sample = sample --[[@as renoise.Sample]],
          name = sample and sample.name or "?",
        }
      else
        skipped = skipped + 1
        self:note(
          ("Skipped %s: no matching sample in the song, so it stays as it is."):format(
            entry.name:match "[^/]+$" or entry.name
          )
        )
      end
    end
  end
  return tasks, skipped
end

---Yield when this tick's time is used up. Raises "cancelled" when asked to stop.
function Job:pause()
  if self.cancel_requested then
    error("cancelled", 0)
  end
  if os.clock() > self.deadline then
    coroutine.yield()
    if self.cancel_requested then
      error("cancelled", 0)
    end
  end
end

function Job:export_samples()
  local total = #self.tasks
  for i, task in ipairs(self.tasks) do
    self:set("export", labels.progress("Exporting", i, total), 0.1 * (i - 1) / total)
    local wav = join(self.work_dir, task.id .. ".wav")
    if not task.sample.sample_buffer:save_as(wav, "wav") then
      error("could not export the sample " .. task.sample.name, 0)
    end
    self:pause()
  end
end

function Job:start_encoder()
  local platform = os.platform()
  local steps = {}
  for _, task in ipairs(self.tasks) do
    steps[#steps + 1] = {
      id = task.id,
      command = encoder.command(
        self.kind,
        self.encoder_path,
        self.quality,
        task.id .. ".wav",
        task.id .. ".ogg",
        platform
      ),
    }
  end
  write_text(
    join(self.work_dir, encoder.script_name(platform)),
    encoder.script(steps, platform, self.work_dir)
  )
  local cmd = encoder.launch_command(platform, self.work_dir)
  self.app.log("launch: " .. cmd)
  if platform == "WINDOWS" then
    -- io.popen returns at once; os.execute would block while a console opens.
    -- The pipe is closed when the job has finished.
    self.pipe = io.popen(cmd)
  else
    os.execute(cmd)
  end
  self.launched_at = os.clock()
  self.next_done = 1
  self:set("encode", labels.progress("Encoding", 0, #self.tasks), 0.1)
end

---Poll the marker files of the job script.
function Job:poll_encoder()
  local total = #self.tasks
  if self.phase == "cancelling" then
    local finished = io.exists(join(self.work_dir, "finished"))
    if finished or os.clock() - self.cancel_started > CANCEL_TIMEOUT_S then
      self:cleanup()
      self:note "Cancelled. No file was written."
      self:set("cancelled", "Cancelled. No file was written.", 0)
    end
    return
  end
  if not io.exists(join(self.work_dir, "started")) then
    if os.clock() - self.launched_at > START_TIMEOUT_S then
      self:fail "The encoder job did not start. Check the encoder path and try again."
    end
    return
  end
  local before = self.next_done
  while
    self.next_done <= total
    and io.exists(join(self.work_dir, self.tasks[self.next_done].id .. ".done"))
  do
    self.next_done = self.next_done + 1
  end
  local finished = io.exists(join(self.work_dir, "finished"))
  if self.next_done ~= before or finished then
    local n = self.next_done - 1
    self:set("encode", labels.progress("Encoding", n, total), 0.1 + 0.8 * n / total)
  end
  if finished then
    self:close_pipe()
    self:begin_coroutine("pack", self.pack)
  end
end

function Job:pack()
  local replacements, replaced, kept, failed = {}, 0, 0, 0
  local failures, kept_names = {}, {} ---@type { name: string, reason: string }[], string[]
  for _, task in ipairs(self.tasks) do
    local code = (read_text(join(self.work_dir, task.id .. ".done")) or ""):match "%-?%d+"
    local ogg = join(self.work_dir, task.id .. ".ogg")
    local size = code == "0" and file_size(ogg) or nil
    if not size then
      failed = failed + 1
      local log = read_text(join(self.work_dir, task.id .. ".log")) or ""
      failures[#failures + 1] = { name = task.name, reason = encoder.reason(log, code) }
    elseif song_file.should_replace(task.entry.compressed_size, size) then
      replacements[task.entry.name] = { name = song_file.ogg_name(task.entry.name), path = ogg }
      replaced = replaced + 1
    else
      kept = kept + 1
      kept_names[#kept_names + 1] = task.name
    end
  end
  if failed > 0 and failed == #self.tasks then
    error(("%s could not encode any sample. %s"):format(self.kind, failures[1].reason), 0)
  end
  for i, f in ipairs(failures) do
    if i > 3 then
      local rest = {}
      for j = 4, #failures do
        rest[#rest + 1] = failures[j].name
      end
      self:note(("%s also failed on %s."):format(self.kind, labels.names(rest, 5)))
      break
    end
    self:note(('%s failed on "%s": %s'):format(self.kind, f.name, f.reason))
  end
  if kept > 0 then
    self:note(
      ("Kept as they were, because OGG would be larger: %s."):format(labels.names(kept_names, 5))
    )
  end

  self:set("pack", "Writing the compressed song...", 0.9)
  self.part = self.target .. ".part"
  local result = zip.rewrite(self.source, self.part, replacements, function(done, total)
    self.progress = 0.9 + 0.1 * (total > 0 and done / total or 1)
    if os.clock() > self.deadline then
      self.on_update(self)
    end
    self:pause()
  end)
  if io.exists(self.target) then
    local ok, err = os.remove(self.target)
    if not ok then
      error("cannot replace " .. self.target .. ": " .. tostring(err), 0)
    end
  end
  local ok, err = os.move(self.part, self.target)
  if not ok then
    error("cannot write " .. self.target .. ": " .. tostring(err), 0)
  end
  self.part = nil
  self.report = {
    old_size = file_size(self.source) or 0,
    new_size = result.size,
    replaced = replaced,
    kept = kept,
    failed = failed,
    skipped = self.skipped,
  }
  self:cleanup()
  self:note(labels.report(self.target, self.report))
  self:note(
    ("The copy is for sharing. Keep working in %s: when Renoise saves the copy, it writes FLAC again, with the lossy sound."):format(
      self.source:match "[^/\\]+$" or self.source
    )
  )
  self:set("done", labels.report_headline(self.target), 1, labels.report_detail(self.report))
end

---Run `fn` as a coroutine, a slice per tick, in `phase`.
---@param phase string
---@param fn fun(self: Job)
function Job:begin_coroutine(phase, fn)
  self.phase = phase
  self.co = coroutine.create(function()
    fn(self)
  end)
end

---@param err any
function Job:on_error(err)
  local message = tostring(err)
  if message == "cancelled" then
    self:cleanup()
    self:note "Cancelled. No file was written."
    self:set("cancelled", "Cancelled. No file was written.", 0)
  else
    self.app.log("job failed: " .. message)
    self:fail(message)
  end
end

function Job:tick()
  if not self.cancel_requested and not self.keep_running() then
    self.app.log "dialog closed: cancelling the export"
    self:cancel()
  end
  if self.phase == "encode" or self.phase == "cancelling" then
    self:poll_encoder()
    if not self.co then
      return
    end
  end
  local co = self.co
  if co then
    self.deadline = os.clock() + BUDGET_S
    local ok, err = coroutine.resume(co)
    if not ok then
      self.co = nil
      self:on_error(err)
    elseif coroutine.status(co) == "dead" and self.co == co then
      self.co = nil
      if self.phase == "export" then
        local start_ok, start_err = pcall(self.start_encoder, self)
        if not start_ok then
          self:on_error(start_err)
        end
      end
    end
  end
end

-- Starting ----------------------------------------------------------------------

---Check the inputs. Returns an error message for the status line, or nil.
---@param opts { target: string|nil, encoder_path: string }
---@return string|nil
function M.check(opts)
  local song = renoise.song()
  if not song then
    return "There is no song to export."
  end
  if song.file_name == "" then
    return "Save the song first: File > Save Song As..."
  end
  local path = opts.encoder_path
  if path == "" then
    return "Choose an encoder first: oggenc, ffmpeg or sox."
  end
  if not io.exists(path) then
    return "The encoder was not found: " .. path
  end
  if not encoder.kind(path) then
    return "Unknown encoder. Choose oggenc, ffmpeg or sox."
  end
  if opts.target and same_path_key(opts.target) == same_path_key(song.file_name) then
    return "Choose another file name: the compressed copy cannot replace the song itself."
  end
  return nil
end

---Save the song, read it, and start the export. Returns the running job, or
---nil and an error message.
---@param opts JobOptions
---@return Job|nil job, string|nil err
function M.start(opts)
  local problem = M.check(opts)
  if problem then
    return nil, problem
  end
  local song = renoise.song() --[[@as renoise.Song]]

  -- The open song stays lossless and keeps its name: save it as it is, then
  -- build the copy from that file.
  renoise.app():save_song()
  local source = song.file_name
  local saved = io.stat(source)
  -- Renoise shows its own message when saving fails; the file is then older.
  if not saved or os.time() - saved.mtime > 30 then
    return nil, "The song could not be saved, so there is nothing current to export."
  end

  local job = setmetatable({
    app = opts.app,
    on_update = opts.on_update,
    on_log = opts.on_log,
    keep_running = opts.keep_running,
    target = opts.target,
    encoder_path = opts.encoder_path,
    kind = encoder.kind(opts.encoder_path),
    quality = opts.quality,
    source = source,
    phase = "export",
    message = "Reading the song...",
    detail = "",
    progress = 0,
  }, Job)

  local ok, err = pcall(function()
    local archive = zip.read_entries(source)
    job.tasks, job.skipped = job:collect(song, archive)
    job.work_dir = make_work_dir()
  end)
  if not ok then
    job:cleanup()
    return nil, tostring(err)
  end
  if #job.tasks == 0 then
    job:cleanup()
    return nil, "This song has no samples to compress."
  end

  job:begin_coroutine("export", job.export_samples)
  job:note(
    ("Saved %s (%s). Encoding %s with %s at quality %g."):format(
      source:match "[^/\\]+$" or source,
      labels.size(saved.size),
      labels.count(#job.tasks, "sample"),
      job.kind,
      job.quality
    )
  )
  job.tick_fn = opts.app.guard(function()
    local tick_ok, tick_err = pcall(job.tick, job)
    if not tick_ok then
      job:on_error(tick_err)
    end
  end)
  opts.app.reg.timer(job.tick_fn, TICK_MS)
  job:set("export", "Exporting samples...", 0)
  return job, nil
end

return M
