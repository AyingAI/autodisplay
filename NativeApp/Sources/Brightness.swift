import Foundation

protocol BrightnessHardware {
    func brightness() throws -> Int
    func setBrightness(_ value: Int) throws
}

extension DisplayDDC: BrightnessHardware {}

// All hardware operations run on the app's serial hardware queue. Keep the
// recovery marker until a write has been confirmed, including across sleep.
final class BrightnessController {
    private let display: BrightnessHardware
    private let defaults: UserDefaults

    init(display: BrightnessHardware, defaults: UserDefaults) {
        self.display = display
        self.defaults = defaults
    }

    var dailyBrightness: Int {
        min(100, max(0, defaults.object(forKey: "dailyBrightness") as? Int ?? 30))
    }

    var restorePending: Bool { defaults.bool(forKey: "restorePending") }

    func prepare(forceRestore: Bool = false) throws -> Int {
        if restorePending || forceRestore { return try restoreDaily() }
        return try display.brightness()
    }

    func applyMovie(_ movie: Bool) throws -> Int {
        guard movie else { return try restoreDaily() }
        // Never mistake an outstanding movie brightness for a new daily value.
        if !restorePending {
            defaults.set(try display.brightness(), forKey: "dailyBrightness")
        }
        defaults.set(true, forKey: "restorePending")
        do { try display.setBrightness(100) }
        catch {
            // A failed readback can follow a successful write.
            _ = try? restoreDaily()
            throw error
        }
        return 100
    }

    private func restoreDaily() throws -> Int {
        let value = dailyBrightness
        defaults.set(true, forKey: "restorePending")
        try display.setBrightness(value)
        defaults.set(false, forKey: "restorePending")
        return value
    }

    func setManualBrightness(_ value: Int) throws -> Int {
        guard (0...100).contains(value) else {
            throw DisplayError.unavailable("亮度值超出范围")
        }
        // A manual choice becomes the new daily value, even if the monitor is
        // temporarily unavailable: subsequent retries must keep this choice.
        defaults.set(value, forKey: "dailyBrightness")
        defaults.set(true, forKey: "restorePending")
        return try restoreDaily()
    }

    func rememberDaily() throws -> Int {
        guard !restorePending else {
            throw DisplayError.unavailable("请先恢复日常亮度，再记住当前值")
        }
        let value = try display.brightness()
        defaults.set(value, forKey: "dailyBrightness")
        return value
    }

    func currentBrightness() throws -> Int { try display.brightness() }
}

struct BrightnessAutomation {
    enum Action: Equatable { case recover, movie(Bool) }

    private(set) var suspended = false
    private(set) var needsRecovery = true
    private(set) var restoringAfterWake = false
    private(set) var generation = 0
    private(set) var manualOverride = false

    mutating func sleep() {
        suspended = true
        needsRecovery = true
        restoringAfterWake = true
        generation += 1
    }

    mutating func wake() {
        suspended = false
        needsRecovery = true
        restoringAfterWake = true
        generation += 1
    }

    mutating func recovered(generation completedGeneration: Int) {
        // A wake notification during an in-flight operation must not be lost.
        if completedGeneration == generation {
            needsRecovery = false
            restoringAfterWake = false
        }
    }

    mutating func takeManualControl() { manualOverride = true }
    mutating func resumeAutomaticControl() { manualOverride = false }
    mutating func updateCandidate(_ candidate: Bool) {
        if !candidate { manualOverride = false }
    }

    func nextAction(desiredMovie: Bool, movie: Bool, restorePending: Bool) -> Action? {
        guard !suspended else { return nil }
        // Restore before considering fullscreen, even if the old movie flag
        // still matches. Failed recovery stays here until the monitor responds.
        if needsRecovery { return .recover }
        let target = desiredMovie && !manualOverride
        if target != movie || (restorePending && !target) { return .movie(target) }
        return nil
    }
}
