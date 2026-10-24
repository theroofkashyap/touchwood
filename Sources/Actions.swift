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
