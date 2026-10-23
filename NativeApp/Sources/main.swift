import AppKit
import Foundation

if CommandLine.arguments.contains("--self-test") {
    runSelfTests()
    exit(0)
}
if CommandLine.arguments.contains("--probe-ddc") || CommandLine.arguments.contains("--verify-current") {
    do {
        let ddc = DisplayDDC()
        let before = try ddc.brightness()
        if CommandLine.arguments.contains("--verify-current") { try ddc.setBrightness(before) }
        let after = try ddc.brightness()
        let report: [String: Any] = ["brightnessBefore": before, "brightnessAfter": after,
            "nativeWriteVerified": CommandLine.arguments.contains("--verify-current") && before == after]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)
        exit(0)
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}

let application = NSApplication.shared
let delegate = AutoDisplayApp()
application.delegate = delegate
// NSApplication.delegate is weak: keep the owner of timers and menu actions alive.
withExtendedLifetime(delegate) { application.run() }
