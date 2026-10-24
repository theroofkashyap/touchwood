import Foundation

/// One desk's buttons, what each does, and what they sounded like while being taught.
/// It holds sound descriptions, never audio.
struct Setup: Codable, Identifiable {
    struct Button: Codable, Identifiable {
        var id: String
        var name: String
        var x: Double, y: Double // fraction of the desk drawing; y grows toward you
        var action: Action? // nil: the button only lights up
    }

    struct Tap: Codable {
        var button: String
        var shape: [Double]
        var peak: Double
    }

    struct Check: Codable {
        var right = 0, wrong = 0, unrecognized = 0
    }

    static let defaults = [
        Button(id: "A", name: "Left", x: 0.12, y: 0.38),
        Button(id: "B", name: "Right", x: 0.88, y: 0.38),
        Button(id: "C", name: "Front left", x: 0.2, y: 0.78),
        Button(id: "D", name: "Front right", x: 0.8, y: 0.78),
    ]

    var id = UUID().uuidString
    var name = "Desk 1"
    var buttons = Array(Setup.defaults.prefix(2))
    var doubleTap = true
    var sensitivity = 0.5 // the dial, 0...1; 0.5 is the detector's usual six times the room noise
    var input = "" // microphone it was taught with
    var taps: [Tap] = []
    var noise: [[Double]] = [] // everyday sounds that must never press a button
    var falsePresses = 0 // everyday sounds that would have pressed one anyway
    var everydaySounds = 0
    var check: Check?

    init() {}

    // Setups saved before presets existed have no id or name.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Desk 1"
        buttons = try c.decode([Button].self, forKey: .buttons)
        doubleTap = try c.decodeIfPresent(Bool.self, forKey: .doubleTap) ?? true
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 0.5
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        taps = try c.decodeIfPresent([Tap].self, forKey: .taps) ?? []
        noise = try c.decodeIfPresent([[Double]].self, forKey: .noise) ?? []
        falsePresses = try c.decodeIfPresent(Int.self, forKey: .falsePresses) ?? 0
        everydaySounds = try c.decodeIfPresent(Int.self, forKey: .everydaySounds) ?? 0
        check = try c.decodeIfPresent(Check.self, forKey: .check)
    }

    /// Every button has taught taps, so the setup can recognize presses.
    var isTaught: Bool { buttons.allSatisfy { button in taps.contains { $0.button == button.id } } }

    /// The detector's threshold over room noise for the dial's position: 12× at 0, 6× at 0.5, 3× at 1.
    var factor: Double { 12 * pow(0.25, sensitivity) }

    func name(_ id: String) -> String { buttons.first { $0.id == id }?.name ?? id }
}

/// What a button does when pressed.
enum Action: Codable, Equatable {
    enum Screenshot: String, Codable, CaseIterable {
        case desktop, clipboard, area
        var title: String { ["desktop": "Desktop", "clipboard": "Clipboard", "area": "Pick area"][rawValue]! }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case nothing, screenshot, app, website, file, shortcut
        var id: String { rawValue }
        /// Lowercase, as printed on the device screen.
        var label: String {
            switch self {
            case .nothing: return "just light up"
            case .screenshot: return "screenshot"
            case .app: return "open app"
            case .website: return "website"
            case .file: return "file or folder"
            case .shortcut: return "shortcut"
            }
        }

        var title: String {
            switch self {
            case .nothing: return "Just light up"
            case .screenshot: return "Take a screenshot"
            case .app: return "Open an app"
            case .website: return "Open a website"
            case .file: return "Open a file or folder"
            case .shortcut: return "Run a Shortcut"
            }
        }
    }

    case screenshot(Screenshot)
    case app(path: String)
    case website(url: String)
    case file(path: String)
    case shortcut(name: String)

    var kind: Kind {
        switch self {
        case .screenshot: return .screenshot
        case .app: return .app
        case .website: return .website
        case .file: return .file
        case .shortcut: return .shortcut
        }
    }

    /// A fresh action of `kind`, still to be filled in; nil for `.nothing`.
    static func blank(_ kind: Kind) -> Action? {
        switch kind {
        case .nothing: return nil
        case .screenshot: return .screenshot(.desktop)
        case .app: return .app(path: "")
        case .website: return .website(url: "")
        case .file: return .file(path: "")
        case .shortcut: return .shortcut(name: "")
        }
    }

    /// A short line for under the button on the desk drawing.
    var summary: String {
        switch self {
        case .screenshot(.desktop): return "Screenshot to Desktop"
        case .screenshot(.clipboard): return "Screenshot to clipboard"
        case .screenshot(.area): return "Screenshot of an area"
        case .app(let path): return path.isEmpty ? "No app chosen" : "Opens \(Self.displayName(path))"
        case .website(let url): return Self.webURL(url)?.host.map { "Opens \($0)" } ?? "No website set"
        case .file(let path): return path.isEmpty ? "Nothing chosen" : "Opens \(Self.displayName(path))"
        case .shortcut(let name): return name.isEmpty ? "No Shortcut chosen" : "Runs \(name)"
        }
    }

    /// A few words for a key cap: "screenshot", "notes", "github.com".
    var short: String {
        switch self {
        case .screenshot: return "screenshot"
        case .app(let path), .file(let path): return path.isEmpty ? "choose…" : Self.displayName(path).lowercased()
        case .website(let url): return Self.webURL(url)?.host?.lowercased() ?? "no address"
        case .shortcut(let name): return name.isEmpty ? "choose…" : name.lowercased()
        }
    }

    static func displayName(_ path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The URL typed for a website, with https:// added when no scheme was given.
    static func webURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let url = URL(string: text.contains("://") ? text : "https://" + text), url.host != nil else { return nil }
        return url
    }
}

/// Every saved preset, and which one is in use. Kept as JSON in Application Support.
struct Library: Codable {
    var presets: [Setup] = []
    var active: String?

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Touchwood", isDirectory: true)
    }

    static func load() -> Library {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("presets.json")),
           let library = try? JSONDecoder().decode(Library.self, from: data) {
            return library
        }
        // Before presets, one setup lived in setup.json; it becomes the first preset.
        if let data = try? Data(contentsOf: folder.appendingPathComponent("setup.json")),
           let setup = try? JSONDecoder().decode(Setup.self, from: data), setup.isTaught {
            return Library(presets: [setup], active: setup.id)
        }
        return Library()
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.folder.appendingPathComponent("presets.json"), options: .atomic)
    }

    var current: Setup? { presets.first { $0.id == active } ?? presets.first }
}

/// Checks that older saved setups still load and that actions survive a save.
func selfTestSetup() {
    let legacy = #"{"buttons":[{"id":"A","name":"Left","x":0.1,"y":0.4},{"id":"B","name":"Right","x":0.9,"y":0.4}],"doubleTap":false,"input":"Mic","taps":[{"button":"A","shape":[1,2],"peak":-20},{"button":"B","shape":[2,1],"peak":-22}],"noise":[],"falsePresses":0,"everydaySounds":3}"#
    var setup = try! JSONDecoder().decode(Setup.self, from: Data(legacy.utf8))
    precondition(setup.name == "Desk 1" && !setup.doubleTap && setup.buttons[0].action == nil && setup.isTaught && setup.everydaySounds == 3)
    precondition(setup.sensitivity == 0.5 && abs(setup.factor - 6) < 1e-9)
    setup.buttons[0].action = .website(url: "example.com")
    setup.buttons[1].action = .screenshot(.clipboard)
    let back = try! JSONDecoder().decode(Library.self, from: JSONEncoder().encode(Library(presets: [setup], active: setup.id)))
    precondition(back.current?.id == setup.id && back.current?.buttons.map(\.action) == setup.buttons.map(\.action))
    precondition(Action.webURL("example.com")?.absoluteString == "https://example.com")
    precondition(Action.webURL("  ") == nil && Action.webURL("http://x.org/a")?.absoluteString == "http://x.org/a")
    precondition(Action.website(url: "news.ycombinator.com/item").summary == "Opens news.ycombinator.com")
}
