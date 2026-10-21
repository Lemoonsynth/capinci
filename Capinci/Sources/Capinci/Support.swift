import AppKit
import SwiftUI

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            let data = await Task.detached { try? Data(contentsOf: url) }.value
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

/// Plain-English names for the converter's "not converted" report keys.
enum DroppedLabel {
    private static let adjustments = [
        "brightness": "Brightness", "contrast": "Contrast", "saturation": "Saturation",
        "temperature": "Temperature", "highlight": "Highlights", "shadow": "Shadows", "white": "Whites",
        "black": "Blacks", "vignetting": "Vignette", "light_sensation": "Light", "mix_mode": "Blend mode",
        "tone": "Tint", "text_effect": "Text effect", "sharpen": "Sharpen", "fade": "Fade", "particle": "Grain",
    ]

    static func label(_ key: String) -> String {
        switch key {
        case "transition": return "Transitions on audio or unplaceable clips"
        case "transition replaced by Cross Dissolve": return "CapCut transitions replaced by Cross Dissolve"
        case "in/out animation": return "In/out animations"
        case "text animation": return "Text animations"
        case "text template animation": return "Text template animations"
        case "mask": return "Masks"
        case "media without file": return "Clips without a media file"
        default: break
        }
        if key.hasPrefix("clip effect (") {
            let type = String(key.dropFirst("clip effect (".count).dropLast())
            return "Adjustment: \(adjustments[type] ?? type)"
        }
        if key.hasPrefix("keyframes: ") { return "Keyframes on \(key.dropFirst("keyframes: ".count))" }
        if key.hasPrefix("clip video_effect") { return "Video effects" }
        if key.hasPrefix("clip filter") { return "Filters" }
        if key.hasSuffix(" track item") {
            let kind = key.dropLast(" track item".count)
            switch kind {
            case "effect": return "Effects (effect track)"
            case "filter": return "Filters (filter track)"
            case "adjust": return "Adjustments (adjustment track)"
            default: return "Items on \(kind) tracks"
            }
        }
        if key.hasSuffix(" item") { return "\(key.dropLast(" item".count).replacingOccurrences(of: "_", with: " ").capitalized)" }
        return key
    }

    static func grouped(_ dropped: [String: Int]) -> [(label: String, count: Int)] {
        var sums: [String: Int] = [:]
        for (key, count) in dropped { sums[label(key), default: 0] += count }
        return sums.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}
