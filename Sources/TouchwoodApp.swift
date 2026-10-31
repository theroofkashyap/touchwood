import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// One instance per recording session, mutated only by its audio callback,
// except `factor`, which the dial sets and the callback copies into the detector.
private final class AudioSession {
    var cutter: TapCutter
    var lastMeter = -1.0
    var peak = 0.0 // loudest buffer since the last meter update, so short taps show
    var factor: Double
    init(_ cutter: TapCutter, factor: Double) {
        self.cutter = cutter
        self.factor = factor
    }
}

enum Screen { case welcome, home, assign, buttons, teach, noise, check, done }

/// A tap that just counted while teaching or checking, shown for a moment before the next prompt.
struct Ack: Equatable {
    var id: String
    var text: String
    var good = true
}

final class AppModel: ObservableObject {
    static let tapsPerButton = 10, checkPrompts = 8, noiseSeconds = 15.0
    static let ackSeconds = 0.8 // as long as a second tap is ignored while teaching
    @Published var screen = Screen.welcome
    @Published var setup = Setup() // the preset in use, or the one being made
    @Published var library = Library()
    @Published var picked: String? // preset highlighted on the welcome screen
    @Published var assigning: String? // button whose action is being chosen
    @Published var selected: String? // button selected while editing the layout
    @Published var actionsOn = true
    @Published var shortcutNames: [String] = []
    @Published var recordingKeys = false // the next key press becomes the assigned button's keys
    @Published var countdown: Int? // seconds until "try" presses the keys
    @Published var tried: String? // what the last "try" did, or why it failed
    @Published var micName = ""
    @Published var requesting = false
    @Published var listening = false
    @Published var warm = false // room noise measured; taps count from here
    @Published var elapsed = 0.0
    @Published var level = 0.0
    @Published var threshold = 0.008
    @Published var prompt: String? // button to tap next while teaching or checking
    @Published var taught: [String: Int] = [:]
    @Published var lit: String? // button just taught or pressed
    @Published var ack: Ack?
    @Published var armed: String? // button waiting for the second tap of a double tap
    @Published var headline: String? // big line on the live screen
    @Published var message: String? // small line under it, or the status while teaching and checking
    @Published var lastPress: Date?
    @Published var noiseLeft = AppModel.noiseSeconds
    @Published var noiseHeard = 0
    @Published var result = Setup.Check() // the check in progress
    @Published var report: SpotReport?
    @Published var error: String?
    private var queue: [String] = []
    private var recognizer: SpotModel?
    private var presser = Presser(double: true)
    private var quietest = -Double.infinity // softest taught tap less 6 dB; anything quieter is ignored
    private var noiseClips: [(onset: Double, shape: [Double], peak: Double)] = []
    private var noiseStart: Date?
    private var lastTaught = -10.0
    private var lastLoud = -10.0 // last time the input crossed the threshold
    private var lastSoft = -10.0 // last "too soft" hint
    private var redos = 0
    private var lastRun: [String: Date] = [:]
    private var keyMonitor: Any?
    private var origin = Screen.welcome // where Cancel returns to from setup
    private var engine: AVAudioEngine?
    private var session: AudioSession?
    private var generation = UUID()
    private var pulse = UUID()
    private var ackMark = UUID()
    private var routeObserver: NSObjectProtocol?

    init() {
        micName = Self.currentMic()
        library = Library.load()
        if let current = library.current { setup = current }
        picked = library.current?.id
    }

    static func currentMic() -> String { AVCaptureDevice.default(for: .audio)?.localizedName ?? "the default microphone" }

    var hasSaved: Bool { !library.presets.isEmpty }
    var total: Int { setup.buttons.count * Self.tapsPerButton }
    var done: Int { taught.values.reduce(0, +) }
    var pickedPreset: Setup? { library.presets.first { $0.id == picked } ?? library.current }
    func name(_ id: String) -> String { setup.name(id) }

    // MARK: Welcome

    func nextPreset() {
        guard !library.presets.isEmpty else { return }
        let at = library.presets.firstIndex { $0.id == pickedPreset?.id } ?? -1
        picked = library.presets[(at + 1) % library.presets.count].id
    }

    func toWelcome() {
        stop()
        message = nil
        headline = nil
        assigning = nil
        picked = setup.id
        screen = .welcome
    }

    func usePicked() {
        if let id = pickedPreset?.id { switchPreset(id) }
    }

    func retrainPicked() {
        if let id = pickedPreset?.id { retrain(id) }
    }

    func editPicked() {
        guard let preset = pickedPreset else { return }
        setup = preset
        library.active = preset.id
        prepare()
        editButtons()
    }

    func checkPicked() {
        guard let preset = pickedPreset else { return }
        leave()
        setup = preset
        library.active = preset.id
        prepare()
        startCheck()
    }

    // MARK: Buttons

    func addButton() {
        guard let next = Setup.defaults.first(where: { button in !setup.buttons.contains { $0.id == button.id } }) else { return }
        setup.buttons.append(next)
        selected = next.id
    }

    func removeButton(_ id: String) {
        guard setup.buttons.count > 2 else { return }
        setup.buttons.removeAll { $0.id == id }
        // The others still sound the same, so their teaching stays; a button added later must not inherit these taps.
        setup.taps.removeAll { $0.button == id }
        selected = setup.buttons.first?.id
    }

    func move(_ id: String, to point: CGPoint) {
        guard screen == .buttons, let i = setup.buttons.firstIndex(where: { $0.id == id }) else { return }
        setup.buttons[i].x = min(0.95, max(0.05, point.x))
        setup.buttons[i].y = min(0.9, max(0.12, point.y))
        selected = id
    }

    func editButtons() {
        stop()
        leave()
        message = nil
        error = nil
        assigning = nil
        selected = selected.flatMap { id in setup.buttons.contains { $0.id == id } ? id : nil } ?? setup.buttons.first?.id
        screen = .buttons
    }

    /// Names, positions and removals change no button's sound, so a taught preset keeps its teaching.
    var canSaveEdits: Bool { setup.isTaught }

    /// Keeps the layout's edits without teaching again, and returns to where editing started.
    func saveEdits() {
        guard canSaveEdits else { return }
        nameUnnamed()
        persist()
        prepare()
        message = nil
        headline = nil
        picked = setup.id
        screen = origin
        if origin == .home { listen() }
    }

    /// Adds a button from the live screen; it needs teaching, so this opens the layout.
    func addFromHome() {
        editButtons()
        addButton()
    }

    /// Notes where setup started, so Cancel can go back there.
    private func leave() {
        if screen == .welcome || screen == .home { origin = screen }
    }

    /// Leaves setup for the saved preset, on the screen setup started from.
    func cancel() {
        stop()
        message = nil
        guard let current = library.current else {
            screen = .welcome
            return
        }
        setup = current
        prepare()
        screen = origin
        if origin == .home { listen() }
    }

    func setGesture(double: Bool) {
        setup.doubleTap = double
        presser = Presser(double: double)
        armed = nil
        if screen == .home { persist() }
    }

    /// The dial's sensitivity; saved when the turn ends.
    func setSensitivity(_ value: Double, final: Bool) {
        setup.sensitivity = min(1, max(0, value))
        session?.factor = setup.factor
        if final && (screen == .home || screen == .assign) { persist() }
    }

    // MARK: Presets

    func switchPreset(_ id: String) {
        guard let preset = library.presets.first(where: { $0.id == id }) else { return }
        setup = preset
        library.active = id
        persist()
        prepare()
        message = nil
        headline = nil
        screen = .home
        listen()
    }

    func retrain(_ id: String) {
        guard let preset = library.presets.first(where: { $0.id == id }) else { return }
        leave()
        setup = preset
        library.active = id
        startTeaching()
    }

    func newPreset() {
        stop()
        leave()
        let taken = Set(library.presets.map(\.name))
        setup = Setup()
        setup.name = (1...).lazy.map { "Desk \($0)" }.first { !taken.contains($0) }!
        selected = setup.buttons.first?.id
        message = nil
        error = nil
        screen = .buttons
    }

    func deletePreset() {
        library.presets.removeAll { $0.id == setup.id }
        library.active = library.presets.first?.id
        persist(adding: false)
        stop()
        setup = library.current ?? Setup()
        picked = library.current?.id
        screen = .welcome
    }

    /// Writes the working setup into the library as the active preset, and the library to disk.
    private func persist(adding: Bool = true) {
        if adding {
            if let i = library.presets.firstIndex(where: { $0.id == setup.id }) { library.presets[i] = setup } else { library.presets.append(setup) }
            library.active = setup.id
        }
        do { try library.save() } catch { self.error = "could not save presets: \(error.localizedDescription)" }
    }

    // MARK: Actions

    func assign(_ id: String) {
        guard setup.buttons.contains(where: { $0.id == id }) else { return }
        settle()
        assigning = id
        screen = .assign
        loadShortcuts()
    }

    func finishAssign() {
        settle()
        assigning = nil
        screen = .home
    }

    func setAction(_ id: String, _ action: Action?) {
        guard let i = setup.buttons.firstIndex(where: { $0.id == id }) else { return }
        settle()
        setup.buttons[i].action = action
        persist()
    }

    /// Stops recording keys and any "try" countdown, and clears what the last try said.
    private func settle() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingKeys = false
        countdown = nil
        tried = nil
    }

    /// Takes the next key press, with its modifiers, as the keys the button being assigned presses. Esc alone cancels.
    func recordKeys() {
        guard let id = assigning else { return }
        settle()
        recordingKeys = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
                self.settle()
            } else {
                self.setAction(id, .keys(combo: KeyCombo(event)))
            }
            return nil // the press was the answer, so nothing else in the app sees it
        }
    }

    /// "try" while assigning. Keys go to the app in front, so they wait three seconds for you to switch to it.
    func tryAction(of id: String) {
        guard let action = setup.buttons.first(where: { $0.id == id })?.action else { return }
        if countdown != nil { return settle() }
        tried = nil
        guard case .keys(.some) = action else { return report(action) }
        countdown = 3
        countDown(action)
    }

    private func countDown(_ action: Action) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let left = self.countdown else { return }
            guard left == 1 else {
                self.countdown = left - 1
                return self.countDown(action)
            }
            self.countdown = nil
            self.report(action)
        }
    }

    private func report(_ action: Action) {
        let done = action.summary.lowercased()
        action.run { failure in DispatchQueue.main.async { [weak self] in self?.tried = failure?.lowercased() ?? done } }
    }

    /// The dial while assigning: one detent per kind of action.
    func dialKind(_ value: Double) {
        guard let id = assigning else { return }
        let kind = Action.Kind.allCases[Int((min(1, max(0, value)) * Double(Action.Kind.allCases.count - 1)).rounded())]
        let current = setup.buttons.first { $0.id == id }?.action?.kind ?? .nothing
        if kind != current { setAction(id, Action.blank(kind)) }
    }

    /// Asks for the app, or the file or folder, that a button opens.
    func choose(_ kind: Action.Kind, for id: String) {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.canChooseDirectories = kind == .file
        if kind == .app {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setAction(id, kind == .app ? .app(path: url.path) : .file(path: url.path))
    }

    func runAction(of id: String) {
        guard let action = setup.buttons.first(where: { $0.id == id })?.action else { return }
        lastRun[id] = Date()
        let done = action.summary.lowercased()
        action.run { failure in DispatchQueue.main.async { [weak self] in self?.message = failure?.lowercased() ?? done } }
    }

    func loadShortcuts() { Action.shortcuts { [weak self] in self?.shortcutNames = $0 } }

    // MARK: Teaching, everyday noise, check

    /// A button left without a name is called by its letter.
    private func nameUnnamed() {
        for i in setup.buttons.indices where setup.buttons[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            setup.buttons[i].name = setup.buttons[i].id
        }
    }

    func startTeaching() {
        leave()
        nameUnnamed()
        setup.taps = []
        setup.noise = []
        setup.check = nil
        setup.input = micName
        recognizer = nil
        report = nil
        taught = [:]
        lastTaught = -10
        redos = 0
        message = nil
        error = nil
        // The buttons in turn, so the next spot is predictable and drift in the room spreads evenly over all of them.
        queue = (0..<Self.tapsPerButton).flatMap { _ in setup.buttons.map(\.id) }
        screen = .teach
        prompt = warm ? queue.first : nil
        listen()
    }

    private func teach(_ shape: [Double], _ peak: Double, at onset: Double) {
        guard let id = prompt else { return }
        // A second tap this close is usually a habit double tap, not an answer to the next prompt.
        guard onset - lastTaught >= Self.ackSeconds else {
            hint("One tap at a time. Wait for the next spot.")
            return
        }
        lastTaught = onset
        let same = setup.taps.filter { $0.button == id }.map(\.shape)
        if same.count >= 4 && redos < 2 {
            let center = centroid(same)
            if euclidean(shape, center) > 2.5 * median(same.map { euclidean($0, center) }) {
                redos += 1
                message = "That one sounded different. Tap \(name(id).lowercased()) again."
                return
            }
        }
        redos = 0
        setup.taps.append(Setup.Tap(button: id, shape: shape, peak: peak))
        taught[id, default: 0] += 1
        message = nil
        acknowledge(id, "Got it")
        queue.removeFirst()
        prompt = queue.first
        if queue.isEmpty {
            noiseClips = []
            noiseHeard = 0
            noiseLeft = Self.noiseSeconds
            noiseStart = Date()
            screen = .noise
        }
    }

    private func finishNoise() {
        noiseStart = nil
        setup.noise = noiseClips.map(\.shape)
        prepare()
        // Judge each everyday sound with a recognizer that never heard it, as a new sound would be.
        let taps = setup.taps.map { (label: $0.button, features: $0.shape) }
        var dry = Presser(double: setup.doubleTap)
        setup.falsePresses = noiseClips.indices.filter { j in
            guard noiseClips[j].peak >= quietest else { return false }
            let without = SpotModel(taps, noise: noiseClips.indices.filter { $0 != j }.map { noiseClips[$0].shape })
            return dry.feed(without.guess(noiseClips[j].shape), at: noiseClips[j].onset) != nil
        }.count
        setup.everydaySounds = noiseClips.count
        startCheck()
    }

    func startCheck() {
        leave()
        result = Setup.Check()
        presser = Presser(double: setup.doubleTap)
        armed = nil
        message = nil
        let ids = setup.buttons.map(\.id)
        queue = (0..<Self.checkPrompts).map { ids[$0 % ids.count] }.shuffled()
        screen = .check
        prompt = warm ? queue.first : nil
        listen()
    }

    private func check(_ guess: Guess, pressed: String?) {
        guard let target = prompt else { return }
        guard let pressed else {
            if case .button = guess { return } // first tap of a double tap
            result.unrecognized += 1
            message = guess == .unsure ? "Not sure which spot that was. Try again." : "That didn't sound like a button. Try again."
            return
        }
        message = nil
        if pressed == target {
            result.right += 1
            acknowledge(pressed, "Correct")
        } else {
            result.wrong += 1
            acknowledge(pressed, "Read as \(name(pressed).lowercased())", good: false)
        }
        queue.removeFirst()
        prompt = queue.first
        if queue.isEmpty {
            setup.check = result
            message = nil
            screen = .done
        }
    }

    func save() {
        persist()
        message = nil
        headline = nil
        presser = Presser(double: setup.doubleTap)
        screen = .home
    }

    /// Builds the recognizer from the setup's taught taps and everyday sounds.
    private func prepare() {
        let taps = setup.taps.map { (label: $0.button, features: $0.shape) }
        recognizer = taps.isEmpty ? nil : SpotModel(taps, noise: setup.noise)
        quietest = (setup.taps.map(\.peak).min() ?? -200) - 6
        presser = Presser(double: setup.doubleTap)
        report = SpotReport(setup.taps.map { (label: $0.button, shape: $0.shape, peak: $0.peak) })
        session?.factor = setup.factor
        armed = nil
    }

    // MARK: Listening

    private func take(_ clip: TapClip) {
        let shape = soundShape(clip.channels[0], rate: clip.rate), peak = peakLevel(clip.channels[0])
        switch screen {
        case .welcome, .buttons, .done:
            return
        case .teach:
            teach(shape, peak, at: clip.onset)
        case .noise:
            noiseClips.append((clip.onset, shape, peak))
            noiseHeard = noiseClips.count
        case .check, .home, .assign:
            guard let recognizer, peak >= quietest else { return }
            let guess = recognizer.guess(shape)
            let pressed = presser.feed(guess, at: clip.onset)
            armed = presser.armed?.spot
            if screen == .check { return check(guess, pressed: pressed) }
            if let pressed { flash(pressed) }
            switch guess {
            case _ where pressed != nil:
                headline = "\(pressed!.lowercased()) \(name(pressed!).lowercased())"
                message = setup.buttons.first { $0.id == pressed }?.action == nil || !actionsOn || screen == .assign ? "pressed" : "…"
                lastPress = Date()
            case .button(let id):
                headline = "\(id.lowercased()) …"
                message = "tap again"
            case .unsure:
                headline = "?"
                message = "not sure which button"
            case .notButton:
                headline = "-"
                message = "not a button"
            }
            // Never while choosing an action, and never twice from a habit double tap in single-tap mode.
            if screen == .home, let pressed, actionsOn, Date().timeIntervalSince(lastRun[pressed] ?? .distantPast) > 1 { runAction(of: pressed) }
        }
    }

    private func tick(_ time: Double) {
        elapsed = time
        if !warm, time >= 3 {
            warm = true
            if screen == .teach || screen == .check { prompt = queue.first }
        }
        if screen == .noise, let start = noiseStart {
            noiseLeft = max(0, Self.noiseSeconds - Date().timeIntervalSince(start))
            if noiseLeft == 0 { finishNoise() }
        }
    }

    func listen() {
        guard !listening, !requesting else { return }
        let id = generation
        requesting = true
        warm = false
        elapsed = 0
        lastLoud = -10 // each recording session counts time from zero
        lastSoft = -10
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == id else { return }
                self.requesting = false
                guard granted else {
                    self.error = "allow touchwood in system settings → privacy & security → microphone."
                    return
                }
                self.record(id: id)
            }
        }
    }

    private func record(id: UUID) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            error = "no microphone input. select your macbook microphone in system settings."
            return
        }
        let session = AudioSession(TapCutter(rate: format.sampleRate, channels: Int(format.channelCount)), factor: setup.factor)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
            session.cutter.detector.factor = session.factor
            let clips = session.cutter.feed(channels)
            let time = session.cutter.detector.elapsed
            let rms = sqrt(channels[0].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, frames)))
            session.peak = max(session.peak, rms)
            guard !clips.isEmpty || time - session.lastMeter >= 0.04 else { return }
            session.lastMeter = time
            let peak = session.peak
            session.peak = 0
            let gate = max(0.008, session.cutter.detector.noise * session.factor)
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.listening else { return }
                self.level = peak
                self.threshold = gate
                self.tick(time)
                clips.forEach(self.take)
                self.watchSoft(peak, gate: gate, at: time)
            }
        }
        self.engine = engine
        self.session = session
        do {
            try engine.start()
            listening = true
            routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.micName = Self.currentMic()
                if self.screen == .home || self.screen == .assign { self.stop() } else { self.cancel() }
                self.error = "the audio input changed, so touchwood stopped listening."
            }
        } catch {
            stop()
            self.error = "could not start the microphone: \(error.localizedDescription)"
        }
    }

    /// While teaching, a sound that comes close to the threshold without crossing it is most likely a tap that was too soft.
    private func watchSoft(_ peak: Double, gate: Double, at time: Double) {
        if peak >= gate {
            lastLoud = time
            return
        }
        guard screen == .teach, warm, prompt != nil, ack == nil, peak >= 0.5 * gate,
              time - lastLoud > 0.5, time - lastSoft > 3 else { return }
        lastSoft = time
        hint("Too soft to count. Tap so the meter passes the line.")
    }

    /// A note under the prompt that clears itself after a moment, unless something replaced it.
    private func hint(_ text: String) {
        message = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.message == text { self?.message = nil }
        }
    }

    /// Lights the spot, glows the screen and holds the next prompt back for a moment.
    private func acknowledge(_ id: String, _ text: String, good: Bool = true) {
        let mark = UUID()
        ackMark = mark
        ack = Ack(id: id, text: text, good: good)
        flash(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ackSeconds) { [weak self] in
            guard self?.ackMark == mark else { return }
            self?.ack = nil
        }
    }

    private func flash(_ id: String) {
        let mark = UUID()
        pulse = mark
        lit = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self?.pulse == mark else { return }
            self?.lit = nil
        }
    }

    func stop() {
        generation = UUID()
        pulse = UUID()
        ackMark = UUID()
        ack = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        session = nil
        listening = false
        requesting = false
        warm = false
        prompt = nil
        lit = nil
        armed = nil
        level = 0
    }
}

@main
struct TouchwoodApp: App {
    var body: some Scene {
        Window("Touchwood", id: "main") {
            DeviceView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
