import Foundation

func runSelfTests() {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        count += 1
    }
    let now = Date()
    let chrome = BrowserPulse(browser: VideoApps.chrome, fullscreenVideo: true, viewportVideo: false, receivedAt: now)
    check(VideoActivity.isMovie(frontmost: VideoApps.iina, fullscreenOnTarget: true, pulses: [], now: now), "IINA fullscreen")
    check(!VideoActivity.isMovie(frontmost: VideoApps.iina, fullscreenOnTarget: false, pulses: [], now: now), "IINA windowed")
    check(!VideoActivity.isMovie(frontmost: VideoApps.chrome, fullscreenOnTarget: true, pulses: [], now: now), "browser fullscreen alone")
    check(VideoActivity.isMovie(frontmost: VideoApps.chrome, fullscreenOnTarget: true, pulses: [chrome], now: now), "browser fullscreen video")
    check(!VideoActivity.isMovie(frontmost: VideoApps.chrome, fullscreenOnTarget: false, pulses: [chrome], now: now), "video on another display")
    check(!VideoActivity.isMovie(frontmost: VideoApps.dia, fullscreenOnTarget: true, pulses: [chrome], now: now), "browser identity separation")
    check(!VideoActivity.isMovie(frontmost: VideoApps.chrome, fullscreenOnTarget: true, pulses: [chrome], now: now.addingTimeInterval(7)), "stale signal restores daily")
    check(!VideoActivity.isMovie(frontmost: "com.apple.finder", fullscreenOnTarget: true, pulses: [chrome], now: now), "leaving video app")
    let request = Data("GET /pair?browser=chrome HTTP/1.1\r\nHost: 127.0.0.1:48741\r\n\r\n".utf8)
    if case .request(let parsed) = HTTPParser.parse(request) { check(parsed.path == "/pair", "HTTP path") }
    else { check(false, "valid request rejected") }
    if case .incomplete = HTTPParser.parse(Data("POST /state HTTP/1.1\r\nHost: 127.0.0.1:48741\r\nContent-Length: 10\r\n\r\n{}".utf8)) { count += 1 }
    else { check(false, "partial request") }
    for bad in [
        "POST /state HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
        "POST /state HTTP/1.1\r\nHost: 127.0.0.1:48741\r\nContent-Length: 100000\r\n\r\n",
        "POST /state HTTP/1.1\r\nHost: 127.0.0.1:48741\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
        "POST /state HTTP/1.1\r\nHost: 127.0.0.1:48741\r\nTransfer-Encoding: chunked\r\n\r\n"
    ] {
        if case .invalid = HTTPParser.parse(Data(bad.utf8)) { count += 1 }
        else { check(false, "malformed HTTP must be rejected") }
    }
    let bridge = BrowserBridge(extensionID: "test-extension")
    check(!bridge.isExtensionRequest(HTTPRequest(method: "POST", path: "/pair", headers: ["x-autodisplay-extension": "test-extension", "origin": "https://attacker.example"], body: Data())), "web origin cannot pair")
    check(bridge.isExtensionRequest(HTTPRequest(method: "POST", path: "/pair", headers: ["x-autodisplay-extension": "test-extension", "origin": "chrome-extension://test-extension"], body: Data())), "extension origin")
    runBrightnessSelfTests { check($0, $1) }
    print("PASS: \(count) native activity/protocol/brightness checks")
}

private final class MemoryBrightnessDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
}

private final class TestBrightnessHardware: BrightnessHardware {
    var value = 30
    var readFailures = 0
    var writeFailures = 0
    var writes: [Int] = []

    func brightness() throws -> Int {
        if readFailures > 0 {
            readFailures -= 1
            throw DisplayError.unavailable("display waking")
        }
        return value
    }

    func setBrightness(_ value: Int) throws {
        writes.append(value)
        self.value = value
        // Model an applied write whose readback could not be confirmed.
        if writeFailures > 0 {
            writeFailures -= 1
            throw DisplayError.unavailable("readback unavailable")
        }
    }
}

private func runBrightnessSelfTests(check: (Bool, String) -> Void) {
    let defaults = MemoryBrightnessDefaults(suiteName: "local.autodisplay.self-test")!
    let display = TestBrightnessHardware()
    let brightness = BrightnessController(display: display, defaults: defaults)
    var automation = BrightnessAutomation()

    check((try? brightness.prepare()) == 30 && display.writes.isEmpty, "startup reads idle brightness without writing")
    automation.recovered(generation: automation.generation)
    check((try? brightness.applyMovie(true)) == 100 && brightness.dailyBrightness == 30 && brightness.restorePending,
          "movie saves daily brightness and arms recovery")

    automation.sleep()
    check(automation.nextAction(desiredMovie: false, movie: true, restorePending: true) == nil,
          "display sleep suspends automatic hardware writes")
    automation.wake()
    check(automation.nextAction(desiredMovie: true, movie: true, restorePending: true) == .recover,
          "display-only wake recovers even with unchanged fullscreen state")
    display.writeFailures = 1
    check((try? brightness.prepare(forceRestore: automation.restoringAfterWake)) == nil && brightness.restorePending,
          "failed wake restore retains recovery marker")
    check(automation.nextAction(desiredMovie: true, movie: true, restorePending: brightness.restorePending) == .recover,
          "failed wake restore retries while video remains fullscreen")
    check((try? brightness.prepare(forceRestore: automation.restoringAfterWake)) == 30 && !brightness.restorePending,
          "successful wake restore confirms daily value before clearing marker")
    automation.recovered(generation: automation.generation)
    check(automation.nextAction(desiredMovie: true, movie: false, restorePending: false) == .movie(true),
          "fullscreen is reapplied after baseline recovery")
    check((try? brightness.applyMovie(true)) == 100 && brightness.dailyBrightness == 30,
          "post-wake fullscreen preserves original daily value")
    check((try? brightness.applyMovie(false)) == 30 && display.value == 30 && !brightness.restorePending,
          "leaving fullscreen after sleep restores daily brightness")

    // A completed write from before sleep must not consume the new recovery.
    let oldGeneration = automation.generation
    automation.sleep()
    automation.wake()
    automation.recovered(generation: oldGeneration)
    check(automation.needsRecovery, "wake during an in-flight operation is retained")
    // A monitor may wake at 100 even after an earlier restoration succeeded.
    display.value = 100
    display.writeFailures = 1
    check((try? brightness.prepare(forceRestore: automation.restoringAfterWake)) == nil && brightness.restorePending,
          "failed forced wake restore re-arms recovery even after an old write cleared it")
    check((try? brightness.prepare(forceRestore: automation.restoringAfterWake)) == 30 && brightness.dailyBrightness == 30,
          "wake reapplies daily brightness even if an old write cleared the marker")
    automation.recovered(generation: automation.generation)

    _ = try? brightness.applyMovie(true)
    automation.takeManualControl()
    check((try? brightness.setManualBrightness(42)) == 42 && brightness.dailyBrightness == 42 && !brightness.restorePending,
          "manual adjustment during fullscreen becomes the daily value")
    check(automation.nextAction(desiredMovie: true, movie: false, restorePending: false) == nil,
          "manual brightness is not immediately overridden by fullscreen")
    automation.updateCandidate(false)
    check(automation.nextAction(desiredMovie: true, movie: false, restorePending: false) == .movie(true),
          "automatic brightness resumes for the next fullscreen session")

    automation.takeManualControl()
    display.writeFailures = 1
    check((try? brightness.setManualBrightness(25)) == nil && brightness.dailyBrightness == 25 && brightness.restorePending,
          "failed manual write retains chosen brightness for retry")
    check(automation.nextAction(desiredMovie: true, movie: false, restorePending: true) == .movie(false),
          "failed manual adjustment retries the chosen value instead of movie brightness")
    check((try? brightness.applyMovie(false)) == 25 && display.value == 25 && !brightness.restorePending,
          "manual adjustment recovers after temporary DDC failure")
    check((try? brightness.setManualBrightness(-1)) == nil && brightness.dailyBrightness == 25,
          "invalid manual brightness cannot overwrite recovery value")
    check((try? brightness.setManualBrightness(0)) == 0 && (try? brightness.setManualBrightness(100)) == 100,
          "manual brightness supports both endpoints")

    _ = try? brightness.setManualBrightness(30)
    display.writeFailures = 2
    check((try? brightness.applyMovie(true)) == nil && brightness.restorePending && brightness.dailyBrightness == 30,
          "failed movie write and rollback retain daily recovery")
    display.value = 100
    check((try? brightness.rememberDaily()) == nil && brightness.dailyBrightness == 30,
          "outstanding movie brightness cannot be remembered as daily")
    check((try? brightness.applyMovie(true)) == 100 && brightness.dailyBrightness == 30,
          "movie retry does not capture outstanding 100 as daily")
    let restarted = BrightnessController(display: display, defaults: defaults)
    check((try? restarted.prepare()) == 30 && display.value == 30 && !restarted.restorePending,
          "restart restores brightness from saved recovery marker")

    display.readFailures = 1
    automation.wake()
    check((try? restarted.prepare(forceRestore: automation.restoringAfterWake)) == 30,
          "wake restores directly without depending on an initial brightness read")
}
