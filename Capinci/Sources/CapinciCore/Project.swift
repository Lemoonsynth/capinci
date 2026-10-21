import Foundation

/// A CapCut project folder, as listed in the sidebar.
public struct CapCutProject: Identifiable, Hashable {
    public let url: URL
    public let modified: Date
    /// From CapCut's small draft_meta_info.json, so the list doesn't parse every project.
    public let seconds: Double?
    public let mediaBytes: Int64?

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var coverURL: URL { url.appendingPathComponent("draft_cover.jpg") }

    public init?(url: URL) {
        guard let draft = CapCutDraft.draftFile(in: url) else { return nil }
        self.url = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: draft.path)
        modified = attrs?[.modificationDate] as? Date ?? .distantPast
        let meta = (try? Data(contentsOf: url.appendingPathComponent("draft_meta_info.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON } ?? [:]
        seconds = meta.num("tm_duration").map { $0 / 1_000_000 }
        mediaBytes = meta.num("draft_timeline_materials_size_").map { Int64($0) }
    }

    /// Every project in CapCut's projects folder, most recently edited first.
    public static func all(in root: URL = CapCutDraft.defaultRoot) -> [CapCutProject] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap(CapCutProject.init(url:)).sorted { $0.modified > $1.modified }
    }
}

/// What the detail pane shows about a project before converting it.
public struct ProjectDetails {
    public let seconds: Double
    public let fps: Double
    public let width: Int
    public let height: Int
    public let isHDR: Bool
    public let videoTracks: Int
    public let audioTracks: Int
    public let texts: Int
    public let captions: Int
    public let fonts: [FontUse]

    public init(project: CapCutProject) throws {
        let draft = try CapCutDraft.load(project.url)
        seconds = (draft.num("duration") ?? 0) / 1_000_000
        fps = draft.num("fps") ?? 30
        let canvas = draft.obj("canvas_config") ?? [:]
        width = Int(canvas.num("width") ?? 1920)
        height = Int(canvas.num("height") ?? 1080)
        isHDR = draft.num("color_space") == 2084
        let tracks = draft.objects("tracks")
        let types = tracks.compactMap { $0.str("type") }
        videoTracks = types.filter { $0 == "video" || $0 == "text" || $0 == "sticker" }.count
        audioTracks = types.filter { $0 == "audio" }.count
        let textTypes = Dictionary(
            (draft.obj("materials") ?? [:]).objects("texts").compactMap { t in t.str("id").map { ($0, t.str("type") ?? "") } },
            uniquingKeysWith: { a, _ in a })
        let onTimeline = tracks.flatMap { $0.objects("segments") }.compactMap { $0.str("material_id") }.compactMap { textTypes[$0] }
        texts = onTimeline.count
        captions = onTimeline.filter { $0 == "subtitle" }.count
        fonts = FontUse.used(in: draft)
    }
}
