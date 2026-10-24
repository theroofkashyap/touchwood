import Foundation
import AVFoundation

if CommandLine.arguments.contains("--self-test") {
    func run(_ bursts: [ClosedRange<Int>]) -> Int {
        var detector = Detector()
        var count = 0
        for i in 0..<700 {
            let loud = bursts.contains { $0.contains(i) }
            if detector.feed(rms: loud ? 0.15 : 0.001, dt: 0.01) { count += 1 }
        }
        return count
    }
    precondition(run([]) == 0)
    precondition(run([350...351]) == 0)
    precondition(run([350...351, 375...376]) == 1)
    precondition(run([350...370, 395...420]) == 0)
    precondition(run([350...351, 410...411]) == 0)
    precondition(run([350...351, 375...376, 400...401, 425...426]) == 1)
    selfTestTapLab()
    selfTestSetup()
    print("Passed: silence, single tap, double tap, sustained noise, slow pair, cooldown, clip cutting, WAV round trip, spot scoring, live guessing, noise refusal, presses, saved presets and actions.")
    exit(0)
}

let argv = Array(CommandLine.arguments.dropFirst())
if argv.contains("--help") {
    print("""
    touchwood [--screenshots | --self-test]
    touchwood --record SPOT SPOT... [--taps N]
    touchwood --analyze [FOLDER]
    Default: report double taps only. --screenshots saves main-display PNGs to ./captures.
    --record asks you to tap the named spots in random order, N times each (default 15), saves each tap as a short clip in ./taps/SPOT/, then runs --analyze.
    --analyze reports how well the spots in ./taps (or FOLDER) can be told apart by sound.
    Use the Mac microphone as your default input. Remain quiet for the first 3 seconds.
    """)
    exit(0)
}
if argv.first == "--analyze" {
    guard argv.count <= 2 else { fputs("Usage: touchwood --analyze [FOLDER]\n", stderr); exit(1) }
    exit(analyze(folder: URL(fileURLWithPath: argv.count == 2 ? argv[1] : "taps")) ? 0 : 1)
}

var spots: [String] = [] // record mode when not empty
var tapsPerSpot = 15
if argv.first == "--record" {
    var rest = argv.dropFirst()
    while let arg = rest.popFirst() {
        if arg == "--taps", let n = rest.popFirst().flatMap({ Int($0) }), (4...100).contains(n) {
            tapsPerSpot = n
        } else if arg.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]*$", options: .regularExpression) != nil, !spots.contains(arg) {
            spots.append(arg)
        } else {
            fputs("Bad spot name or option: \(arg). Spot names use letters, digits, - and _; --taps takes 4 to 100.\n", stderr)
            exit(1)
        }
    }
    guard spots.count >= 2 else {
        fputs("Name at least two spots, e.g. --record left right\n", stderr)
        exit(1)
    }
} else if !Set(argv).isSubset(of: ["--screenshots"]) {
    fputs("Unknown option. Use --help.\n", stderr)
    exit(1)
}

let screenshots = argv.contains("--screenshots")
let engine = AVAudioEngine()
var detector = Detector()
var cutter: TapCutter? // set before recording starts, then owned by the audio callback
var capturing = false // accessed only on the main queue
let tapFolder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("taps")
var prompts: [String] = [] // spots still to ask for; main queue only, like the two below
var asked = false
var lastSaved = -10.0

func trigger() {
    print("Double tap detected at \(Date())")
    guard screenshots, !capturing else { return }
    capturing = true
    let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("captures")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("\(UUID().uuidString).png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-m", path]
        process.terminationHandler = { task in
            DispatchQueue.main.async {
                capturing = false
                print(task.terminationStatus == 0 ? "Saved \(path)" : "Capture failed. Check Screen Recording permission for your terminal.")
            }
        }
        try process.run()
    } catch {
        capturing = false
        print("Capture failed: \(error)")
    }
}

func ask() {
    asked = true
    let progress = spots.map { spot in "\(spot) \(tapsPerSpot - prompts.filter { $0 == spot }.count)/\(tapsPerSpot)" }
    print("→ Tap \(prompts[0].uppercased())   (\(progress.joined(separator: " · ")))")
}

func save(_ clip: TapClip) {
    guard asked, let spot = prompts.first else { return }
    // A second tap this close is usually a habit double tap, not an answer to the next prompt.
    guard clip.onset - lastSaved >= 0.8 else {
        print("  Ignored a tap that came too soon. One tap per prompt.")
        return
    }
    let folder = tapFolder.appendingPathComponent(spot)
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WAV.write(clip, to: folder.appendingPathComponent("\(spot)-\(Int(Date().timeIntervalSince1970 * 1000)).wav"))
    } catch {
        fputs("Could not save the clip: \(error)\n", stderr)
        exit(1)
    }
    lastSaved = clip.onset
    prompts.removeFirst()
    if !prompts.isEmpty {
        ask()
        return
    }
    engine.stop()
    print("\nSaved \(spots.count * tapsPerSpot) taps in \(tapFolder.path).\n")
    exit(analyze(folder: tapFolder) ? 0 : 1)
}

func start() {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
        fputs("No enabled audio input.\n", stderr)
        exit(1)
    }
    print("Input: \(format.channelCount) channel(s), \(format.sampleRate) Hz. Using channel 1.")
    if spots.isEmpty {
        print("Calibrating for 3 seconds; keep quiet. Then double-tap 140–480 ms apart. Ctrl-C stops.")
        print(screenshots ? "Screenshot mode enabled." : "Dry run: events only.")
        // Split actual callback buffers into ~5 ms windows; hardware may ignore requested size.
        input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0] else { return }
            let window = max(1, Int(format.sampleRate * 0.005))
            var offset = 0
            while offset < Int(buffer.frameLength) {
                let end = min(offset + window, Int(buffer.frameLength))
                var energy = 0.0
                for i in offset..<end { energy += Double(samples[i]) * Double(samples[i]) }
                let count = Double(end - offset)
                if detector.feed(rms: sqrt(energy / count), dt: count / format.sampleRate) {
                    DispatchQueue.main.async { trigger() }
                }
                offset = end
            }
        }
    } else {
        print("Calibrating for 3 seconds; keep quiet. Then tap once where each prompt says. Mix soft and firm taps at every spot. Ctrl-C stops.")
        prompts = spots.flatMap { Array(repeating: $0, count: tapsPerSpot) }.shuffled()
        cutter = TapCutter(rate: format.sampleRate, channels: Int(format.channelCount))
        input.installTap(onBus: 0, bufferSize: 256, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
            for clip in cutter?.feed(channels) ?? [] {
                DispatchQueue.main.async { save(clip) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { ask() }
    }
    do { try engine.start() }
    catch { fputs("Audio engine failed: \(error)\n", stderr); exit(1) }
}

AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        guard granted else {
            fputs("Microphone access denied. Enable it for your terminal in System Settings.\n", stderr)
            exit(1)
        }
        start()
    }
}
RunLoop.main.run()
