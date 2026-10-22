// Command-line Capinci:
//   capinci-cli <project folder> <output.fcpxml> [--copy-media <folder>] [--srt]

import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    exit(code)
}

var positional: [String] = []
var mediaFolder: URL?
var writeSRT = false
var rest = CommandLine.arguments.dropFirst()
while let arg = rest.popFirst() {
    switch arg {
    case "--copy-media":
        guard let folder = rest.popFirst() else { fail("--copy-media needs a folder", code: 2) }
        mediaFolder = URL(fileURLWithPath: folder)
    case "--srt": writeSRT = true
    default: positional.append(arg)
    }
}
guard positional.count == 2 else {
    fail("usage: capinci-cli <project folder> <output.fcpxml> [--copy-media <folder>] [--srt]", code: 2)
}

do {
    let dir = URL(fileURLWithPath: positional[0])
    let output = URL(fileURLWithPath: positional[1])
    let privateFolder = output.deletingLastPathComponent()
        .appendingPathComponent("\(output.deletingPathExtension().lastPathComponent) Media")
    let converter = try Converter(projectDir: dir, options: .init(mediaFolder: mediaFolder, privateMediaFolder: privateFolder))
    let xml = converter.build(name: dir.lastPathComponent)
    try converter.copyMedia()
    try xml.write(to: output, atomically: true, encoding: .utf8)
    if writeSRT, let srt = converter.subtitlesSRT() {
        try srt.write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
    }
    let r = converter.report
    print("\(r.clips) clips, \(r.compoundClips) compound, \(r.speedChanges) speed, \(r.speedCurves) curves, "
          + "\(r.titles) titles (\(r.subtitles) subtitles), \(r.transitions) transitions, \(r.reversed) reversed, \(r.fades) fades, \(r.transitionFades) transition-fades, \(r.blendModes) blend, \(r.colorGrades) graded, \(r.keyframedClips) keyframed, "
          + "\(r.markers) markers, \(r.missingMedia.count) missing, \(converter.mediaCopies.count) copied (\(r.privateCopied) from CapCut's private folder)")
    for font in r.fonts.sorted(by: { $0.family < $1.family }) {
        print("  font: \(font.family)\(font.installed ? "" : " (not installed)")")
    }
    for (what, count) in r.dropped.sorted(by: { $0.key < $1.key }) {
        print(String(format: "  %3d x %@", count, what))
    }
} catch {
    fail(error.localizedDescription)
}
