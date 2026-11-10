--[[
  The Export Compressed Song dialog. `build` returns the builder (so the dev
  bridge can map ids to views) and the root view; `show_job` and
  `show_message` update it while an export runs; `show_found` and
  `add_log` show the encoder search and the message log.
]]

local encoder = require "src.encoder"
local labels = require "src.labels"

local M = {}

local BUTTON_HEIGHT = renoise.ViewBuilder.DEFAULT_DIALOG_BUTTON_HEIGHT

local WIDTH = 480 -- content width inside the dialog margin
local DIALOG_MARGIN = 12
local SECTION = 10 -- between the groups
local PAD = 10 -- inside a group
local LINE = 6 -- between the rows of a group
local GAP = 4 -- between the controls of a row
local CONTROL = 22 -- height of fields, buttons and the slider
local GROUP_INNER = WIDTH - 2 * PAD
local TITLE = 90 -- group title; the rest of that row shows the group's state
local LABEL = 60 -- left label column of the encoder rows
local FIELD = GROUP_INNER - LABEL - GAP
local BROWSE = 84
local FIND = 60
local CANCEL = 84
local SAVE = 104
local REVEAL = 116
local STATUS = WIDTH - CANCEL - SAVE - GAP - 12 -- status line beside the buttons
local STATUS_CHARS = 52 -- what fits in STATUS; bold text is wider
local STATUS_CHARS_BOLD = 44
local DETAIL_CHARS = 92 -- what fits in WIDTH
local DETAIL_CHARS_NARROW = 68 -- beside the "Show in folder" button
local LOG_HEIGHT = 104
local PLACEHOLDER = "Messages about the song, the encoder and the export show up here."

---Progress of the running job, 0..1, read by the canvas renderer.
local progress = 0
---@type "idle"|"running"|"done"|"failed"
local progress_state = "idle"

---@param ctx renoise.Views.Canvas.Context
local function render_progress(ctx)
  local w, h = ctx.size.width, ctx.size.height
  ctx:clear_rect(0, 0, w, h)
  ctx.fill_color = "button_back"
  ctx:fill_rect(0, 0, w, h)
  local filled = math.floor(w * math.max(0, math.min(1, progress)) + 0.5)
  if filled > 0 then
    if progress_state == "failed" then
      ctx.fill_color = "body_font"
    else
      ctx.fill_color = "selected_button_back"
    end
    ctx:fill_rect(0, 0, filled, h)
  end
end

---Samples in the song that have their own data (slice aliases share one).
---@param song renoise.Song|nil
---@return integer
local function count_samples(song)
  if not song then
    return 0
  end
  local n = 0
  for _, instrument in ipairs(song.instruments) do
    for _, sample in ipairs(instrument.samples) do
      if not sample.is_slice_alias and sample.sample_buffer.has_sample_data then
        n = n + 1
      end
    end
  end
  return n
end

---@return string
local function song_text()
  local song = renoise.song()
  if not song then
    return "Song: (none)"
  end
  local st = song.file_name ~= "" and io.stat(song.file_name) or nil
  return labels.song(song.file_name, st and st.size or nil, count_samples(song))
end

---@param vb renoise.ViewBuilder
---@param id string
---@return renoise.Views.View|nil
local function view(vb, id)
  return vb.views[id]
end

---Change a text and keep its width. A text view grows to fit a longer text and
---never shrinks again, which pushes its neighbours out of the group.
---@param text_view renoise.Views.Text
---@param text string
local function set_text(text_view, text)
  local width = text_view.width
  text_view.text = text
  text_view.width = width
end

---Update the encoder state in the title row of the Encoder group.
---@param vb renoise.ViewBuilder
---@param path string
function M.show_encoder(vb, path)
  local info = view(vb, "encoder_info") --[[@as renoise.Views.Text|nil]]
  local hint = view(vb, "encoder_hint") --[[@as renoise.Views.Text|nil]]
  local link = view(vb, "encoder_link") --[[@as renoise.Views.TextLink|nil]]
  if not (info and hint and link) then
    return
  end
  local kind = path ~= "" and encoder.kind(path) or nil
  local show_hint = false
  if path == "" then
    set_text(info, "No encoder chosen. Find searches this computer for one.")
    info.style = "strong"
    show_hint = true
  elseif not io.exists(path) then
    set_text(info, "This file does not exist.")
    info.style = "strong"
    show_hint = true
  elseif not kind then
    set_text(info, "Unknown program. Choose oggenc, ffmpeg or sox.")
    info.style = "strong"
    show_hint = true
  else
    set_text(info, "Encoding with " .. kind .. ".")
    info.style = "normal"
  end
  local h = encoder.download_hint(os.platform())
  set_text(hint, h.text)
  hint.visible = show_hint
  link.visible = show_hint
end

---Show the open song's name, size and sample count again. The song line goes
---stale when the song is saved or samples change while the dialog is open.
---@param vb renoise.ViewBuilder
function M.show_song(vb)
  local song_info = view(vb, "song_info") --[[@as renoise.Views.Text|nil]]
  if song_info then
    set_text(song_info, song_text())
  end
end

---Whether the log still shows its placeholder text.
local has_placeholder = true

---Append a line to the message log.
---@param vb renoise.ViewBuilder
---@param line string
function M.add_log(vb, line)
  local log = view(vb, "log") --[[@as renoise.Views.MultiLineText|nil]]
  if not log then
    return
  end
  if has_placeholder then
    log.text = line -- add_line after clear() would leave an empty first line
    has_placeholder = false
  else
    log:add_line(line)
  end
  log:scroll_to_last_line()
end

---Fill the drop-down of found encoders (shown when there is a choice).
---@param vb renoise.ViewBuilder
---@param found string[]
---@param current string
function M.show_found(vb, found, current)
  local popup = view(vb, "found") --[[@as renoise.Views.Popup|nil]]
  local row = view(vb, "found_row")
  if not (popup and row) then
    return
  end
  local finder = require "src.finder"
  local items, index = {}, 1
  for i, p in ipairs(found) do
    items[i] = finder.label(p)
    if p == current then
      index = i
    end
  end
  popup.items = items
  if #items > 0 then
    popup.value = index
  end
  row.visible = #items >= 2
end

---Show what the encoder search is doing in the title row of the Encoder group.
---@param vb renoise.ViewBuilder
---@param text string
function M.show_search(vb, text)
  local info = view(vb, "encoder_info") --[[@as renoise.Views.Text|nil]]
  if info then
    set_text(info, text)
    info.style = "normal"
  end
end

---Show a message in the status line beside the buttons. A long message, or a
---`detail`, continues on a second line that appears below the buttons.
---@param vb renoise.ViewBuilder
---@param message string
---@param is_error boolean|nil
---@param detail string|nil Second line.
---@param with_reveal boolean|nil Show the "Show in folder" button beside the second line.
function M.show_message(vb, message, is_error, detail, with_reveal)
  local status = view(vb, "status") --[[@as renoise.Views.Text|nil]]
  local second = view(vb, "status_detail") --[[@as renoise.Views.Text|nil]]
  local row = view(vb, "detail_row")
  local reveal = view(vb, "reveal")
  if not (status and second and row and reveal) then
    return
  end
  -- A row that grew makes the dialog wider for good, so the row must never be
  -- wider than WIDTH: narrow the text before the button shows up.
  if with_reveal then
    second.width = WIDTH - REVEAL - GAP
    reveal.visible = true
  else
    reveal.visible = false
    second.width = WIDTH
  end
  local second_chars = with_reveal and DETAIL_CHARS_NARROW or DETAIL_CHARS
  local has_detail = detail ~= nil and detail ~= ""
  local first, rest
  if has_detail then
    first = labels.ellipsize(message, STATUS_CHARS_BOLD)
    rest = labels.ellipsize(detail --[[@as string]], second_chars)
  else
    first, rest = labels.split_lines(message, STATUS_CHARS, second_chars)
  end
  set_text(status, first)
  set_text(second, rest)
  -- Results stand out: an error, or the headline of a finished export.
  status.style = (is_error or has_detail) and "strong" or "normal"
  second.style = is_error and "strong" or "normal"
  status.font = has_detail and "bold" or "normal"
  row.visible = rest ~= "" or with_reveal == true
end

---Reflect a job's state in the dialog.
---@param vb renoise.ViewBuilder
---@param job Job
function M.show_job(vb, job)
  local running = job:running()
  progress = job.progress or 0
  if job.phase == "failed" then
    progress_state = "failed"
  elseif job.phase == "done" then
    progress_state = "done"
  elseif running then
    progress_state = "running"
  else
    progress_state = "idle"
  end
  local bar = view(vb, "progress") --[[@as renoise.Views.Canvas|nil]]
  if bar then
    bar:update()
  end
  M.show_message(vb, job.message, job.phase == "failed", job.detail, job.phase == "done")
  local function set_active(id, active)
    local v = view(vb, id)
    if v then
      ---@diagnostic disable-next-line: inject-field
      v.active = active
    end
  end
  set_active("save", not running)
  set_active("cancel", running and job.phase ~= "cancelling")
  set_active("quality", not running)
  set_active("encoder_path", not running)
  set_active("browse", not running)
  set_active("find", not running)
  set_active("found", not running)
  if job.phase == "done" then
    M.show_song(vb)
  end
end

---@param app table The application module (`src/app.lua`).
---@return renoise.ViewBuilder vb, renoise.Views.View root
function M.build(app)
  local vb = renoise.ViewBuilder()
  local prefs = app.prefs()
  progress, progress_state = 0, "idle"

  ---A framed group. Its first row is the title and, to the right, the group's
  ---current state (`state`, a text view of width GROUP_INNER - TITLE).
  ---@param title string
  ---@param state renoise.Views.Text|nil
  local function group(title, state, ...)
    return vb:column {
      background = "group",
      margin = PAD,
      spacing = LINE,
      width = WIDTH,
      vb:row {
        vb:text { text = title, font = "bold", style = "strong", width = TITLE },
        state or vb:space { width = GROUP_INNER - TITLE },
      },
      ...,
    }
  end

  ---A row of the Encoder group: a label, then controls that share FIELD.
  local function labelled(label, ...)
    return vb:row {
      spacing = GAP,
      vb:text { text = label, width = LABEL, height = CONTROL },
      ...,
    }
  end

  local half = math.floor(GROUP_INNER / 2)
  local quality_group = group(
    "Quality",
    vb:text {
      id = "quality_text",
      width = GROUP_INNER - TITLE,
      align = "right",
      font = "bold",
      text = labels.quality(prefs.quality.value),
    },
    vb:slider {
      id = "quality",
      width = GROUP_INNER,
      height = CONTROL,
      min = -1,
      max = 10,
      default = 6,
      value = labels.quality_step(prefs.quality.value),
      tooltip = "Vorbis quality, -1 (smallest) to 10 (best sound). 6 is a good start.",
      steps = { 1, 2 },
      notifier = app.guard(function(value)
        -- Renoise does not call a notifier again for a change made inside it,
        -- so update everything here, then snap the knob to the whole step.
        local step = labels.quality_step(value)
        prefs.quality.value = step
        set_text(vb.views.quality_text --[[@as renoise.Views.Text]], labels.quality(step))
        if step ~= value then
          local slider = vb.views.quality --[[@as renoise.Views.Slider]]
          slider.value = step
        end
      end),
    },
    vb:row {
      vb:text { text = "◂ Smaller file", width = half },
      vb:text { text = "Better sound ▸", width = GROUP_INNER - half, align = "right" },
    }
  )

  local encoder_group = group(
    "Encoder",
    vb:text { id = "encoder_info", width = GROUP_INNER - TITLE, align = "right", text = "" },
    labelled(
      "Program",
      vb:textfield {
        id = "encoder_path",
        width = FIELD - FIND - BROWSE - 2 * GAP,
        height = CONTROL,
        bind = prefs.encoder_path,
        tooltip = "Full path to oggenc, ffmpeg or sox. Saved for next time.",
      },
      vb:button {
        id = "find",
        text = "Find",
        width = FIND,
        height = CONTROL,
        tooltip = "Search this computer for oggenc, ffmpeg or sox, also inside other programs.",
        notifier = app.guard(app.find_encoders),
      },
      vb:button {
        id = "browse",
        text = "Browse...",
        width = BROWSE,
        height = CONTROL,
        notifier = app.guard(app.browse_encoder),
      }
    ),
    vb:row {
      id = "found_row",
      visible = false,
      labelled(
        "Found",
        vb:popup {
          id = "found",
          width = FIELD,
          height = CONTROL,
          items = {},
          tooltip = "Every encoder Find came across. The best kind comes first.",
          notifier = app.guard(function(index)
            local path = app.found and app.found[index]
            if path and path ~= prefs.encoder_path.value then
              prefs.encoder_path.value = path
            end
          end),
        }
      ),
    },
    vb:text { id = "encoder_hint", text = "", width = GROUP_INNER, visible = false },
    vb:link {
      id = "encoder_link",
      text = "Where to get an encoder ▸",
      visible = false,
      notifier = app.guard(function()
        renoise.app():open_url(encoder.download_hint(os.platform()).url)
      end),
    }
  )

  local messages = app.messages or {}
  local log_group = group(
    "Messages",
    nil,
    vb:multiline_text {
      id = "log",
      width = GROUP_INNER,
      height = LOG_HEIGHT,
      style = "border",
      text = #messages > 0 and table.concat(messages, "\n") or PLACEHOLDER,
    }
  )
  has_placeholder = #messages == 0

  -- The status shares a row with the buttons. The second line sits below them,
  -- so the buttons do not move when it appears.
  local footer = vb:column {
    spacing = LINE,
    width = WIDTH,
    vb:canvas {
      id = "progress",
      width = WIDTH,
      height = 6,
      mode = "transparent",
      render = render_progress,
    },
    vb:column {
      spacing = GAP,
      width = WIDTH,
      vb:horizontal_aligner {
        mode = "justify",
        width = WIDTH,
        vb:text { id = "status", text = "Ready.", width = STATUS, height = BUTTON_HEIGHT },
        vb:row {
          spacing = GAP,
          vb:button {
            id = "cancel",
            text = "Cancel",
            width = CANCEL,
            height = BUTTON_HEIGHT,
            active = false,
            notifier = app.guard(app.cancel),
          },
          vb:button {
            id = "save",
            text = "Save...",
            width = SAVE,
            height = BUTTON_HEIGHT,
            font = "bold",
            tooltip = "Save the song, then choose where to write the compressed copy.",
            notifier = app.guard(app.export),
          },
        },
      },
      vb:row {
        id = "detail_row",
        spacing = GAP,
        visible = false,
        vb:text { id = "status_detail", text = "", width = WIDTH, height = BUTTON_HEIGHT },
        vb:button {
          id = "reveal",
          text = "Show in folder",
          width = REVEAL,
          height = BUTTON_HEIGHT,
          visible = false,
          notifier = app.guard(function()
            local job = app.job
            if job and job.target then
              local folder = job.target:match "^(.*)[/\\]" or job.target
              renoise.app():open_path(folder)
            end
          end),
        },
      },
    },
  }

  local root = vb:column {
    id = "root",
    margin = DIALOG_MARGIN,
    spacing = SECTION,
    vb:column {
      spacing = 2,
      vb:text {
        id = "song_info",
        text = song_text(),
        font = "big",
        style = "strong",
        width = WIDTH,
      },
      vb:text {
        text = "Writes a copy of the song with its samples as OGG Vorbis.",
        width = WIDTH,
      },
    },
    quality_group,
    encoder_group,
    log_group,
    footer,
  }

  M.show_encoder(vb, prefs.encoder_path.value)
  M.show_found(vb, app.found or {}, prefs.encoder_path.value)
  local log = vb.views.log --[[@as renoise.Views.MultiLineText]]
  log:scroll_to_last_line()
  return vb, root
end

---Keep the encoder line in step with the preference (Browse, detection, typing).
---Registered once per tool start; looks up the open dialog when it fires.
---@param app table
function M.watch_encoder(app)
  app.reg.notifier(
    app.prefs().encoder_path,
    app.guard(function()
      local entry = app.dialogs.main
      if entry and entry.dialog.visible then
        M.show_encoder(entry.vb, app.prefs().encoder_path.value)
      end
    end)
  )
end

return M
