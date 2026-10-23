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
    print("PASS: \(count) native activity/protocol checks")
}
