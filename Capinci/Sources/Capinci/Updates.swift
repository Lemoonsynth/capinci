import AppKit
import SwiftUI

/// Looks for a newer Capinci on GitHub at launch. Capinci isn't notarized, so it
/// can't replace itself: a newer release shows a banner that opens its download page.
@Observable @MainActor
final class UpdateChecker {
    struct Release {
        let version: String
        let page: URL
    }

    static let repository = "Lemoonsynth/capinci"

    /// The newer release, once found; nil while checking, offline or up to date.
    private(set) var available: Release?
    /// Set by "Check for Updates…" so an up-to-date answer is shown too.
    private(set) var upToDate = false
    var dismissed = false

    /// CAPINCI_PRETEND_VERSION=1.0.0 makes the running app look older, to test the banner.
    let current = ProcessInfo.processInfo.environment["CAPINCI_PRETEND_VERSION"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    func check(manual: Bool = false) {
        Task {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            // Offline or rate-limited: say nothing at launch, the next launch tries again.
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                if manual { NSSound.beep() }
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(version, than: current) {
                available = Release(version: version, page: page)
                dismissed = false
            } else if manual {
                upToDate = true
                try? await Task.sleep(for: .seconds(4))
                upToDate = false
            }
        }
    }

    /// Compares dotted versions number by number: 1.0.10 is newer than 1.0.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

/// The pill at the top of the window announcing a new version.
struct UpdateBanner: View {
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        if let release = updates.available, !updates.dismissed {
            pill {
                Image(systemName: "sparkles").foregroundStyle(Lime.neon)
                Text("Capinci \(release.version) is out").foregroundStyle(Lime.text)
                Button("Download") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.plain)
                    .font(Lime.mono(13, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 24)
                    .background(Capsule().fill(Lime.purple))
                Button { updates.dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Lime.dim)
                }
                .buttonStyle(.plain)
                .help("Hide until next launch")
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if updates.upToDate {
            pill {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Lime.neon)
                Text("Capinci \(updates.current) is the latest version").foregroundStyle(Lime.text)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(Lime.mono(13, .bold))
            .padding(.leading, 14).padding(.trailing, 10)
            .frame(height: 36)
            .background(Capsule().fill(Lime.socket.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Lime.neon.opacity(0.6), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }
}
