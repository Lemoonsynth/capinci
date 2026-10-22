import AppKit
import SwiftUI

/// The window: the lime housing from the mockup, holding either the project gallery
/// or one project's conversion screen.
struct RootView: View {
    @Environment(ProjectLibrary.self) private var library
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        ZStack {
            Color.black
            Backdrop()
            Group {
                if let project = library.openedProject {
                    ProjectScreen(project: project)
                        .padding(.top, 30)
                        .padding(.horizontal, 64)
                        .padding(.bottom, 44)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                } else {
                    HomeScreen()
                        .transition(.opacity)
                }
            }
        }
        .overlay(alignment: .top) { UpdateBanner().padding(.top, 10) }
        .animation(.spring(duration: 0.35), value: updates.available?.version)
        .animation(.spring(duration: 0.35), value: updates.dismissed)
        .animation(.spring(duration: 0.35), value: updates.upToDate)
        .frame(minWidth: 1000, minHeight: 760)
        .animation(.spring(duration: 0.35), value: library.opened)
        .ignoresSafeArea()
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach(library.add)
            return !urls.isEmpty
        }
    }
}

// MARK: - Home

/// The gallery, laid out on the plate: header in the top band, cards in the
/// recessed middle, the LCD in its slot and NEXT in the round socket.
struct HomeScreen: View {
    @Environment(ProjectLibrary.self) private var library

    var body: some View {
        @Bindable var library = library
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let x = { (p: CGFloat) in Backdrop.x(p, in: w) }
            let y = { (p: CGFloat) in Backdrop.y(p, in: h) }

            HStack(alignment: .center, spacing: 16) {
                LogoPlate {
                    VStack(alignment: .leading, spacing: 0) {
                        Logo(height: 54)
                        Text("Your CapCut projects").font(Lime.mono(14, .bold)).foregroundStyle(Lime.text)
                            .padding(.leading, 10)
                    }
                }
                Spacer(minLength: 20)
                SocketSearchField(text: $library.search).frame(maxWidth: 340)
                PurpleButton(title: "Open folder", systemImage: "folder.fill") { library.openFolder() }
                    .help("Open a CapCut project from another folder (⌘O)")
            }
            .frame(width: x(1052) - x(120), height: 100)
            .position(x: (x(120) + x(1052)) / 2, y: 78)

            gallery
                .frame(width: x(1078) - x(90), height: y(714) - y(150))
                .position(x: (x(90) + x(1078)) / 2, y: (y(150) + y(714)) / 2)

            LCDStrip {
                Image(systemName: "play.fill").font(.system(size: 12))
                if let p = library.selected {
                    Text("\(p.name) selected").lineLimit(1)
                    Spacer()
                    Text(summary(p)).opacity(0.75).lineLimit(1)
                } else {
                    Text("Pick a project")
                    Spacer()
                }
            }
            .frame(width: x(752) - x(224), height: y(800) - y(733))
            .position(x: (x(224) + x(752)) / 2, y: (y(733) + y(800)) / 2)

            ArcadeButton(title: "NEXT", diameter: 132) {
                if let p = library.selected { library.open(p) }
            }
            .disabled(library.selected == nil)
            .keyboardShortcut(.return, modifiers: [])
            .help("Open the selected project (↩)")
            .position(x: x(929), y: y(781))
        }
    }

    private var gallery: some View {
        Socket(padding: 14) {
            if library.projects.isEmpty {
                empty("No CapCut projects found", "CapCut keeps them in ~/Movies/CapCut. Use Open folder for one stored elsewhere.")
            } else if library.filtered.isEmpty {
                empty("Nothing matches “\(library.search)”", "Try another name.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 400), spacing: 16)], spacing: 16) {
                        ForEach(library.filtered) { project in
                            ProjectCard(project: project, selected: project.id == library.selection)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func summary(_ p: CapCutProject) -> String {
        var parts: [String] = []
        if let s = p.seconds { parts.append(clock(s)) }
        if let b = p.mediaBytes, b > 0 { parts.append(bytes(b)) }
        return parts.joined(separator: " · ")
    }

    private func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(Lime.dim)
            Text(title).font(Lime.mono(17, .bold)).foregroundStyle(Lime.text)
            Text(detail).font(.system(size: 13)).foregroundStyle(Lime.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProjectCard: View {
    @Environment(ProjectLibrary.self) private var library
    let project: CapCutProject
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Cover(url: project.coverURL)
                .overlay(alignment: .topTrailing) {
                    if library.details[project.url]?.isHDR == true {
                        Badge(text: "HDR10").padding(8)
                    }
                }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
                .padding([.top, .horizontal], 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name).font(Lime.mono(14, .bold)).foregroundStyle(Lime.text).lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11, weight: .semibold))
                    Text(project.seconds.map(clock) ?? "--:--")
                    Text("·")
                    Text(project.modified.formatted(.relative(presentation: .named)))
                }
                .font(Lime.mono(12))
                .foregroundStyle(Lime.dim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(shape.fill(Lime.socket.opacity(0.9)))
        .overlay(shape.strokeBorder(selected ? Lime.purpleLight : Lime.bright.opacity(hover ? 1 : 0.75), lineWidth: selected ? 3 : 1.5))
        .shadow(color: selected ? Lime.purple.opacity(0.9) : .clear, radius: 12)
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { library.open(project) }
        .onTapGesture { library.selection = project.id }
        .task { await library.loadDetails(project) }
        .help("Click to select, double-click to open")
    }
}

// MARK: - Project

struct ProjectScreen: View {
    @Environment(ProjectLibrary.self) private var library
    let project: CapCutProject

    var body: some View {
        @Bindable var library = library
        let details = library.details[project.url]
        let busy = library.progress[project.url]
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                PurpleButton(title: "Projects", systemImage: "chevron.left") { library.opened = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Back to all projects (esc)")
                LogoPlate { Logo(height: 48) }
                Spacer()
                Text("CapCut → DaVinci Resolve\nProject Converter")
                    .font(Lime.mono(13, .bold))
                    .foregroundStyle(Lime.text)
                    .shadow(color: .black.opacity(0.8), radius: 3)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.trailing, 24)
            .frame(height: 96)

            HStack(alignment: .top, spacing: 16) {
                Socket(step: 1, title: "PROJECT") {
                    Cover(url: project.coverURL)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(project.name).font(Lime.mono(19, .bold)).foregroundStyle(Lime.text).lineLimit(2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info(details)).font(Lime.mono(13)).foregroundStyle(Lime.dim)
                        if let d = details {
                            Text("\(d.videoTracks) video · \(d.audioTracks) audio · \(d.texts) texts").font(Lime.mono(13)).foregroundStyle(Lime.dim)
                        }
                    }
                    HStack(spacing: 6) {
                        if details?.isHDR == true { Badge(text: "HDR10") }
                        if (details?.captions ?? 0) > 0 { Badge(text: "\(details!.captions) CAPTIONS", color: Lime.text) }
                    }
                    Spacer(minLength: 0)
                    PurpleButton(title: "Change project", systemImage: "square.grid.2x2.fill") { library.opened = nil }
                }
                .frame(width: 290)

                Socket(step: 2, title: "OPTIONS") {
                    VStack(spacing: 0) {
                        LimeToggle(title: "Copy media\(mediaSize)",
                                   detail: "Copies every clip next to the timeline, with readable names, so Resolve no longer needs CapCut's files.",
                                   isOn: $library.copyMedia)
                        divider
                        LimeToggle(title: "Captions → .srt",
                                   detail: (details?.captions ?? 0) > 0
                                       ? "\(details!.captions) auto-captions to import in Resolve (File → Import → Subtitle)."
                                       : "Saves CapCut auto-captions as a subtitle file, if the project has any.",
                                   isOn: $library.exportCaptions)
                        divider
                        LimeToggle(title: "Auto-install fonts",
                                   detail: "Installs the fonts CapCut downloaded, so Resolve shows your texts right.",
                                   isOn: $library.autoInstallFonts)
                        divider
                        FontsSummary(project: project)
                            .padding(.top, 10)
                    }
                }

                Socket(step: 3, title: "CONVERT") {
                    VStack(spacing: 14) {
                        Spacer(minLength: 0)
                        ArcadeButton(title: "CONVERT", diameter: 168, busy: busy != nil, progress: busy?.fraction) {
                            library.convert(project)
                        }
                        .disabled(busy != nil)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Convert for DaVinci Resolve (⌘↩)")
                        Text(busy?.stage ?? "Creates a timeline you import\nwith File → Import → Timeline")
                            .font(Lime.mono(11.5))
                            .foregroundStyle(Lime.dim)
                            .multilineTextAlignment(.center)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(width: 240)
            }
            .frame(minHeight: 340, maxHeight: 440)
            .layoutPriority(1)

            Socket(step: 4, title: "RESULT") {
                ResultPanel(project: project, isHDR: details?.isHDR == true)
            }
            .frame(minHeight: 150)
        }
        .task { await library.loadDetails(project) }
    }

    private var divider: some View {
        Rectangle().fill(Lime.bright.opacity(0.18)).frame(height: 1).padding(.vertical, 10)
    }

    private var mediaSize: String {
        guard let b = project.mediaBytes, b > 0 else { return "" }
        return " (\(bytes(b)))"
    }

    private func info(_ d: ProjectDetails?) -> String {
        let duration = clock(d?.seconds ?? project.seconds ?? 0)
        guard let d else { return duration }
        let fps = abs(d.fps - d.fps.rounded()) < 0.01 ? "\(Int(d.fps.rounded()))" : String(format: "%.2f", d.fps)
        return "\(duration) · \(fps) fps · \(d.width)×\(d.height)"
    }
}

/// Fonts the project's texts use, and a button to install the ones CapCut downloaded.
struct FontsSummary: View {
    @Environment(ProjectLibrary.self) private var library
    let project: CapCutProject

    var body: some View {
        let fonts = library.details[project.url]?.fonts ?? []
        let missing = fonts.filter { !$0.installed }
        let installable = missing.filter { $0.file != nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("FONTS IN THIS PROJECT").font(Lime.mono(11, .bold)).foregroundStyle(Lime.dim)
                Spacer()
                if !installable.isEmpty {
                    Button("Install \(installable.count) now") { library.installFonts(for: project) }
                        .buttonStyle(.plain)
                        .font(Lime.mono(11, .bold))
                        .foregroundStyle(Lime.purpleLight)
                }
            }
            if fonts.isEmpty {
                Text("No texts with custom fonts.").font(.system(size: 12)).foregroundStyle(Lime.dim)
            }
            FlowLayout(spacing: 6) {
                ForEach(fonts, id: \.self) { font in
                    HStack(spacing: 4) {
                        Circle().fill(font.installed ? Lime.neon : font.file != nil ? Lime.amber : Color.red.opacity(0.8))
                            .frame(width: 6, height: 6)
                        Text(font.family).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Lime.text)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.06)))
                    .help(font.installed ? "Installed" : font.file != nil ? "Not installed yet: CapCut downloaded it" : "Gone from CapCut's cache: reinstall it yourself")
                }
            }
        }
    }
}

struct ResultPanel: View {
    @Environment(ProjectLibrary.self) private var library
    let project: CapCutProject
    let isHDR: Bool

    var body: some View {
        if let result = library.results[project.url], let r = result.report {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    LCDStrip {
                        Image(systemName: "checkmark.circle.fill")
                        Text(stats(r)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    HStack(spacing: 10) {
                        PurpleButton(title: "Show in Finder", systemImage: "folder.fill") {
                            NSWorkspace.shared.activateFileViewerSelecting([result.output])
                        }
                        PurpleButton(title: "Open Resolve", systemImage: "arrow.up.forward.app.fill") { openResolve() }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        line("doc.fill", result.output.lastPathComponent)
                        if let folder = result.mediaFolder { line("doc.on.doc.fill", "\(result.copiedFiles) media copied to “\(folder.lastPathComponent)”") }
                        if let srt = result.captionsFile { line("captions.bubble.fill", "Captions saved as “\(srt.lastPathComponent)”") }
                        if !result.installedFonts.isEmpty { line("textformat", "Installed: \(result.installedFonts.sorted().joined(separator: ", ")) — restart Resolve") }
                        if !r.missingMedia.isEmpty {
                            line("exclamationmark.triangle.fill", "\(r.missingMedia.count) media missing from CapCut: offline in Resolve", color: Lime.amber)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("TO REDO IN RESOLVE").font(Lime.mono(11, .bold)).foregroundStyle(Lime.dim)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if r.dropped.isEmpty { Text("Nothing, everything came across.").font(.system(size: 12)).foregroundStyle(Lime.text) }
                            ForEach(DroppedLabel.grouped(r.dropped), id: \.label) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("\(row.count)×").font(Lime.mono(12, .bold)).foregroundStyle(Lime.purpleLight)
                                    Text(row.label).font(.system(size: 12)).foregroundStyle(Lime.text)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                }
                .frame(width: 330)
            }
        } else if let error = library.results[project.url]?.error {
            LCDStrip { Image(systemName: "xmark.octagon.fill"); Text(error).lineLimit(2) }
        } else {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    LCDStrip {
                        Image(systemName: "hourglass")
                        Text(library.progress[project.url]?.stage ?? "Ready. Press CONVERT and choose where to save.")
                    }
                    Text("Then in Resolve: File → Import → Timeline… → pick the .fcpxml → tick “Use color information” → Ok. Compound clips open with Clip → Open in Timeline.")
                        .font(.system(size: 12.5)).foregroundStyle(Lime.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isHDR {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HDR PROJECT").font(Lime.mono(11, .bold)).foregroundStyle(Lime.amber)
                        Text("In Resolve, before importing: Project Settings → Color Management → DaVinci YRGB Color Managed, mode HDR, output HDR PQ.")
                            .font(.system(size: 12)).foregroundStyle(Lime.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(width: 330, alignment: .leading)
                }
            }
        }
    }

    private func stats(_ r: ConversionReport) -> String {
        var parts = ["\(r.clips) clips"]
        if r.compoundClips > 0 { parts.append("\(r.compoundClips) compound") }
        if r.speedCurves > 0 { parts.append("\(r.speedCurves) speed curves") }
        if r.speedChanges > 0 { parts.append("\(r.speedChanges) speed changes") }
        if r.transitions > 0 { parts.append("\(r.transitions) transition\(r.transitions == 1 ? "" : "s")") }
        if r.reversed > 0 { parts.append("\(r.reversed) reversed") }
        if r.colorGrades > 0 { parts.append("\(r.colorGrades) graded") }
        if r.titles > 0 { parts.append("\(r.titles) texts") }
        if r.keyframedClips > 0 { parts.append("\(r.keyframedClips) animated") }
        if !r.fonts.isEmpty { parts.append("\(r.fonts.count) fonts") }
        return parts.joined(separator: " · ")
    }

    private func line(_ icon: String, _ text: String, color: Color = Lime.text) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
            Text(text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(color)
    }

    private func openResolve() {
        let ids = ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]
        guard let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first
        else { NSSound.beep(); return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let s = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// A cover image cropped to a fixed 16:9 frame, whatever the picture's own size.
struct Cover: View {
    let url: URL

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { Thumbnail(url: url) }
            .clipped()
    }
}

// MARK: - Formatting

func clock(_ seconds: Double) -> String {
    let t = Int(seconds.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

func bytes(_ count: Int64) -> String {
    count.formatted(.byteCount(style: .file).locale(Locale(identifier: "en_US")))
}
