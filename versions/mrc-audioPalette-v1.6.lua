--[[
  mrc-audioPalette-v1.6.lua
  =========================================================================
  Colour-based audio clip organiser for DaVinci Resolve 21.x.
  Script version: 1.6   (history kept in the versions\ folder)

  One window, five stacked sections:
    1. Main Audio  -- classify selected audio clips into Voiceover / Music /
                      SFX / Ambience, tick clips, colour them.
    2. Invert      -- every audio clip on the timeline that is NOT in the
                      excluded buckets (your selection does not matter).
    3. Group By    -- hand-picked groups with their own colour pool.
    4. Selected Rows -- rename or colour only the checked rows.
    5. Audio Tracks -- tick tracks directly, save named track groups, then colour.

  Rules learned from the working scripts in this folder:
    * Handlers are wired before the list is populated, and the list fill is
      guarded so the change events it fires are ignored.
    * The list is a ui:Tree with a checkbox per row. CheckState is read on
      demand (when an action runs), never trusted from change events, because
      those are unreliable on this build.
    * Colour writes are verified by read-back; SetClipColor's return value
      cannot be trusted (it returns nil on success).
    * "No colour" is restored with ClearClipColor(), not SetClipColor("").
    * Clip identity uses GetUniqueId() when available.
    * Every write is snapshotted first, so Revert can put the timeline back.
    * Suggestions never auto-apply.

  INSTALL
    %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\
    then Workspace > Scripts > Utility > mrchauhan-audio-palette.

  STATE FILES (next to this script)
    mrc-audioPalette-memory.state    per-project buckets + groups
    mrc-audioPalette-snapshot.state  last colour pass, for Revert
]]

-- =========================================================================
-- Helpers
-- =========================================================================
local function trim(s)
  s = tostring(s or "")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function clip_text(s, n)
  s = tostring(s or "")
  if #s <= n then return s end
  return s:sub(1, n - 3) .. "..."
end

local function q(s)
  s = tostring(s or "")
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    if c == "\\" then return "\\\\" end
    if c == '"' then return '\\"' end
    return string.format("\\%03d", string.byte(c))
  end) .. '"'
end

local function ser(v, indent)
  indent = indent or ""
  local kind = type(v)
  if kind == "string" then return q(v) end
  if kind == "number" then return tostring(v) end
  if kind == "boolean" then return tostring(v) end
  if kind ~= "table" then return "nil" end

  local parts, inner = {}, indent .. "  "
  for k, value in pairs(v) do
    local key
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      key = k .. " = "
    elseif type(k) == "string" then
      key = "[" .. q(k) .. "] = "
    else
      key = "[" .. tostring(k) .. "] = "
    end
    parts[#parts + 1] = inner .. key .. ser(value, inner)
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function save_table(path, value)
  local f = io.open(path, "w")
  if not f then return false end
  f:write("return " .. ser(value) .. "\n")
  f:close()
  return true
end

local function load_table(path)
  local chunk = loadfile(path)
  if not chunk then return nil end
  local ok, value = pcall(chunk)
  if ok and type(value) == "table" then return value end
  return nil
end

local function script_dir()
  local src = (debug.getinfo(1, "S") or {}).source or ""
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return src:match("^(.*)[\\/][^\\/]+$") or (os.getenv("TEMP") or ".")
end

local DIR = script_dir()
local MEMORY_PATH = DIR .. "\\mrc-audioPalette-memory.state"
local SNAPSHOT_PATH = DIR .. "\\mrc-audioPalette-snapshot.state"
local LEGACY_MEMORY_PATH = DIR .. "\\clipsorter-memory.state"
local LEGACY_SNAPSHOT_PATH = DIR .. "\\clipsorter-snapshot.state"

-- Resolve returns array-like tables that may also carry string keys; keep the
-- real objects only (same helper the Copy Preset Attributes script uses).
local function objectsOf(t)
  local out = {}
  for _, v in pairs(t or {}) do
    local ty = type(v)
    if ty ~= "number" and ty ~= "string" and ty ~= "boolean" then
      out[#out + 1] = v
    end
  end
  return out
end

-- =========================================================================
-- Resolve / Fusion bootstrap
-- =========================================================================
local resolve
do
  local ok, r = pcall(function() return _G.resolve end)
  if ok and r and type(r) ~= "boolean" then resolve = r end
  if resolve == nil then
    ok, r = pcall(function() return Resolve() end)
    if ok and r then resolve = r end
  end
end
if resolve == nil then
  print("mrc-audioPalette: no Resolve object. Run from Workspace > Scripts.")
  return
end

local fusion
do
  local ok, f = pcall(function() return resolve:Fusion() end)
  if ok then fusion = f end
end

local ui, disp
if fusion then
  local ok, manager = pcall(function() return fusion.UIManager end)
  if ok and manager ~= nil then ui = manager end
end
if ui and type(bmd) == "table" and bmd.UIDispatcher then
  local ok, d = pcall(bmd.UIDispatcher, ui)
  if ok then disp = d end
end
if not ui or not disp then
  print("mrc-audioPalette: UIManager unavailable in this context.")
  return
end

local project, timeline
do
  local ok, p = pcall(function() return resolve:GetCurrentProject() end)
  if ok then project = p end
  if project then
    local tok, t = pcall(function() return project:GetCurrentTimeline() end)
    if tok then timeline = t end
  end
end
if not project or not timeline then
  print("mrc-audioPalette: open a project and a timeline first.")
  return
end

local PROJECT = "Untitled"
do
  local ok, n = pcall(function() return project:GetName() end)
  if ok and n then PROJECT = tostring(n) end
end

local VERSION = "?"
do
  local ok, v = pcall(function() return resolve:GetVersion() end)
  if ok and type(v) == "table" then
    VERSION = ("%s.%s.%s"):format(tostring(v[1]), tostring(v[2]), tostring(v[3]))
  end
end

-- =========================================================================
-- Colours
-- =========================================================================
-- 16 names verified against Resolve 21.1.0.14 on this machine ("Red" is not
-- accepted by SetClipColor here).
local COLORS = {
  "Orange", "Apricot", "Yellow", "Lime", "Olive", "Green", "Teal", "Navy",
  "Blue", "Purple", "Violet", "Pink", "Tan", "Beige", "Brown", "Chocolate",
}

local function read_color(item)
  local ok, c = pcall(function() return item:GetClipColor() end)
  if ok and type(c) == "string" then return c end
  return ""
end

local function set_color(item, name)
  pcall(function() item:SetClipColor(name) end)
  local now = read_color(item)
  return now == name, now
end

local function clear_color(item)
  local ok = pcall(function() item:ClearClipColor() end)
  local now = read_color(item)
  return ok and now == "", now
end

-- =========================================================================
-- Timeline access
-- =========================================================================
local function get_name(item)
  local ok, n = pcall(function() return item:GetName() end)
  if ok and n then return tostring(n) end
  return "?"
end

local function get_track_name(index)
  local ok, name = pcall(function() return timeline:GetTrackName("audio", index) end)
  name = ok and trim(name) or ""
  return name ~= "" and name or ("Audio " .. tostring(index))
end

local function set_track_name(index, name)
  local ok = pcall(function() return timeline:SetTrackName("audio", index, name) end)
  return ok and get_track_name(index) == name
end

local function set_name(item, name)
  local ok = pcall(function() item:SetName(name) end)
  local now = get_name(item)
  return ok and now == name, now
end

local function get_start(item)
  local ok, s = pcall(function() return item:GetStart() end)
  if ok and s then return tonumber(s) or 0 end
  return 0
end

local function get_uid(item)
  local ok, id = pcall(function() return item:GetUniqueId() end)
  if ok and id ~= nil and tostring(id) ~= "" then return tostring(id) end
  return nil
end

local function track_of(item)
  local ok, t = pcall(function() return item:GetTrackTypeAndIndex() end)
  if ok and type(t) == "table" and tostring(t[1]) == "audio" then
    return tostring(t[2])
  end
  return nil
end

-- GetItemListInTrack can also return gaps and Fairlight transitions. Resolve
-- returns nil from GetMediaPoolItem for those, but the call itself can also
-- raise for a perfectly real clip. Only a clean nil means "no media": an error
-- must never make a real clip disappear.
local no_media_names = {}
local no_media_seen = {}

local function note_no_media(name)
  if no_media_seen[name] then return end
  no_media_seen[name] = true
  no_media_names[#no_media_names + 1] = name
end

-- Returns "ok", "none", or "error", plus a detail string (media name / message).
local function media_state(item)
  local ok, mpi = pcall(function() return item:GetMediaPoolItem() end)
  if not ok then return "error", tostring(mpi) end
  if mpi == nil then return "none", "" end
  local name = "?"
  pcall(function() name = tostring(mpi:GetName()) end)
  return "ok", name
end

local function selected_audio()
  local out = {}
  local ok, sel = pcall(function() return timeline:GetSelectedClips() end)
  if not ok or sel == nil then return out end

  local seen = {}
  for _, item in ipairs(objectsOf(sel)) do
    local track = track_of(item)
    if track then
      local name = get_name(item)
      local start = get_start(item)
      local uid = get_uid(item) or (name .. "|" .. tostring(start) .. "|" .. track)
      if not seen[uid] then
        seen[uid] = true
        local state = media_state(item)
        if state == "none" then note_no_media(name) end
        out[#out + 1] = {
          item = item,
          uid = uid,
          name = name,
          start = start,
          track = track,
          color = read_color(item),
          media = state,
        }
      end
    end
  end
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

local function all_audio_map()
  local by_uid, by_key = {}, {}
  local ok, count = pcall(function() return timeline:GetTrackCount("audio") end)
  if not ok or not count then return by_uid, by_key end
  for t = 1, count do
    local tok, list = pcall(function() return timeline:GetItemListInTrack("audio", t) end)
    if tok and list then
      for _, item in ipairs(objectsOf(list)) do
        local name = get_name(item)
        local start = get_start(item)
        local key = name .. "|" .. tostring(start) .. "|" .. tostring(t)
        by_key[key] = item
        local uid = get_uid(item)
        if uid then by_uid[uid] = item end
      end
    end
  end
  return by_uid, by_key
end

-- =========================================================================
-- Classification (suggestions only)
-- =========================================================================
local RULES = {
  { bucket = "Voiceover", words = {
      "voice", "vo_", "_vo", " vo", "vo ", "dialog", "dialogue", "narrat",
      "interview", "lav", "_mic", "mic_" } },
  { bucket = "Background Music", words = {
      "music", "bgm", "score", "soundtrack", "theme", "song", "_mx", "mx_" } },
  { bucket = "SFX", words = {
      "sfx", "whoosh", "woosh", "swoosh", "impact", "riser", "transition",
      "click", "pop", "beep", "alert", "bell", "signal", "slam", "crash" } },
  { bucket = "Ambience", words = {
      "amb", "ambience", "ambiance", "atmos", "room tone", "roomtone",
      "crowd", "wind", "rain", "forest", "city" } },
}

local function suggest(name)
  local lower = string.lower(name)
  for _, rule in ipairs(RULES) do
    for _, word in ipairs(rule.words) do
      if lower:find(word, 1, true) then return rule.bucket end
    end
  end
  return nil
end

-- =========================================================================
-- Memory (per project, keyed by clip name)
-- =========================================================================
local BUCKETS = {
  { key = "vo",  name = "Voiceover" },
  { key = "mu",  name = "Background Music" },
  { key = "sfx", name = "SFX" },
  { key = "amb", name = "Ambience" },
}
local BUCKET_NAMES = {}
for _, b in ipairs(BUCKETS) do BUCKET_NAMES[b.name] = true end

local memory_all = load_table(MEMORY_PATH) or load_table(LEGACY_MEMORY_PATH) or {}
local mem = memory_all[PROJECT]
if type(mem) ~= "table" then mem = {} end
mem.clips = mem.clips or {}
mem.groups = mem.groups or {}
mem.track_groups = mem.track_groups or {}
memory_all[PROJECT] = mem

local function save_memory() save_table(MEMORY_PATH, memory_all) end

local function bucket_of(name)
  local rec = mem.clips[name]
  if rec and BUCKET_NAMES[rec.bucket] then return rec.bucket end
  return nil
end

local function group_of(name)
  local rec = mem.clips[name]
  if rec and rec.group and rec.group ~= "" then return rec.group end
  return nil
end

local function remember(name, bucket, group)
  local rec = mem.clips[name] or {}
  if bucket ~= nil then rec.bucket = bucket end
  if group ~= nil then rec.group = group end
  mem.clips[name] = rec
end

-- Remove a clip from a bucket or a group. Returns true only if something was
-- actually removed, so the status line can report a real count.
local function forget(name, what)
  local rec = mem.clips[name]
  if not rec then return false end
  local had = false
  if what == "bucket" and rec.bucket then rec.bucket = nil; had = true end
  if what == "group" and rec.group then rec.group = nil; had = true end
  if not rec.bucket and not rec.group then mem.clips[name] = nil end
  return had
end

-- Every audio clip on the timeline, as records shaped like selected_audio().
-- Invert uses this so it never depends on what you happened to select.
local function all_audio_clips()
  local out, seen = {}, {}
  local ok, count = pcall(function() return timeline:GetTrackCount("audio") end)
  if not ok or not count then return out end

  for t = 1, count do
    local tok, list = pcall(function() return timeline:GetItemListInTrack("audio", t) end)
    if tok and list then
      for _, item in ipairs(objectsOf(list)) do
        local name = get_name(item)
        local start = get_start(item)
        local uid = get_uid(item) or (name .. "|" .. tostring(start) .. "|" .. tostring(t))
        if not seen[uid] then
          seen[uid] = true
          local state = media_state(item)
          if state == "none" then note_no_media(name) end
          out[#out + 1] = {
            item = item,
            uid = uid,
            name = name,
            start = start,
            track = tostring(t),
            color = read_color(item),
            bucket = bucket_of(name),
            suggestion = suggest(name),
            group = group_of(name),
            media = state,
          }
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

-- =========================================================================
-- Colour draw
-- =========================================================================
-- Randomize assigns each clip a different colour by walking a shuffled
-- palette, so a bucket of 5 clips gets 5 distinct colours instead of five
-- random picks that might collide.
local function shuffled_palette()
  local pool = {}
  for i, c in ipairs(COLORS) do pool[i] = c end
  for i = #pool, 2, -1 do
    local j = math.random(i)
    pool[i], pool[j] = pool[j], pool[i]
  end
  return pool
end

math.randomseed(os.time())

-- =========================================================================
-- Snapshot / revert
-- =========================================================================
local pending = {}

local function snapshot_add(clip)
  pending[#pending + 1] = {
    uid = clip.uid,
    name = clip.name,
    start = clip.start,
    track = clip.track,
    color = clip.color,
  }
end

local function snapshot_commit()
  if #pending == 0 then return end
  save_table(SNAPSHOT_PATH, {
    project = PROJECT,
    time = os.date("%Y-%m-%d %H:%M:%S"),
    items = pending,
  })
  pending = {}
end

local function revert_last()
  local snap = load_table(SNAPSHOT_PATH) or load_table(LEGACY_SNAPSHOT_PATH)
  if not snap or type(snap.items) ~= "table" then
    return false, "No snapshot found."
  end
  if snap.project ~= PROJECT then
    return false, ("Snapshot belongs to a different project (%s)."):format(tostring(snap.project))
  end

  local by_uid, by_key = all_audio_map()
  local restored, missing = 0, 0
  for _, rec in ipairs(snap.items) do
    local item = (rec.uid and by_uid[rec.uid])
      or by_key[rec.name .. "|" .. tostring(rec.start) .. "|" .. tostring(rec.track)]
    if item then
      local ok
      if rec.color == "" then
        ok = clear_color(item)
      else
        ok = set_color(item, rec.color)
      end
      if ok then restored = restored + 1 else missing = missing + 1 end
    else
      missing = missing + 1
    end
  end
  return true, ("Reverted %d clip(s), %d not found."):format(restored, missing)
end

-- =========================================================================
-- Runtime state
-- =========================================================================
local clips = {}
local timeline_clips = {}
local list_all = false
local checked = {}
local row_items = {}
local rebuilding = false
local dry_run = false
local status_text = "Ready."
local last_random = nil
local selected_tracks = {}
local track_items = {}
local rebuilding_tracks = false
local SCRIPT_VERSION = "1.9"

local function refresh_selection()
  no_media_names, no_media_seen = {}, {}
  clips = selected_audio()
  timeline_clips = all_audio_clips()
  for _, c in ipairs(clips) do
    c.color = read_color(c.item)
    c.bucket = bucket_of(c.name)
    c.suggestion = suggest(c.name)
    c.group = group_of(c.name)
  end
end

refresh_selection()

-- =========================================================================
-- Window
-- =========================================================================
local WINDOW_ID = "MrcAudioPaletteMain"

local function title(text)
  return ui:Label{ Text = text, Weight = 0,
    StyleSheet = "color: rgba(255,255,255,0.85); font-weight: bold;" }
end

local function gap(h)
  return ui:Label{ Text = "", Weight = 0, MinimumSize = { 1, h } }
end

local function bucket_row(b)
  return ui:HGroup{ Weight = 0,
    ui:Label{ ID = b.key .. "_count", Text = b.name, FixedSize = { 210, 24 },
      Alignment = { AlignVCenter = true } },
    ui:ComboBox{ ID = b.key .. "_color", Weight = 0, FixedSize = { 140, 24 } },
    ui:Button{ ID = b.key .. "_apply", Text = "Colour", FixedSize = { 76, 24 } },
    ui:Button{ ID = b.key .. "_rand",  Text = "Randomize", FixedSize = { 86, 24 } },
    ui:Button{ ID = b.key .. "_clear", Text = "Clear", FixedSize = { 60, 24 } },
    ui:Button{ ID = b.key .. "_remove", Text = "Remove bucket", FixedSize = { 112, 24 } },
    ui:Label{ Text = "", Weight = 1 },
  }
end

local win = disp:AddWindow({
  ID = WINDOW_ID,
  WindowTitle = "mrchauhan-audio-palette",
  Geometry = { 100, 60, 1080, 960 },

  ui:VGroup{
    ID = "root",

    ui:HGroup{ Weight = 0,
      ui:Label{ ID = "title", Text = "mrchauhan-audio-palette", Weight = 0,
        StyleSheet = "font-size: 15px; font-weight: bold;" },
      ui:Label{ ID = "context", Text = "", Weight = 1,
        Alignment = { AlignVCenter = true } },
      ui:CheckBox{ ID = "listAll", Text = "List whole timeline", Checked = false,
        Weight = 0, FixedSize = { 150, 26 } },
      ui:Button{ ID = "refresh", Text = "Refresh selection", FixedSize = { 150, 26 } },
      ui:Button{ ID = "diagnose", Text = "Diagnose", FixedSize = { 90, 26 } },
    },

    ui:HGroup{ Weight = 0,
      ui:CheckBox{ ID = "dryRun", Text = "Dry run (preview only)", Checked = false, Weight = 0 },
      ui:Label{ Text = "", Weight = 1 },
      ui:Button{ ID = "shuffle", Text = "Shuffle again", FixedSize = { 116, 24 } },
      ui:Button{ ID = "revert", Text = "Undo last run", FixedSize = { 120, 24 } },
      ui:Button{ ID = "resetAll", Text = "Reset all assignments", FixedSize = { 170, 24 } },
    },

    gap(6),
    title("1. Main Audio"),
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Ticked clips ->", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "assignBucket", Weight = 0, FixedSize = { 160, 24 } },
      ui:Button{ ID = "assignBucketBtn", Text = "Assign to bucket", FixedSize = { 140, 24 } },
      ui:Button{ ID = "unassignBucketBtn", Text = "Remove from bucket", FixedSize = { 150, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "", FixedSize = { 210, 24 } },
      ui:Button{ ID = "acceptSuggestions", Text = "Accept suggestions", FixedSize = { 140, 24 } },
      ui:Button{ ID = "tickAll", Text = "Tick all rows", FixedSize = { 106, 24 } },
      ui:Button{ ID = "tickNone", Text = "Untick all rows", FixedSize = { 112, 24 } },
      ui:Button{ ID = "clearTicked", Text = "Clear ticked colour", FixedSize = { 140, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },
    ui:Tree{ ID = "List", Weight = 1, MinimumSize = { 100, 190 } },
    bucket_row(BUCKETS[1]),
    bucket_row(BUCKETS[2]),
    bucket_row(BUCKETS[3]),
    bucket_row(BUCKETS[4]),

    gap(6),
    title("2. Invert"),
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Exclude these buckets:", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:CheckBox{ ID = "in_vo",  Text = "VO",    Checked = true, Weight = 0 },
      ui:CheckBox{ ID = "in_mu",  Text = "Music", Checked = true, Weight = 0 },
      ui:CheckBox{ ID = "in_sfx", Text = "SFX",   Checked = true, Weight = 0 },
      ui:CheckBox{ ID = "in_amb", Text = "Amb",   Checked = true, Weight = 0 },
      ui:CheckBox{ ID = "in_whole", Text = "Whole timeline (ignore my selection)",
        Checked = true, Weight = 0 },
      ui:Label{ Text = "", Weight = 1 },
    },
    ui:HGroup{ Weight = 0,
      ui:Label{ ID = "invertCount", Text = "", FixedSize = { 300, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "invert_color", Weight = 0, FixedSize = { 140, 24 } },
      ui:Button{ ID = "invert_apply", Text = "Colour", FixedSize = { 76, 24 } },
      ui:Button{ ID = "invert_rand",  Text = "Randomize", FixedSize = { 86, 24 } },
      ui:Button{ ID = "invert_clear", Text = "Clear", FixedSize = { 60, 24 } },
      ui:Button{ ID = "invert_all",   Text = "Colour all audio", FixedSize = { 140, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },

    gap(6),
    title("3. Group By  (hand-picked)"),
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "New group:", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:LineEdit{ ID = "newGroup", Text = "", Weight = 0, FixedSize = { 200, 24 },
        PlaceholderText = "e.g. whooshes" },
      ui:Button{ ID = "createGroup", Text = "Create", FixedSize = { 80, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Group:", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "groupSel", Weight = 0, FixedSize = { 200, 24 } },
      ui:ComboBox{ ID = "group_color", Weight = 0, FixedSize = { 140, 24 } },
      ui:Button{ ID = "group_assign", Text = "Assign ticked", FixedSize = { 110, 24 } },
      ui:Button{ ID = "group_unassign", Text = "Remove ticked", FixedSize = { 112, 24 } },
      ui:Button{ ID = "group_apply",  Text = "Colour", FixedSize = { 76, 24 } },
      ui:Button{ ID = "group_rand",   Text = "Randomize", FixedSize = { 86, 24 } },
    ui:Button{ ID = "group_clear",  Text = "Clear", FixedSize = { 60, 24 } },
    ui:Label{ Text = "", Weight = 1 },
  },

    gap(6),
    title("4. Selected Rows"),
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Ticked rows ->", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:LineEdit{ ID = "renameRows", Text = "", Weight = 0, FixedSize = { 240, 24 },
        PlaceholderText = "New clip name" },
      ui:Button{ ID = "renameRowsBtn", Text = "Rename ticked", FixedSize = { 118, 24 } },
      ui:ComboBox{ ID = "selected_color", Weight = 0, FixedSize = { 140, 24 } },
      ui:Button{ ID = "selected_apply", Text = "Colour ticked", FixedSize = { 110, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Rename audio track ->", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "renameTrackSel", Weight = 0, FixedSize = { 210, 24 } },
      ui:LineEdit{ ID = "renameTrackName", Text = "", Weight = 0, FixedSize = { 240, 24 },
        PlaceholderText = "New track name" },
      ui:Button{ ID = "renameTrackBtn", Text = "Rename track", FixedSize = { 112, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },

    gap(6),
    title("5. Audio Tracks"),
    ui:Tree{ ID = "TrackList", Weight = 0, MinimumSize = { 100, 112 },
      MaximumSize = { 16777215, 150 } },
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Ticked tracks ->", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:LineEdit{ ID = "trackGroupName", Text = "", Weight = 0, FixedSize = { 180, 24 },
        PlaceholderText = "e.g. Voiceover" },
      ui:Button{ ID = "trackGroupSave", Text = "Add to group", FixedSize = { 102, 24 } },
      ui:ComboBox{ ID = "trackGroupSel", Weight = 0, FixedSize = { 180, 24 } },
      ui:Button{ ID = "trackGroupUse", Text = "Use group", FixedSize = { 88, 24 } },
      ui:Button{ ID = "trackGroupDelete", Text = "Delete group", FixedSize = { 96, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Ticked tracks ->", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "track_color", Weight = 0, FixedSize = { 140, 24 } },
      ui:Button{ ID = "track_apply", Text = "Colour tracks", FixedSize = { 110, 24 } },
      ui:Button{ ID = "track_invert", Text = "Colour other tracks", FixedSize = { 142, 24 } },
      ui:Button{ ID = "trackUntick", Text = "Untick all", FixedSize = { 90, 24 } },
      ui:Label{ Text = "", Weight = 1 },
    },

    gap(6),
    ui:Label{ ID = "status", Text = "Ready.", Weight = 0, WordWrap = true,
      MinimumSize = { 1, 22 } },
    ui:TextEdit{ ID = "log", ReadOnly = true, Weight = 0, MinimumSize = { 1, 80 } },
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "", Weight = 1 },
      ui:Button{ ID = "close", Text = "Close", Default = true,
        MinimumSize = { 120, 30 } },
    },
  },
})

local items = win:GetItems()

-- Tree configuration must happen before any rows are added.
pcall(function()
  items.List.ColumnCount     = 1
  items.List.HeaderHidden    = true
  items.List.Indentation     = 0
  items.List.RootIsDecorated = false
  items.List.SortingEnabled  = false
end)
pcall(function() items.List:SetColumnWidth(0, 940) end)
pcall(function()
  items.TrackList.ColumnCount = 1
  items.TrackList.HeaderHidden = true
  items.TrackList.Indentation = 0
  items.TrackList.RootIsDecorated = false
  items.TrackList.SortingEnabled = false
  items.TrackList:SetColumnWidth(0, 940)
end)

-- =========================================================================
-- Widget helpers
-- =========================================================================
local combo_values = {}

local function fill_combo(id, values, selected)
  local combo = items[id]
  if not combo then return end
  combo_values[id] = values
  pcall(function() combo:Clear() end)
  for _, v in ipairs(values) do
    pcall(function() combo:AddItem(v) end)
  end
  local idx = 0
  if selected then
    for i, v in ipairs(values) do
      if v == selected then idx = i - 1 break end
    end
  end
  pcall(function() combo.CurrentIndex = idx end)
  pcall(function() combo.CurrentText = values[idx + 1] end)
end

local function combo_value(id, fallback)
  local values = combo_values[id]
  local combo = items[id]
  if not values or not combo then return fallback end
  local ok, idx = pcall(function() return combo.CurrentIndex end)
  if ok and type(idx) == "number" and values[idx + 1] then
    return values[idx + 1]
  end
  return fallback
end

local function log_line(text)
  local existing = ""
  pcall(function() existing = items.log.PlainText or "" end)
  local lines = {}
  if existing ~= "" then
    for line in existing:gmatch("[^\n]+") do lines[#lines + 1] = line end
  end
  lines[#lines + 1] = text
  while #lines > 150 do table.remove(lines, 1) end
  local joined = table.concat(lines, "\n")
  local ok = pcall(function() items.log.PlainText = joined end)
  if not ok then pcall(function() items.log.Text = joined end) end
end

local function status(text)
  status_text = text
  pcall(function() items.status.Text = text end)
end

local function tip(id, text)
  local widget = items[id]
  if widget then pcall(function() widget.ToolTip = text end) end
end

-- =========================================================================
-- List (Tree with a checkbox per clip)
-- =========================================================================
local function line_for(c)
  local colour = (c.color ~= "") and c.color or "-"
  local note
  if c.bucket then
    note = "= " .. c.bucket
  elseif c.suggestion then
    note = "suggested: " .. c.suggestion
  else
    note = "unassigned"
  end
  if c.group then note = note .. "  [" .. c.group .. "]" end
  if c.media == "none" then note = note .. "  [no media item]"
  elseif c.media == "error" then note = note .. "  [media lookup error]" end
  return string.format("A%-3s  %-46s  %-10s  %s",
    c.track, clip_text(c.name, 46), colour, note)
end

-- Populating fires ItemChanged; we do not listen to it, but the guard keeps a
-- future handler from re-entering mid-build.
-- Which clips the Tree shows: the timeline selection, or every audio clip on
-- the timeline. Ticks survive switching between the two.
local function displayed_clips()
  return list_all and timeline_clips or clips
end

local function fill_list()
  if not items.List then
    status("Tree widget unavailable -- cannot list clips.")
    return
  end
  rebuilding = true
  local ok, err = pcall(function()
    items.List:Clear()
    row_items = {}
    for _, c in ipairs(displayed_clips()) do
      local row = items.List:NewItem()
      row.Text[0] = line_for(c)
      row.TextAlignment[0] = { AlignLeft = true, AlignVCenter = true }
      row.Flags = { ItemIsUserCheckable = true, ItemIsEnabled = true,
                    ItemIsSelectable = true }
      row.CheckState[0] = checked[c.uid] and "Checked" or "Unchecked"
      items.List:AddTopLevelItem(row)
      row_items[c.uid] = row
    end
  end)
  rebuilding = false
  if not ok then status("Could not build the clip list: " .. tostring(err)) end
end

-- Read the boxes only when an action needs them. Change events are unreliable
-- on this build, so nothing is trusted until this runs.
local function harvest()
  if rebuilding then return end
  for _, c in ipairs(displayed_clips()) do
    local row = row_items[c.uid]
    if row then
      local ok, state = pcall(function() return row.CheckState[0] end)
      if ok then checked[c.uid] = (tostring(state) == "Checked") end
    end
  end
end

local function set_all(on)
  rebuilding = true
  local want = on and "Checked" or "Unchecked"
  for _, c in ipairs(displayed_clips()) do
    checked[c.uid] = on
    local row = row_items[c.uid]
    if row then
      local ok, state = pcall(function() return row.CheckState[0] end)
      if ok and tostring(state) ~= want then
        pcall(function() row.CheckState[0] = want end)
      end
    end
  end
  rebuilding = false
end

local function ticked_clips()
  harvest()
  local out = {}
  for _, c in ipairs(displayed_clips()) do
    if checked[c.uid] then out[#out + 1] = c end
  end
  return out
end

-- =========================================================================
-- Derived data
-- =========================================================================
-- Buckets and groups are name-based and cover the whole timeline, not just the
-- current selection. Otherwise "Colour Background Music" would silently skip
-- every music clip you did not happen to have selected.
local function bucket_clips(bucket)
  local out = {}
  for _, c in ipairs(timeline_clips) do
    if c.bucket == bucket then out[#out + 1] = c end
  end
  return out
end

local function group_names()
  local names = {}
  for name in pairs(mem.groups) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function group_clips(group)
  local out = {}
  for _, c in ipairs(timeline_clips) do
    if c.group == group then out[#out + 1] = c end
  end
  return out
end

local function audio_track_count()
  local ok, count = pcall(function() return timeline:GetTrackCount("audio") end)
  return (ok and tonumber(count)) or 0
end

local function audio_track_choices()
  local choices = {}
  for index = 1, audio_track_count() do
    local name = get_track_name(index)
    choices[#choices + 1] = (name == "Audio " .. tostring(index))
      and name or ("Audio " .. tostring(index) .. " - " .. name)
  end
  return choices
end

local function track_index(choice)
  return tonumber(tostring(choice or ""):match("^Audio%s+(%d+)"))
end

local function selected_track_names()
  local indexes = {}
  for index in pairs(selected_tracks) do indexes[#indexes + 1] = index end
  table.sort(indexes)
  local names = {}
  for _, index in ipairs(indexes) do names[#names + 1] = "Audio " .. tostring(index) end
  return names
end

local function selected_tracks_label()
  local names = selected_track_names()
  if #names == 0 then return "No tracks selected" end
  return table.concat(names, ", ")
end

local function track_group_names()
  local names = {}
  for name in pairs(mem.track_groups) do names[#names + 1] = name end
  table.sort(names)
  return names
end

local function fill_track_list()
  if not items.TrackList then return end
  rebuilding_tracks = true
  local ok, err = pcall(function()
    items.TrackList:Clear()
    track_items = {}
    for index = 1, audio_track_count() do
      local row = items.TrackList:NewItem()
      local name = get_track_name(index)
      row.Text[0] = (name == "Audio " .. tostring(index)) and name
        or ("Audio " .. tostring(index) .. " - " .. name)
      row.TextAlignment[0] = { AlignLeft = true, AlignVCenter = true }
      row.Flags = { ItemIsUserCheckable = true, ItemIsEnabled = true,
                    ItemIsSelectable = true }
      row.CheckState[0] = selected_tracks[index] and "Checked" or "Unchecked"
      items.TrackList:AddTopLevelItem(row)
      track_items[index] = row
    end
  end)
  rebuilding_tracks = false
  if not ok then status("Could not build the audio track list: " .. tostring(err)) end
end

local function harvest_tracks()
  if rebuilding_tracks then return end
  for index, row in pairs(track_items) do
    local ok, state = pcall(function() return row.CheckState[0] end)
    if ok then selected_tracks[index] = (tostring(state) == "Checked") end
  end
end

local function untick_all_tracks()
  selected_tracks = {}
  fill_track_list()
end

local function track_clips(invert)
  local out = {}
  for _, c in ipairs(timeline_clips) do
    local chosen = selected_tracks[tonumber(c.track)] and true or false
    if chosen ~= invert then out[#out + 1] = c end
  end
  return out
end

local function invert_clips()
  local inside = {
    Voiceover = items.in_vo.Checked,
    ["Background Music"] = items.in_mu.Checked,
    SFX = items.in_sfx.Checked,
    Ambience = items.in_amb.Checked,
  }

  -- Default is the whole timeline: Invert must not depend on what you selected.
  local source = clips
  local whole = false
  pcall(function() whole = items.in_whole.Checked and true or false end)
  if whole then source = timeline_clips end

  local out = {}
  for _, c in ipairs(source) do
    if not (c.bucket and inside[c.bucket]) then out[#out + 1] = c end
  end
  return out
end

-- Used in status lines so it is always obvious which scope ran.
local function invert_label()
  local whole = false
  pcall(function() whole = items.in_whole.Checked and true or false end)
  return whole and "Invert (whole timeline)" or "Invert (selection)"
end

-- Shuffle again: re-runs the last Randomize with a fresh palette. The spec is
-- re-resolved each time so it always uses current buckets and current colours.
local function list_for_random(spec)
  if not spec then return {} end
  if spec.kind == "bucket" then return bucket_clips(spec.name) end
  if spec.kind == "group"  then return group_clips(spec.name) end
  if spec.kind == "invert" then return invert_clips() end
  return {}
end

-- =========================================================================
-- Refresh
-- =========================================================================
local function refresh_widgets()
  -- Run the invert scan first: it is what notices transitions on the timeline,
  -- and the header should report them in the same pass.
  local inverted = invert_clips()

  local ignored = ""
  if #no_media_names > 0 then
    ignored = ("   -   %d item(s) with no media item"):format(#no_media_names)
  end

  local tlname = ""
  local okn, name = pcall(function() return timeline:GetName() end)
  if okn and name then tlname = tostring(name) end
  pcall(function()
    items.context.Text = ("%s  /  %s   -   %d selected audio clip(s)%s   -   Resolve %s")
      :format(PROJECT, tlname, #clips, ignored, VERSION)
  end)

  for _, b in ipairs(BUCKETS) do
    fill_combo(b.key .. "_color", COLORS, combo_value(b.key .. "_color", COLORS[1]))
    local members = bucket_clips(b.name)
    local label = items[b.key .. "_count"]
    if label then
      label.Text = ("%s (%d)"):format(b.name, #members)
      local names = {}
      for i = 1, math.min(12, #members) do names[i] = members[i].name end
      tip(b.key .. "_count", ("%s (%d): %s%s"):format(
        b.name, #members, table.concat(names, ", "),
        (#members > 12) and " ..." or ""))
    end
  end

  fill_combo("assignBucket", { "Voiceover", "Background Music", "SFX", "Ambience" },
    combo_value("assignBucket", "SFX"))
  fill_combo("invert_color", COLORS, combo_value("invert_color", COLORS[1]))
  fill_combo("group_color", COLORS, combo_value("group_color", COLORS[1]))
  fill_combo("selected_color", COLORS, combo_value("selected_color", COLORS[1]))
  local rename_track_choices = audio_track_choices()
  fill_combo("renameTrackSel", rename_track_choices,
    combo_value("renameTrackSel", rename_track_choices[1]))
  local valid_tracks = {}
  for index = 1, audio_track_count() do
    if selected_tracks[index] then valid_tracks[index] = true end
  end
  selected_tracks = valid_tracks
  fill_combo("track_color", COLORS, combo_value("track_color", COLORS[1]))
  local track_groups = track_group_names()
  fill_combo("trackGroupSel", track_groups, combo_value("trackGroupSel", track_groups[1]))
  fill_track_list()

  local groups = group_names()
  fill_combo("groupSel", groups, combo_value("groupSel", groups[1]))

  local whole = false
  pcall(function() whole = items.in_whole.Checked and true or false end)
  local source_count = whole and #timeline_clips or #clips
  local excluded = source_count - #inverted
  pcall(function()
    if excluded > 0 then
      items.invertCount.Text = ("%d to colour, %d excluded by buckets")
        :format(#inverted, excluded)
    else
      items.invertCount.Text = ("%d to colour"):format(#inverted)
    end
  end)

  fill_list()
  status(status_text)
end

local function refresh_all(message)
  refresh_selection()
  refresh_widgets()
  if message then status(message) end
end

-- =========================================================================
-- Colour actions
-- =========================================================================
-- A colour write can be refused: locked track, offline media, disabled clip.
-- Every failure prints what the clip actually is, so no guessing is needed.
local function track_locked(track)
  local ok, v = pcall(function() return timeline:GetIsTrackLocked("audio", tonumber(track)) end)
  if ok then return v end
  return nil
end

local function describe_item(item)
  local bits = {}
  local function add(label, fn)
    local ok, v = pcall(fn)
    if ok and v ~= nil then bits[#bits + 1] = label .. "=" .. tostring(v) end
  end
  add("enabled", function() return item:GetClipEnabled() end)
  add("start", function() return item:GetStart() end)
  local ok, mpi = pcall(function() return item:GetMediaPoolItem() end)
  if not ok then
    bits[#bits + 1] = "media=ERROR(" .. tostring(mpi) .. ")"
  elseif mpi then
    add("file", function() return mpi:GetClipProperty("File Name") end)
    add("path", function() return mpi:GetClipProperty("File Path") end)
  else
    bits[#bits + 1] = "media=nil"
  end
  return table.concat(bits, "  ")
end

local function report_failure(c, action)
  local message = ("  FAILED %s  %s  A%s  track_locked=%s  %s"):format(
    action, clip_text(c.name, 40), tostring(c.track),
    tostring(track_locked(c.track)), describe_item(c.item))
  log_line(message)
  print("mrc-audioPalette:" .. message)
end

local function action_apply(list, colour, mode, label, spec)
  if #list == 0 then
    status(("Nothing to colour for %s."):format(label))
    return
  end

  -- Only a confirmed nil media pool item is left alone (gaps/transitions).
  -- A failed API call keeps the clip in, because it may well be colourable.
  local work, no_media = {}, {}
  for _, c in ipairs(list) do
    if c.media == "none" then no_media[#no_media + 1] = c
    else work[#work + 1] = c end
  end
  if #work == 0 then
    status(("%s: all %d item(s) report no media item, nothing to colour.")
      :format(label, #no_media))
    return
  end

  pending = {}
  local changed, failed, skipped = 0, 0, 0

  -- One shuffled palette per press: every clip in the list gets a different
  -- colour, and pressing Randomize again gives a fresh draw.
  local targets = {}
  if mode == "random" then
    local pool = shuffled_palette()
    for i, c in ipairs(work) do
      targets[c.uid] = pool[((i - 1) % #pool) + 1]
    end
    if spec then last_random = spec end
  end
  local function target_for(c) return targets[c.uid] or colour end

  if dry_run then
    local preview = {}
    for _, c in ipairs(work) do
      local target = target_for(c)
      preview[#preview + 1] = ("%s  %s -> %s"):format(clip_text(c.name, 38), c.color, target)
    end
    log_line(("DRY RUN %s: %d clip(s)"):format(label, #preview))
    for i = 1, math.min(12, #preview) do log_line("  " .. preview[i]) end
    if #preview > 12 then log_line(("  ... %d more"):format(#preview - 12)) end
    status(("Dry run: %d clip(s) would change for %s."):format(#preview, label))
    return
  end

  for _, c in ipairs(work) do
    local target = target_for(c)
    if c.color == target then
      skipped = skipped + 1
    else
      snapshot_add(c)
      local ok, now = set_color(c.item, target)
      if ok then
        c.color = now
        changed = changed + 1
      else
        failed = failed + 1
        report_failure(c, "SetClipColor " .. target)
      end
    end
  end

  snapshot_commit()
  refresh_all()
  local how = (mode == "random") and "random draw" or tostring(colour)
  local ignored = (#no_media > 0) and (", %d without media"):format(#no_media) or ""
  status(("%s [%s]: %d changed, %d already correct, %d failed%s.")
    :format(label, how, changed, skipped, failed, ignored))
  log_line(("APPLY %s [%s]: %d changed, %d skipped, %d failed%s")
    :format(label, how, changed, skipped, failed, ignored))
  if #no_media > 0 then
    local names = {}
    for i = 1, math.min(6, #no_media) do names[i] = no_media[i].name end
    log_line(("  no media item (not colourable): %s%s"):format(
      table.concat(names, ", "), (#no_media > 6) and " ..." or ""))
  end
end

local function action_clear(list, label)
  if #list == 0 then
    status(("Nothing to clear for %s."):format(label))
    return
  end
  local work, no_media = {}, {}
  for _, c in ipairs(list) do
    if c.media == "none" then no_media[#no_media + 1] = c
    else work[#work + 1] = c end
  end
  if #work == 0 then
    status(("%s: all %d item(s) report no media item, nothing to clear.")
      :format(label, #no_media))
    return
  end
  if dry_run then
    status(("Dry run: %d clip(s) would be cleared for %s."):format(#work, label))
    return
  end

  pending = {}
  local cleared, failed = 0, 0
  for _, c in ipairs(work) do
    snapshot_add(c)
    local ok, now = clear_color(c.item)
    if ok then c.color = now; cleared = cleared + 1
    else failed = failed + 1; report_failure(c, "ClearClipColor") end
  end
  snapshot_commit()
  refresh_all()
  local ignored = (#no_media > 0) and (", %d without media"):format(#no_media) or ""
  status(("%s: %d cleared, %d failed%s."):format(label, cleared, failed, ignored))
end

local function action_rename(list, requested_name)
  if #list == 0 then
    status("Tick some clips first.")
    return
  end
  local base_name = trim(requested_name)
  if base_name == "" then
    status("Type a new clip name first.")
    return
  end
  if dry_run then
    status(("Dry run: %d ticked clip(s) would be renamed to %s.")
      :format(#list, base_name))
    return
  end

  local renamed, failed = 0, 0
  for index, c in ipairs(list) do
    local target = (#list == 1) and base_name or (base_name .. " " .. tostring(index))
    local old_name = c.name
    if old_name ~= target then
      local rec = mem.clips[old_name]
      local ok, now = set_name(c.item, target)
      if ok then
        c.name = now
        if rec then
          mem.clips[target] = { bucket = rec.bucket, group = rec.group }
          mem.clips[old_name] = nil
        end
        renamed = renamed + 1
      else
        failed = failed + 1
        report_failure(c, "SetName " .. target)
      end
    end
  end
  save_memory()
  refresh_all()
  local suffix = (#list > 1) and " (numbered)" or ""
  status(("Renamed %d clip(s), %d failed%s."):format(renamed, failed, suffix))
  log_line(("RENAME: %d renamed, %d failed%s"):format(renamed, failed, suffix))
end

-- =========================================================================
-- Handlers
-- =========================================================================
win.On.refresh.Clicked = function()
  refresh_all(("Refreshed: %d audio clip(s) selected."):format(#clips))
end

-- Facts, not guesses: dump what Resolve says about every audio item, with the
-- media lookup separated into ok / nil / error.
win.On.diagnose.Clicked = function()
  log_line("---- DIAGNOSE: every audio item on the timeline ----")
  local ok, count = pcall(function() return timeline:GetTrackCount("audio") end)
  if not ok or not count then
    status("Could not read the audio tracks.")
    return
  end
  local shown = 0
  for t = 1, count do
    local tok, list = pcall(function() return timeline:GetItemListInTrack("audio", t) end)
    if tok and list then
      for _, item in ipairs(objectsOf(list)) do
        local state, detail = media_state(item)
        local okd, dur = pcall(function() return item:GetDuration() end)
        local okc, colour = pcall(function() return item:GetClipColor() end)
        local okid, uid = pcall(function() return item:GetUniqueId() end)
        local line = ("A%-2s %-34s start=%-8s dur=%-5s media=%-5s %-26s colour=%-10s uid=%s")
          :format(tostring(t), clip_text(get_name(item), 34), tostring(get_start(item)),
            tostring(okd and dur or "?"), state, tostring(detail or ""):sub(1, 26),
            tostring(okc and colour or "?"), tostring(okid and uid or "?"))
        log_line(line)
        print("mrc-audioPalette DIAG: " .. line)
        shown = shown + 1
      end
    end
  end
  status(("Diagnostics for %d item(s) written to the log and the Console."):format(shown))
end

win.On.dryRun.Clicked = function()
  dry_run = items.dryRun.Checked and true or false
  status(dry_run and "Dry run ON -- nothing will be written." or "Dry run OFF.")
end

win.On.shuffle.Clicked = function()
  if not last_random then
    status("Nothing to shuffle yet. Press Randomize on a bucket, group or Invert first.")
    return
  end
  action_apply(list_for_random(last_random), nil, "random", last_random.label, last_random)
end

win.On.revert.Clicked = function()
  local ok, message = revert_last()
  refresh_all()
  status((ok and "Reverted. " or "Revert failed. ") .. tostring(message))
  log_line("REVERT: " .. tostring(message))
end

win.On.tickAll.Clicked = function()
  set_all(true)
  status(("Ticked %d clip(s)."):format(#clips))
end

win.On.tickNone.Clicked = function()
  set_all(false)
  status("Unticked all.")
end

win.On.clearTicked.Clicked = function()
  local list = ticked_clips()
  if #list == 0 then status("Tick some clips first."); return end
  action_clear(list, "Ticked clips")
end

win.On.acceptSuggestions.Clicked = function()
  local n = 0
  for _, c in ipairs(clips) do
    if c.bucket == nil then
      local s = suggest(c.name)
      if s then remember(c.name, s, nil); n = n + 1 end
    end
  end
  save_memory()
  refresh_all(("Accepted %d suggestion(s)."):format(n))
end

win.On.assignBucketBtn.Clicked = function()
  local target = combo_value("assignBucket", "SFX")
  local list = ticked_clips()
  if #list == 0 then status("Tick some clips first."); return end
  for _, c in ipairs(list) do remember(c.name, target, nil) end
  save_memory()
  refresh_all(("Assigned %d ticked clip(s) to %s."):format(#list, target))
end

win.On.unassignBucketBtn.Clicked = function()
  local list = ticked_clips()
  if #list == 0 then status("Tick some clips first."); return end
  local n = 0
  for _, c in ipairs(list) do
    if forget(c.name, "bucket") then n = n + 1 end
  end
  save_memory()
  refresh_all(("Removed %d clip(s) from their bucket. Colours were not touched."):format(n))
end

win.On.listAll.Clicked = function()
  list_all = items.listAll.Checked and true or false
  fill_list()
  if list_all then
    status(("Listing all %d audio clip(s) on the timeline."):format(#timeline_clips))
  else
    status(("Listing %d selected audio clip(s)."):format(#clips))
  end
end

win.On.resetAll.Clicked = function()
  mem.clips = {}
  mem.groups = {}
  mem.track_groups = {}
  last_random = nil
  save_memory()
  refresh_all("All bucket, clip group, and track group assignments cleared. Clip colours were not changed.")
end

for _, b in ipairs(BUCKETS) do
  win.On[b.key .. "_apply"].Clicked = function()
    action_apply(bucket_clips(b.name), combo_value(b.key .. "_color", COLORS[1]),
      "colour", b.name)
  end
  win.On[b.key .. "_rand"].Clicked = function()
    action_apply(bucket_clips(b.name), nil, "random", b.name,
      { kind = "bucket", name = b.name, label = b.name })
  end
  win.On[b.key .. "_clear"].Clicked = function()
    action_clear(bucket_clips(b.name), b.name)
  end
  win.On[b.key .. "_remove"].Clicked = function()
    local members = bucket_clips(b.name)
    for _, c in ipairs(members) do forget(c.name, "bucket") end
    save_memory()
    refresh_all(("Removed %d clip(s) from %s. Colours were not touched.")
      :format(#members, b.name))
  end
end

for _, key in ipairs({ "vo", "mu", "sfx", "amb", "whole" }) do
  win.On["in_" .. key].Clicked = function()
    refresh_widgets()
  end
end

win.On.invert_apply.Clicked = function()
  action_apply(invert_clips(), combo_value("invert_color", COLORS[1]), "colour", invert_label())
end
win.On.invert_rand.Clicked = function()
  action_apply(invert_clips(), nil, "random", invert_label(),
    { kind = "invert", label = invert_label() })
end
win.On.invert_clear.Clicked = function()
  action_clear(invert_clips(), invert_label())
end
win.On.invert_all.Clicked = function()
  action_apply(timeline_clips, combo_value("invert_color", COLORS[1]),
    "colour", "Every audio clip")
end

win.On.createGroup.Clicked = function()
  local name = trim(items.newGroup.Text or "")
  if name == "" then status("Type a group name first."); return end
  if mem.groups[name] then status("That group already exists."); return end
  mem.groups[name] = COLORS[(#group_names() % #COLORS) + 1]
  items.newGroup.Text = ""
  save_memory()
  refresh_all(("Group '%s' created with colour %s."):format(name, mem.groups[name]))
end

win.On.group_assign.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Create or pick a group first."); return end
  local list = ticked_clips()
  if #list == 0 then status("Tick some clips first."); return end
  for _, c in ipairs(list) do remember(c.name, nil, group) end
  save_memory()
  refresh_all(("Assigned %d clip(s) to '%s'."):format(#list, group))
end

win.On.group_unassign.Clicked = function()
  local list = ticked_clips()
  if #list == 0 then status("Tick some clips first."); return end
  local n = 0
  for _, c in ipairs(list) do
    if forget(c.name, "group") then n = n + 1 end
  end
  save_memory()
  refresh_all(("Removed %d clip(s) from their group."):format(n))
end

win.On.group_apply.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Pick a group first."); return end
  action_apply(group_clips(group), combo_value("group_color", COLORS[1]),
    "colour", "Group " .. group)
end

win.On.group_rand.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Pick a group first."); return end
  action_apply(group_clips(group), nil, "random", "Group " .. group,
    { kind = "group", name = group, label = "Group " .. group })
end

win.On.group_clear.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Pick a group first."); return end
  action_clear(group_clips(group), "Group " .. group)
end

win.On.renameRowsBtn.Clicked = function()
  action_rename(ticked_clips(), items.renameRows.Text or "")
end

win.On.renameTrackBtn.Clicked = function()
  local index = track_index(combo_value("renameTrackSel", ""))
  local name = trim(items.renameTrackName.Text or "")
  if not index then status("Pick an audio track first."); return end
  if name == "" then status("Type a new audio track name first."); return end
  if not set_track_name(index, name) then
    status(("Resolve could not rename Audio %d."):format(index))
    return
  end
  refresh_widgets()
  status(("Renamed Audio %d to '%s'."):format(index, name))
end

win.On.selected_apply.Clicked = function()
  local list = ticked_clips()
  if #list == 0 then status("Tick some clips first."); return end
  action_apply(list, combo_value("selected_color", COLORS[1]), "colour", "Ticked rows")
end

win.On.trackGroupSave.Clicked = function()
  harvest_tracks()
  local name = trim(items.trackGroupName.Text or "")
  if name == "" then status("Type a track group name first."); return end
  if next(selected_tracks) == nil then status("Tick one or more audio tracks first."); return end
  local group = mem.track_groups[name] or {}
  for index in pairs(selected_tracks) do group[index] = true end
  mem.track_groups[name] = group
  save_memory()
  refresh_widgets()
  status(("Added %s to track group '%s'."):format(selected_tracks_label(), name))
end

win.On.trackGroupUse.Clicked = function()
  local name = combo_value("trackGroupSel", "")
  local group = mem.track_groups[name]
  if not group then status("Create or pick a track group first."); return end
  selected_tracks = {}
  for index in pairs(group) do selected_tracks[tonumber(index)] = true end
  refresh_widgets()
  status(("Loaded track group '%s': %s."):format(name, selected_tracks_label()))
end

win.On.trackGroupDelete.Clicked = function()
  local name = combo_value("trackGroupSel", "")
  if name == "" or not mem.track_groups[name] then status("Pick a track group first."); return end
  mem.track_groups[name] = nil
  save_memory()
  refresh_widgets()
  status(("Deleted track group '%s'."):format(name))
end

win.On.trackUntick.Clicked = function()
  untick_all_tracks()
  status("Unticked all audio tracks.")
end

win.On.track_apply.Clicked = function()
  harvest_tracks()
  if next(selected_tracks) == nil then status("Tick one or more audio tracks first."); return end
  action_apply(track_clips(false), combo_value("track_color", COLORS[1]), "colour",
    "Audio tracks: " .. selected_tracks_label())
end

win.On.track_invert.Clicked = function()
  harvest_tracks()
  if next(selected_tracks) == nil then status("Tick one or more audio tracks first."); return end
  action_apply(track_clips(true), combo_value("track_color", COLORS[1]), "colour",
    "All other audio tracks (excluding " .. selected_tracks_label() .. ")")
end

win.On[WINDOW_ID].Close = function(ev)
  save_memory()
  win:Hide()
  disp:ExitLoop()
end

win.On.close.Clicked = function()
  save_memory()
  win:Hide()
  disp:ExitLoop()
end

-- =========================================================================
-- Tooltips: one line per control, so nothing needs guessing
-- =========================================================================
tip("refresh", "Re-read the clips currently selected in the timeline. Nothing else is pulled in.")
tip("diagnose", "Write what Resolve reports for every audio item (name, track, duration, media, colour) to the log and the Console.")
tip("revert", "Undo the last mrc-audioPalette colour or clear pass. This is not Resolve's global undo.")
tip("shuffle", "Repeat the last Randomize with a fresh set of colours.")
tip("dryRun", "Preview what would change. Nothing is written to the timeline.")

tip("tickAll", "Tick every row in this list.")
tip("tickNone", "Untick every row in this list.")
tip("listAll", "Show every audio clip on the timeline in the list, not just the ones selected in the timeline.")
tip("unassignBucketBtn", "Remove the ticked clips from whichever bucket they are in. Their colour is not changed.")
tip("group_unassign", "Remove the ticked clips from their group. Their colour is not changed.")
tip("resetAll", "Clear every bucket and group assignment for this project. Clip colours are not changed.")
tip("clearTicked", "Remove the clip colour from the ticked rows only. Bucket assignment is kept.")
tip("acceptSuggestions", "Save the keyword guesses as real bucket assignments. Never applied automatically.")
tip("assignBucket", "Which bucket the Assign button should use.")
tip("assignBucketBtn", "Put every ticked clip into the chosen bucket.")
tip("renameRows", "Enter a name for the ticked clips. When several are ticked, they are numbered to keep their names distinct.")
tip("renameRowsBtn", "Rename only the ticked rows. Existing bucket and group assignments move with each renamed clip.")
tip("selected_color", "Colour to apply only to the ticked rows.")
tip("selected_apply", "Apply the selected colour only to the ticked rows.")
tip("renameTrackSel", "Choose the timeline audio track to rename.")
tip("renameTrackName", "Type the new name for the chosen timeline audio track.")
tip("renameTrackBtn", "Rename the chosen audio track in the DaVinci Resolve timeline.")
tip("TrackList", "Tick one or more audio tracks. The list reflects every audio track on the current timeline.")
tip("trackGroupName", "Type a reusable name such as Voiceover, then add the ticked tracks to it.")
tip("trackGroupSave", "Add the ticked tracks to this named track group. Use the same name later to add more tracks.")
tip("trackGroupSel", "Choose a saved track group to load or delete.")
tip("trackGroupUse", "Tick exactly the audio tracks stored in the chosen group.")
tip("trackGroupDelete", "Delete the chosen saved track group. Timeline colours are not changed.")
tip("track_color", "Colour to apply to the ticked tracks or every other track.")
tip("track_apply", "Colour every audio clip on the ticked tracks, across the whole timeline.")
tip("track_invert", "Colour every audio clip on tracks that are not ticked, across the whole timeline.")
tip("trackUntick", "Untick every audio track without changing timeline colours or saved groups.")

for _, b in ipairs(BUCKETS) do
  tip(b.key .. "_color", "Colour to use for the " .. b.name .. " bucket.")
  tip(b.key .. "_apply", "Apply that colour to every clip in " .. b.name .. ".")
  tip(b.key .. "_rand", "Give each clip in " .. b.name .. " a different colour. Press again for a new draw.")
  tip(b.key .. "_clear", "Remove the clip colour from every clip in " .. b.name .. ".")
  tip(b.key .. "_remove", "Remove every clip from the " .. b.name .. " bucket. Clip colours are not changed.")
end

tip("in_vo", "Voiceover clips are left alone by Invert.")
tip("in_mu", "Music clips are left alone by Invert.")
tip("in_sfx", "SFX clips are left alone by Invert.")
tip("in_amb", "Ambience clips are left alone by Invert.")
tip("in_whole", "Invert scans every audio clip on the timeline, whatever you have selected.")
tip("invert_apply", "Colour every clip outside the excluded buckets.")
tip("invert_rand", "Give every clip outside the excluded buckets a different colour.")
tip("invert_clear", "Remove the clip colour from every clip outside the excluded buckets.")
tip("invert_all", "Colour every audio clip on the timeline, including the ones already in a bucket.")

tip("newGroup", "Type a name, then press Create.")
tip("createGroup", "Create a hand-picked group with its own colour.")
tip("groupSel", "Which group the Assign and colour buttons act on.")
tip("group_assign", "Put every ticked clip into the selected group.")
tip("group_apply", "Colour every clip in the selected group.")
tip("group_rand", "Give each clip in the selected group a different colour.")
tip("group_clear", "Remove the clip colour from every clip in the selected group.")

-- =========================================================================
-- Show (populate only after every handler exists)
-- =========================================================================
refresh_widgets()
log_line("mrc-audioPalette v" .. SCRIPT_VERSION .. " started. Project: " .. PROJECT .. "  Resolve " .. VERSION)
log_line(("Selected audio clips: %d"):format(#clips))
if #no_media_names > 0 then
  log_line(("Item(s) the API reports without media: %s")
    :format(table.concat(no_media_names, ", ")))
end
if #clips == 0 then
  status("No audio clips selected. Invert still works: it scans the whole timeline.")
end

win:Show()
disp:RunLoop()
win:Hide()
