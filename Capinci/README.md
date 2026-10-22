# Capinci

Native Mac app (SwiftUI) that turns a CapCut project into a DaVinci Resolve timeline (FCPXML).
No dependencies. Its converter is the reference one (`../capcut2davinci.py` is frozen).

## Using it
1. Open **Capinci**: your CapCut projects are listed, most recent first.
   Project elsewhere? ⌘O, or drop its folder onto the window.
2. Pick a project, set the options, click **Convert…** (⌘↩) and choose where to save the `.fcpxml`.
   - **Copy media next to the timeline** (off by default): copies the clips into `<name> Media/`
     beside the timeline, with readable names, so the Resolve project no longer depends on CapCut.
   - **Export captions as subtitles (.srt)**: CapCut auto-captions → `.srt` (Resolve: File → Import → Subtitle).
3. In Resolve: File → Import → Timeline…, tick **Use color information**. The app recalls the steps, and the HDR settings when needed.
   Fonts CapCut downloaded can be installed from the result card.

## What converts
Cuts, every track, compound clips, speed changes and speed curves, reversed clips,
position/scale/rotation/flip/opacity, keyframes on those and on volume (linear or ease), audio fades
(as volume keyframes), fade in/out animations (as opacity keyframes), transitions (Mix → Cross Dissolve,
Black Fade → Dip To Color, other CapCut transitions → Cross Dissolve + note; on upper tracks dissolves
become opacity fades), blend modes, brightness/contrast/temperature/fade (as an ASC CDL grade, imported
when *Use color information* is ticked), styled texts and text templates (font, size, colour per range,
bold/italic, outline, shadow, alignment, position), HDR (Rec. 2020 PQ) and drop-frame timecode.
Sounds in CapCut's private folder are copied next to the timeline.
Not converted (listed in the app and flagged with disabled "⚑" titles above the video, since Resolve
ignores FCPXML markers): CapCut effects, filters, saturation, highlights/shadows, masks, other in/out and
text animations, voice effects.

The app checks GitHub for a newer release at launch (`Updates.swift`) and shows a Download banner.

## Building
```bash
./build.sh            # → build/Capinci.app (+ build/capinci-cli)
./build.sh install    # also copies it to /Applications
```
Built with `swiftc` from the Command Line Tools (no Xcode). `tools/overlay.yaml.in` works around a
Command Line Tools bug (duplicate SwiftBridging module) without touching the system.

## Command line
```bash
build/capinci-cli "<project folder>" out.fcpxml [--copy-media "<folder>"] [--srt]
```

## Files
- `Sources/CapinciCore/Converter.swift` — the converter
- `Sources/CapinciCore/Project.swift` — project list and details (duration, fps, HDR, captions)
- `Sources/Capinci/` — the interface
- `tools/make-icon.swift` — draws the app icon
