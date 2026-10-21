import AppKit
import SwiftUI

/// Capinci's "Clear Lime" look: see-through neon-lime plastic with its circuits
/// showing, dark green sockets, glossy purple buttons and a green LCD.
enum Lime {
    static let neon = Color(red: 0.71, green: 1.0, blue: 0.18)
    static let bright = Color(red: 0.85, green: 1.0, blue: 0.42)
    static let deep = Color(red: 0.22, green: 0.47, blue: 0.0)
    static let socket = Color(red: 0.03, green: 0.11, blue: 0.02)
    static let text = Color(red: 0.87, green: 1.0, blue: 0.62)
    static let dim = Color(red: 0.55, green: 0.72, blue: 0.36)
    static let lcd = Color(red: 0.78, green: 0.95, blue: 0.42)
    static let lcdInk = Color(red: 0.10, green: 0.22, blue: 0.04)
    static let purple = Color(red: 0.55, green: 0.24, blue: 1.0)
    static let purpleLight = Color(red: 0.78, green: 0.62, blue: 1.0)
    static let purpleDark = Color(red: 0.24, green: 0.06, blue: 0.60)
    static let amber = Color(red: 1.0, green: 0.74, blue: 0.25)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Backdrop (from the chosen mockup)

/// The lime housing generated from mockup B, drawn 9-slice style: corners, screws
/// and the top and bottom bands keep their size, only the middle stretches.
struct Backdrop: View {
    /// Image size in points (the 2336×1744 px plate shown at 2×) and the fixed edges.
    static let size = CGSize(width: 1168, height: 872)
    static let caps = EdgeInsets(top: 145, leading: 115, bottom: 165, trailing: 115)

    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "backdrop", withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = size
        return image
    }()

    var body: some View {
        if let image = Backdrop.image {
            Image(nsImage: image)
                .resizable(capInsets: Backdrop.caps, resizingMode: .stretch)
        } else {
            PlasticShell().padding(8)
        }
    }

    /// Where a point of the plate lands in a window of the given size.
    static func x(_ p: CGFloat, in width: CGFloat) -> CGFloat {
        map(p, size.width, caps.leading, caps.trailing, width)
    }

    static func y(_ p: CGFloat, in height: CGFloat) -> CGFloat {
        map(p, size.height, caps.top, caps.bottom, height)
    }

    private static func map(_ p: CGFloat, _ length: CGFloat, _ lead: CGFloat, _ trail: CGFloat, _ target: CGFloat) -> CGFloat {
        if p <= lead { return p }
        if p >= length - trail { return target - (length - p) }
        return lead + (p - lead) * (target - lead - trail) / (length - lead - trail)
    }
}

/// The CAPINCI wordmark generated with the mockup (falls back to the drawn one).
struct Logo: View {
    var height: CGFloat = 66

    static let image: NSImage? = Bundle.main.url(forResource: "logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let image = Logo.image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(height: height)
        } else {
            Wordmark(size: height * 0.62)
        }
    }
}

// MARK: - Plastic shell (drawn fallback)

/// The translucent lime body the whole window is made of.
struct PlasticShell: View {
    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
            ZStack {
                shape.fill(LinearGradient(colors: [Lime.bright.opacity(0.95), Lime.neon.opacity(0.86), Color(red: 0.45, green: 0.80, blue: 0.0).opacity(0.92)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                Circuits(seed: 7).opacity(0.33).clipShape(shape)
                // sheen across the plastic
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.28), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 220)
                    .rotationEffect(.degrees(22))
                    .offset(x: -geo.size.width * 0.28)
                    .blendMode(.screen)
                    .clipShape(shape)
                shape.fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.18)))
                    .blendMode(.screen)
                // thick plastic edges: bright rim, darker inner wall
                shape.strokeBorder(Lime.bright, lineWidth: 2.5)
                shape.inset(by: 6).stroke(Lime.deep.opacity(0.45), lineWidth: 6).blur(radius: 5).clipShape(shape)
                shape.inset(by: 2.5).stroke(.white.opacity(0.55), lineWidth: 1)
                // corner screws
                ForEach(0..<4, id: \.self) { i in
                    Screw()
                        .position(x: i % 2 == 0 ? 26 : geo.size.width - 26, y: i < 2 ? 26 : geo.size.height - 26)
                }
            }
            .shadow(color: Lime.neon.opacity(0.45), radius: 24)
        }
    }
}

/// Circuit traces, chips and vias seen through the plastic (deterministic).
struct Circuits: View {
    let seed: UInt64

    var body: some View {
        Canvas { ctx, size in
            var rng = SplitMix(seed: seed)
            let ink = Color(red: 0.06, green: 0.22, blue: 0.0)
            // traces: right-angle runs
            for _ in 0..<70 {
                var p = CGPoint(x: rng.next(in: 0...size.width), y: rng.next(in: 0...size.height))
                var path = Path()
                path.move(to: p)
                for step in 0..<Int(rng.next(in: 2...5)) {
                    let len = rng.next(in: 30...170)
                    if step % 2 == 0 { p.x += rng.bool() ? len : -len } else { p.y += rng.bool() ? len : -len }
                    path.addLine(to: p)
                }
                ctx.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: rng.next(in: 1...2.4), lineCap: .round, lineJoin: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(ink))
            }
            // chips
            for _ in 0..<12 {
                let w = rng.next(in: 34...80), h = rng.next(in: 26...54)
                let r = CGRect(x: rng.next(in: 0...size.width - w), y: rng.next(in: 0...size.height - h), width: w, height: h)
                ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(ink.opacity(0.8)))
                var x = r.minX + 5
                while x < r.maxX - 4 {
                    ctx.fill(Path(CGRect(x: x, y: r.minY - 5, width: 2.5, height: 5)), with: .color(ink))
                    ctx.fill(Path(CGRect(x: x, y: r.maxY, width: 2.5, height: 5)), with: .color(ink))
                    x += 7
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A tiny deterministic random generator, so the circuits never move between launches.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + CGFloat(Double(next() % 10_000) / 10_000) * (range.upperBound - range.lowerBound)
    }

    mutating func bool() -> Bool { next() % 2 == 0 }
}

struct Screw: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.25)],
                                         center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 10))
            Image(systemName: "plus").font(.system(size: 9, weight: .black)).foregroundStyle(Color(white: 0.2))
        }
        .frame(width: 18, height: 18)
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
    }
}

// MARK: - Sockets (panels)

/// A dark green recess in the plastic, with a lime rim; optional numbered title.
struct Socket<Content: View>: View {
    var step: Int? = nil
    var title: String? = nil
    var padding: CGFloat = 14
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 10) {
                    if let step { StepNumber(step) }
                    Text(title).font(Lime.mono(17, .bold)).tracking(1).foregroundStyle(Lime.text)
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(Lime.socket.opacity(0.86))
                shape.fill(LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.15)))
            }
        }
        .overlay(shape.strokeBorder(highlighted ? Lime.purpleLight : Lime.bright.opacity(0.9), lineWidth: highlighted ? 2.5 : 1.5))
        .shadow(color: highlighted ? Lime.purple.opacity(0.9) : .clear, radius: 10)
    }
}

struct StepNumber: View {
    let n: Int
    init(_ n: Int) { self.n = n }

    var body: some View {
        Text("\(n)")
            .font(.system(size: 15, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(RadialGradient(colors: [Lime.purpleLight, Lime.purple, Lime.purpleDark],
                                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 18)))
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Type

/// "CAPINCI" in chunky glossy purple italic.
struct Wordmark: View {
    var size: CGFloat = 46

    var body: some View {
        let text = Text("CAPINCI").font(.system(size: size, weight: .black).italic()).tracking(1)
        ZStack {
            text.foregroundStyle(Lime.purpleDark).offset(x: 2, y: 3)
            text.foregroundStyle(LinearGradient(colors: [Lime.purpleLight, Lime.purple, Color(red: 0.36, green: 0.10, blue: 0.85)],
                                                startPoint: .top, endPoint: .bottom))
            text.foregroundStyle(LinearGradient(colors: [.white.opacity(0.75), .clear], startPoint: .top, endPoint: .center))
                .mask(text)
        }
        .shadow(color: Lime.purple.opacity(0.6), radius: 8)
        .fixedSize()
    }
}

// MARK: - Controls

/// Glossy purple pill button.
struct PurpleButton: View {
    let title: String
    var systemImage: String? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .bold)) }
                Text(title).font(Lime.mono(14, .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background {
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Lime.purpleLight, Lime.purple, Lime.purpleDark], startPoint: .top, endPoint: .bottom))
                    Capsule().fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center))
                        .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 18)
                    Capsule().strokeBorder(Lime.purpleLight.opacity(0.9), lineWidth: 1.5)
                }
            }
            .shadow(color: Lime.purple.opacity(hover ? 0.8 : 0.45), radius: hover ? 12 : 6, y: 2)
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

/// The big round arcade button.
struct ArcadeButton: View {
    let title: String
    var diameter: CGFloat = 170
    var busy = false
    var progress: Double? = nil
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Lime.socket.opacity(0.9))
                Circle().strokeBorder(Lime.bright.opacity(0.8), lineWidth: 2)
                Circle()
                    .fill(RadialGradient(colors: [Lime.purpleLight, Lime.purple, Lime.purpleDark],
                                         center: UnitPoint(x: 0.4, y: 0.32), startRadius: 4, endRadius: diameter * 0.45))
                    .padding(diameter * 0.09)
                    .shadow(color: Lime.purple.opacity(hover ? 0.95 : 0.6), radius: hover ? 22 : 12)
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), Lime.purpleDark], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                    .padding(diameter * 0.09)
                Ellipse()
                    .fill(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: diameter * 0.5, height: diameter * 0.22)
                    .offset(y: -diameter * 0.24)
                if busy {
                    Circle()
                        .trim(from: 0, to: progress ?? 0.25)
                        .stroke(Lime.neon, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(diameter * 0.045)
                        .shadow(color: Lime.neon, radius: 6)
                }
                Text(busy ? "WORKING" : title)
                    .font(Lime.mono(diameter * 0.15, .heavy))
                    .foregroundStyle(Lime.text)
                    .shadow(color: Lime.purpleDark, radius: 0, y: 2)
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(hover && !busy ? 1.03 : 1)
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.25), value: hover)
    }
}

/// A purple switch with a white knob.
struct LimeToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.25)) { isOn.toggle() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Lime.text)
                    if let detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Lime.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Lime.purpleLight, Lime.purple], startPoint: .top, endPoint: .bottom))
                                        : AnyShapeStyle(Color(white: 0.28)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    Circle().fill(.white).padding(3).shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                }
                .frame(width: 52, height: 30)
                .shadow(color: isOn ? Lime.purple.opacity(0.6) : .clear, radius: 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Green LCD strip with dark ink.
struct LCDStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(Lime.mono(14, .bold))
            .foregroundStyle(Lime.lcdInk)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Lime.lcd)
                    Canvas { ctx, size in
                        var y: CGFloat = 0
                        while y < size.height {
                            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.06)))
                            y += 3
                        }
                    }
                    RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Lime.socket.opacity(0.8), lineWidth: 3))
    }
}

struct Badge: View {
    let text: String
    var color: Color = Lime.purpleLight

    var body: some View {
        Text(text)
            .font(Lime.mono(11, .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Lime.socket.opacity(0.85)))
            .overlay(Capsule().strokeBorder(color, lineWidth: 1.2))
    }
}

/// Search field set into the plastic.
struct SocketSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .bold)).foregroundStyle(Lime.text)
            TextField("", text: $text, prompt: Text("Search projects").foregroundStyle(Lime.dim))
                .textFieldStyle(.plain)
                .font(Lime.mono(15))
                .foregroundStyle(Lime.text)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Lime.dim) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Lime.socket.opacity(0.86)))
        .overlay(Capsule().strokeBorder(Lime.bright.opacity(0.9), lineWidth: 1.5))
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

/// The dark recess the logo sits in, as on the mockup.
struct LogoPlate<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    shape.fill(Lime.socket.opacity(0.92))
                    shape.fill(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
                }
            }
            .overlay(shape.strokeBorder(Lime.bright.opacity(0.9), lineWidth: 1.5))
            .fixedSize()
    }
}
