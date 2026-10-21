#!/usr/bin/env python3
"""Convert a CapCut desktop project into an FCPXML timeline for DaVinci Resolve.

FROZEN (2026-10-21): superseded by the Capinci app and its `capinci-cli`
(Capinci/Sources/CapinciCore/Converter.swift), which adds styled texts,
transitions, keyframes and media copying. Kept for reference only.

Usage:
    python3 capcut2davinci.py --list
    python3 capcut2davinci.py "My Project"            # project name or folder path
    python3 capcut2davinci.py "My Project" -o out.fcpxml

Then in Resolve: File > Import > Timeline... and pick the .fcpxml.

What carries over: cuts, every video/audio track (as lanes), compound clips
(as compound clips), speed changes and speed curves, scale/position/rotation/flip,
opacity, clip volume, audio fades, plain text titles and project markers.
What does not: CapCut effects, filters, color adjustments, transitions and
animations. They are left as markers so you can see where to redo them.
"""

import argparse
import json
import math
import os
import re
import sys
from fractions import Fraction
from urllib.parse import quote
from xml.sax.saxutils import escape, quoteattr

DEFAULT_ROOT = os.path.expanduser(
    "~/Movies/CapCut/User Data/Projects/com.lveditor.draft"
)
PLACEHOLDER = re.compile(r"##_draftpath_placeholder_[^#]*_##")
US = 1_000_000  # CapCut stores every time in microseconds


def frame_duration(fps):
    """Seconds per frame as an exact fraction (handles 23.976/29.97/59.94)."""
    for rate in (24, 25, 30, 48, 50, 60, 120):
        ntsc = rate * 1000 / 1001
        if abs(fps - ntsc) < 0.01:
            return Fraction(1001, rate * 1000)
        if abs(fps - rate) < 0.01:
            return Fraction(1, rate)
    return Fraction(1, round(fps))


def rational(seconds):
    seconds = Fraction(seconds)
    if seconds.denominator == 1:
        return f"{seconds.numerator}s"
    return f"{seconds.numerator}/{seconds.denominator}s"


class Converter:
    def __init__(self, project_dir):
        self.project_dir = project_dir
        self.draft = self._load_draft(project_dir)
        self.fd = frame_duration(self.draft["fps"])
        canvas = self.draft.get("canvas_config") or {}
        self.width = int(canvas.get("width") or 1920)
        self.height = int(canvas.get("height") or 1080)
        self.tc_format = "DF" if self.draft.get("is_drop_frame_timecode") and self.fd.numerator == 1001 else "NDF"
        # CapCut stores the HDR transfer as its SMPTE number: 2084 = PQ (HDR10)
        self.color_space = "Rec. 2020 PQ" if self.draft.get("color_space") == 2084 else None
        self.assets = {}  # resolved path -> (asset id, xml)
        self.media = []  # compound clip <media> xml, in dependency order
        self.next_id = 2  # r1 is the sequence format
        self.title_styles = 0
        self.needs_title_effect = False
        self.report = {
            "clips": 0,
            "compound clips": 0,
            "speed changes": 0,
            "speed curves": 0,
            "titles": 0,
            "markers": 0,
            "missing media": set(),
            "dropped (not convertible)": {},
        }

    # ---- loading -------------------------------------------------------

    @staticmethod
    def _load_draft(project_dir):
        for name in ("draft_info.json", "draft_content.json"):
            path = os.path.join(project_dir, name)
            if os.path.exists(path):
                with open(path, encoding="utf-8") as f:
                    try:
                        return json.load(f)
                    except json.JSONDecodeError:
                        sys.exit(
                            f"{path} is not plain JSON (newer CapCut versions "
                            "encrypt projects); this version can't read it."
                        )
        sys.exit(f"No draft_info.json in {project_dir}")

    def resolve_path(self, path):
        return PLACEHOLDER.sub(lambda _: self.project_dir, path or "")

    # ---- helpers -------------------------------------------------------

    def frames(self, us):
        return round(Fraction(us) / US / self.fd)

    def t(self, frames):
        return rational(frames * self.fd)

    def new_id(self):
        rid = f"r{self.next_id}"
        self.next_id += 1
        return rid

    def drop(self, what):
        dropped = self.report["dropped (not convertible)"]
        dropped[what] = dropped.get(what, 0) + 1

    def asset_for(self, material):
        path = self.resolve_path(material.get("path"))
        is_photo = material.get("type") == "photo"
        # CapCut audio can be a video file's soundtrack ("video_original_sound"):
        # it needs its own audio-only asset, or Resolve brings the picture too.
        is_audio = material.get("type") not in ("video", "photo")
        key = (path, is_audio)
        if key in self.assets:
            return self.assets[key][0]
        if not os.path.exists(path):
            self.report["missing media"].add(path)
        rid = self.new_id()
        has_audio = is_audio or (not is_photo and material.get("has_audio", True))
        duration = self.frames(material.get("duration") or 0) or 1
        name = material.get("material_name") or material.get("name") or os.path.basename(path)
        attrs = (
            f'id="{rid}" name={quoteattr(name)} start="0s" duration="{self.t(duration)}"'
            f' hasVideo="{0 if is_audio else 1}" hasAudio="{1 if has_audio else 0}"'
        )
        if has_audio:
            attrs += ' audioSources="1" audioChannels="2" audioRate="48000"'
        xml = (
            f"    <asset {attrs}>\n"
            f'      <media-rep kind="original-media" src={quoteattr("file://" + quote(path))}/>\n'
            f"    </asset>"
        )
        self.assets[key] = (rid, xml)
        return rid

    # ---- per-segment conversion ----------------------------------------

    def convert_draft(self, draft, indent):
        """Return (clip xml list, marker xml list, duration in frames)."""
        materials = draft["materials"]
        by_id = {}
        for kind, items in materials.items():
            if isinstance(items, list):
                for item in items:
                    if isinstance(item, dict) and "id" in item:
                        by_id[item["id"]] = (kind, item)

        clips, markers = [], []
        video_lane, audio_lane = 0, 0
        for track in draft["tracks"]:
            kind = track["type"]
            if kind == "audio":
                audio_lane -= 1
                lane = audio_lane
            elif kind in ("video", "text", "sticker"):
                video_lane += 1
                lane = video_lane
            else:
                lane = None  # effect / filter / adjust tracks become markers
            for seg in track["segments"]:
                out = self.convert_segment(seg, kind, lane, by_id, indent)
                if out:
                    (clips if out[0] == "clip" else markers).append(out[1])
                # anything attached that we can't reproduce becomes a marker
                for ref in seg.get("extra_material_refs", []):
                    ref_kind, ref_item = by_id.get(ref, (None, None))
                    if ref_kind == "transitions":
                        self.drop("transition")
                        end = seg["target_timerange"]["start"] + seg["target_timerange"]["duration"]
                        markers.append(self.marker(end, f"Transition: {ref_item.get('name') or 'CapCut'}", indent))
                    elif ref_kind in ("material_animations",) and ref_item.get("animations"):
                        self.drop("in/out animation")
                    elif ref_kind in ("effects", "video_effects", "filters") and ref_item.get("type") not in (None, "", "speed"):
                        self.drop(f"clip {ref_kind[:-1]} ({ref_item.get('type')})")
                    elif ref_kind in ("common_mask", "masks"):
                        self.drop("mask")
                if seg.get("common_keyframes"):
                    self.drop("keyframed segment (static values used)")

        for mark_set in materials.get("time_marks") or []:
            for item in mark_set.get("mark_items") or []:
                start = (item.get("time_range") or {}).get("start", 0)
                markers.append(self.marker(start, item.get("title") or "Marker", indent))

        duration = self.frames(draft.get("duration") or 0)
        end_of_clips = max(
            (self.frames(s["target_timerange"]["start"] + s["target_timerange"]["duration"])
             for t in draft["tracks"] for s in t["segments"]),
            default=0,
        )
        duration = max(duration, end_of_clips, 1)
        markers = [m for m in markers if m[0] < duration]
        return clips, [m[1] for m in markers], duration

    def marker(self, start_us, name, indent):
        self.report["markers"] += 1
        f = self.frames(start_us)
        return (f, f'{indent}<marker start="{self.t(f)}" duration="{rational(self.fd)}" value={quoteattr(name)}/>')

    def convert_segment(self, seg, kind, lane, by_id, indent):
        mat_kind, mat = by_id.get(seg["material_id"], (None, None))
        tr = seg["target_timerange"]
        start_f = self.frames(tr["start"])
        end_f = self.frames(tr["start"] + tr["duration"])
        dur_f = end_f - start_f
        if dur_f <= 0:
            return None

        if lane is None or mat is None:
            name = (mat or {}).get("name") or (mat or {}).get("type") or kind
            self.drop(f"{kind} track item")
            return ("marker", self.marker(tr["start"], f"{kind.capitalize()}: {name}", indent))

        if mat_kind == "texts":
            return ("clip", self.title(seg, mat, lane, start_f, dur_f, indent))
        if mat_kind not in ("videos", "audios"):
            self.drop(f"{mat_kind} item")
            return ("marker", self.marker(tr["start"], f"{mat_kind}: {mat.get('name') or ''}", indent))

        enabled = "" if seg.get("visible", True) else ' enabled="0"'
        src = seg.get("source_timerange") or {"start": 0, "duration": tr["duration"]}
        speed = src["duration"] / tr["duration"] if src.get("duration") else 1.0
        if abs(speed - 1) < 0.001:
            speed = 1.0

        compound = None
        if not mat.get("path"):
            compound = next(
                (item for ref in seg.get("extra_material_refs", [])
                 for k, item in [by_id.get(ref, (None, None))] if k == "drafts"),
                None,
            )
            if compound is None:
                self.drop("media without file")
                return None

        if compound is not None:
            ref, media_frames = self.compound_media(compound, mat.get("material_name"))
            tag = "ref-clip"
            # an audio-only compound would otherwise get an empty video track
            if all(t["type"] == "audio" for t in (compound.get("draft") or {}).get("tracks", [])):
                enabled += ' srcEnable="audio"'
        else:
            ref = self.asset_for(mat)
            media_frames = self.frames(mat.get("duration") or 0)
            tag = "asset-clip"
            if kind == "audio":
                enabled += ' srcEnable="audio"'

        # Clip `start` is in the clip's local (retimed) time; the timeMap maps
        # local time back to media time across the whole media.
        local_start = self.frames(src["start"] / speed)
        children = []
        curve = next(
            (item["curve_speed"] for ref in seg.get("extra_material_refs", [])
             for k, item in [by_id.get(ref, (None, None))]
             if k == "speeds" and (item.get("curve_speed") or {}).get("speed_points")),
            None,
        )
        if curve:
            self.report["speed curves"] += 1
            local_start = self.frames(src["start"])
            children.append(self.curve_time_map(curve["speed_points"], src, tr["duration"], indent))
        elif speed != 1.0:
            self.report["speed changes"] += 1
            end_local = max(media_frames, 1) / speed
            children.append(
                f'{indent}  <timeMap>\n'
                f'{indent}    <timept time="0s" value="0s" interp="linear"/>\n'
                f'{indent}    <timept time="{rational(Fraction(end_local).limit_denominator(1000) * self.fd)}" '
                f'value="{self.t(max(media_frames, 1))}" interp="linear"/>\n'
                f'{indent}  </timeMap>'
            )

        clip = seg.get("clip")
        if clip and mat_kind == "videos":
            children += self.transform(clip, indent)

        volume = seg.get("volume", 1.0)
        if mat.get("type") != "photo":
            children += self.volume(seg, volume, by_id, indent)

        name = mat.get("material_name") or mat.get("name") or "Clip"
        if compound is not None:
            name = name or "Compound clip"
        self.report["clips"] += 1
        body = "\n".join(children)
        head = (
            f'{indent}<{tag} ref="{ref}" lane="{lane}" offset="{self.t(start_f)}" '
            f'start="{self.t(local_start)}" duration="{self.t(dur_f)}" name={quoteattr(name)}{enabled}'
        )
        return ("clip", f"{head}>\n{body}\n{indent}</{tag}>" if body else f"{head}/>")

    def curve_time_map(self, points, src, target_us, indent, ramp_steps=6):
        """timeMap for a CapCut speed curve.

        CapCut spreads the speed points over the source clip (x = 0..1 of the
        used media). Interpolating them linearly gives the right shape, but
        CapCut smooths the curve in a way that changes the total duration by a
        few percent, so the timing is rescaled to land exactly on CapCut's
        clip length: the cut points stay frame-accurate, the ramp may differ
        slightly inside the clip.
        """
        pts = sorted(points, key=lambda p: p["x"])

        def speed_at(x):
            for a, b in zip(pts, pts[1:]):
                if a["x"] <= x <= b["x"] and b["x"] > a["x"]:
                    u = (x - a["x"]) / (b["x"] - a["x"])
                    return max(0.01, a["y"] + (b["y"] - a["y"]) * u)
            return max(0.01, pts[-1]["y"])

        # Resolve turns every time point into its own speed segment, so keep
        # them few: flat spans need none, ramps get `ramp_steps` steps.
        xs = {0.0, 1.0} | {p["x"] for p in pts if 0 <= p["x"] <= 1}
        for a, b in zip(pts, pts[1:]):
            if abs(a["y"] - b["y"]) > 0.01 and b["x"] - a["x"] > 0.02:
                xs |= {a["x"] + (b["x"] - a["x"]) * i / ramp_steps for i in range(1, ramp_steps)}
        xs = sorted(x for x in xs if 0 <= x <= 1)
        elapsed = [0.0]  # timeline time spent to reach each x, in source units
        for a, b in zip(xs, xs[1:]):
            steps = 32
            h = (b - a) / steps
            elapsed.append(elapsed[-1] + sum(h / speed_at(a + (i + 0.5) * h) for i in range(steps)))
        scale = target_us / elapsed[-1]

        def exact(us):  # seconds, rounded to 1/100 of a frame
            return rational(Fraction(round(Fraction(us) / US / self.fd * 100), 100) * self.fd)

        start = src["start"]
        lines = [f'{indent}    <timept time="0s" value="0s" interp="linear"/>']
        if start > 0:
            lines.append(f'{indent}    <timept time="{exact(start)}" value="{exact(start)}" interp="linear"/>')
        for x, e in zip(xs[1:], elapsed[1:]):
            lines.append(
                f'{indent}    <timept time="{exact(start + e * scale)}" '
                f'value="{exact(start + x * src["duration"])}" interp="linear"/>'
            )
        return f"{indent}  <timeMap>\n" + "\n".join(lines) + f"\n{indent}  </timeMap>"

    def transform(self, clip, indent):
        out = []
        scale = clip.get("scale") or {}
        sx, sy = scale.get("x", 1.0), scale.get("y", 1.0)
        flip = clip.get("flip") or {}
        if flip.get("horizontal"):
            sx = -sx
        if flip.get("vertical"):
            sy = -sy
        pos = clip.get("transform") or {}
        # CapCut: x/y = 1 moves the centre by half the canvas. FCPXML: units are
        # percent of the frame height, y up.
        px = pos.get("x", 0.0) * (self.width / 2) / self.height * 100
        py = pos.get("y", 0.0) * 50
        rot = -(clip.get("rotation") or 0.0) + 0.0  # CapCut turns clockwise; + 0.0 avoids "-0.0000"
        if (sx, sy, px, py, rot) != (1, 1, 0, 0, 0):
            out.append(
                f'{indent}  <adjust-transform position="{px:.4f} {py:.4f}" '
                f'scale="{sx:.6f} {sy:.6f}" rotation="{rot:.4f}" anchor="0 0"/>'
            )
        alpha = clip.get("alpha", 1.0)
        if alpha < 0.999:
            out.append(f'{indent}  <adjust-blend amount="{alpha:.4f}"/>')
        return out

    def volume(self, seg, volume, by_id, indent):
        fade = next(
            (item for ref in seg.get("extra_material_refs", [])
             for k, item in [by_id.get(ref, (None, None))] if k == "audio_fades"),
            None,
        )
        fade_in = self.frames(fade.get("fade_in_duration", 0)) if fade else 0
        fade_out = self.frames(fade.get("fade_out_duration", 0)) if fade else 0
        if abs(volume - 1) < 0.001 and not fade_in and not fade_out:
            return []
        db = -96.0 if volume <= 0 else max(-96.0, 20 * math.log10(volume))
        if not fade_in and not fade_out:
            return [f'{indent}  <adjust-volume amount="{db:.2f}dB"/>']
        fades = ""
        if fade_in:
            fades += f'{indent}      <fadeIn type="easeIn" duration="{self.t(fade_in)}"/>\n'
        if fade_out:
            fades += f'{indent}      <fadeOut type="easeOut" duration="{self.t(fade_out)}"/>\n'
        return [
            f'{indent}  <adjust-volume amount="{db:.2f}dB">\n'
            f'{indent}    <param name="amount">\n{fades}{indent}    </param>\n'
            f'{indent}  </adjust-volume>'
        ]

    def title(self, seg, mat, lane, start_f, dur_f, indent):
        self.needs_title_effect = True
        self.report["titles"] += 1
        text = mat.get("content") or ""
        try:
            text = json.loads(text).get("text", text)
        except (ValueError, AttributeError):
            pass
        self.drop("text styling/animation (plain title kept)")
        self.title_styles += 1
        sid = f"ts{self.title_styles}"
        return (
            f'{indent}<title ref="r_title" lane="{lane}" offset="{self.t(start_f)}" '
            f'start="0s" duration="{self.t(dur_f)}" name={quoteattr(text[:40] or "Text")}>\n'
            f'{indent}  <text><text-style ref="{sid}">{escape(text)}</text-style></text>\n'
            f'{indent}  <text-style-def id="{sid}"><text-style font="Helvetica" fontSize="72" '
            f'fontColor="1 1 1 1" alignment="center"/></text-style-def>\n'
            f'{indent}</title>'
        )

    def compound_media(self, compound, name=None):
        if "_media_id" in compound:
            return compound["_media_id"], compound["_media_frames"]
        self.report["compound clips"] += 1
        sub = compound.get("draft")
        if sub is None:
            path = self.resolve_path(compound.get("draft_file_path"))
            with open(path, encoding="utf-8") as f:
                sub = json.load(f)
        clips, markers, duration = self.convert_draft(sub, " " * 12)
        rid = self.new_id()
        name = name or compound.get("name") or f"Compound clip {self.report['compound clips']}"
        body = "\n".join(clips + markers)
        self.media.append(
            f'    <media id="{rid}" name={quoteattr(name)}>\n'
            f'      <sequence format="r1" duration="{self.t(duration)}" tcStart="0s" tcFormat="{self.tc_format}">\n'
            f'        <spine>\n'
            f'          <gap name="Gap" offset="0s" start="0s" duration="{self.t(duration)}">\n'
            f'{body}\n'
            f'          </gap>\n'
            f'        </spine>\n'
            f'      </sequence>\n'
            f'    </media>'
        )
        compound["_media_id"], compound["_media_frames"] = rid, duration
        return rid, duration

    # ---- document --------------------------------------------------------

    def build(self, name):
        clips, markers, duration = self.convert_draft(self.draft, " " * 12)
        resources = [
            f'    <format id="r1" name="CapCut {self.width}x{self.height}" '
            f'frameDuration="{rational(self.fd)}" width="{self.width}" height="{self.height}"'
            + (f' colorSpace="{self.color_space}"' if self.color_space else "") + "/>"
        ]
        if self.needs_title_effect:
            resources.append(
                '    <effect id="r_title" name="Basic Title" '
                'uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>'
            )
        resources += [xml for _, xml in self.assets.values()]
        resources += self.media
        body = "\n".join(clips + markers)
        return (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<!DOCTYPE fcpxml>\n"
            '<fcpxml version="1.9">\n'
            "  <resources>\n" + "\n".join(resources) + "\n  </resources>\n"
            "  <library>\n"
            f"    <event name={quoteattr(name)}>\n"
            f"      <project name={quoteattr(name)}>\n"
            f'        <sequence format="r1" duration="{self.t(duration)}" tcStart="0s" tcFormat="{self.tc_format}">\n'
            "          <spine>\n"
            f'            <gap name="Gap" offset="0s" start="0s" duration="{self.t(duration)}">\n'
            f"{body}\n"
            "            </gap>\n"
            "          </spine>\n"
            "        </sequence>\n"
            "      </project>\n"
            "    </event>\n"
            "  </library>\n"
            "</fcpxml>\n"
        )


def find_project(arg, root):
    if os.path.isdir(arg):
        return os.path.abspath(arg)
    path = os.path.join(root, arg)
    if os.path.isdir(path):
        return path
    sys.exit(f'Project "{arg}" not found in {root} (use --list)')


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("project", nargs="?", help="CapCut project name or folder")
    parser.add_argument("-o", "--output", help="output .fcpxml path")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="CapCut projects folder")
    parser.add_argument("--list", action="store_true", help="list CapCut projects")
    args = parser.parse_args()

    if args.list or not args.project:
        for name in sorted(os.listdir(args.root)):
            if os.path.exists(os.path.join(args.root, name, "draft_info.json")):
                print(name)
        return

    project_dir = find_project(args.project, args.root)
    name = os.path.basename(project_dir.rstrip("/"))
    converter = Converter(project_dir)
    xml = converter.build(name)
    output = args.output or os.path.join(os.getcwd(), f"{name}.fcpxml")
    with open(output, "w", encoding="utf-8") as f:
        f.write(xml)

    r = converter.report
    print(f"Wrote {output}")
    print(f"  {r['clips']} clips, {r['compound clips']} compound clips, "
          f"{r['speed changes']} speed changes, {r['speed curves']} speed curves, "
          f"{r['titles']} titles, {r['markers']} markers")
    if r["missing media"]:
        print(f"  {len(r['missing media'])} media files not found (will show offline):")
        for path in sorted(r["missing media"]):
            print(f"    {path}")
    if r["dropped (not convertible)"]:
        print("  Not converted (redo in Resolve; most are marked on the timeline):")
        for what, count in sorted(r["dropped (not convertible)"].items()):
            print(f"    {count:3d} x {what}")


if __name__ == "__main__":
    main()
