import SwiftUI
import AppKit

// The parts of the device: body, keys, dial, switches, screen.

enum Palette {
    static let body = Color(hex: 0xD9D9D4)
    static let ink = Color(hex: 0x1A1A18)
    static let muted = Color(hex: 0x55554F)
    static let error = Color(hex: 0x9A4300)
    static let screw = Color(hex: 0xC6C6C0)
    static let ledOff = Color(hex: 0xA6A6A0)
    static let orange = Color(hex: 0xFF7300)
    static let fnCap = Color(hex: 0xC3C3BD)
    static let fnEdge = Color(hex: 0x9C9C96)
    static let track = Color(hex: 0xBDBDB7)
    static let nub = Color(hex: 0xF4F4F1)
    static let bezel = Color(hex: 0x232321)
    static let screen = Color(hex: 0x0A0A0A)
    static let lcd = Color(hex: 0xF2F2EE)
    static let lcdMid = Color(hex: 0xB5B5B0)
    static let lcdDim = Color(hex: 0x8F8F8A)
    static let lcdLine = Color(hex: 0x6E6E69)
    static let lcdFaint = Color(hex: 0x3C3C39)
    static let lcdOff = Color(hex: 0x2A2A28)
    static let warn = Color(hex: 0xFF9A4D)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }

/// SVGs shipped in the app's Resources folder.
enum Bundled {
    static func image(_ name: String, template: Bool = false) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        return image
    }
}

// MARK: LEDs

enum LEDState { case off, on, blink }

struct LED: View {
    let state: LEDState
    var size: CGFloat = 8

    var body: some View {
        switch state {
        case .off:
            Circle().fill(Palette.ledOff)
                .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
                .frame(width: size, height: size)
        case .on:
            Circle().fill(Palette.orange)
                .frame(width: size, height: size)
                .shadow(color: Palette.orange.opacity(0.8), radius: size * 0.7)
        case .blink:
            TimelineView(.periodic(from: .now, by: 0.45)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.45) % 2 == 0
                Circle().fill(on ? Palette.orange : Color.clear)
                    .overlay(Circle().strokeBorder(Palette.orange, lineWidth: 2))
                    .frame(width: size, height: size)
                    .shadow(color: Palette.orange.opacity(on ? 0.7 : 0), radius: size * 0.6)
            }
        }
    }
}

// MARK: Keys

enum Cap {
    case white, grey, dark, orange, empty

    var fill: Color {
        switch self {
        case .white: return Color(hex: 0xF4F4F1)
        case .grey: return Color(hex: 0xC3C3BD)
        case .dark: return Color(hex: 0x2B2B29)
        case .orange: return Palette.orange
        case .empty: return .clear
        }
    }
    var edge: Color {
        switch self {
        case .white: return Color(hex: 0xAEAEA8)
        case .grey: return Color(hex: 0x9C9C96)
        case .dark: return Color(hex: 0x121211)
        case .orange: return Color(hex: 0xC25700)
        case .empty: return .clear
        }
    }
    var ink: Color { self == .dark ? Color(hex: 0xF4F4F1) : self == .empty ? Palette.muted : Palette.ink }
    var sub: Color {
        switch self {
        case .grey: return Color(hex: 0x3F3F3B)
        case .dark: return Color(hex: 0xB9B9B3)
        case .orange: return Color(hex: 0x3A1A00)
        default: return Palette.muted
        }
    }
}

/// What one of the four big keys shows and does on the current screen.
struct KeySpec {
    var label = ""
    var glyph = ""
    var sub = ""
    var cap = Cap.empty
    var led = LEDState.off
    var down = false // drawn pressed, as when its spot was just tapped
    var help = ""
    var action: (() -> Void)?
}

struct DeviceKey: View {
    let spec: KeySpec

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LED(state: spec.led)
                Text(spec.label).font(mono(12)).foregroundStyle(Palette.ink).lineLimit(1)
            }
            .frame(height: 14)
            Button { spec.action?() } label: { EmptyView() }
                .buttonStyle(KeyCap(spec: spec))
                .disabled(spec.action == nil)
                .help(spec.help)
                .accessibilityLabel(spec.label.isEmpty ? "empty key" : spec.label)
                .accessibilityValue(spec.sub)
        }
        .frame(width: 132, alignment: .leading)
    }
}

/// A key cap that sinks when pressed; its darker side shows below it while raised.
struct KeyCap: ButtonStyle {
    let spec: KeySpec

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed || spec.down
        let cap = spec.cap
        return VStack(alignment: .leading, spacing: 0) {
            Text(spec.glyph).font(mono(30, .medium)).foregroundStyle(cap.ink)
            Spacer(minLength: 0)
            Text(spec.sub).font(mono(10)).foregroundStyle(cap.sub).lineLimit(1)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 132, height: 132, alignment: .topLeading)
        .background {
            if cap == .empty {
                RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0x8E8E88), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(cap.edge).offset(y: down ? 1 : 4)
                    RoundedRectangle(cornerRadius: 18).fill(cap.fill)
                        .overlay(RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.06)], startPoint: .top, endPoint: .bottom)))
                }
                .shadow(color: .black.opacity(down ? 0.1 : 0.16), radius: down ? 3 : 9, y: down ? 2 : 6)
            }
        }
        .offset(y: down ? 3 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .animation(.easeOut(duration: 0.06), value: down)
    }
}

/// A small key in the function row, with its own LED.
struct FnSpec {
    var label: String
    var led = LEDState.off
    var action: (() -> Void)?
}

struct FunctionKey: View {
    let spec: FnSpec

    var body: some View {
        VStack(spacing: 8) {
            LED(state: spec.led, size: 6)
            Button(spec.label) { spec.action?() }
                .buttonStyle(FnCap())
                .disabled(spec.action == nil)
                .opacity(spec.action == nil ? 0.5 : 1)
        }
    }
}

struct FnCap: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed
        return configuration.label
            .font(mono(11)).foregroundStyle(Palette.ink)
            .frame(width: 64, height: 34)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Palette.fnEdge).offset(y: down ? 1 : 3)
                    RoundedRectangle(cornerRadius: 10).fill(Palette.fnCap)
                }
                .shadow(color: .black.opacity(0.1), radius: 5, y: 3)
            }
            .offset(y: down ? 2 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Dial and switches

/// A dial turned by dragging up or down; reports each change, and the last one as final.
struct Dial: View {
    let label: String
    let value: Double
    let readout: String
    var enabled = true
    let change: (Double, Bool) -> Void
    @State private var start: Double?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Canvas { context, _ in
                    for i in 0..<11 {
                        let a = (-135 + Double(i) * 27) * .pi / 180, outer = i % 5 == 0 ? 53.0 : 49.0
                        var tick = Path()
                        tick.move(to: CGPoint(x: 56 + 44 * sin(a), y: 56 - 44 * cos(a)))
                        tick.addLine(to: CGPoint(x: 56 + outer * sin(a), y: 56 - outer * cos(a)))
                        context.stroke(tick, with: .color(Palette.muted), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
                Circle().fill(Color(hex: 0x121211)).frame(width: 74, height: 74).offset(y: 3)
                Circle().fill(Color(hex: 0x2B2B29)).frame(width: 74, height: 74)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 2).frame(width: 66, height: 66)
                Capsule().fill(Palette.orange).frame(width: 3.5, height: 17).offset(y: -20.5)
                    .frame(width: 112, height: 112)
                    .rotationEffect(.degrees(-135 + min(1, max(0, value)) * 270))
            }
            .frame(width: 112, height: 112)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if start == nil { start = value }
                    change(min(1, max(0, (start ?? value) - drag.translation.height / 160)), false)
                }
                .onEnded { drag in
                    change(min(1, max(0, (start ?? value) - drag.translation.height / 160)), true)
                    start = nil
                })
            .help("drag up or down to turn")
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(readout)
            .accessibilityAdjustableAction { direction in
                change(min(1, max(0, value + (direction == .increment ? 0.1 : -0.1))), true)
            }
            HStack(spacing: 10) {
                Text(label)
                Text(readout).foregroundStyle(Palette.muted)
            }
            .font(mono(11)).foregroundStyle(Palette.ink)
        }
        .opacity(enabled ? 1 : 0.5)
        .allowsHitTesting(enabled)
    }
}

struct SlideSwitch: View {
    let title: String
    let left: String
    let right: String
    let isRight: Bool
    var enabled = true
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(mono(10)).foregroundStyle(Palette.muted)
            Button(action: toggle) {
                ZStack(alignment: isRight ? .trailing : .leading) {
                    Capsule().fill(Palette.track)
                        .overlay(Capsule().stroke(Color.black.opacity(0.14), lineWidth: 1))
                    Capsule().fill(Palette.nub).frame(width: 36, height: 20).padding(3)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                }
                .frame(width: 76, height: 26)
                .animation(.easeOut(duration: 0.12), value: isRight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isRight ? right : left)
            HStack {
                Text(left)
                Spacer()
                Text(right)
            }
            .font(mono(10)).foregroundStyle(Palette.muted).frame(width: 76)
        }
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
    }
}

struct Screw: View {
    let angle: Double

    var body: some View {
        Circle().fill(Palette.screw)
            .overlay(Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5))
            .overlay(Capsule().fill(Color(hex: 0x8E8E88)).frame(width: 8, height: 1.5).rotationEffect(.degrees(angle)))
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
    }
}

// MARK: Screen

/// The black screen in its bezel. Controls inside it draw in their dark appearance.
/// `glow` rings it in orange, visible from the corner of the eye while you look at the desk.
struct ScreenFrame<Content: View>: View {
    var glow = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 20)
            .frame(width: 524, height: 290)
            .background(Palette.screen, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.orange, lineWidth: 3)
                    .shadow(color: Palette.orange, radius: 6)
                    .opacity(glow ? 1 : 0)
                    .animation(.easeOut(duration: glow ? 0.06 : 0.5), value: glow)
            }
            .environment(\.colorScheme, .dark)
            .padding(8)
            .background(Palette.bezel, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A small button drawn on the screen.
struct ScreenPill: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(mono(12))
            .foregroundStyle(on ? Palette.screen : Palette.lcd)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(on ? Palette.lcd : configuration.isPressed ? Palette.lcdOff : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.lcdFaint))
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}

struct MicBars: View {
    let level: Double
    private let heights: [CGFloat] = [4, 7, 10, 12, 9, 6, 4, 3]

    var body: some View {
        let lit = Int(min(1, max(0, (20 * log10(max(level, 0.00001)) + 70) / 70)) * 8)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                Rectangle().fill(i < lit ? Palette.lcd : Palette.lcdFaint).frame(width: 3, height: heights[i])
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// The microphone level, with a line where a sound starts to count as a tap.
struct TapMeter: View {
    let level: Double
    let threshold: Double
    private let width: CGFloat = 140

    private func x(_ value: Double) -> CGFloat {
        CGFloat(min(1, max(0, (20 * log10(max(value, 0.00001)) + 70) / 70))) * width
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("mic").font(mono(10)).foregroundStyle(Palette.lcdDim)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.lcdOff)
                Capsule().fill(level >= threshold ? Palette.orange : Palette.lcdMid)
                    .frame(width: max(6, x(level)))
                    .animation(.easeOut(duration: 0.15), value: level)
                if threshold > 0 {
                    Rectangle().fill(Palette.lcd).frame(width: 2, height: 16).offset(x: x(threshold) - 1)
                }
            }
            .frame(width: width, height: 6)
        }
        .accessibilityElement()
        .accessibilityLabel("microphone level")
        .accessibilityValue(level >= threshold ? "loud enough for a tap" : "below a tap")
    }
}

/// Top-down line drawing of the laptop with a dot per button.
struct DeskMap: View {
    let buttons: [Setup.Button]
    var lit: String?
    var armed: String?
    var selected: String?
    var target: String? // the spot to tap next; it pulses and the others fade
    var names = false // label spots by name instead of letter
    var move: ((String, CGPoint) -> Void)?
    var select: ((String) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                context.stroke(Path(roundedRect: CGRect(x: 172, y: 14, width: 136, height: 26), cornerRadius: 3), with: .color(Palette.lcdLine), lineWidth: 1.2)
                context.stroke(Path(roundedRect: CGRect(x: 160, y: 44, width: 160, height: 82), cornerRadius: 7), with: .color(Palette.lcdLine), lineWidth: 1.2)
                context.stroke(Path(roundedRect: CGRect(x: 176, y: 54, width: 128, height: 38), cornerRadius: 3), with: .color(Palette.lcdFaint), lineWidth: 1)
                context.stroke(Path(roundedRect: CGRect(x: 215, y: 99, width: 50, height: 19), cornerRadius: 3), with: .color(Palette.lcdFaint), lineWidth: 1)
            }
            ForEach(buttons) { button in
                spot(button)
                    .position(x: button.x * 480, y: button.y * 150)
                    .gesture(DragGesture(coordinateSpace: .named("map")).onChanged { drag in
                        move?(button.id, CGPoint(x: drag.location.x / 480, y: drag.location.y / 150))
                    })
                    .onTapGesture { select?(button.id) }
            }
        }
        .frame(width: 480, height: 150)
        .coordinateSpace(name: "map")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("desk map with buttons " + buttons.map { $0.name }.joined(separator: ", "))
    }

    private func spot(_ button: Setup.Button) -> some View {
        ZStack {
            if lit == button.id {
                Circle().stroke(Palette.orange.opacity(0.25), lineWidth: 1.2).frame(width: 60, height: 60)
                Circle().stroke(Palette.orange.opacity(0.55), lineWidth: 1.2).frame(width: 38, height: 38)
                Circle().fill(Palette.orange).frame(width: 18, height: 18)
            } else if target == button.id {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                    Circle().stroke(Palette.orange.opacity(1 - phase), lineWidth: 2)
                        .frame(width: 22 + 40 * phase, height: 22 + 40 * phase)
                }
                Circle().fill(Palette.orange).frame(width: 22, height: 22)
            } else if armed == button.id {
                Circle().stroke(Palette.orange.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3])).frame(width: 32, height: 32)
                Circle().strokeBorder(Palette.orange, lineWidth: 2).frame(width: 18, height: 18)
            } else if selected == button.id {
                Circle().fill(Palette.lcd).frame(width: 18, height: 18)
            } else {
                Circle().strokeBorder(target == nil ? Palette.lcd : Palette.lcdLine, lineWidth: 1.5).frame(width: 18, height: 18)
            }
            Text(names ? button.name.lowercased() : button.id.lowercased())
                .font(mono(12))
                .foregroundStyle(target == button.id ? Palette.orange : target == nil ? Palette.lcd : Palette.lcdDim)
                .lineLimit(1).fixedSize()
                .offset(y: 26) // clear of the rings around a lit spot
        }
        .frame(width: 60, height: 60)
        .contentShape(Circle())
    }
}

// MARK: Dot-matrix type

/// Text drawn as round dots on a 5×7 grid, like a small LCD. Lowercase only; unknown characters are blank.
struct DotText: View {
    let text: String
    var pitch: CGFloat = 6
    var color: Color = Palette.lcd

    var body: some View {
        let characters = Array(text.lowercased())
        Canvas { context, _ in
            for (i, character) in characters.enumerated() {
                guard let rows = DotFont.glyphs[character] else { continue }
                for (r, row) in rows.enumerated() {
                    for (c, bit) in row.enumerated() where bit == "#" {
                        let dot = CGRect(x: (CGFloat(i * 6 + c) + 0.1) * pitch, y: (CGFloat(r) + 0.1) * pitch, width: pitch * 0.8, height: pitch * 0.8)
                        context.fill(Path(ellipseIn: dot), with: .color(color))
                    }
                }
            }
        }
        .frame(width: max(0, CGFloat(characters.count * 6 - 1)) * pitch, height: 7 * pitch)
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

enum DotFont {
    static let glyphs: [Character: [String]] = [
        "a": [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
        "b": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "####."],
        "c": [".....", ".....", ".###.", "#....", "#....", "#...#", ".###."],
        "d": ["....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####"],
        "e": [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
        "f": ["..##.", ".#..#", ".#...", "###..", ".#...", ".#...", ".#..."],
        "g": [".....", ".####", "#...#", "#...#", ".####", "....#", ".###."],
        "h": ["#....", "#....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "i": ["..#..", ".....", ".##..", "..#..", "..#..", "..#..", ".###."],
        "j": ["...#.", ".....", "..##.", "...#.", "...#.", "#..#.", ".##.."],
        "k": ["#....", "#....", "#..#.", "#.#..", "##...", "#.#..", "#..#."],
        "l": [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#"],
        "n": [".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"],
        "o": [".....", ".....", ".###.", "#...#", "#...#", "#...#", ".###."],
        "p": [".....", "####.", "#...#", "#...#", "####.", "#....", "#...."],
        "q": [".....", ".####", "#...#", "#...#", ".####", "....#", "....#"],
        "r": [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."],
        "s": [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
        "t": [".#...", ".#...", "###..", ".#...", ".#...", ".#..#", "..##."],
        "u": [".....", ".....", "#...#", "#...#", "#...#", "#..##", ".##.#"],
        "v": [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
        "w": [".....", ".....", "#...#", "#...#", "#.#.#", "#.#.#", ".#.#."],
        "x": [".....", ".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#"],
        "y": [".....", "#...#", "#...#", "#...#", ".####", "....#", ".###."],
        "z": [".....", ".....", "#####", "...#.", "..#..", ".#...", "#####"],
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
        ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
        ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
        "/": [".....", "....#", "...#.", "..#..", ".#...", "#....", "....."],
        "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
        "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
        "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
        "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
        "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
        "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
        "…": [".....", ".....", ".....", ".....", ".....", ".....", "#.#.#"],
        " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    ]
}
