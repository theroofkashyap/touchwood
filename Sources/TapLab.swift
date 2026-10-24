import Foundation
import Accelerate

// Checks whether desk spots sound different: cut a clip per tap, describe it, compare spots.

struct TapClip {
    var onset: Double // seconds since listening started
    var rate: Double
    var channels: [[Float]]
}

/// Cuts a clip from 20 ms before to 130 ms after every single tap. Owned by the audio callback.
struct TapCutter {
    static let before = 0.02, after = 0.13
    var detector = Detector()
    let rate: Double
    private var ring: [[Float]] // the last second of every channel
    private var written = 0
    private var pending: [(onset: Double, start: Int)] = []

    init(rate: Double, channels: Int) {
        self.rate = rate
        ring = Array(repeating: Array(repeating: 0, count: Int(rate)), count: channels)
    }

    /// Takes one buffer per channel; returns the clips whose tail has now arrived.
    mutating func feed(_ samples: [[Float]]) -> [TapClip] {
        let frames = samples[0].count, size = ring[0].count
        for c in ring.indices { for i in 0..<frames { ring[c][(written + i) % size] = samples[c][i] } }
        written += frames
        let window = max(1, Int(rate * 0.005))
        var offset = 0
        while offset < frames {
            let end = min(offset + window, frames)
            var energy = 0.0
            for i in offset..<end { energy += Double(samples[0][i]) * Double(samples[0][i]) }
            let count = Double(end - offset)
            let taps = detector.tapCount
            _ = detector.feed(rms: sqrt(energy / count), dt: count / rate)
            if detector.tapCount != taps {
                pending.append((detector.lastTap, Int(detector.lastTap * rate) - Int(Self.before * rate)))
            }
            offset = end
        }
        let length = Int((Self.before + Self.after) * rate)
        var clips: [TapClip] = []
        var waiting: [(onset: Double, start: Int)] = []
        for tap in pending {
            if tap.start + length > written { waiting.append(tap); continue }
            guard tap.start >= max(0, written - size) else { continue }
            clips.append(TapClip(onset: tap.onset, rate: rate, channels: ring.map { channel in
                (tap.start..<tap.start + length).map { channel[$0 % size] }
            }))
        }
        pending = waiting
        return clips
    }
}

/// 32-bit float WAV files, which QuickTime and most audio tools open.
enum WAV {
    static func write(_ clip: TapClip, to url: URL) throws {
        let channels = clip.channels.count, frames = clip.channels[0].count, size = frames * channels * 4
        var data = Data("RIFF".utf8)
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        put(UInt32(36 + size))
        data.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16)); put(UInt16(3)); put(UInt16(channels)); put(UInt32(clip.rate))
        put(UInt32(Int(clip.rate) * channels * 4)); put(UInt16(channels * 4)); put(UInt16(32))
        data.append(contentsOf: "data".utf8)
        put(UInt32(size))
        for i in 0..<frames { for c in 0..<channels { put(clip.channels[c][i].bitPattern) } }
        try data.write(to: url)
    }

    static func read(_ url: URL) throws -> TapClip {
        let bytes = [UInt8](try Data(contentsOf: url))
        func int(_ at: Int, _ width: Int) -> Int { (0..<width).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        let corrupt = CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw corrupt }
        var at = 12, channels = 0, rate = 0.0, isFloat = false
        while at + 8 <= bytes.count {
            let size = int(at + 4, 4), body = at + 8
            guard body + size <= bytes.count else { break }
            if tag(at) == "fmt ", size >= 16 {
                isFloat = int(body, 2) == 3 && int(body + 14, 2) == 32
                channels = int(body + 2, 2)
                rate = Double(int(body + 4, 4))
            } else if tag(at) == "data", isFloat, channels > 0 {
                let frames = size / (4 * channels)
                return TapClip(onset: 0, rate: rate, channels: (0..<channels).map { c in
                    (0..<frames).map { Float(bitPattern: UInt32(int(body + ($0 * channels + c) * 4, 4))) }
                })
            }
            at = body + size + size % 2
        }
        throw corrupt
    }
}

/// How one tap sounds with loudness removed: energy in 24 bands from 150 Hz up,
/// relative to their average, plus how fast the sound dies away.
func soundShape(_ x: [Float], rate: Double) -> [Double] {
    let peak = x.map { abs($0) }.max() ?? 0
    let onset = max(0, (x.firstIndex { abs($0) >= peak * 0.3 } ?? 0) - Int(0.002 * rate))
    let log2n = Int(log2(0.085 * rate).rounded())
    let n = 1 << log2n
    // Keep the attack whole and fade the tail, so the frame's end adds no false ring.
    let frame = (0..<n).map { i in onset + i < x.count ? x[onset + i] * Float(0.5 + 0.5 * cos(Double.pi * Double(i) / Double(n))) : 0 }
    var real = [Float](repeating: 0, count: n / 2)
    var imag = real
    var power = real
    let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2))!
    defer { vDSP_destroy_fftsetup(setup) }
    real.withUnsafeMutableBufferPointer { re in
        imag.withUnsafeMutableBufferPointer { im in
            var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
            frame.withUnsafeBufferPointer { f in
                f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
            }
            vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
        }
    }
    let low = 150.0, high = min(16_000, rate * 0.45), binHz = rate / Double(n)
    func bin(_ band: Int) -> Int { Int(low * pow(high / low, Double(band) / 24) / binHz) }
    let bands = (0..<24).map { b in log10(power[bin(b)..<max(bin(b) + 1, bin(b + 1))].reduce(0.0) { $0 + Double($1) } + 1e-12) }
    let average = bands.reduce(0, +) / 24
    func energy(_ from: Double, _ to: Double) -> Double {
        x[min(x.count, onset + Int(from * rate))..<min(x.count, onset + Int(to * rate))].reduce(0.0) { $0 + Double($1) * Double($1) }
    }
    return bands.map { $0 - average } + [log10((energy(0.015, 0.08) + 1e-12) / (energy(0, 0.015) + 1e-12))]
}

/// Peak level of a clip in dB below full scale.
func peakLevel(_ x: [Float]) -> Double { 20 * log10(Double(x.map { abs($0) }.max() ?? 0) + 1e-9) }

func centroid(_ rows: [[Double]]) -> [Double] { rows[0].indices.map { d in rows.reduce(0.0) { $0 + $1[d] } / Double(rows.count) } }
func euclidean(_ a: [Double], _ b: [Double]) -> Double { sqrt(zip(a, b).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }) }
func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }

enum Guess: Equatable { case button(String), unsure, notButton }

/// Recognizes taught spots by the nearest spot average, measured in units of how much each
/// feature varies between taps at the same spot. Refuses close calls and unfamiliar sounds.
struct SpotModel {
    /// How much closer the best spot must be than the runner-up, in squared distance.
    static let margin = 4.0
    private let spread: [Double]
    private let centers: [(spot: String, center: [Double])]
    private let taught: [(spot: String, features: [Double])]
    private let noise: [[Double]]
    private let limit: Double

    /// `noise` holds everyday sounds that must never press a button.
    init(_ taps: [(label: String, features: [Double])], noise: [[Double]] = []) {
        let spots = Set(taps.map(\.label)).sorted()
        let groups = spots.map { spot in taps.filter { $0.label == spot }.map(\.features) }
        let middles = groups.map(centroid)
        let within = taps[0].features.indices.map { d in
            zip(groups, middles).reduce(0.0) { sum, group in sum + group.0.reduce(0.0) { $0 + pow($1[d] - group.1[d], 2) } }
                / Double(max(1, taps.count - spots.count))
        }
        // Shrink toward the typical spread, so a band that happened to hold steady in a few taps can't dominate.
        let typical = median(within)
        let spread = within.map { sqrt(0.7 * $0 + 0.3 * typical) + 1e-9 }
        func scale(_ row: [Double]) -> [Double] { zip(row, spread).map { $0.0 / $0.1 } }
        let scaled = groups.map { $0.map(scale) }
        let centers = scaled.map(centroid)
        self.spread = spread
        self.centers = zip(spots, centers).map { (spot: $0.0, center: $0.1) }
        taught = zip(spots, scaled).flatMap { pair in pair.1.map { (spot: pair.0, features: $0) } }
        self.noise = noise.map(scale)
        // How far an honest new tap lands: each taught tap against its spot's average without it.
        let strays = zip(scaled, centers).flatMap { pair -> [Double] in
            let (rows, center) = pair, n = Double(rows.count)
            return rows.count < 2 ? [] : rows.map { row in euclidean(row, zip(center, row).map { ($0.0 * n - $0.1) / (n - 1) }) }
        }.sorted()
        limit = strays.isEmpty ? .infinity : 1.3 * strays[min(strays.count - 1, strays.count * 9 / 10)]
    }

    private func ranked(_ features: [Double]) -> (z: [Double], spots: [(spot: String, distance: Double)]) {
        let z = zip(features, spread).map { $0.0 / $0.1 }
        return (z, centers.map { (spot: $0.spot, distance: euclidean(z, $0.center)) }.sorted { $0.distance < $1.distance })
    }

    /// The spot with the nearest average, never refusing; for scoring.
    func nearest(_ features: [Double]) -> String { ranked(features).spots[0].spot }

    func guess(_ features: [Double]) -> Guess {
        let (z, spots) = ranked(features)
        let best = spots[0]
        guard best.distance <= limit else { return .notButton }
        // Closer to something heard during everyday noise than to any tap taught at this spot.
        let tap = taught.filter { $0.spot == best.spot }.map { euclidean(z, $0.features) }.min()!
        if let sound = noise.map({ euclidean(z, $0) }).min(), sound < tap { return .notButton }
        if spots.count > 1, pow(spots[1].distance, 2) - pow(best.distance, 2) < Self.margin { return .unsure }
        return .button(best.spot)
    }
}

/// Turns guesses into presses: one tap, or two taps on the same button 140–480 ms apart.
struct Presser {
    let double: Bool
    private(set) var armed: (spot: String, at: Double)?

    init(double: Bool) { self.double = double }

    mutating func feed(_ guess: Guess, at time: Double) -> String? {
        guard case .button(let spot) = guess else {
            armed = nil
            return nil
        }
        guard double else { return spot }
        if let first = armed, first.spot == spot, (0.14...0.48).contains(time - first.at) {
            armed = nil
            return spot
        }
        armed = (spot, time)
        return nil
    }
}

/// Guesses each tap's spot from all the other taps (leave-one-out, nearest average).
func leaveOneOut(_ taps: [(label: String, features: [Double])]) -> [String] {
    taps.indices.map { i in SpotModel(taps.indices.filter { $0 != i }.map { taps[$0] }).nearest(taps[i].features) }
}

enum Verdict { case clear, partial, notSeparable, unclear }

/// Leave-one-out scores for labeled taps, shared by the command-line report and the app.
struct SpotReport {
    let spots: [String]
    let counts: [String: Int]
    let shapeScore: Double, loudScore: Double, chance: Double
    let verdict: Verdict
    private let labels: [String], guesses: [String], peaks: [Double]

    /// Nil with fewer than two spots or under 4 taps at any spot.
    init?(_ taps: [(label: String, shape: [Double], peak: Double)]) {
        let counts = Dictionary(grouping: taps, by: \.label).mapValues(\.count)
        guard counts.count >= 2, counts.values.allSatisfy({ $0 >= 4 }) else { return nil }
        let labels = taps.map(\.label)
        let guesses = leaveOneOut(taps.map { (label: $0.label, features: $0.shape) })
        func score(_ guesses: [String]) -> Double { Double(zip(labels, guesses).filter { $0.0 == $0.1 }.count) / Double(labels.count) }
        let shapeScore = score(guesses)
        let loudScore = score(leaveOneOut(taps.map { (label: $0.label, features: [$0.peak]) }))
        self.counts = counts
        self.labels = labels
        self.guesses = guesses
        self.shapeScore = shapeScore
        self.loudScore = loudScore
        spots = counts.keys.sorted()
        peaks = taps.map(\.peak)
        chance = Double(counts.values.max()!) / Double(labels.count)
        // Quiet taps carry more room noise, so a force difference between spots also changes their shape.
        if shapeScore >= 0.75 && loudScore >= 0.75 && loudScore >= shapeScore - 0.05 {
            verdict = .unclear
        } else if shapeScore >= 0.9 {
            verdict = .clear
        } else if shapeScore >= 0.75 {
            verdict = .partial
        } else {
            verdict = .notSeparable
        }
    }

    func count(tapped: String, guessed: String) -> Int { zip(labels, guesses).filter { $0.0 == tapped && $0.1 == guessed }.count }
    func averagePeak(_ spot: String) -> Double { zip(labels, peaks).filter { $0.0 == spot }.reduce(0.0) { $0 + $1.1 } / Double(counts[spot]!) }
}

/// Prints how well the spots recorded under `folder` can be told apart. Returns false when there is too little to judge.
func analyze(folder: URL) -> Bool {
    let files = FileManager.default
    var taps: [(label: String, shape: [Double], peak: Double)] = []
    var rates = Set<Int>(), channels = 1
    for spot in ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() {
        let dir = folder.appendingPathComponent(spot)
        for name in ((try? files.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where name.hasSuffix(".wav") {
            do {
                let clip = try WAV.read(dir.appendingPathComponent(name))
                taps.append((spot, soundShape(clip.channels[0], rate: clip.rate), peakLevel(clip.channels[0])))
                rates.insert(Int(clip.rate))
                channels = max(channels, clip.channels.count)
            } catch {
                print("Skipping \(spot)/\(name): \(error.localizedDescription)")
            }
        }
    }
    guard let report = SpotReport(taps) else {
        print("Need two or more spots with at least 4 taps each in \(folder.path).\nRecord some with: ./build/touchwood --record left right")
        return false
    }
    func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    let spots = report.spots
    let format = rates.sorted().map { "\($0) Hz" }.joined(separator: ", ") + (channels == 1 ? ", 1 channel" : ", \(channels) channels, first one compared")
    print(spots.map { "\(report.counts[$0]!) \($0)" }.joined(separator: " · ") + " taps from \(folder.path) (\(format))")
    print("\nSound shape, loudness removed: \(percent(report.shapeScore)) guessed right (chance is \(percent(report.chance)))")
    let width = spots.map(\.count).max()! + 4
    func cell(_ text: String) -> String { String(repeating: " ", count: max(0, width - text.count)) + text }
    print("  " + "tapped".padding(toLength: width, withPad: " ", startingAt: 0) + spots.map(cell).joined() + "  ← guessed")
    for spot in spots {
        let row = spots.map { String(report.count(tapped: spot, guessed: $0)) }
        print("  " + spot.padding(toLength: width, withPad: " ", startingAt: 0) + row.map(cell).joined())
    }
    let levels = spots.map { "\($0) \(Int(report.averagePeak($0).rounded())) dBFS" }
    print("\nLoudness alone: \(percent(report.loudScore)) guessed right (average peak: \(levels.joined(separator: ", ")))\n")
    switch report.verdict {
    case .unclear:
        print("Verdict: unclear. Loudness alone tells these spots apart about as well, so this may be how hard you tapped rather than where. Record again, tapping soft and firm at every spot.")
    case .clear:
        print("Verdict: these spots sound clearly different. Try them live in the Touchwood app.")
    case .partial:
        print("Verdict: partly separable. Try spots farther apart or on different surfaces.")
    case .notSeparable:
        print("Verdict: not separable with this setup. Try very different spots, like the desk and the palm rest, before giving up.")
    }
    if report.counts.values.min()! < 10 { print("With under 10 taps per spot, treat this as a rough estimate.") }
    return true
}

/// Repeatable random numbers for the self-test.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Synthetic checks for clip cutting, WAV files, spot scoring and live guessing. Says nothing about real desks.
func selfTestTapLab() {
    let rate = 48_000.0
    var cutter = TapCutter(rate: rate, channels: 2)
    var clips: [TapClip] = []
    for block in 0..<Int(4.5 * rate) / 480 {
        let samples = (0..<480).map { i -> Float in (192_000..<192_480).contains(block * 480 + i) ? 0.2 : 0.001 }
        clips += cutter.feed([samples, samples])
    }
    precondition(clips.count == 1 && clips[0].channels.count == 2)
    let loud = clips[0].channels[0].firstIndex { $0 > 0.1 } ?? -1
    precondition(clips[0].channels[0].count == Int((TapCutter.before + TapCutter.after) * rate))
    precondition((Int(0.01 * rate)..<Int(0.02 * rate)).contains(loud))

    let url = FileManager.default.temporaryDirectory.appendingPathComponent("touchwood-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try! WAV.write(clips[0], to: url)
    let back = try! WAV.read(url)
    precondition(back.rate == rate && back.channels == clips[0].channels)

    // A tap rings at its spot's pitch and dies away; force and room noise vary.
    var random = SplitMix(state: 7)
    func tap(_ pitch: Double, _ decay: Double, force: ClosedRange<Double> = 0.05...0.5) -> (shape: [Double], peak: Double) {
        let strength = Double.random(in: force, using: &random)
        let ring = pitch * Double.random(in: 0.95...1.05, using: &random)
        let x = (0..<Int(0.15 * rate)).map { i -> Float in
            let t = Double(i) / rate - 0.02
            let sound = t < 0 ? 0 : strength * exp(-t / decay) * sin(2 * .pi * ring * t)
            return Float(sound + Double.random(in: -0.002...0.002, using: &random))
        }
        return (soundShape(x, rate: rate), peakLevel(x))
    }
    func taps(_ spots: [(label: String, pitch: Double, decay: Double, force: ClosedRange<Double>)], each: Int) -> [(label: String, shape: [Double], peak: Double)] {
        (0..<each).flatMap { _ in spots.map { spot in
            let sound = tap(spot.pitch, spot.decay, force: spot.force)
            return (label: spot.label, shape: sound.shape, peak: sound.peak)
        } }
    }
    let apart = [(label: "a", pitch: 700.0, decay: 0.008, force: 0.05...0.5), (label: "b", pitch: 2400.0, decay: 0.004, force: 0.05...0.5)]
    precondition(SpotReport(taps(apart, each: 12))?.verdict == .clear)
    precondition(SpotReport(taps([apart[0], (label: "b", pitch: 700, decay: 0.008, force: 0.05...0.5)], each: 12))?.verdict == .notSeparable)
    precondition(SpotReport(taps([(label: "a", pitch: 700, decay: 0.008, force: 0.3...0.5), (label: "b", pitch: 700, decay: 0.008, force: 0.03...0.08)], each: 12))?.verdict == .unclear)

    // Taught spots are recognized live, and a sound unlike any of them is turned away.
    let taught = taps(apart, each: 10).map { (label: $0.label, features: $0.shape) }
    let model = SpotModel(taught)
    precondition((0..<5).allSatisfy { _ in model.guess(tap(700, 0.008).shape) == .button("a") && model.guess(tap(2400, 0.004).shape) == .button("b") })
    precondition(model.guess(tap(6000, 0.03).shape) == .notButton)
    // A longer ring at a's pitch passes for a, until it is taught as everyday noise.
    let ringing = (0..<20).map { _ in tap(700, 0.012).shape }
    let typing = SpotModel(taught, noise: (0..<10).map { _ in tap(700, 0.012).shape })
    precondition(ringing.filter { model.guess($0) == .button("a") }.count >= 15)
    precondition(ringing.filter { typing.guess($0) == .notButton }.count >= 12)
    precondition((0..<20).filter { _ in typing.guess(tap(700, 0.008).shape) == .button("a") }.count >= 12)

    var presser = Presser(double: true)
    precondition(presser.feed(.button("a"), at: 1) == nil && presser.feed(.button("a"), at: 1.25) == "a")
    precondition(presser.feed(.button("a"), at: 3) == nil && presser.feed(.button("b"), at: 3.25) == nil && presser.feed(.button("b"), at: 3.9) == nil)
    precondition(presser.feed(.unsure, at: 4) == nil && presser.armed == nil)
    var single = Presser(double: false)
    precondition(single.feed(.button("b"), at: 1) == "b" && single.feed(.notButton, at: 2) == nil)
}
