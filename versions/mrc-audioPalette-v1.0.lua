--[[
  mrc-audioPalette-v1.0.lua
  =========================================================================
  Colour-based audio clip organiser for DaVinci Resolve 21.x.

  One window, three stacked sections:
    1. Main Audio  -- classify selected audio clips into Voiceover / Music /
                      SFX / Ambience, tick clips, colour them.
    2. Invert      -- every audio clip on the timeline that is NOT in the
                      excluded buckets (your selection does not matter).
    3. Group By    -- hand-picked groups with their own colour pool.

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
    then Workspace > Scripts > Utility > ClipSorter.

  STATE FILES (next to this script)
    clipsorter-memory.state    per-project buckets + groups
    clipsorter-snapshot.state  last colour pass, for Revert
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
local MEMORY_PATH = DIR .. "\\clipsorter-memory.state"
local SNAPSHOT_PATH = DIR .. "\\clipsorter-snapshot.state"

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
  print("ClipSorter: no Resolve object. Run from Workspace > Scripts.")
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
  print("ClipSorter: UIManager unavailable in this context.")
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
  print("ClipSorter: open a project and a timeline first.")
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
        out[#out + 1] = {
          item = item,
          uid = uid,
          name = name,
          start = start,
          track = track,
          color = read_color(item),
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

local memory_all = load_table(MEMORY_PATH) or {}
local mem = memory_all[PROJECT]
if type(mem) ~= "table" then mem = {} end
mem.clips = mem.clips or {}
mem.groups = mem.groups or {}
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
  local snap = load_table(SNAPSHOT_PATH)
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
local checked = {}
local row_items = {}
local rebuilding = false
local dry_run = false
local status_text = "Ready."

local function refresh_selection()
  clips = selected_audio()
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
local WINDOW_ID = "ClipSorterMain"

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
    ui:Label{ Text = "", Weight = 1 },
  }
end

local win = disp:AddWindow({
  ID = WINDOW_ID,
  WindowTitle = "ClipSorter",
  Geometry = { 100, 60, 1080, 880 },

  ui:VGroup{
    ID = "root",

    ui:HGroup{ Weight = 0,
      ui:Label{ ID = "title", Text = "ClipSorter", Weight = 0,
        StyleSheet = "font-size: 15px; font-weight: bold;" },
      ui:Label{ ID = "context", Text = "", Weight = 1,
        Alignment = { AlignVCenter = true } },
      ui:Button{ ID = "refresh", Text = "Refresh selection", FixedSize = { 150, 26 } },
    },

    ui:HGroup{ Weight = 0,
      ui:CheckBox{ ID = "dryRun", Text = "Dry run (preview only)", Checked = false, Weight = 0 },
      ui:Label{ Text = "", Weight = 1 },
      ui:Button{ ID = "revert", Text = "Undo last run", FixedSize = { 120, 24 } },
    },

    gap(6),
    title("1. Main Audio"),
    ui:HGroup{ Weight = 0,
      ui:Label{ Text = "Ticked clips ->", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "assignBucket", Weight = 0, FixedSize = { 160, 24 } },
      ui:Button{ ID = "assignBucketBtn", Text = "Assign to bucket", FixedSize = { 140, 24 } },
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
      ui:Label{ ID = "invertCount", Text = "", FixedSize = { 210, 24 },
        Alignment = { AlignVCenter = true } },
      ui:ComboBox{ ID = "invert_color", Weight = 0, FixedSize = { 140, 24 } },
      ui:Button{ ID = "invert_apply", Text = "Colour", FixedSize = { 76, 24 } },
      ui:Button{ ID = "invert_rand",  Text = "Randomize", FixedSize = { 86, 24 } },
      ui:Button{ ID = "invert_clear", Text = "Clear", FixedSize = { 60, 24 } },
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
      ui:Button{ ID = "group_apply",  Text = "Colour", FixedSize = { 76, 24 } },
      ui:Button{ ID = "group_rand",   Text = "Randomize", FixedSize = { 86, 24 } },
      ui:Button{ ID = "group_clear",  Text = "Clear", FixedSize = { 60, 24 } },
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
  return string.format("A%-3s  %-46s  %-10s  %s",
    c.track, clip_text(c.name, 46), colour, note)
end

-- Populating fires ItemChanged; we do not listen to it, but the guard keeps a
-- future handler from re-entering mid-build.
local function fill_list()
  if not items.List then
    status("Tree widget unavailable -- cannot list clips.")
    return
  end
  rebuilding = true
  local ok, err = pcall(function()
    items.List:Clear()
    row_items = {}
    for _, c in ipairs(clips) do
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
  for _, c in ipairs(clips) do
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
  for _, c in ipairs(clips) do
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
  for _, c in ipairs(clips) do
    if checked[c.uid] then out[#out + 1] = c end
  end
  return out
end

-- =========================================================================
-- Derived data
-- =========================================================================
local function bucket_clips(bucket)
  local out = {}
  for _, c in ipairs(clips) do
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
  for _, c in ipairs(clips) do
    if c.group == group then out[#out + 1] = c end
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
  if whole then source = all_audio_clips() end

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

-- =========================================================================
-- Refresh
-- =========================================================================
local function refresh_widgets()
  pcall(function()
    items.context.Text = ("%s  /  %s   -   %d selected audio clip(s)   -   Resolve %s")
      :format(PROJECT, "", #clips, VERSION)
  end)
  local okn, tlname = pcall(function() return timeline:GetName() end)
  if okn and tlname then
    pcall(function()
      items.context.Text = ("%s  /  %s   -   %d selected audio clip(s)   -   Resolve %s")
        :format(PROJECT, tostring(tlname), #clips, VERSION)
    end)
  end

  for _, b in ipairs(BUCKETS) do
    fill_combo(b.key .. "_color", COLORS, combo_value(b.key .. "_color", COLORS[1]))
    local label = items[b.key .. "_count"]
    if label then label.Text = ("%s (%d)"):format(b.name, #bucket_clips(b.name)) end
  end

  fill_combo("assignBucket", { "Voiceover", "Background Music", "SFX", "Ambience" },
    combo_value("assignBucket", "SFX"))
  fill_combo("invert_color", COLORS, combo_value("invert_color", COLORS[1]))
  fill_combo("group_color", COLORS, combo_value("group_color", COLORS[1]))

  local groups = group_names()
  fill_combo("groupSel", groups, combo_value("groupSel", groups[1]))

  local inverted = invert_clips()
  pcall(function()
    items.invertCount.Text = ("%d clip(s) to colour"):format(#inverted)
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
local function action_apply(list, colour, mode, label)
  if #list == 0 then
    status(("Nothing to colour for %s."):format(label))
    return
  end

  pending = {}
  local changed, failed, skipped = 0, 0, 0

  -- One shuffled palette per press: every clip in the list gets a different
  -- colour, and pressing Randomize again gives a fresh draw.
  local targets = {}
  if mode == "random" then
    local pool = shuffled_palette()
    for i, c in ipairs(list) do
      targets[c.uid] = pool[((i - 1) % #pool) + 1]
    end
  end
  local function target_for(c) return targets[c.uid] or colour end

  if dry_run then
    local preview = {}
    for _, c in ipairs(list) do
      local target = target_for(c)
      preview[#preview + 1] = ("%s  %s -> %s"):format(clip_text(c.name, 38), c.color, target)
    end
    log_line(("DRY RUN %s: %d clip(s)"):format(label, #preview))
    for i = 1, math.min(12, #preview) do log_line("  " .. preview[i]) end
    if #preview > 12 then log_line(("  ... %d more"):format(#preview - 12)) end
    status(("Dry run: %d clip(s) would change for %s."):format(#preview, label))
    return
  end

  for _, c in ipairs(list) do
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
      end
    end
  end

  snapshot_commit()
  refresh_all()
  status(("%s: %d changed, %d already correct, %d failed.")
    :format(label, changed, skipped, failed))
  log_line(("APPLY %s: %d changed, %d skipped, %d failed")
    :format(label, changed, skipped, failed))
end

local function action_clear(list, label)
  if #list == 0 then
    status(("Nothing to clear for %s."):format(label))
    return
  end
  if dry_run then
    status(("Dry run: %d clip(s) would be cleared for %s."):format(#list, label))
    return
  end

  pending = {}
  local cleared, failed = 0, 0
  for _, c in ipairs(list) do
    snapshot_add(c)
    local ok, now = clear_color(c.item)
    if ok then c.color = now; cleared = cleared + 1
    else failed = failed + 1 end
  end
  snapshot_commit()
  refresh_all()
  status(("%s: %d cleared, %d failed."):format(label, cleared, failed))
end

-- =========================================================================
-- Handlers
-- =========================================================================
win.On.refresh.Clicked = function()
  refresh_all(("Refreshed: %d audio clip(s) selected."):format(#clips))
end

win.On.dryRun.Clicked = function()
  dry_run = items.dryRun.Checked and true or false
  status(dry_run and "Dry run ON -- nothing will be written." or "Dry run OFF.")
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

for _, b in ipairs(BUCKETS) do
  win.On[b.key .. "_apply"].Clicked = function()
    action_apply(bucket_clips(b.name), combo_value(b.key .. "_color", COLORS[1]),
      "colour", b.name)
  end
  win.On[b.key .. "_rand"].Clicked = function()
    action_apply(bucket_clips(b.name), nil, "random", b.name)
  end
  win.On[b.key .. "_clear"].Clicked = function()
    action_clear(bucket_clips(b.name), b.name)
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
  action_apply(invert_clips(), nil, "random", invert_label())
end
win.On.invert_clear.Clicked = function()
  action_clear(invert_clips(), invert_label())
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

win.On.group_apply.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Pick a group first."); return end
  action_apply(group_clips(group), combo_value("group_color", COLORS[1]),
    "colour", "Group " .. group)
end

win.On.group_rand.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Pick a group first."); return end
  action_apply(group_clips(group), nil, "random", "Group " .. group)
end

win.On.group_clear.Clicked = function()
  local group = combo_value("groupSel", "")
  if group == "" then status("Pick a group first."); return end
  action_clear(group_clips(group), "Group " .. group)
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
tip("revert", "Undo the last ClipSorter colour or clear pass. This is not Resolve's global undo.")
tip("dryRun", "Preview what would change. Nothing is written to the timeline.")

tip("tickAll", "Tick every row in this list.")
tip("tickNone", "Untick every row in this list.")
tip("clearTicked", "Remove the clip colour from the ticked rows only. Bucket assignment is kept.")
tip("acceptSuggestions", "Save the keyword guesses as real bucket assignments. Never applied automatically.")
tip("assignBucket", "Which bucket the Assign button should use.")
tip("assignBucketBtn", "Put every ticked clip into the chosen bucket.")

for _, b in ipairs(BUCKETS) do
  tip(b.key .. "_color", "Colour to use for the " .. b.name .. " bucket.")
  tip(b.key .. "_apply", "Apply that colour to every clip in " .. b.name .. ".")
  tip(b.key .. "_rand", "Give each clip in " .. b.name .. " a different colour. Press again for a new draw.")
  tip(b.key .. "_clear", "Remove the clip colour from every clip in " .. b.name .. ".")
end

tip("in_vo", "Voiceover clips are left alone by Invert.")
tip("in_mu", "Music clips are left alone by Invert.")
tip("in_sfx", "SFX clips are left alone by Invert.")
tip("in_amb", "Ambience clips are left alone by Invert.")
tip("in_whole", "Invert scans every audio clip on the timeline, whatever you have selected.")
tip("invert_apply", "Colour every clip outside the excluded buckets.")
tip("invert_rand", "Give every clip outside the excluded buckets a different colour.")
tip("invert_clear", "Remove the clip colour from every clip outside the excluded buckets.")

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
log_line("ClipSorter started. Project: " .. PROJECT .. "  Resolve " .. VERSION)
log_line(("Selected audio clips: %d"):format(#clips))
if #clips == 0 then
  status("No audio clips selected. Invert still works: it scans the whole timeline.")
end

win:Show()
disp:RunLoop()
win:Hide()
