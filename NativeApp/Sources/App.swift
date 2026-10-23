import AppKit
import Foundation
import Security

struct BrowserPairing: Codable {
    let browser: String
    let token: String
}

final class AutoDisplayApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let ddc = DisplayDDC()
    private let hardwareQueue = DispatchQueue(label: "local.autodisplay.hardware")
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var bridge: BrowserBridge!
    private var pairings: [String: BrowserPairing] = [:]
    private var pulses: [String: BrowserPulse] = [:]
    private var pendingPair: (browser: String, expires: Date)?
    private var enabled = true
    private var dailyBrightness = 30
    private var currentBrightness: Int?
    private var movie = false
    private var applying = false
    private var prepared = false
    private var terminating = false
    private var desiredMovie = false
    private var lastCandidate = false
    private var candidateSince = Date()
    private var retryAfter = Date.distantPast
    private var hardwareError: String?
    private var bridgeError: String?
    private var signalSources: [DispatchSourceSignal] = []
    private var tickCount = 0
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("AutoDisplay menu bar starting")
        NSApp.setActivationPolicy(.accessory)
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        dailyBrightness = min(100, max(0, defaults.object(forKey: "dailyBrightness") as? Int ?? 30))
        if let data = defaults.data(forKey: "browserPairings"),
           let saved = try? JSONDecoder().decode([String: BrowserPairing].self, from: data) { pairings = saved }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "AutoDisplay")
        let extensionID = ((try? String(contentsOf: Bundle.main.url(forResource: "extension-id", withExtension: "txt")!)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        bridge = BrowserBridge(extensionID: extensionID)
        bridge.onRequest = { [weak self] request in self?.handle(request) ?? .json(["error": "正在退出"], status: 503) }
        bridge.onStatus = { [weak self] error in self?.bridgeError = error; self?.refreshMenu() }
        bridge.start()
        for signum in [SIGTERM, SIGINT] {
            signal(signum, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signum, queue: .main)
            source.setEventHandler {
                // AppKit waits in a nested run loop while terminating. Leave the
                // dispatch callback before starting that wait so main-queue work can finish.
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke),
            name: NSWorkspace.didWakeNotification, object: nil)
        refreshMenu()
        prepareHardware()
    }

    private func prepareHardware() {
        applying = true
        let recover = defaults.bool(forKey: "restorePending")
        let daily = dailyBrightness
        hardwareQueue.async {
            let result = Result { () -> Int in
                if recover { try self.ddc.setBrightness(daily); self.defaults.set(false, forKey: "restorePending") }
                return try self.ddc.brightness()
            }
            DispatchQueue.main.async {
                self.applying = false
                self.prepared = true
                switch result {
                case .success(let value): self.currentBrightness = value; self.hardwareError = nil
                case .failure(let error): self.hardwareError = error.localizedDescription; self.retryAfter = Date().addingTimeInterval(10)
                }
                self.refreshMenu()
                self.tick()
            }
        }
    }

    @objc private func woke() {
        retryAfter = .distantPast
        if !applying { prepareHardware() }
    }

    private func tick() {
        guard !terminating, prepared else { return }
        let now = Date()
        var candidate = false
        if enabled, let target = TargetDisplay.connected(),
           let app = NSWorkspace.shared.frontmostApplication {
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                candidate = desiredMovie // Do not flash while the user opens this menu.
            } else {
                candidate = VideoActivity.isMovie(frontmost: app.bundleIdentifier ?? "",
                    fullscreenOnTarget: VideoActivity.fullscreenWindow(pid: app.processIdentifier, target: target.bounds),
                    pulses: Array(pulses.values), now: now)
            }
        }
        if candidate != lastCandidate { lastCandidate = candidate; candidateSince = now }
        if now.timeIntervalSince(candidateSince) >= 0.3 || !enabled { desiredMovie = candidate }
        if !applying, now >= retryAfter,
           (desiredMovie != movie || (defaults.bool(forKey: "restorePending") && !desiredMovie)) {
            apply(movie: desiredMovie)
        }
        tickCount += 1
        if tickCount % 4 == 0 { refreshMenu() }
    }

    private func apply(movie targetMovie: Bool) {
        guard !applying, !terminating else { return }
        applying = true
        let restoreValue = dailyBrightness
        refreshMenu()
        hardwareQueue.async {
            var savedDaily = restoreValue
            let result = Result { () -> Int in
                if targetMovie {
                    // Capture the user's actual daily setting instead of always forcing 30.
                    let before = try self.ddc.brightness()
                    if !self.defaults.bool(forKey: "restorePending") {
                        savedDaily = before
                        self.defaults.set(savedDaily, forKey: "dailyBrightness")
                    }
                    self.defaults.set(true, forKey: "restorePending")
                    do { try self.ddc.setBrightness(100) }
                    catch {
                        // A failed readback may follow an applied write: attempt restoration.
                        if (try? self.ddc.setBrightness(savedDaily)) != nil {
                            self.defaults.set(false, forKey: "restorePending")
                        }
                        throw error
                    }
                    return 100
                }
                try self.ddc.setBrightness(restoreValue)
                self.defaults.set(false, forKey: "restorePending")
                return restoreValue
            }
            DispatchQueue.main.async {
                self.dailyBrightness = savedDaily
                self.applying = false
                switch result {
                case .success(let value):
                    self.movie = targetMovie
                    self.currentBrightness = value
                    self.hardwareError = nil
                    self.retryAfter = .distantPast
                case .failure(let error):
                    self.hardwareError = error.localizedDescription
                    self.retryAfter = Date().addingTimeInterval(10)
                }
                self.refreshMenu()
            }
        }
    }

    private func refreshMenu() {
        guard statusItem != nil, !menuIsOpen else { return }
        let menu = NSMenu()
        menu.delegate = self
        func line(_ title: String) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item) }
        line(applying ? "正在调整亮度…" : movie ? "观影 · 100%" : "日常 · \(currentBrightness ?? dailyBrightness)%")
        if let error = hardwareError { line(error) }
        let toggle = NSMenuItem(title: "自动调整亮度", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self; toggle.state = enabled ? .on : .off; menu.addItem(toggle)
        menu.addItem(.separator())
        line("观影亮度：100%")
        line("恢复亮度：\(dailyBrightness)%")
        let remember = NSMenuItem(title: "记住当前日常亮度", action: #selector(rememberDaily), keyEquivalent: "")
        remember.target = self; remember.isEnabled = !movie && !applying; menu.addItem(remember)
        menu.addItem(.separator())
        line("IINA：自动检测全屏窗口")
        for browser in [VideoApps.chrome, VideoApps.dia] {
            let active = pulses.values.contains { $0.browser == browser && Date().timeIntervalSince($0.receivedAt) < 6 }
            let paired = pairings.values.contains { $0.browser == browser }
            line("\(VideoApps.name(browser))：\(active ? "已连接" : paired ? "等待网页视频信号" : "未连接扩展")")
            let connect = NSMenuItem(title: "连接 \(VideoApps.name(browser))…", action: #selector(connectBrowser(_:)), keyEquivalent: "")
            connect.target = self; connect.representedObject = browser; menu.addItem(connect)
        }
        if let error = bridgeError { line(error) }
        let folder = NSMenuItem(title: "浏览器扩展文件夹…", action: #selector(showExtension), keyEquivalent: "")
        folder.target = self; menu.addItem(folder)
        let help = NSMenuItem(title: "使用说明…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self; menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出并恢复日常亮度", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.toolTip = "AutoDisplay · \(movie ? "观影亮度" : "日常亮度")"
        statusItem.button?.image = NSImage(systemSymbolName: hardwareError == nil ? (movie ? "sun.max.fill" : "sun.max") : "sun.max.trianglebadge.exclamationmark", accessibilityDescription: "AutoDisplay")
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        guard !movie, !applying else { return }
        hardwareQueue.async {
            guard let value = try? self.ddc.brightness() else { return }
            DispatchQueue.main.async { self.currentBrightness = value }
        }
    }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false; refreshMenu() }

    @objc private func toggleEnabled() {
        enabled.toggle(); defaults.set(enabled, forKey: "enabled")
        retryAfter = .distantPast; tick(); refreshMenu()
    }

    @objc private func rememberDaily() {
        guard !movie, !applying else { return }
        hardwareQueue.async {
            let result = Result { try self.ddc.brightness() }
            DispatchQueue.main.async {
                switch result {
                case .success(let value):
                    self.dailyBrightness = value; self.currentBrightness = value
                    self.defaults.set(value, forKey: "dailyBrightness")
                case .failure(let error): self.hardwareError = error.localizedDescription
                }
                self.refreshMenu()
            }
        }
    }

    @objc private func connectBrowser(_ sender: NSMenuItem) {
        guard let browser = sender.representedObject as? String,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser), bridgeError == nil else { return }
        pendingPair = (browser, Date().addingTimeInterval(90))
        let name = browser == VideoApps.chrome ? "chrome" : "dia"
        let url = URL(string: "http://127.0.0.1:\(BrowserBridge.port)/pair?browser=\(name)")!
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    @objc private func showExtension() {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("BrowserExtension") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func showHelp() {
        if let url = Bundle.main.url(forResource: "使用说明", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        if request.method == "GET", request.path == "/health" {
            return .json(["app": "AutoDisplay", "enabled": enabled, "ready": prepared,
                          "movie": movie, "applying": applying,
                          "brightness": currentBrightness ?? -1, "dailyBrightness": dailyBrightness,
                          "displayConnected": TargetDisplay.connected() != nil,
                          "hardwareError": hardwareError ?? "", "bridgeError": bridgeError ?? ""])
        }
        if request.method == "GET", request.path == "/pair" {
            return HTTPResponse(status: 200, body: Data(BrowserBridge.pairingHTML.utf8), contentType: "text/html; charset=utf-8")
        }
        guard request.method == "POST", bridge.isExtensionRequest(request),
              let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return .json(["error": "请求未被授权"], status: 403)
        }
        if request.path == "/pair" {
            guard let pending = pendingPair, pending.expires > Date(),
                  let browser = body["browser"] as? String, browser == pending.browser,
                  let client = body["client"] as? String, UUID(uuidString: client) != nil else {
                return .json(["error": "请先从 AutoDisplay 菜单选择连接当前浏览器"], status: 409)
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                return .json(["error": "无法生成连接凭据"], status: 503)
            }
            let token = Data(bytes).base64EncodedString()
            pairings[client] = BrowserPairing(browser: browser, token: token)
            defaults.set(try? JSONEncoder().encode(pairings), forKey: "browserPairings")
            pendingPair = nil; refreshMenu()
            return .json(["token": token, "browser": browser])
        }
        guard request.path == "/state",
              let client = request.headers["x-autodisplay-client"],
              let pairing = pairings[client], request.headers["x-autodisplay-token"] == pairing.token else {
            return .json(["error": "请重新连接此浏览器"], status: 401)
        }
        guard let fullscreen = body["fullscreenVideo"] as? Bool,
              let viewport = body["viewportVideo"] as? Bool else { return .json(["error": "状态格式错误"], status: 400) }
        pulses[client] = BrowserPulse(browser: pairing.browser, fullscreenVideo: fullscreen,
                                      viewportVideo: viewport, receivedAt: Date())
        tick()
        return .json(["ok": true])
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true; timer?.invalidate(); bridge.stop()
        // The serial queue also waits for an in-flight movie write before restoring.
        hardwareQueue.async {
            var failure: Error?
            if self.defaults.bool(forKey: "restorePending") {
                let restoreValue = self.defaults.object(forKey: "dailyBrightness") as? Int ?? 30
                do { try self.ddc.setBrightness(restoreValue); self.defaults.set(false, forKey: "restorePending") }
                catch { failure = error }
            }
            // This must also run in AppKit's modal termination loop.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                if let failure = failure {
                    let alert = NSAlert()
                    alert.messageText = "显示器未确认恢复日常亮度"
                    alert.informativeText = failure.localizedDescription + "。原值已保留，重新打开 AutoDisplay 时会再尝试恢复。"
                    alert.addButton(withTitle: "退出")
                    alert.runModal()
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
