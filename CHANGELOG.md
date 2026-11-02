# mrchauhan-audio-palette — version history

Old builds are never overwritten. Every release is archived in `versions\` and
`mrc-audioPalette.lua` is always the newest one. The copy Resolve runs lives at:

```
%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\mrc-audioPalette.lua
```

---

## v1.6 — current

Changed:

- Renamed the script to **`mrchauhan-audio-palette`** (`mrc-audioPalette.lua`).
  Existing ClipSorter assignment and undo state is read once as a fallback, so
  prior project data is retained.
- Renamed archived builds to **`mrc-audioPalette-vX.Y.lua`**.
- Added **Rename audio track** in Section 4. Choose a timeline audio track,
  enter a name, and rename it directly in Resolve.

## v1.8

Changed Audio Tracks:

- Replaced the add/remove dropdown workflow with a directly tickable list of
  every audio track, so individual or multiple tracks can be selected at once.
- **Named track groups** let you save selections such as `Voiceover` containing
  `Audio 1` and `Audio 2`; use the same name later to add more tracks.
- Loading a track group ticks exactly its member tracks. **`Colour other
  tracks`** always excludes all currently ticked tracks.

## v1.7

Added:

- **`5. Audio Tracks`** with a dropdown that lists every available timeline
  audio track (`Audio 1`, `Audio 2`, and so on).
- Add several tracks to one selection, then **`Colour tracks`** to colour only
  those tracks, or **`Colour other tracks`** to invert the selection and colour
  every other audio track.

## v1.6

Added:

- **`Remove bucket`** after `Clear` in every bucket row. It removes every
  member from that particular bucket without changing clip colours.
- **`4. Selected Rows`** for actions on only the ticked list rows:
  - **`Rename ticked`** changes the selected audio clip name. When several
    rows are ticked, they receive numbered names such as `Interview 1` and
    `Interview 2`, and their saved bucket/group assignments are retained.
  - **`Colour ticked`** applies the chosen colour directly to just those rows.

## v1.5

Added:

- **`List whole timeline` checkbox** (top right). The list can now show every
  audio clip on the timeline, not just your selection. That is how you see which
  clips make up `Background Music (5)`.
- **`Remove from bucket`** — takes the ticked clips out of whichever bucket they
  are in. Colours are untouched.
- **`Remove ticked`** in Group By — takes the ticked clips out of their group.
- **`Reset all assignments`** — clears every bucket and group assignment for the
  project. Clip colours are not changed.
- Bucket labels now have a tooltip listing their member clip names.

## v1.4

Fixed the "left behind" clips:

- **Bucket and group colours now apply to the whole timeline**, not only to the
  clips that were selected. `Colour` under *Background Music* now colours every
  music clip in the project, including ones you never selected.
- **Invert shows what it is excluding**, e.g.
  `45 to colour, 3 excluded by buckets`. Music clips were being excluded by the
  *Music* checkbox, which is why they stayed behind an Invert pass.
- **New `Colour all audio` button** next to Invert: colours every audio clip on
  the timeline and ignores the bucket exclusions entirely.
- The timeline is scanned once per refresh and shared by buckets, groups and
  Invert, so the counts always agree.

## v1.3

Corrected and added:

- **Nothing is removed from the list any more.** Every audio item Resolve
  returns is listed. Items the API definitively reports with **no media pool
  item** stay visible, tagged `[no media item]`, and colour actions skip them
  with a stated reason instead of hiding them.
- **Real clip no longer dropped on an API error.** In v1.2 any failure of
  `GetMediaPoolItem()` was treated as "not a clip". Now only a clean `nil`
  counts as no media; an error keeps the clip in and it is attempted normally.
- **New `Diagnose` button** (top right). Writes one line per audio item to the
  window log and the Console:

  `A2  Cross Fade -3 dB  start=108080  dur=48  media=nil  colour=  uid=...`

  `media=` is `ok` (with the media name), `nil` (API says there is no media
  item), or `error` (the call failed — the item is still colourable).
- Status lines now say how many items were skipped for having no media.

## v1.2

Added, not removed:

- **Crossfades and transitions are ignored.** `GetItemListInTrack` returns
  Fairlight crossfades (`Cross Fade -3 dB`, `Cross Fade 0 dB`, …) beside the
  real clips. They have no media pool item, Resolve refuses `SetClipColor` on
  them, and that was the `2 failed` in every Invert run. Anything without a
  media pool item is now skipped, so Invert reports 0 failures.
- **Skipped items are named, not hidden.** The header shows
  `N transition(s) ignored` and the startup log lists their names, e.g.
  `Ignored 2 non-clip item(s): Cross Fade -3 dB, Cross Fade 0 dB`.
- Failure diagnostics from v1.1 still print for any real clip that refuses a
  colour.

## v1.1

- **Invert now scans the whole timeline.** New checkbox
  *"Whole timeline (ignore my selection)"*, on by default. Invert colours every
  audio clip that is not in the excluded buckets, so the timeline selection no
  longer matters.
- **Shuffle restored** as *"Shuffle again"*: repeats the last Randomize on the
  same bucket / group / Invert scope with a fresh palette.
- **Failure diagnostics.** Every clip that refuses a colour is now printed in
  the console and the window log with:

  `FAILED <action> <name> A<track> track_locked=<true/false> enabled=<..> start=<..> file=<..> path=<..>`

- **Log lines now name the colour**, e.g.
  `APPLY Invert (whole timeline) [Orange]: 45 changed, 0 skipped, 2 failed`
  versus `[random draw]`, so a history of clicks can be read back.
- Tooltips on every control.
- Version number shown in the startup log line.

## v1.0 — first run

- Three stacked sections: Main Audio, Invert, Group By.
- Tickable Tree list of the selected audio clips.
- Bucket assignment remembered per project in `clipsorter-memory.state`.
- Colour writes verified by read-back; every pass snapshotted to
  `clipsorter-snapshot.state` for *Undo last run*.
- Dry run, Clear ticked colour, per-bucket Colour / Randomize / Clear.
