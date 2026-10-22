// CapCut desktop project -> FCPXML timeline for DaVinci Resolve.
//
// This is the reference converter (it started as a port of ../capcut2davinci.py,
// which is now frozen). `capinci-cli` runs it from the command line.

import CoreText
import Foundation

typealias JSON = [String: Any]

let US = 1_000_000.0  // CapCut stores every time in microseconds

public enum ConverterError: LocalizedError {
    case noDraft(String)
    case encrypted(String)

    public var errorDescription: String? {
        switch self {
        case .noDraft(let path):
            return "No draft_info.json in \(path)."
        case .encrypted(let path):
            return "\(path) can't be read (recent CapCut versions encrypt some projects)."
        }
    }
}

public struct ConversionOptions {
    /// Copy every media file into this folder (with readable names) and point the timeline at the copies.
    public var mediaFolder: URL?
    public init(mediaFolder: URL? = nil) { self.mediaFolder = mediaFolder }
}

public struct FontUse: Hashable {
    public let family: String
    /// The font file in CapCut's cache; nil once CapCut has purged it.
    public let file: String?
    public let installed: Bool

    /// What a CapCut font path refers to, and the family/face to name it by in the timeline.
    static func lookup(_ path: String) -> (use: FontUse, name: (family: String, face: String)?) {
        let installedFamilies = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor],
           let d = descriptors.first,
           let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
            let face = CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? "Regular"
            return (FontUse(family: family, file: path, installed: installedFamilies.contains(family)), (family, face))
        }
        // CapCut cleared the file from its cache; its name is usually the
        // PostScript name ("IMFellDWPicaSC-Regular"), which Resolve can match.
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard stem.lowercased() != "font" else {
            return (FontUse(family: "Unknown CapCut font", file: nil, installed: false), nil)
        }
        let parts = stem.split(separator: "-", maxSplits: 1).map(String.init)
        let name = (parts[0], parts.count > 1 ? parts[1] : "Regular")
        return (FontUse(family: name.0, file: nil, installed: installedFamilies.contains(name.0)), name)
    }

    /// Every font the project's texts use, without converting it.
    static func used(in draft: JSON) -> [FontUse] {
        var paths: Set<String> = []
        func collect(_ draft: JSON) {
            let materials = draft.obj("materials") ?? [:]
            for text in materials.objects("texts") {
                if let path = text.text("font_path") { paths.insert(path) }
                if let raw = text.text("content"), let data = raw.data(using: .utf8),
                   let content = try? JSONSerialization.jsonObject(with: data) as? JSON {
                    for style in content.objects("styles") {
                        if let path = style.obj("font")?.text("path") { paths.insert(path) }
                    }
                }
            }
            for compound in materials.objects("drafts") { if let sub = compound.obj("draft") { collect(sub) } }
        }
        collect(draft)
        var byFamily: [String: FontUse] = [:]
        for path in paths {
            let use = lookup(path).use
            // prefer an entry that still has its file, so it can be installed
            if byFamily[use.family]?.file == nil { byFamily[use.family] = use }
        }
        return byFamily.values.sorted { $0.family.localizedCaseInsensitiveCompare($1.family) == .orderedAscending }
    }

    /// Copies fonts CapCut downloaded into ~/Library/Fonts, where Resolve (after a restart) finds them.
    /// Returns the families installed.
    @discardableResult
    public static func install(_ fonts: [FontUse]) -> [String] {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var installed: [String] = []
        for font in fonts where !font.installed {
            guard let file = font.file else { continue }
            let ext = (file as NSString).pathExtension.isEmpty ? "ttf" : (file as NSString).pathExtension
            let safe = font.family.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            let destination = folder.appendingPathComponent("\(safe).\(ext)")
            if FileManager.default.fileExists(atPath: destination.path)
                || (try? FileManager.default.copyItem(atPath: file, toPath: destination.path)) != nil {
                installed.append(font.family)
            }
        }
        return installed
    }
}

public struct ConversionReport {
    public var clips = 0
    public var compoundClips = 0
    public var speedChanges = 0
    public var speedCurves = 0
    public var titles = 0
    public var subtitles = 0
    public var transitions = 0
    public var keyframedClips = 0
    public var markers = 0
    public var missingMedia: Set<String> = []
    public var fonts: Set<FontUse> = []
    /// What CapCut had that FCPXML can't carry, keyed by an English label.
    public var dropped: [String: Int] = [:]
}

// MARK: - Exact time arithmetic

struct Rational {
    var num: Int64
    var den: Int64

    init(_ num: Int64, _ den: Int64 = 1) {
        let g = Rational.gcd(abs(num), abs(den))
        let sign: Int64 = den < 0 ? -1 : 1
        self.num = g == 0 ? 0 : sign * num / g
        self.den = g == 0 ? 1 : sign * den / g
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }

    /// FCPXML time value: "3s" or "1001/60000s".
    var seconds: String { den == 1 ? "\(num)s" : "\(num)/\(den)s" }

    var double: Double { Double(num) / Double(den) }
}

/// Integer division rounded half-to-even, like Python's round() on a Fraction.
private func roundHalfEven(_ n: Int64, _ d: Int64) -> Int64 {
    var q = n / d
    var r = n % d
    if r < 0 { q -= 1; r += d }
    if 2 * r > d || (2 * r == d && q % 2 != 0) { q += 1 }
    return q
}

/// Seconds per frame as an exact fraction (handles 23.976/29.97/59.94).
func frameDuration(_ fps: Double) -> Rational {
    for rate in [24, 25, 30, 48, 50, 60, 120] {
        if abs(fps - Double(rate) * 1000 / 1001) < 0.01 { return Rational(1001, Int64(rate) * 1000) }
        if abs(fps - Double(rate)) < 0.01 { return Rational(1, Int64(rate)) }
    }
    return Rational(1, Int64(fps.rounded()))
}

/// Python's Fraction.limit_denominator, applied to a Double.
func limitDenominator(_ x: Double, _ maxDen: Int64) -> Rational {
    if x.isZero || !x.isFinite { return Rational(0) }
    let exp = x.exponent - Int(x.significandWidth)
    guard exp > -62, exp < 10 else { return Rational(Int64((x * Double(maxDen)).rounded()), maxDen) }
    var n = exp < 0 ? Int64(x * pow(2, Double(-exp))) : Int64(x)
    var d: Int64 = exp < 0 ? Int64(1) << Int64(-exp) : 1
    if d <= maxDen { return Rational(n, d) }
    var (p0, q0, p1, q1): (Int64, Int64, Int64, Int64) = (0, 1, 1, 0)
    while true {
        let a = n / d
        let q2 = q0 + a * q1
        if q2 > maxDen { break }
        (p0, q0, p1, q1) = (p1, q1, p0 + a * p1, q2)
        (n, d) = (d, n - a * d)
    }
    let k = (maxDen - q0) / q1
    let bound1 = Rational(p0 + k * p1, q0 + k * q1)
    let bound2 = Rational(p1, q1)
    return abs(bound2.double - x) <= abs(bound1.double - x) ? bound2 : bound1
}

// MARK: - XML helpers

func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func quoteAttr(_ s: String) -> String {
    var v = xmlEscape(s)
        .replacingOccurrences(of: "\n", with: "&#10;")
        .replacingOccurrences(of: "\r", with: "&#13;")
        .replacingOccurrences(of: "\t", with: "&#9;")
    if v.contains("\"") {
        if v.contains("'") {
            v = v.replacingOccurrences(of: "\"", with: "&quot;")
        } else {
            return "'\(v)'"
        }
    }
    return "\"\(v)\""
}

private let urlSafe: CharacterSet = {
    var set = CharacterSet()
    set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~/")
    return set
}()

func fileURLString(_ path: String) -> String {
    "file://" + (path.addingPercentEncoding(withAllowedCharacters: urlSafe) ?? path)
}

func fmt(_ value: Double, _ digits: Int) -> String {
    String(format: "%.\(digits)f", value + 0.0)
}

// MARK: - JSON access with Python-like truthiness

extension Dictionary where Key == String, Value == Any {
    func num(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func str(_ key: String) -> String? { self[key] as? String }
    func obj(_ key: String) -> JSON? { self[key] as? JSON }
    func list(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
    func objects(_ key: String) -> [JSON] { list(key).compactMap { $0 as? JSON } }
    func flag(_ key: String, default value: Bool) -> Bool {
        guard let n = self[key] as? NSNumber else { return value }
        return n.boolValue
    }
    /// Non-empty string, like `x.get(key) or ...` in Python.
    func text(_ key: String) -> String? {
        guard let s = self[key] as? String, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - Loading

public enum CapCutDraft {
    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/CapCut/User Data/Projects/com.lveditor.draft")

    public static func draftFile(in projectDir: URL) -> URL? {
        for name in ["draft_info.json", "draft_content.json"] {
            let url = projectDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func load(_ projectDir: URL) throws -> JSON {
        guard let file = draftFile(in: projectDir) else { throw ConverterError.noDraft(projectDir.path) }
        let data = try Data(contentsOf: file)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            throw ConverterError.encrypted(file.path)
        }
        return json
    }
}

// MARK: - Converter

public final class Converter {
    let projectDir: String
    let draft: JSON
    let fd: Rational
    let width: Int
    let height: Int
    let tcFormat: String
    let colorSpace: String?
    let options: ConversionOptions

    private var assets: [String: (id: String, xml: String)] = [:]
    private var assetOrder: [String] = []
    private var media: [String] = []
    private var compoundCache: [String: (id: String, frames: Int64)] = [:]
    private var effects: [String: String] = [:]  // effect name -> resource id
    private var effectXML: [String] = []
    private var nextId = 2  // r1 is the sequence format
    private var titleStyles = 0
    private var fontCache: [String: (family: String, face: String)?] = [:]
    private var subtitleCues: [(start: Double, end: Double, text: String)] = []
    /// Media to copy when `options.mediaFolder` is set: source path -> destination.
    public private(set) var mediaCopies: [(source: String, destination: URL)] = []
    private var usedCopyNames: Set<String> = []
    public private(set) var report = ConversionReport()

    public init(projectDir: URL, options: ConversionOptions = .init()) throws {
        self.projectDir = projectDir.standardizedFileURL.path
        self.options = options
        draft = try CapCutDraft.load(projectDir)
        fd = frameDuration(draft.num("fps") ?? 30)
        let canvas = draft.obj("canvas_config") ?? [:]
        width = Int(canvas.num("width") ?? 0) == 0 ? 1920 : Int(canvas.num("width")!)
        height = Int(canvas.num("height") ?? 0) == 0 ? 1080 : Int(canvas.num("height")!)
        tcFormat = draft.flag("is_drop_frame_timecode", default: false) && fd.num == 1001 ? "DF" : "NDF"
        // CapCut stores the HDR transfer as its SMPTE number: 2084 = PQ (HDR10)
        colorSpace = draft.num("color_space") == 2084 ? "Rec. 2020 PQ" : nil
    }

    // ---- helpers

    func resolvePath(_ path: String?) -> String {
        guard let path else { return "" }
        guard let regex = try? NSRegularExpression(pattern: "##_draftpath_placeholder_[^#]*_##") else { return path }
        let range = NSRange(path.startIndex..., in: path)
        return regex.stringByReplacingMatches(
            in: path, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: projectDir))
    }

    func frames(_ us: Double) -> Int64 {
        if us == us.rounded(), abs(us) < 1e13 {
            return roundHalfEven(Int64(us) * fd.den, Int64(US) * fd.num)
        }
        return Int64((us / US * Double(fd.den) / Double(fd.num)).rounded(.toNearestOrEven))
    }

    func t(_ frames: Int64) -> String { Rational(frames * fd.num, fd.den).seconds }

    private func newId() -> String {
        defer { nextId += 1 }
        return "r\(nextId)"
    }

    private func drop(_ what: String) { report.dropped[what, default: 0] += 1 }

    private func effect(_ name: String, uid: String) -> String {
        if let id = effects[name] { return id }
        let id = newId()
        effects[name] = id
        effectXML.append("    <effect id=\"\(id)\" name=\(quoteAttr(name)) uid=\(quoteAttr(uid))/>")
        return id
    }

    private func assetFor(_ material: JSON) -> String {
        let path = resolvePath(material.str("path"))
        let type = material.str("type")
        let isPhoto = type == "photo"
        // CapCut audio can be a video file's soundtrack ("video_original_sound"):
        // it needs its own audio-only asset, or Resolve brings the picture too.
        let isAudio = type != "video" && type != "photo"
        let key = "\(isAudio)|\(path)"
        if let existing = assets[key] { return existing.id }
        let exists = FileManager.default.fileExists(atPath: path)
        if !exists { report.missingMedia.insert(path) }
        let rid = newId()
        let hasAudio = isAudio || (!isPhoto && material.flag("has_audio", default: true))
        var duration = frames(material.num("duration") ?? 0)
        if duration == 0 { duration = 1 }
        let name = material.text("material_name") ?? material.text("name") ?? (path as NSString).lastPathComponent
        var src = path
        if exists, let folder = options.mediaFolder {
            src = copyDestination(for: path, readableName: name, in: folder).path
        }
        var attrs = "id=\"\(rid)\" name=\(quoteAttr(name)) start=\"0s\" duration=\"\(t(duration))\""
            + " hasVideo=\"\(isAudio ? 0 : 1)\" hasAudio=\"\(hasAudio ? 1 : 0)\""
        if hasAudio { attrs += " audioSources=\"1\" audioChannels=\"2\" audioRate=\"48000\"" }
        let xml = "    <asset \(attrs)>\n"
            + "      <media-rep kind=\"original-media\" src=\(quoteAttr(fileURLString(src)))/>\n"
            + "    </asset>"
        assets[key] = (rid, xml)
        assetOrder.append(key)
        return rid
    }

    /// Where a media file goes when copying: CapCut renames imports to hashes, so use
    /// the clip's name from CapCut when it has one, keeping the file's extension.
    private func copyDestination(for path: String, readableName: String, in folder: URL) -> URL {
        if let done = mediaCopies.first(where: { $0.source == path }) { return done.destination }
        let ext = (path as NSString).pathExtension
        var stem = (readableName as NSString).deletingPathExtension
        stem = stem.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        var candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
        var n = 2
        while usedCopyNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        usedCopyNames.insert(candidate.lowercased())
        let destination = folder.appendingPathComponent(candidate)
        mediaCopies.append((path, destination))
        return destination
    }

    // ---- per-draft conversion

    private typealias Lookup = [String: (kind: String, item: JSON)]

    /// A converted clip, not yet placed. `make` renders it at a given offset, with a
    /// lane attribute (connected clips) or none (primary storyline), plus any clips
    /// anchored to it.
    private struct Item {
        var start: Int64
        var end: Int64
        /// The clip's own time at its first frame (its `start` attribute).
        var localStart: Int64
        var make: (_ laneAttr: String, _ offset: Int64, _ anchored: [String]) -> String
        var transition: (name: String, frames: Int64)?
    }

    /// One element of the primary storyline, with what gets anchored to it.
    private struct Slot {
        var start: Int64
        var end: Int64
        var localStart: Int64
        var item: Item?          // nil: a gap
        var anchored: [String] = []
        var transition: (name: String, frames: Int64)?
    }

    /// Converts one draft (the project, or a compound clip's sub-draft) into the
    /// children of its primary <spine>, and its duration in frames.
    ///
    /// The first video track becomes the primary storyline, so its transitions are
    /// real Resolve transitions; every other track is connected to it. (FCPXML
    /// "secondary storylines" would carry transitions on other tracks too, but
    /// Resolve imports them as one compound clip whose audio collides with the
    /// audio tracks, and it trims that audio.)
    private func convertDraft(_ draft: JSON, indent: String) -> (String, Int64) {
        let materials = draft.obj("materials") ?? [:]
        var byId: Lookup = [:]
        for (kind, items) in materials {
            for case let item as JSON in (items as? [Any] ?? []) {
                if let id = item.str("id") { byId[id] = (kind, item) }
            }
        }

        let tracks = draft.objects("tracks")
        let mainTrack = tracks.firstIndex { $0.str("type") == "video" }
        var mainItems: [Item] = []
        var connected: [(item: Item, lane: Int)] = []
        var markers: [(frame: Int64, name: String)] = []
        var videoLane = 0, audioLane = 0

        for (index, track) in tracks.enumerated() {
            let kind = track.str("type") ?? ""
            var lane: Int?
            if index == mainTrack {
                lane = 0
            } else if kind == "audio" {
                audioLane -= 1
                lane = audioLane
            } else if ["video", "text", "sticker"].contains(kind) {
                videoLane += 1
                lane = videoLane
            }  // effect / filter / adjust tracks become markers

            let segments = track.objects("segments").sorted {
                ($0.obj("target_timerange")?.num("start") ?? 0) < ($1.obj("target_timerange")?.num("start") ?? 0)
            }
            for seg in segments {
                var item: Item?
                switch convertSegment(seg, kind: kind, lane: lane, byId: byId, indent: indent) {
                case .clip(let converted): item = converted
                case .marker(let m): markers.append(m)
                case nil: break
                }
                // anything attached that we can't reproduce becomes a marker
                for case let ref as String in seg.list("extra_material_refs") {
                    guard let (refKind, refItem) = byId[ref] else { continue }
                    if refKind == "transitions" {
                        let name = refItem.text("name") ?? "CapCut"
                        let length = frames(refItem.num("duration") ?? 0)
                        if item != nil, index == mainTrack, length > 0 {
                            item!.transition = (name, length)
                        } else {
                            drop(index == mainTrack ? "transition" : "transition on an upper track")
                            let tr = seg.obj("target_timerange") ?? [:]
                            markers.append(marker((tr.num("start") ?? 0) + (tr.num("duration") ?? 0), "Transition: \(name)"))
                        }
                    } else if refKind == "material_animations", !refItem.list("animations").isEmpty {
                        drop("in/out animation")
                    } else if ["effects", "video_effects", "filters"].contains(refKind),
                              let type = refItem.text("type"), type != "speed" {
                        drop("clip \(refKind.dropLast()) (\(type))")
                    } else if refKind == "common_mask" || refKind == "masks" {
                        drop("mask")
                    }
                }
                guard let item, let lane else { continue }
                if index == mainTrack { mainItems.append(item) } else { connected.append((item, lane)) }
            }
        }

        for markSet in materials.objects("time_marks") {
            for item in markSet.objects("mark_items") {
                markers.append(marker(item.obj("time_range")?.num("start") ?? 0, item.text("title") ?? "Marker"))
            }
        }

        var duration = frames(draft.num("duration") ?? 0)
        for track in tracks {
            for seg in track.objects("segments") {
                let tr = seg.obj("target_timerange") ?? [:]
                duration = max(duration, frames((tr.num("start") ?? 0) + (tr.num("duration") ?? 0)))
            }
        }
        duration = max(duration, 1)

        // The primary storyline: main-track clips, with gaps wherever it's empty.
        var slots: [Slot] = []
        var cursor: Int64 = 0
        for item in mainItems where item.end > cursor {
            if item.start > cursor { slots.append(Slot(start: cursor, end: item.start, localStart: 0)) }
            slots.append(Slot(start: max(item.start, cursor), end: item.end, localStart: item.localStart,
                              item: item, transition: item.transition))
            cursor = item.end
        }
        if let last = slots.last, let (_, length) = last.transition, last.end >= duration {
            // a fade at the very end needs something to fade into
            duration = last.end + (length + 1) / 2
        }
        if cursor < duration { slots.append(Slot(start: cursor, end: duration, localStart: 0)) }

        // Anchor everything else to the storyline element under its first frame.
        func slotIndex(_ frame: Int64) -> Int {
            slots.lastIndex { $0.start <= frame } ?? 0
        }
        let inner = indent + "  "
        for (item, lane) in connected {
            let i = slotIndex(item.start)
            let offset = slots[i].localStart + (item.start - slots[i].start)
            slots[i].anchored.append(item.make(" lane=\"\(lane)\"", offset, []).indented(by: "  "))
        }
        for m in markers where m.frame < duration {
            let i = slotIndex(m.frame)
            let start = slots[i].localStart + (m.frame - slots[i].start)
            slots[i].anchored.append("\(inner)<marker start=\"\(t(start))\" duration=\"\(fd.seconds)\" value=\(quoteAttr(m.name))/>")
        }

        var children: [String] = []
        for (i, slot) in slots.enumerated() {
            if let item = slot.item {
                children.append(item.make("", slot.start, slot.anchored))
            } else {
                let head = "\(indent)<gap name=\"Gap\" offset=\"\(t(slot.start))\" start=\"0s\" duration=\"\(t(slot.end - slot.start))\""
                children.append(slot.anchored.isEmpty ? "\(head)/>"
                                : "\(head)>\n" + slot.anchored.joined(separator: "\n") + "\n\(indent)</gap>")
            }
            if let (name, length) = slot.transition, i + 1 < slots.count {
                let (fxName, uid, exact) = Converter.transitionEffect(for: name)
                if !exact { drop("transition replaced by Cross Dissolve") }
                let ref = effect(fxName, uid: uid)
                report.transitions += 1
                children.append("\(indent)<transition name=\(quoteAttr(fxName)) offset=\"\(t(slot.end - length / 2))\" "
                                + "duration=\"\(t(length))\">\n\(inner)<filter-video ref=\"\(ref)\" name=\(quoteAttr(fxName))/>\n"
                                + "\(indent)</transition>")
            }
        }
        return (children.joined(separator: "\n"), duration)
    }

    /// Resolve maps FCPXML transitions by name; anything CapCut-specific becomes a Cross Dissolve.
    static func transitionEffect(for capcutName: String) -> (name: String, uid: String, exact: Bool) {
        let crossDissolve = ("Cross Dissolve", "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265")
        let fadeToColor = ("Fade To Color", ".../Transitions.localized/Dissolves.localized/Fade To Color.localized/Fade To Color.motn")
        switch capcutName.lowercased() {
        case "mix", "dissolve", "cross dissolve", "fade": return (crossDissolve.0, crossDissolve.1, true)
        case "black fade", "fade to black", "dark flash": return (fadeToColor.0, fadeToColor.1, true)
        default: return (crossDissolve.0, crossDissolve.1, false)
        }
    }

    private func marker(_ startUs: Double, _ name: String) -> (frame: Int64, name: String) {
        report.markers += 1
        return (frames(startUs), name)
    }

    private enum Output {
        case clip(Item)
        case marker((frame: Int64, name: String))
    }

    private func firstRef(_ seg: JSON, _ byId: Lookup, kind: String, where test: (JSON) -> Bool = { _ in true }) -> JSON? {
        for case let ref as String in seg.list("extra_material_refs") {
            if let (k, item) = byId[ref], k == kind, test(item) { return item }
        }
        return nil
    }

    private func convertSegment(_ seg: JSON, kind: String, lane: Int?, byId: Lookup, indent: String) -> Output? {
        let found = seg.str("material_id").flatMap { byId[$0] }
        let tr = seg.obj("target_timerange") ?? [:]
        let trStart = tr.num("start") ?? 0, trDuration = tr.num("duration") ?? 0
        let startF = frames(trStart)
        let endF = frames(trStart + trDuration)
        let durF = endF - startF
        if durF <= 0 { return nil }

        guard lane != nil, let (matKind, mat) = found else {
            let name = found?.item.text("name") ?? found?.item.text("type") ?? kind
            drop("\(kind) track item")
            return .marker(marker(trStart, "\(kind.prefix(1).uppercased())\(kind.dropFirst().lowercased()): \(name)"))
        }

        if matKind == "texts" || matKind == "text_templates" {
            return title(seg, mat, kind: matKind, byId: byId, startF: startF, durF: durF, trStart: trStart,
                         trDuration: trDuration, indent: indent).map(Output.clip)
        }
        if matKind != "videos" && matKind != "audios" {
            drop("\(matKind) item")
            return .marker(marker(trStart, "\(matKind): \(mat.text("name") ?? "")"))
        }

        var enabled = seg.flag("visible", default: true) ? "" : " enabled=\"0\""
        let src = seg.obj("source_timerange") ?? ["start": 0, "duration": trDuration]
        let srcStart = src.num("start") ?? 0, srcDuration = src.num("duration") ?? 0
        var speed = srcDuration != 0 ? srcDuration / trDuration : 1.0
        if abs(speed - 1) < 0.001 { speed = 1.0 }

        var compound: JSON?
        if mat.text("path") == nil {
            compound = firstRef(seg, byId, kind: "drafts")
            if compound == nil {
                drop("media without file")
                return nil
            }
        }

        let ref: String, mediaFrames: Int64, tag: String
        if let compound {
            (ref, mediaFrames) = compoundMedia(compound, name: mat.text("material_name"))
            tag = "ref-clip"
            // an audio-only compound would otherwise get an empty video track
            let subTracks = (compound.obj("draft") ?? [:]).objects("tracks")
            if !subTracks.isEmpty, subTracks.allSatisfy({ $0.str("type") == "audio" }) {
                enabled += " srcEnable=\"audio\""
            }
        } else {
            ref = assetFor(mat)
            mediaFrames = frames(mat.num("duration") ?? 0)
            tag = "asset-clip"
            if kind == "audio" { enabled += " srcEnable=\"audio\"" }
        }

        // Clip `start` is in the clip's local (retimed) time; the timeMap maps
        // local time back to media time across the whole media.
        var localStart = frames(srcStart / speed)
        var children: [String] = []
        let curve = firstRef(seg, byId, kind: "speeds") { !(($0.obj("curve_speed") ?? [:]).list("speed_points").isEmpty) }
        if let curve, let points = curve.obj("curve_speed")?.objects("speed_points") {
            report.speedCurves += 1
            localStart = frames(srcStart)
            children.append(curveTimeMap(points, srcStart: srcStart, srcDuration: srcDuration,
                                         targetUs: trDuration, indent: indent))
        } else if speed != 1.0 {
            report.speedChanges += 1
            let endLocal = Double(max(mediaFrames, 1)) / speed
            let limited = limitDenominator(endLocal, 1000)
            children.append(
                "\(indent)  <timeMap>\n"
                + "\(indent)    <timept time=\"0s\" value=\"0s\" interp=\"linear\"/>\n"
                + "\(indent)    <timept time=\"\(Rational(limited.num * fd.num, limited.den * fd.den).seconds)\" "
                + "value=\"\(t(max(mediaFrames, 1)))\" interp=\"linear\"/>\n"
                + "\(indent)  </timeMap>")
        }

        let keys = Keyframes(seg, converter: self, localStart: localStart)
        if keys.any { report.keyframedClips += 1 }
        keys.unsupported.forEach { drop("keyframes: \($0)") }
        if let clip = seg.obj("clip"), matKind == "videos" { children += transform(clip, keys, indent) }
        if mat.str("type") != "photo" {
            children += volume(seg, seg.num("volume") ?? 1.0, keys, byId, localStart: localStart, durF: durF, indent)
        }

        let name = mat.text("material_name") ?? mat.text("name") ?? "Clip"
        report.clips += 1
        let body = children.joined(separator: "\n")
        return .clip(Item(start: startF, end: endF, localStart: localStart, make: { lane, offset, anchored in
            let head = "\(indent)<\(tag) ref=\"\(ref)\"\(lane) offset=\"\(self.t(offset))\" "
                + "start=\"\(self.t(localStart))\" duration=\"\(self.t(durF))\" name=\(quoteAttr(name))\(enabled)"
            let inside = ([body].filter { !$0.isEmpty } + anchored).joined(separator: "\n")
            return inside.isEmpty ? "\(head)/>" : "\(head)>\n\(inside)\n\(indent)</\(tag)>"
        }))
    }

    /// timeMap for a CapCut speed curve.
    ///
    /// CapCut spreads the speed points over the source clip (x = 0..1 of the
    /// used media). Interpolating them linearly gives the right shape, but
    /// CapCut smooths the curve in a way that changes the total duration by a
    /// few percent, so the timing is rescaled to land exactly on CapCut's clip
    /// length: the cut points stay frame-accurate, the ramp may differ slightly
    /// inside the clip.
    private func curveTimeMap(_ points: [JSON], srcStart: Double, srcDuration: Double,
                              targetUs: Double, indent: String, rampSteps: Int = 6) -> String {
        let pts = points.map { (x: $0.num("x") ?? 0, y: $0.num("y") ?? 1) }.sorted { $0.x < $1.x }

        func speedAt(_ x: Double) -> Double {
            for (a, b) in zip(pts, pts.dropFirst()) where a.x <= x && x <= b.x && b.x > a.x {
                let u = (x - a.x) / (b.x - a.x)
                return max(0.01, a.y + (b.y - a.y) * u)
            }
            return max(0.01, pts.last?.y ?? 1)
        }

        // Resolve turns every time point into its own speed segment, so keep
        // them few: flat spans need none, ramps get `rampSteps` steps.
        var xSet: Set<Double> = [0.0, 1.0]
        for p in pts where 0 <= p.x && p.x <= 1 { xSet.insert(p.x) }
        for (a, b) in zip(pts, pts.dropFirst()) where abs(a.y - b.y) > 0.01 && b.x - a.x > 0.02 {
            for i in 1..<rampSteps { xSet.insert(a.x + (b.x - a.x) * Double(i) / Double(rampSteps)) }
        }
        let xs = xSet.filter { 0 <= $0 && $0 <= 1 }.sorted()
        var elapsed = [0.0]  // timeline time spent to reach each x, in source units
        for (a, b) in zip(xs, xs.dropFirst()) {
            let steps = 32
            let h = (b - a) / Double(steps)
            var sum = 0.0
            for i in 0..<steps { sum += h / speedAt(a + (Double(i) + 0.5) * h) }
            elapsed.append(elapsed.last! + sum)
        }
        let scale = targetUs / elapsed.last!

        func exact(_ us: Double) -> String {  // seconds, rounded to 1/100 of a frame
            let k = Int64((us / US * Double(fd.den) / Double(fd.num) * 100).rounded(.toNearestOrEven))
            return Rational(k * fd.num, 100 * fd.den).seconds
        }

        var lines = ["\(indent)    <timept time=\"0s\" value=\"0s\" interp=\"linear\"/>"]
        if srcStart > 0 {
            lines.append("\(indent)    <timept time=\"\(exact(srcStart))\" value=\"\(exact(srcStart))\" interp=\"linear\"/>")
        }
        for (x, e) in zip(xs.dropFirst(), elapsed.dropFirst()) {
            lines.append("\(indent)    <timept time=\"\(exact(srcStart + e * scale))\" "
                         + "value=\"\(exact(srcStart + x * srcDuration))\" interp=\"linear\"/>")
        }
        return "\(indent)  <timeMap>\n" + lines.joined(separator: "\n") + "\n\(indent)  </timeMap>"
    }

    // ---- transform, opacity, volume

    /// CapCut: x/y = 1 moves the centre by half the canvas. FCPXML: units are
    /// percent of the frame height, y up.
    func position(_ x: Double, _ y: Double) -> String {
        "\(fmt(x * (Double(width) / 2) / Double(height) * 100, 4)) \(fmt(y * 50, 4))"
    }

    private func transform(_ clip: JSON, _ keys: Keyframes, _ indent: String) -> [String] {
        var out: [String] = []
        let scale = clip.obj("scale") ?? [:]
        let flip = clip.obj("flip") ?? [:]
        let fx: Double = flip.flag("horizontal", default: false) ? -1 : 1
        let fy: Double = flip.flag("vertical", default: false) ? -1 : 1
        let sx = (scale.num("x") ?? 1.0) * fx, sy = (scale.num("y") ?? 1.0) * fy
        let pos = clip.obj("transform") ?? [:]
        let px = pos.num("x") ?? 0, py = pos.num("y") ?? 0
        let rot = -(clip.num("rotation") ?? 0) + 0.0  // CapCut turns clockwise; + 0.0 avoids "-0.0000"

        var params: [String] = []
        if let k = keys.position {
            params.append(keys.param("position", k) { self.position($0[0], $0[1]) })
        }
        if let k = keys.scale {
            params.append(keys.param("scale", k) { "\(fmt($0[0] * fx, 6)) \(fmt($0[1] * fy, 6))" })
        }
        if let k = keys.rotation {
            params.append(keys.param("rotation", k) { fmt(-$0[0], 4) })
        }
        let isStatic = sx == 1 && sy == 1 && px == 0 && py == 0 && rot == 0
        if !isStatic || !params.isEmpty {
            let head = "\(indent)  <adjust-transform position=\"\(position(px, py))\" "
                + "scale=\"\(fmt(sx, 6)) \(fmt(sy, 6))\" rotation=\"\(fmt(rot, 4))\" anchor=\"0 0\""
            out.append(params.isEmpty ? "\(head)/>"
                       : "\(head)>\n" + params.map { $0.indented(by: "\(indent)    ") }.joined(separator: "\n") + "\n\(indent)  </adjust-transform>")
        }
        let alpha = clip.num("alpha") ?? 1.0
        if let k = keys.alpha {
            out.append("\(indent)  <adjust-blend amount=\"\(fmt(alpha, 4))\">\n"
                       + keys.param("amount", k) { fmt($0[0], 4) }.indented(by: "\(indent)    ")
                       + "\n\(indent)  </adjust-blend>")
        } else if alpha < 0.999 {
            out.append("\(indent)  <adjust-blend amount=\"\(fmt(alpha, 4))\"/>")
        }
        return out
    }

    private func decibels(_ volume: Double) -> String {
        "\(fmt(volume <= 0 ? -96.0 : max(-96.0, 20 * log10(volume)), 2))dB"
    }

    /// Volume, volume keyframes and fades. Fades become volume keyframes: Resolve
    /// reads those, and they combine with keyframes CapCut already had.
    private func volume(_ seg: JSON, _ volume: Double, _ keys: Keyframes, _ byId: Lookup,
                        localStart: Int64, durF: Int64, _ indent: String) -> [String] {
        let fade = firstRef(seg, byId, kind: "audio_fades")
        let fadeIn = fade.map { frames($0.num("fade_in_duration") ?? 0) } ?? 0
        let fadeOut = fade.map { frames($0.num("fade_out_duration") ?? 0) } ?? 0
        if abs(volume - 1) < 0.001 && fadeIn == 0 && fadeOut == 0 && keys.volume == nil { return [] }

        var points = keys.volume ?? []
        if fadeIn > 0 || fadeOut > 0 {
            let level = { (f: Int64) -> Double in Keyframes.valueAt(points, f)?[0] ?? volume }
            var faded: [Keyframes.Point] = []
            if fadeIn > 0 {
                faded.append(.init(frame: 0, values: [0], smooth: false))
                faded.append(.init(frame: min(fadeIn, durF), values: [level(fadeIn)], smooth: false))
            }
            faded += points.filter { $0.frame > fadeIn && $0.frame < durF - fadeOut }
            if fadeOut > 0 {
                faded.append(.init(frame: max(durF - fadeOut, fadeIn), values: [level(durF - fadeOut)], smooth: false))
                faded.append(.init(frame: durF, values: [0], smooth: false))
            }
            points = faded
        }
        if points.isEmpty { return ["\(indent)  <adjust-volume amount=\"\(decibels(volume))\"/>"] }
        return ["\(indent)  <adjust-volume amount=\"\(decibels(volume))\">\n"
                + keys.param("amount", points) { self.decibels($0[0]) }.indented(by: "\(indent)    ")
                + "\n\(indent)  </adjust-volume>"]
    }

    // ---- text

    private struct Run {
        var text: String
        var style: JSON
    }

    private func title(_ seg: JSON, _ mat: JSON, kind: String, byId: Lookup, startF: Int64, durF: Int64,
                       trStart: Double, trDuration: Double, indent: String) -> Item? {
        // A text template holds one or more text materials.
        var texts: [JSON] = []
        if kind == "text_templates" {
            for resource in mat.objects("text_info_resources") {
                if let id = resource.str("text_material_id"), let (k, text) = byId[id], k == "texts" { texts.append(text) }
            }
            drop("text template animation")
        } else {
            texts = [mat]
        }

        let clip = seg.obj("clip") ?? [:]
        let scale = clip.obj("scale")?.num("x") ?? 1.0
        var runs: [Run] = []
        var alignment = 1
        for (i, text) in texts.enumerated() {
            if i > 0 { runs.append(Run(text: "\n", style: runs.last?.style ?? [:])) }
            // CapCut wraps lines at line_max_width (a share of the canvas width); Resolve doesn't wrap.
            runs += wrap(styledRuns(text), maxWidth: (text.num("line_max_width") ?? 0.82) * Double(width), scale: scale)
            alignment = Int(text.num("alignment") ?? 1)
            if !(text.objects("animations")).isEmpty { drop("text animation") }
        }
        let plain = runs.map(\.text).joined()
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let isSubtitle = texts.first?.str("type") == "subtitle"
        if isSubtitle {
            report.subtitles += 1
            subtitleCues.append((trStart, trStart + trDuration, plain))
        }
        report.titles += 1

        let align = ["left", "center", "right", "justified"][min(max(alignment, 0), 3)]
        var defs: [String] = []
        var spans: [String] = []
        for run in runs {
            titleStyles += 1
            let sid = "ts\(titleStyles)"
            spans.append("<text-style ref=\"\(sid)\">\(xmlEscape(run.text))</text-style>")
            defs.append("\(indent)  <text-style-def id=\"\(sid)\"><text-style \(textStyleAttributes(run.style, scale: scale, alignment: align))/></text-style-def>")
        }

        let pos = clip.obj("transform") ?? [:]
        let rot = -(clip.num("rotation") ?? 0) + 0.0
        let transform = "\(indent)  <adjust-transform position=\"\(position(pos.num("x") ?? 0, pos.num("y") ?? 0))\" "
            + "rotation=\"\(fmt(rot, 4))\"/>"
        let alpha = clip.num("alpha") ?? 1.0
        let blend = alpha < 0.999 ? "\n\(indent)  <adjust-blend amount=\"\(fmt(alpha, 4))\"/>" : ""
        let enabled = seg.flag("visible", default: true) ? "" : " enabled=\"0\""
        let name = String(plain.replacingOccurrences(of: "\n", with: " ").prefix(40))
        let ref = effect("Basic Title", uid: ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti")
        let body = "\(indent)  <text>\(spans.joined())</text>\n" + defs.joined(separator: "\n") + "\n\(transform)\(blend)"
        return Item(start: startF, end: startF + durF, localStart: 0, make: { lane, offset, anchored in
            "\(indent)<title ref=\"\(ref)\"\(lane) offset=\"\(self.t(offset))\" start=\"0s\" duration=\"\(self.t(durF))\" "
                + "name=\(quoteAttr(name))\(enabled)>\n" + ([body] + anchored).joined(separator: "\n") + "\n\(indent)</title>"
        })
    }

    /// Splits a CapCut text into runs, one per style range (ranges count characters).
    private func styledRuns(_ text: JSON) -> [Run] {
        guard let raw = text.text("content") else { return [] }
        guard let data = raw.data(using: .utf8),
              let content = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let string = content["text"] as? String
        else { return [Run(text: raw, style: [:])] }
        let chars = Array(string)
        var styles = content.objects("styles").sorted { ($0.list("range").first as? NSNumber)?.intValue ?? 0 < ($1.list("range").first as? NSNumber)?.intValue ?? 0 }
        if styles.isEmpty { styles = [[:]] }
        var runs: [Run] = []
        var cursor = 0
        for style in styles {
            let range = style.list("range").compactMap { ($0 as? NSNumber)?.intValue }
            let lo = min(max(range.first ?? 0, cursor), chars.count)
            let hi = min(max(range.count > 1 ? range[1] : chars.count, lo), chars.count)
            if lo > cursor { runs.append(Run(text: String(chars[cursor..<lo]), style: style)) }
            if hi > lo { runs.append(Run(text: String(chars[lo..<hi]), style: style)) }
            cursor = max(cursor, hi)
        }
        if cursor < chars.count { runs.append(Run(text: String(chars[cursor...]), style: styles.last ?? [:])) }
        // Material-level fallbacks for styles that leave things out
        return runs.map { run in
            var style = run.style
            if style["fill"] == nil, let hex = text.str("text_color") { style["_hex"] = hex }
            if style["size"] == nil { style["size"] = text.num("font_size") ?? 15 }
            if style["font"] == nil, let path = text.text("font_path") { style["font"] = ["path": path] }
            style["_alpha"] = text.num("text_alpha") ?? 1
            return Run(text: run.text, style: style)
        }
    }

    /// CapCut size 1 ≈ 3.9 px, whatever the canvas: CapCut's text boxes measure
    /// 5.83 px of line height per size unit on 1080×1920, 1920×1080 and 1920×1440 alike.
    private static let pixelsPerSize = 3.9

    private func fontPixels(_ style: JSON, scale: Double) -> Double {
        (style.num("size") ?? 15) * Converter.pixelsPerSize * scale
    }

    /// Breaks runs at spaces so each line fits `maxWidth` canvas pixels, measuring
    /// with the run's own font (or Helvetica when CapCut no longer has the file).
    private func wrap(_ runs: [Run], maxWidth: Double, scale: Double) -> [Run] {
        guard maxWidth > 0 else { return runs }
        var out: [Run] = []
        var lineWidth = 0.0
        for run in runs {
            let font = measuringFont(run.style, scale: scale)
            var text = ""
            // keep each word with the space before it, so a break replaces that space
            for word in run.text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                let piece = word.offset == 0 ? String(word.element) : " " + word.element
                for (i, part) in piece.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if i > 0 {
                        text += "\n"
                        lineWidth = 0
                    }
                    let w = Converter.measure(String(part), font)
                    if lineWidth > 0, lineWidth + w > maxWidth, part.hasPrefix(" ") {
                        text += "\n" + part.dropFirst()
                        lineWidth = Converter.measure(String(part.dropFirst()), font)
                    } else {
                        text += part
                        lineWidth += w
                    }
                }
            }
            out.append(Run(text: text, style: run.style))
        }
        return out
    }

    private var measuringFonts: [String: CTFont] = [:]

    private func measuringFont(_ style: JSON, scale: Double) -> CTFont {
        let size = fontPixels(style, scale: scale)
        let path = style.obj("font")?.str("path") ?? ""
        let key = "\(path)|\(size)"
        if let font = measuringFonts[key] { return font }
        var font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor],
           let d = descriptors.first {
            font = CTFontCreateWithFontDescriptor(d, size, nil)
        }
        measuringFonts[key] = font
        return font
    }

    static func measure(_ text: String, _ font: CTFont) -> Double {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
    }

    private func textStyleAttributes(_ style: JSON, scale: Double, alignment: String) -> String {
        // Resolve reads FCPXML font sizes as points of a 1080-line frame and scales them to the timeline height.
        let size = fontPixels(style, scale: scale) * 1080 / Double(height)
        var color = solidColor(style.obj("fill")) ?? hexColor(style.str("_hex")) ?? [1, 1, 1]
        color.append(style.num("_alpha") ?? 1)
        let font = fontName(style.obj("font")?.str("path"))
        var attrs = "font=\(quoteAttr(font.family)) fontFace=\(quoteAttr(font.face)) fontSize=\"\(fmt(size, 1))\" "
            + "fontColor=\"\(colorString(color))\" alignment=\"\(alignment)\""
        if style.flag("bold", default: false) { attrs += " bold=\"1\"" }
        if style.flag("italic", default: false) { attrs += " italic=\"1\"" }
        if let stroke = style.objects("strokes").first {
            let c = (solidColor(stroke) ?? [0, 0, 0]) + [1]
            attrs += " strokeColor=\"\(colorString(c))\" strokeWidth=\"\(fmt((stroke.num("width") ?? 0.08) * size * 0.25, 1))\""
        }
        if let shadow = style.objects("shadows").first {
            let c = (solidColor(shadow) ?? [0, 0, 0]) + [shadow.num("alpha") ?? 0.9]
            let angle = (360 - (shadow.num("angle") ?? -45)).truncatingRemainder(dividingBy: 360)
            attrs += " shadowColor=\"\(colorString(c))\" shadowOffset=\"\(fmt((shadow.num("distance") ?? 5) * scale, 1)) \(fmt(angle, 0))\""
                + " shadowBlurRadius=\"\(fmt((shadow.num("feather") ?? 0) * 100, 1))\""
        }
        return attrs
    }

    private func solidColor(_ paint: JSON?) -> [Double]? {
        guard let c = paint?.obj("content")?.obj("solid")?.list("color").compactMap({ ($0 as? NSNumber)?.doubleValue }),
              c.count >= 3 else { return nil }
        return Array(c.prefix(3))
    }

    private func hexColor(_ hex: String?) -> [Double]? {
        guard var h = hex, h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return [Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255]
    }

    private func colorString(_ c: [Double]) -> String { c.map { fmt($0, 4) }.joined(separator: " ") }

    /// Family and face of a font file from CapCut's cache, read with CoreText.
    private func fontName(_ path: String?) -> (family: String, face: String) {
        guard let path, !path.isEmpty else { return ("Helvetica", "Regular") }
        if let cached = fontCache[path] { return cached ?? ("Helvetica", "Regular") }
        let (use, found) = FontUse.lookup(path)
        report.fonts.insert(use)
        fontCache[path] = found
        return found ?? ("Helvetica", "Regular")
    }

    // ---- compound clips

    private func compoundMedia(_ compound: JSON, name: String?) -> (String, Int64) {
        let cacheKey = compound.str("id") ?? UUID().uuidString
        if let cached = compoundCache[cacheKey] { return (cached.id, cached.frames) }
        report.compoundClips += 1
        var sub = compound.obj("draft")
        if sub == nil, let path = compound.str("draft_file_path"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: resolvePath(path))) {
            sub = try? JSONSerialization.jsonObject(with: data) as? JSON
        }
        let (body, duration) = convertDraft(sub ?? [:], indent: String(repeating: " ", count: 10))
        let rid = newId()
        let mediaName = name ?? compound.text("name") ?? "Compound clip \(report.compoundClips)"
        media.append(
            "    <media id=\"\(rid)\" name=\(quoteAttr(mediaName))>\n"
            + "      <sequence format=\"r1\" duration=\"\(t(duration))\" tcStart=\"0s\" tcFormat=\"\(tcFormat)\">\n"
            + "        <spine>\n"
            + "\(body)\n"
            + "        </spine>\n"
            + "      </sequence>\n"
            + "    </media>")
        compoundCache[cacheKey] = (rid, duration)
        return (rid, duration)
    }

    // ---- outputs

    public func build(name: String) -> String {
        let (body, duration) = convertDraft(draft, indent: String(repeating: " ", count: 12))
        var resources = ["    <format id=\"r1\" name=\"CapCut \(width)x\(height)\" "
                         + "frameDuration=\"\(fd.seconds)\" width=\"\(width)\" height=\"\(height)\""
                         + (colorSpace.map { " colorSpace=\"\($0)\"" } ?? "") + "/>"]
        resources += effectXML
        resources += assetOrder.map { assets[$0]!.xml }
        resources += media
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<!DOCTYPE fcpxml>\n"
            + "<fcpxml version=\"1.9\">\n"
            + "  <resources>\n" + resources.joined(separator: "\n") + "\n  </resources>\n"
            + "  <library>\n"
            + "    <event name=\(quoteAttr(name))>\n"
            + "      <project name=\(quoteAttr(name))>\n"
            + "        <sequence format=\"r1\" duration=\"\(t(duration))\" tcStart=\"0s\" tcFormat=\"\(tcFormat)\">\n"
            + "          <spine>\n"
            + "\(body)\n"
            + "          </spine>\n"
            + "        </sequence>\n"
            + "      </project>\n"
            + "    </event>\n"
            + "  </library>\n"
            + "</fcpxml>\n"
    }

    /// CapCut's auto-captions as an .srt file (Resolve: File → Import → Subtitle). Call after build().
    public func subtitlesSRT() -> String? {
        guard !subtitleCues.isEmpty else { return nil }
        func stamp(_ us: Double) -> String {
            let ms = Int((us / 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return subtitleCues.sorted { $0.start < $1.start }.enumerated().map { i, cue in
            "\(i + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// Copies the media planned by `options.mediaFolder`, reporting progress from 0 to 1.
    public func copyMedia(progress: (Double) -> Void = { _ in }) throws {
        guard let folder = options.mediaFolder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, copy) in mediaCopies.enumerated() {
            if !FileManager.default.fileExists(atPath: copy.destination.path) {
                try FileManager.default.copyItem(atPath: copy.source, toPath: copy.destination.path)
            }
            progress(Double(i + 1) / Double(mediaCopies.count))
        }
    }
}

// MARK: - Keyframes

/// A segment's CapCut keyframes, in FCPXML terms: frames from the clip's start.
struct Keyframes {
    struct Point {
        var frame: Int64
        var values: [Double]
        var smooth: Bool
    }

    var position: [Point]?
    var scale: [Point]?
    var rotation: [Point]?
    var alpha: [Point]?
    var volume: [Point]?
    var unsupported: [String] = []
    let converter: Converter
    let localStart: Int64

    var any: Bool { position != nil || scale != nil || rotation != nil || alpha != nil || volume != nil }

    init(_ seg: JSON, converter: Converter, localStart: Int64) {
        self.converter = converter
        self.localStart = localStart
        var tracks: [String: [Point]] = [:]
        for group in seg.objects("common_keyframes") {
            guard let type = group.str("property_type") else { continue }
            tracks[type] = group.objects("keyframe_list").map { k in
                Point(frame: converter.frames(k.num("time_offset") ?? 0),
                      values: k.list("values").compactMap { ($0 as? NSNumber)?.doubleValue },
                      smooth: (k.str("curveType") ?? "Line") != "Line")
            }.sorted { $0.frame < $1.frame }
        }
        let clip = seg.obj("clip") ?? [:]
        let pos = clip.obj("transform") ?? [:], scl = clip.obj("scale") ?? [:]
        position = Keyframes.merge(tracks["KFTypePositionX"], tracks["KFTypePositionY"],
                                   pos.num("x") ?? 0, pos.num("y") ?? 0)
        scale = Keyframes.merge(tracks["KFTypeScaleX"], tracks["KFTypeScaleY"] ?? tracks["KFTypeScaleX"],
                                scl.num("x") ?? 1, scl.num("y") ?? 1)
        rotation = tracks["KFTypeRotation"]
        alpha = tracks["KFTypeAlpha"]
        volume = tracks["KFTypeVolume"]
        let handled: Set<String> = ["KFTypePositionX", "KFTypePositionY", "KFTypeScaleX", "KFTypeScaleY",
                                    "KFTypeRotation", "KFTypeAlpha", "KFTypeVolume", "KFTypeLastVolume"]
        unsupported = tracks.keys.filter { !handled.contains($0) }.sorted()
            .map { $0.replacingOccurrences(of: "KFType", with: "").lowercased() }
    }

    /// Joins two single-value keyframe tracks (X and Y) into one two-value track.
    static func merge(_ a: [Point]?, _ b: [Point]?, _ restA: Double, _ restB: Double) -> [Point]? {
        guard a != nil || b != nil else { return nil }
        let frames = Set((a ?? []).map(\.frame) + (b ?? []).map(\.frame)).sorted()
        return frames.map { f in
            let va = a.flatMap { valueAt($0, f)?[0] } ?? restA
            let vb = b.flatMap { valueAt($0, f)?[0] } ?? restB
            let smooth = (a ?? []).first { $0.frame == f }?.smooth ?? (b ?? []).first { $0.frame == f }?.smooth ?? false
            return Point(frame: f, values: [va, vb], smooth: smooth)
        }
    }

    /// Linear interpolation of a keyframe track at a frame (held before the first and after the last).
    static func valueAt(_ points: [Point], _ frame: Int64) -> [Double]? {
        guard let first = points.first, let last = points.last else { return nil }
        if frame <= first.frame { return first.values }
        if frame >= last.frame { return last.values }
        for (a, b) in zip(points, points.dropFirst()) where a.frame <= frame && frame <= b.frame {
            let u = Double(frame - a.frame) / Double(max(b.frame - a.frame, 1))
            return zip(a.values, b.values).map { $0 + ($1 - $0) * u }
        }
        return last.values
    }

    /// `<param>` with a keyframeAnimation; times are in the clip's local time.
    func param(_ name: String, _ points: [Point], _ value: ([Double]) -> String) -> String {
        let keys = points.filter { !$0.values.isEmpty }.map { p in
            let interp = p.smooth ? "interp=\"ease\" curve=\"smooth\"" : "interp=\"linear\" curve=\"linear\""
            return "    <keyframe time=\"\(converter.t(localStart + p.frame))\" value=\"\(value(p.values))\" \(interp)/>"
        }
        return "<param name=\"\(name)\">\n  <keyframeAnimation>\n" + keys.joined(separator: "\n") + "\n  </keyframeAnimation>\n</param>"
    }
}

extension String {
    func indented(by prefix: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false).map { prefix + $0 }.joined(separator: "\n")
    }
}
