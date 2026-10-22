import AppKit
import SwiftUI

@main
struct CapinciApp: App {
    @State private var library = ProjectLibrary()
    @State private var updates = UpdateChecker()

    var body: some Scene {
        Window("Capinci", id: "main") {
            RootView()
                .environment(library)
                .environment(updates)
                .task { updates.check() }
                .tint(Lime.purple)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.check(manual: true) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open CapCut Project…") { library.openFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Projects") { library.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}

/// The list of CapCut projects, what's selected, the conversion options and each project's last result.
@Observable @MainActor
final class ProjectLibrary {
    var projects: [CapCutProject] = []
    var selection: CapCutProject.ID?
    var search = ""
    var details: [URL: ProjectDetails] = [:]
    var results: [URL: ConversionResult] = [:]
    var progress: [URL: ConversionProgress] = [:]
    /// The project shown on the conversion screen; nil shows the gallery.
    var opened: URL?

    var copyMedia: Bool = UserDefaults.standard.bool(forKey: "copyMedia") {
        didSet { UserDefaults.standard.set(copyMedia, forKey: "copyMedia") }
    }
    var exportCaptions: Bool = UserDefaults.standard.object(forKey: "exportCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(exportCaptions, forKey: "exportCaptions") }
    }
    var autoInstallFonts: Bool = UserDefaults.standard.object(forKey: "autoInstallFonts") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoInstallFonts, forKey: "autoInstallFonts") }
    }

    /// Projects opened by hand from outside CapCut's folder.
    private var extra: [CapCutProject] = []

    init() { reload() }

    var filtered: [CapCutProject] {
        guard !search.isEmpty else { return projects }
        return projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var selected: CapCutProject? { projects.first { $0.id == selection } }
    var openedProject: CapCutProject? { projects.first { $0.url == opened } }

    func open(_ project: CapCutProject) {
        selection = project.id
        opened = project.url
    }

    func reload() {
        let found = CapCutProject.all()
        projects = extra.filter { e in !found.contains { $0.url == e.url } } + found
        details = [:]
        if selection == nil || selected == nil { selection = projects.first?.id }
    }

    func add(_ url: URL) {
        guard let project = CapCutProject(url: url) else {
            NSSound.beep()
            return
        }
        if !projects.contains(project) {
            extra.insert(project, at: 0)
            projects.insert(project, at: 0)
        }
        open(project)
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = CapCutDraft.defaultRoot
        panel.message = "Choose a CapCut project folder"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url { add(url) }
    }

    func loadDetails(_ project: CapCutProject) async {
        guard details[project.url] == nil else { return }
        let loaded = await Task.detached { try? ProjectDetails(project: project) }.value
        if let loaded { details[project.url] = loaded }
    }

    func convert(_ project: CapCutProject) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "fcpxml") ?? .xml]
        panel.nameFieldStringValue = "\(project.name).fcpxml"
        panel.directoryURL = lastOutputFolder
        panel.message = copyMedia
            ? "Choose where to save the timeline. Media will be copied into a folder next to it."
            : "Choose where to save the timeline for DaVinci Resolve."
        panel.prompt = "Convert"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        lastOutputFolder = output.deletingLastPathComponent()

        let mediaFolder = copyMedia
            ? output.deletingLastPathComponent().appendingPathComponent("\(output.deletingPathExtension().lastPathComponent) Media")
            : nil
        let captions = exportCaptions
        let fonts = autoInstallFonts
        let url = project.url
        progress[url] = .init(stage: "Converting…")
        results[url] = nil
        Task {
            let result = await Task.detached {
                ConversionResult.run(project: project, output: output, mediaFolder: mediaFolder,
                                     captions: captions, installFonts: fonts) { done, total in
                    Task { @MainActor in self.progress[url] = .init(stage: "Copying media \(done) of \(total)…",
                                                                    fraction: Double(done) / Double(max(total, 1))) }
                }
            }.value
            progress[url] = nil
            results[url] = result
            if !result.installedFonts.isEmpty { refreshDetails(project) }
        }
    }

    /// Installs the fonts a project uses that CapCut downloaded but macOS doesn't have yet.
    func installFonts(for project: CapCutProject) {
        guard let fonts = details[project.url]?.fonts else { return }
        let installed = FontUse.install(fonts.filter { !$0.installed && $0.file != nil })
        if var result = results[project.url] {
            result.installedFonts.formUnion(installed)
            results[project.url] = result
        }
        refreshDetails(project)
    }

    private func refreshDetails(_ project: CapCutProject) {
        details[project.url] = nil
        Task { await loadDetails(project) }
    }

    private var lastOutputFolder: URL {
        get {
            UserDefaults.standard.url(forKey: "lastOutputFolder")
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        }
        set { UserDefaults.standard.set(newValue, forKey: "lastOutputFolder") }
    }
}

struct ConversionProgress {
    var stage: String
    var fraction: Double?
}

struct ConversionResult {
    var output: URL
    var report: ConversionReport?
    var mediaFolder: URL?
    var copiedFiles = 0
    var captionsFile: URL?
    var installedFonts: Set<String> = []
    var error: String?

    static func run(project: CapCutProject, output: URL, mediaFolder: URL?, captions: Bool, installFonts: Bool,
                    progress: @escaping @Sendable (Int, Int) -> Void) -> ConversionResult {
        do {
            let privateFolder = output.deletingLastPathComponent()
                .appendingPathComponent("\(output.deletingPathExtension().lastPathComponent) Media")
            let converter = try Converter(projectDir: project.url,
                                          options: .init(mediaFolder: mediaFolder, privateMediaFolder: privateFolder))
            let xml = converter.build(name: project.name)
            let total = converter.mediaCopies.count
            try converter.copyMedia { fraction in progress(Int((fraction * Double(total)).rounded()), total) }
            try xml.write(to: output, atomically: true, encoding: .utf8)
            var result = ConversionResult(output: output, report: converter.report,
                                          mediaFolder: total > 0 ? (mediaFolder ?? privateFolder) : nil, copiedFiles: total)
            if installFonts {
                result.installedFonts = Set(FontUse.install(converter.report.fonts.filter { !$0.installed && $0.file != nil }))
            }
            if captions, let srt = converter.subtitlesSRT() {
                let file = output.deletingPathExtension().appendingPathExtension("srt")
                try srt.write(to: file, atomically: true, encoding: .utf8)
                result.captionsFile = file
            }
            return result
        } catch {
            return ConversionResult(output: output, error: error.localizedDescription)
        }
    }
}
