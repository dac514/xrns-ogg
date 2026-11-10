--[[
  Application module. Owns everything the tool registers with Renoise (menu
  entries, key bindings, notifiers, timers, dialogs) so that it can be started
  and stopped cleanly. That is what makes the dev bridge's soft reload safe:
  `APP.stop()` on the old module, re-require `src/`, `APP.start()` on the new one.

  Rules:
  * Register only through `App.reg.*` and `App.register_dialog`.
  * No side effects at module level; do them in `App.start()`.
  * `App.start()` can run while Renoise is still starting, when reading
    `renoise.app().theme` raises an error. Register `renoise.app()`
    observables when a dialog first opens instead.
  * Wrap callbacks that Renoise invokes with `App.guard` so errors reach the
    dev log.
  * Inside song list notifiers, read dependents through `App.defer`.
]]

local App = {}

---@class ExportCompressedSongPreferences : renoise.Document.DocumentNode
---@field quality renoise.Document.ObservableNumber Vorbis quality, -1 to 10.
---@field encoder_path renoise.Document.ObservableString oggenc, ffmpeg or sox.

App.name = "Export Compressed Song"
App.menu_entry = "Main Menu:File:Export Compressed Song..."
App.keybinding = "Global:Tools:Export Compressed Song..."
App.browse_title = "Choose oggenc, ffmpeg or sox"
App.target_title = "Export Compressed Song"

---@class AppDialogEntry
---@field dialog renoise.Dialog
---@field vb renoise.ViewBuilder
---@field root renoise.Views.View

---Registered dialogs by name. Read by the dev bridge's `views` command.
---@type table<string, AppDialogEntry>
App.dialogs = {}

---Log sink. The dev bridge replaces it to capture messages into its ring buffer.
---@type fun(kind: string, text: string)
App.log_sink = function(kind, text)
  print(("[%s] %s"):format(kind, text))
end

---Replace the log sink (used by the dev bridge).
---@param sink fun(kind: string, text: string)
function App.set_log_sink(sink)
  App.log_sink = sink
end

---@param text string
function App.log(text)
  App.log_sink("app", text)
end

---@return ExportCompressedSongPreferences
function App.prefs()
  return renoise.tool().preferences --[[@as ExportCompressedSongPreferences]]
end

---Wrap a callback so that errors are logged before being re-raised.
---@generic F : function
---@param fn F
---@return F
function App.guard(fn)
  return function(...)
    local n = select("#", ...)
    local args = { ... }
    local results = {
      xpcall(function()
        return fn(unpack(args, 1, n))
      end, function(err)
        return debug.traceback(tostring(err), 2)
      end),
    }
    if not results[1] then
      local message = results[2] and tostring(results[2]) or "unknown error"
      App.log_sink("error", message)
      error(message, 0)
    end
    return unpack(results, 2)
  end
end

-- Registration ---------------------------------------------------------------

---Registration helpers. Everything registered here is undone by `App.stop()`.
local reg = {
  ---@type string[]
  menus = {},
  ---@type string[]
  keys = {},
  ---@type { observable: renoise.Document.Observable, fn: function }[]
  notifiers = {},
  ---@type function[]
  timers = {},
}
App.reg = reg

---@param entry ToolMenuEntry
function reg.menu(entry)
  local tool = renoise.tool()
  if tool:has_menu_entry(entry.name) then
    tool:remove_menu_entry(entry.name)
  end
  tool:add_menu_entry(entry)
  table.insert(reg.menus, entry.name)
end

---@param binding ToolKeybindingEntry
function reg.key(binding)
  local tool = renoise.tool()
  if tool:has_keybinding(binding.name) then
    tool:remove_keybinding(binding.name)
  end
  tool:add_keybinding(binding)
  table.insert(reg.keys, binding.name)
end

---@param observable renoise.Document.Observable
---@param fn function
function reg.notifier(observable, fn)
  if observable:has_notifier(fn) then
    return -- already registered and tracked; safe to call again on refresh
  end
  observable:add_notifier(fn)
  table.insert(reg.notifiers, { observable = observable, fn = fn })
end

---@param fn function
---@param interval_ms integer
function reg.timer(fn, interval_ms)
  local tool = renoise.tool()
  if tool:has_timer(fn) then
    tool:remove_timer(fn)
  end
  tool:add_timer(fn, interval_ms)
  table.insert(reg.timers, fn)
end

-- Deferral -------------------------------------------------------------------

---@type fun()[]
local deferred = {}

local function run_deferred()
  renoise.tool().app_idle_observable:remove_notifier(run_deferred)
  local queue = deferred
  deferred = {}
  for _, fn in ipairs(queue) do
    pcall(App.guard(fn)) -- guard logs the error, pcall keeps the queue going
  end
end

---Queue `fn` (once) for the next idle tick, after Renoise has finished the
---current operation. Song list notifiers (`tracks_observable`,
---`instruments_observable`, `sequencer.pattern_sequence_observable`,
---`phrase_mappings_observable`) fire *during* the edit: inside them the list is
---updated but patterns, sequence and selection are not, and the song must not
---be modified. Observe the dependent object when it has an observable;
---otherwise defer the work with this.
---https://forum.renoise.com/t/79511  https://forum.renoise.com/t/33796/11
---@param fn fun()
function App.defer(fn)
  if table.find(deferred, fn) then
    return
  end
  table.insert(deferred, fn)
  local idle = renoise.tool().app_idle_observable
  if not idle:has_notifier(run_deferred) then
    idle:add_notifier(run_deferred)
  end
end

-- Dialogs --------------------------------------------------------------------

---@param name string
---@param dialog renoise.Dialog
---@param vb renoise.ViewBuilder
---@param root renoise.Views.View
function App.register_dialog(name, dialog, vb, root)
  App.dialogs[name] = { dialog = dialog, vb = vb, root = root }
end

function App.close_dialogs()
  for name, entry in pairs(App.dialogs) do
    if entry.dialog.visible then
      entry.dialog:close()
    end
    App.dialogs[name] = nil
  end
end

-- Messages --------------------------------------------------------------------

---Lines of the dialog's message log, kept while the tool runs.
---@type string[]
App.messages = {}
local MAX_MESSAGES = 200

---Add a line to the message log (and the dev log).
---@param text string
function App.note(text)
  local line = os.date "%H:%M  " .. text
  App.messages[#App.messages + 1] = line
  if #App.messages > MAX_MESSAGES then
    table.remove(App.messages, 1)
  end
  App.log(text)
  local entry = App.dialogs.main
  if entry and entry.dialog.visible then
    require("src.ui").add_log(entry.vb, line)
  end
end

-- Encoder -----------------------------------------------------------------------

---Encoders that Find came across, best first.
---@type string[]
App.found = {}

---@type fun()|nil
local search_tick = nil

---@param text string
local function show_search(text)
  local entry = App.dialogs.main
  if entry and entry.dialog.visible then
    require("src.ui").show_search(entry.vb, text)
  end
end

local function stop_search()
  local tool = renoise.tool()
  if search_tick and tool:has_timer(search_tick) then
    tool:remove_timer(search_tick)
  end
  search_tick = nil
end

---@return boolean
function App.searching()
  return search_tick ~= nil
end

---@param found string[]
---@param visited integer
local function search_done(found, visited)
  App.found = found
  local prefs = App.prefs()
  local labels = require "src.labels"
  if #found == 0 then
    App.note(("Find: no oggenc, ffmpeg or sox in %s."):format(labels.count(visited, "folder")))
  else
    App.note(
      ("Find: %s in %s."):format(labels.count(#found, "encoder"), labels.count(visited, "folder"))
    )
    for _, p in ipairs(found) do
      App.note("  " .. p)
    end
    if prefs.encoder_path.value ~= found[1] then
      prefs.encoder_path.value = found[1]
    end
  end
  local entry = App.dialogs.main
  if entry and entry.dialog.visible then
    local ui = require "src.ui"
    ui.show_encoder(entry.vb, prefs.encoder_path.value)
    ui.show_found(entry.vb, found, prefs.encoder_path.value)
  end
end

---Search this computer for an encoder, a slice per timer tick, and use the
---best one found. Stops when the dialog closes.
function App.find_encoders()
  if search_tick then
    return
  end
  local finder = require "src.finder"
  local platform = os.platform()
  local roots = finder.roots(platform, os.getenv)
  local fs = { dirnames = os.dirnames, filenames = os.filenames }
  local deadline = 0
  local co = coroutine.create(function()
    return finder.search(platform, roots, fs, function(visited)
      if os.clock() > deadline then
        coroutine.yield(visited)
      end
      local entry = App.dialogs.main
      return not (entry and entry.dialog.visible)
    end)
  end)
  App.note "Find: searching this computer for an encoder..."
  show_search "Searching..."
  search_tick = App.guard(function()
    deadline = os.clock() + 0.025
    local ok, a, b = coroutine.resume(co)
    if not ok then
      stop_search()
      App.note("Find failed: " .. tostring(a))
      show_search "The search failed."
    elseif coroutine.status(co) == "dead" then
      stop_search()
      search_done(a, b)
    else
      show_search(("Searching... %d folders"):format(a or 0))
    end
  end)
  App.reg.timer(search_tick, 30)
end

---Fill in the encoder path when it is empty or the file is gone, from the
---search path and the usual install folders.
---@return string|nil path The encoder found, or nil.
function App.detect_encoder()
  local prefs = App.prefs()
  local current = prefs.encoder_path.value
  if current ~= "" and io.exists(current) then
    return current
  end
  local encoder = require "src.encoder"
  local found = encoder.find(os.platform(), os.getenv, io.exists)
  if found then
    prefs.encoder_path.value = found
    App.note("Found " .. found)
  end
  return found
end

---Let the user pick the encoder program.
function App.browse_encoder()
  local extensions = os.platform() == "WINDOWS" and { "exe" } or { "*" }
  local path = renoise.app():prompt_for_filename_to_read(extensions, App.browse_title)
  if path ~= "" then
    App.prefs().encoder_path.value = path
  end
end

---The running or last job.
---@type Job|nil
App.job = nil

---@param job Job
local function on_job_update(job)
  local entry = App.dialogs.main
  if entry and entry.dialog.visible then
    require("src.ui").show_job(entry.vb, job)
  end
  if job.phase == "done" or job.phase == "failed" or job.phase == "cancelled" then
    local detail = job.detail ~= "" and (": " .. job.detail) or ""
    renoise.app():show_status(App.name .. ": " .. job.message .. detail)
  end
end

---@param message string
local function show_problem(message)
  App.note(message)
  local entry = App.dialogs.main
  if entry and entry.dialog.visible then
    require("src.ui").show_message(entry.vb, message, true)
  end
  renoise.app():show_status(App.name .. ": " .. message)
end

---Ask for a target file, then start the export.
---@param target string|nil Skip the file prompt and write here (scripting, tests).
function App.export(target)
  if App.job and App.job:running() then
    return
  end
  local job_module = require "src.job"
  local prefs = App.prefs()
  local problem = job_module.check { encoder_path = prefs.encoder_path.value }
  if problem then
    show_problem(problem)
    return
  end
  if type(target) ~= "string" then
    target = renoise.app():prompt_for_filename_to_write("xrns", App.target_title)
  end
  if target == "" then
    return
  end
  if not target:lower():match "%.xrns$" then
    target = target .. ".xrns"
  end
  local labels = require "src.labels"
  local job, err = job_module.start {
    app = App,
    target = target,
    encoder_path = prefs.encoder_path.value,
    quality = labels.quality_step(prefs.quality.value),
    on_update = on_job_update,
    on_log = App.note,
    keep_running = function()
      local entry = App.dialogs.main
      return entry ~= nil and entry.dialog.visible
    end,
  }
  if not job then
    show_problem(err or "The export could not start.")
    return
  end
  App.job = job
end

---Stop the running export.
function App.cancel()
  if App.job then
    App.job:cancel()
  end
end

---Show the main dialog, creating it if needed.
function App.show_dialog()
  local existing = App.dialogs.main
  if existing and existing.dialog.visible then
    existing.dialog:show()
    return
  end
  App.detect_encoder()
  local ui = require "src.ui"
  local vb, root = ui.build(App)
  local dialog = renoise.app():show_custom_dialog(App.name, root)
  App.register_dialog("main", dialog, vb, root)
  if App.job and App.job:running() then
    ui.show_job(vb, App.job)
  end
  local path = App.prefs().encoder_path.value
  if path == "" or not io.exists(path) then
    App.find_encoders() -- nothing on the search path: look further, in the background
  end
end

-- Lifecycle ------------------------------------------------------------------

function App.start()
  reg.menu {
    name = App.menu_entry,
    invoke = App.guard(App.show_dialog),
  }
  reg.key {
    name = App.keybinding,
    invoke = App.guard(App.show_dialog),
  }
  -- Close dialogs when the song changes so no view keeps stale song references.
  reg.notifier(renoise.tool().app_new_document_observable, App.close_dialogs)
  require("src.ui").watch_encoder(App)
  App.log "started"
end

function App.stop()
  stop_search()
  if App.job then
    App.job:cancel()
  end
  App.close_dialogs()
  local tool = renoise.tool()
  for _, name in ipairs(reg.menus) do
    if tool:has_menu_entry(name) then
      tool:remove_menu_entry(name)
    end
  end
  for _, name in ipairs(reg.keys) do
    if tool:has_keybinding(name) then
      tool:remove_keybinding(name)
    end
  end
  for _, n in ipairs(reg.notifiers) do
    -- The observable may belong to a song that no longer exists.
    pcall(function()
      if n.observable:has_notifier(n.fn) then
        n.observable:remove_notifier(n.fn)
      end
    end)
  end
  for _, fn in ipairs(reg.timers) do
    if tool:has_timer(fn) then
      tool:remove_timer(fn)
    end
  end
  deferred = {}
  if tool.app_idle_observable:has_notifier(run_deferred) then
    tool.app_idle_observable:remove_notifier(run_deferred)
  end
  reg.menus, reg.keys, reg.notifiers, reg.timers = {}, {}, {}, {}
  App.log "stopped"
end

return App
