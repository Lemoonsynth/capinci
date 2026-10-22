<p align="center">
  <img src="Capinci/tools/icon-source.png" width="128" alt="Capinci icon">
</p>
<p align="center">
  <img src="Capinci/Resources/logo.png" width="420" alt="CAPINCI">
</p>

<h3 align="center">Love CapCut, but the job says DaVinci?</h3>
<p align="center">Capinci moves your whole edit across. No rebuilding.</p>

---

Capinci is a small Mac app that reads your CapCut desktop projects and writes an FCPXML
timeline that DaVinci Resolve imports with **File → Import → Timeline…**: cuts, tracks,
compound clips, speed curves, texts, transitions, keyframes and markers come across.

## Download

Get **Capinci-1.0.1.dmg** from the [latest release](../../releases/latest).
macOS 14 (Sonoma) or later, Apple Silicon and Intel.

1. Open the DMG and drag **Capinci** onto **Applications**.
2. The first time, macOS blocks it: Capinci isn't signed with an Apple Developer ID yet.
   Try to open it once, then go to **System Settings → Privacy & Security** and click
   **Open Anyway** next to “Capinci was blocked”. (Or run
   `xattr -dr com.apple.quarantine /Applications/Capinci.app` in Terminal.)

## Using it

1. Capinci lists the projects in CapCut's folder (`~/Movies/CapCut/…`) with their covers.
   For a project elsewhere, use **Open folder** or drop its folder on the window.
2. Pick one → **NEXT** → set the options → **CONVERT** → choose where to save the `.fcpxml`.
3. In Resolve: **File → Import → Timeline…**, pick the file, tick **Use color information**
   (it brings CapCut's brightness, contrast, temperature and fade), **Ok**.

Options:
- **Copy media** — copies every clip next to the timeline with readable names, so the
  Resolve project no longer depends on CapCut's folders and cache.
- **Captions → .srt** — saves CapCut auto-captions as a subtitle file
  (Resolve: File → Import → Subtitle).
- **Auto-install fonts** — installs the fonts CapCut downloaded for your texts.

## What comes across

| Converted | Notes |
|---|---|
| Cuts, every video/audio track, hidden tracks (as disabled clips) | |
| Compound clips (nested) | open with Clip → Open in Timeline |
| Constant speed and **speed curves** | curves keep exact clip length; the ramp inside may differ by a few % |
| Position, scale, rotation, flip, opacity — and their keyframes | linear and ease interpolation |
| Volume, volume keyframes, audio fades | fades become volume keyframes |
| Transitions | Mix → Cross Dissolve, Black Fade → Fade To Color, others → Cross Dissolve + marker |
| Texts and text templates | font, size, colour per range, bold/italic, outline, shadow, alignment, position, line wrapping |
| Markers, HDR10 (Rec. 2020 PQ) tagging, drop-frame timecode | |

Not converted (listed in the app and flagged with markers on the timeline): CapCut effects,
filters and colour adjustments, masks, in/out and text animations.

### HDR projects
Set up the Resolve project **before** importing: Project Settings → Color Management →
*DaVinci YRGB Color Managed*, processing mode *HDR*, output colour space *HDR PQ*; tick
*Use color information* when importing. Otherwise HDR footage looks washed out.

## Building from source

No Xcode needed, only the Command Line Tools:

```bash
cd Capinci
./build.sh            # build/Capinci.app (universal)
./build.sh install    # also copy to /Applications
./build.sh dist       # also make build/Capinci-<version>.dmg
```

There is a command-line version too:

```bash
Capinci/build/capinci-cli "<CapCut project folder>" out.fcpxml [--copy-media <folder>] [--srt]
```

See [Capinci/README.md](Capinci/README.md) for how the code is organised.

## Limits

- Projects that recent CapCut versions encrypt can't be read.
- Media CapCut removed from its cache (stickers, online elements) arrive offline.
- Tested with CapCut 9.5 and DaVinci Resolve 21 on macOS 26.

`legacy/` holds the original Python converter, now frozen.

## License

[MIT](LICENSE) © 2026 Ethereal Moon
