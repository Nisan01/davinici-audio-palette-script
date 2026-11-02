# mrc-audioPalette

<p align="center">
  <img src="https://img.shields.io/badge/DaVinci%20Resolve-21.x-1f1f1f?style=for-the-badge&logo=blackmagicdesign&logoColor=white" alt="DaVinci Resolve 21.x">
  <img src="https://img.shields.io/badge/Latest-v1.6-6f42c1?style=for-the-badge" alt="Latest version v1.6">
  <img src="https://img.shields.io/badge/Language-Lua-2C2D72?style=for-the-badge&logo=lua&logoColor=white" alt="Lua">
</p>

<p align="center">
  A focused DaVinci Resolve utility for organizing, naming, and colour-coding
  audio clips and tracks directly on the timeline.
</p>

## What it does

`mrc-audioPalette` turns a busy audio timeline into a manageable visual
overview. Select clips or tracks, assign them to meaningful groups, apply
consistent colours, and keep the organization saved per project.

The script is designed for editors working with voiceover, music, sound
effects, ambience, dialogue, and other recurring audio categories.

## Latest release — v1.6

The latest build is available here:

**[Download `mrc-audioPalette-v1.6.lua`](versions/mrc-audioPalette-v1.6.lua)**

### Highlights

- **Five focused sections**
  - **Main Audio** — classify clips into Voiceover, Music, SFX, and Ambience.
  - **Invert** — colour clips outside excluded buckets, with whole-timeline
    scanning available.
  - **Group By** — create hand-picked clip groups with their own colour pool.
  - **Selected Rows** — rename or colour only the checked rows.
  - **Audio Tracks** — select tracks directly and colour them as a set.
- **Named track groups** — save reusable selections such as `Voiceover` made
  from `Audio 1` and `Audio 2`.
- **Timeline-wide colouring** — bucket and group colours apply to every
  matching clip on the timeline, not only the current selection.
- **Safe preview mode** — use **Dry run** to see what would change before
  writing colours or names.
- **Non-clip awareness** — crossfades and transitions remain visible but are
  identified and skipped safely because they have no media pool item.
- **Diagnostics** — inspect media status and colour failures with the
  **Diagnose** button and the Resolve console.
- **Revert support** — undo the last colour or clear pass without relying on
  Resolve's global undo history.
- **Legacy migration** — existing ClipSorter assignment and snapshot state is
  read as a fallback when the renamed script is first used.

## Installation

1. Download [the latest v1.6 script](versions/mrc-audioPalette-v1.6.lua).
2. Copy it to DaVinci Resolve's Fusion Utility Scripts folder:

   ```text
   %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\
   ```

3. Open DaVinci Resolve and open a project with a timeline.
4. Run the script from **Workspace > Scripts > Utility > mrc-audioPalette**.

If the `Utility` folder does not exist, create it manually. Keep the `.lua`
extension unchanged.

## Quick start

1. Open a timeline containing audio clips.
2. Run `mrc-audioPalette`.
3. Refresh the clip list if the timeline has changed.
4. Tick clips or tracks to work with.
5. Add clips to a bucket or group, choose a colour, and use **Colour**.
6. Use **Dry run** first when working on an important timeline.
7. Use **Revert last run** if you need to undo the script's most recent colour
   or clear operation.

For large timelines, enable **List whole timeline** when you need to inspect
or organize clips outside the current Resolve selection.

## Data and safety

The script stores project-specific state beside the script:

```text
mrc-audioPalette-memory.state
mrc-audioPalette-snapshot.state
```

- The memory file stores bucket, group, and named-track-group assignments.
- The snapshot file stores the previous colour state used by **Revert**.
- Colour changes are verified by reading the colour back from Resolve.
- Items that Resolve reports as having no media pool item are not coloured or
  renamed, and remain visible with a clear status.
- **Clear** removes colours; **Remove** actions change assignments without
  changing clip colours.

Back up these `.state` files if you want to preserve organization between
machines or installations.

## Compatibility

- DaVinci Resolve **21.x**
- Windows installation path shown above
- Fusion scripting with Lua and Resolve's `UIManager`
- A project and an open timeline are required

## Version history

Detailed implementation notes are maintained in
[CHANGELOG.md](CHANGELOG.md). The release table below intentionally keeps the
current version at the top.

| Version | Status | Archive |
| --- | --- | --- |
| **v1.6** | Current | [mrc-audioPalette-v1.6.lua](versions/mrc-audioPalette-v1.6.lua) |
| v1.5 | Archived | [mrc-audioPalette-v1.5.lua](versions/mrc-audioPalette-v1.5.lua) |
| v1.4 | Archived | [mrc-audioPalette-v1.4.lua](versions/mrc-audioPalette-v1.4.lua) |
| v1.3 | Archived | [mrc-audioPalette-v1.3.lua](versions/mrc-audioPalette-v1.3.lua) |
| v1.2 | Archived | [mrc-audioPalette-v1.2.lua](versions/mrc-audioPalette-v1.2.lua) |
| v1.1 | Archived | [mrc-audioPalette-v1.1.lua](versions/mrc-audioPalette-v1.1.lua) |
| v1.0 | Archived | [mrc-audioPalette-v1.0.lua](versions/mrc-audioPalette-v1.0.lua) |

## Troubleshooting

### The script does not appear in Workspace > Scripts

Confirm that the file is in the `Fusion\Scripts\Utility` folder, that the
extension is `.lua`, and that Resolve was restarted after the file was copied.

### A transition appears in the list

This is expected. Resolve exposes crossfades and transitions alongside real
audio clips. They remain visible for transparency but are marked as having no
media item and are skipped by colour actions.

### A clip refuses a colour

Use **Diagnose** and check the Resolve console. The diagnostic output includes
the clip name, track, lock state, enabled state, start position, media file,
and file path to help identify the cause.

## Project files

```text
.
├── CHANGELOG.md
├── README.md
└── versions/
    ├── mrc-audioPalette-v1.0.lua
    ├── mrc-audioPalette-v1.1.lua
    ├── mrc-audioPalette-v1.2.lua
    ├── mrc-audioPalette-v1.3.lua
    ├── mrc-audioPalette-v1.4.lua
    ├── mrc-audioPalette-v1.5.lua
    └── mrc-audioPalette-v1.6.lua
```

Archived builds are never overwritten. Use the versioned file when you need
to reproduce an older workflow.

## License

No license file is currently included in this repository. Add a license before
redistributing the script or incorporating it into another project.