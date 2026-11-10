--[[
  Tests for src/labels.lua. Run with `just test` or `just test tests/labels_test.lua`.
]]

local t = require "tests.helper"
local labels = require "src.labels"

t.eq(labels.quality_step(5.4), 5, "quality_step: rounds down")
t.eq(labels.quality_step(5.5), 6, "quality_step: rounds up")
t.eq(labels.quality_step(-3), -1, "quality_step: clamps low")
t.eq(labels.quality_step(11), 10, "quality_step: clamps high")

t.eq(labels.quality(-1), "-1 · smallest · ~45 kbps", "quality: -1")
t.eq(labels.quality(3), "3 · balanced · ~112 kbps", "quality: 3")
t.eq(labels.quality(6), "6 · good · ~192 kbps", "quality: 6")
t.eq(labels.quality(10), "10 · highest · ~500 kbps", "quality: 10")

t.eq(labels.size(287), "287 bytes", "size: bytes")
t.eq(labels.size(4094), "4.0 KB", "size: KB")
t.eq(labels.size(4162847), "3.97 MB", "size: MB")
t.eq(labels.size(1288490189), "1.20 GB", "size: GB")

t.eq(labels.size_change(4162847, 618660), "3.97 MB → 0.59 MB", "size_change: MB")
t.eq(labels.size_change(300, 4094), "0.3 KB → 4.0 KB", "size_change: larger target")

t.eq(labels.count(1, "sample"), "1 sample", "count: one")
t.eq(labels.count(52, "sample"), "52 samples", "count: many")

t.eq(labels.song("", nil, 3), "Song: not saved yet · 3 samples", "song: unsaved")
t.eq(
  labels.song([[C:\Music\Demo.xrns]], 4162847, 52),
  "Song: Demo.xrns · 3.97 MB · 52 samples",
  "song: windows path"
)
t.eq(labels.song("/m/Demo.xrns", nil, 1), "Song: Demo.xrns · 1 sample", "song: no size")

t.eq(
  labels.report("/m/Demo-ogg.xrns", {
    old_size = 4162847,
    new_size = 618660,
    replaced = 37,
    kept = 15,
    failed = 0,
    skipped = 0,
  }),
  "Saved Demo-ogg.xrns: 3.97 MB → 0.59 MB (15%) · 37 samples as OGG, 15 kept unchanged.",
  "report: typical"
)
t.eq(
  labels.report(
    "x.xrns",
    { old_size = 100, new_size = 100, replaced = 0, kept = 0, failed = 2, skipped = 0 }
  ),
  "Saved x.xrns: 100 bytes → 100 bytes (100%) · 0 samples as OGG, 2 kept unchanged."
    .. " The encoder failed on 2 samples.",
  "report: failures"
)
t.eq(
  labels.report(
    "x.xrns",
    { old_size = 0, new_size = 0, replaced = 1, kept = 0, failed = 0, skipped = 0 }
  ),
  "Saved x.xrns: 0 bytes → 0 bytes (100%) · 1 sample as OGG.",
  "report: empty song"
)

t.eq(labels.report_headline [[C:\Out\Song (OGG).xrns]], "Saved Song (OGG).xrns", "headline")
t.eq(labels.ellipsize("short", 10), "short", "ellipsize: short text unchanged")
t.eq(labels.ellipsize("abcdefghijkl", 7), "abc…jkl", "ellipsize: keeps both ends")
t.eq(labels.ellipsize("ääääääää", 5), "ää…ää", "ellipsize: counts UTF-8 characters")

local l1, l2 = labels.split_lines("Short.", 20)
t.eq(l1 .. "|" .. l2, "Short.|", "split_lines: fits")
l1, l2 = labels.split_lines("ffmpeg could not encode. This ffmpeg lacks libvorbis.", 30)
t.eq(
  l1 .. "|" .. l2,
  "ffmpeg could not encode.|This ffmpeg lacks libvorbis.",
  "split_lines: sentence"
)
l1, l2 = labels.split_lines("one two three four five six", 12)
t.eq(l1 .. "|" .. l2, "one two|three …e six", "split_lines: at a space, rest shortened")
l1, l2 = labels.split_lines("abcdefghijklmnop", 10)
t.eq(l1 .. "|" .. l2, "abcdefghij|klmnop", "split_lines: no space")

t.eq(labels.names({}, 3), "", "names: none")
t.eq(labels.names({ "Kick" }, 3), '"Kick"', "names: one")
t.eq(labels.names({ "Kick", "Snare" }, 3), '"Kick" and "Snare"', "names: two")
t.eq(labels.names({ "a", "b", "c" }, 3), '"a", "b" and "c"', "names: all shown")
t.eq(labels.names({ "a", "b", "c", "d", "e" }, 2), '"a", "b" and 3 more', "names: more")

t.eq(labels.progress("Encoding", 12, 52), "Encoding 12 of 52 samples...", "progress")

t.done()
