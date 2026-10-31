import AppKit

extension Action {
    /// Runs the action; `done` gets nil on success or a sentence saying what went wrong, on any queue.
    func run(_ done: @escaping (String?) -> Void) {
        switch self {
        case .screenshot(let mode):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let stamp = formatter.string(from: Date())
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            func file(_ screen: Int) -> String { desktop.appendingPathComponent("Touchwood \(stamp)\(screen > 0 ? " (\(screen + 1))" : "").png").path }
            switch mode {
            case .clipboard: Self.launch("/usr/sbin/screencapture", ["-c"], done)
            case .area: Self.launch("/usr/sbin/screencapture", ["-i", file(0)], done)
            // screencapture writes one display per file name given.
            case .desktop: Self.launch("/usr/sbin/screencapture", NSScreen.screens.indices.map(file), done)
            }
        case .app(let path):
            guard !path.isEmpty else { return done("No app chosen for this button.") }
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration()) { _, error in
                done(error.map { "Couldn't open \(Self.displayName(path)): \($0.localizedDescription)" })
            }
        case .website(let text):
            guard let url = Self.webURL(text) else { return done("No website set for this button.") }
            done(NSWorkspace.shared.open(url) ? nil : "Couldn't open \(url.absoluteString).")
        case .file(let path):
            guard !path.isEmpty else { return done("Nothing chosen for this button.") }
            guard FileManager.default.fileExists(atPath: path) else { return done("\(Self.displayName(path)) is no longer there.") }
            done(NSWorkspace.shared.open(URL(fileURLWithPath: path)) ? nil : "Couldn't open \(Self.displayName(path)).")
        case .shortcut(let name):
            guard !name.isEmpty else { return done("No Shortcut chosen for this button.") }
            Self.launch("/usr/bin/shortcuts", ["run", name], done)
        case .keys(let combo):
            guard let combo else { return done("No keys set for this button.") }
            // Posting key events needs Accessibility; the option has macOS show its prompt when it's missing.
            guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
                return done("Allow Touchwood in Privacy & Security → Accessibility, then try again.")
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return done("Touchwood is in front. Keys go to the app in front, so switch to it first.")
            }
            Self.press(combo)
            done(nil)
        }
    }

    private static func press(_ combo: KeyCombo) {
        var flags = CGEventFlags()
        if combo.control { flags.insert(.maskControl) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.shift { flags.insert(.maskShift) }
        if combo.command { flags.insert(.maskCommand) }
        if combo.fn { flags.insert(.maskSecondaryFn) }
        if combo.keypad { flags.insert(.maskNumericPad) }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func launch(_ tool: String, _ arguments: [String], _ done: @escaping (String?) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.terminationHandler = { task in
            done(task.terminationStatus == 0 ? nil : "\(URL(fileURLWithPath: tool).lastPathComponent) failed (exit \(task.terminationStatus)).")
        }
        do { try process.run() } catch { done("Couldn't start \(tool): \(error.localizedDescription)") }
    }

    /// Names of the user's Shortcuts, delivered on the main queue; empty when there are none or listing fails.
    static func shortcuts(_ done: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return DispatchQueue.main.async { done([]) } }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            var seen = Set<String>()
            let names = output.split(separator: "\n").map(String.init).filter { seen.insert($0).inserted }
            DispatchQueue.main.async { done(names) }
        }
    }
}

extension KeyCombo {
    private static let names: [UInt16: String] = [
        36: "return", 76: "enter", 48: "tab", 49: "space", 51: "delete", 117: "forward delete", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "home (fn ←)", 119: "end (fn →)", 116: "page up (fn ↑)", 121: "page down (fn ↓)",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// The combo a key press makes, with the key named as it reads unshifted on this keyboard layout.
    init(_ event: NSEvent) {
        let flags = event.modifierFlags
        let typed = event.characters(byApplyingModifiers: [])?.lowercased() ?? ""
        self.init(code: event.keyCode, key: Self.names[event.keyCode] ?? (typed.isEmpty ? "key \(event.keyCode)" : typed),
                  control: flags.contains(.control), option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command),
                  fn: flags.contains(.function), keypad: flags.contains(.numericPad))
    }
}
