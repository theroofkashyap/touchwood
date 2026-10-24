import Foundation

// Deliberately detects a rhythm, not position. All state is owned by the audio callback.
struct Detector {
    var tapCount = 0
    var noise = 0.0001
    var elapsed = 0.0
    var aboveSince: Double?
    var lastTap = -10.0
    var firstTap: Double?
    var cooldown = 0.0
    var factor = 6.0 // how far above the room noise a burst must rise; lower is more sensitive

    mutating func feed(rms: Double, dt: Double) -> Bool {
        elapsed += dt
        if elapsed < 3 {
            noise = noise * 0.95 + rms * 0.05
            return false
        }
        let threshold = max(0.008, noise * factor)
        if rms > threshold {
            if aboveSince == nil { aboveSince = elapsed }
            return false
        }
        noise = noise * 0.995 + rms * 0.005
        guard let onset = aboveSince else { return false }
        aboveSince = nil
        let duration = elapsed - onset
        guard duration <= 0.065, onset - lastTap > 0.10 else { return false }
        tapCount += 1
        lastTap = onset
        guard onset > cooldown else { return false }
        if let first = firstTap, onset - first >= 0.14, onset - first <= 0.48 {
            firstTap = nil
            cooldown = elapsed + 1.5
            return true
        }
        firstTap = onset
        return false
    }
}

