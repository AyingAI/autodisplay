import Foundation
import CoreGraphics

enum VideoApps {
    static let iina = "com.colliderli.iina"
    static let chrome = "com.google.Chrome"
    static let dia = "company.thebrowser.dia"
    static let browsers: Set<String> = [chrome, dia]
    static func name(_ bundleID: String) -> String {
        switch bundleID {
        case iina: return "IINA"
        case chrome: return "Chrome"
        case dia: return "Dia"
        default: return bundleID
        }
    }
}

struct BrowserPulse {
    let browser: String
    let fullscreenVideo: Bool
    let viewportVideo: Bool
    let receivedAt: Date
}

enum VideoActivity {
    static func isMovie(frontmost: String, fullscreenOnTarget: Bool,
                        pulses: [BrowserPulse], now: Date) -> Bool {
        guard fullscreenOnTarget else { return false }
        if frontmost == VideoApps.iina { return true }
        guard VideoApps.browsers.contains(frontmost) else { return false }
        return pulses.contains {
            $0.browser == frontmost && now.timeIntervalSince($0.receivedAt) >= 0 &&
            now.timeIntervalSince($0.receivedAt) < 6 &&
            ($0.fullscreenVideo || $0.viewportVideo)
        }
    }

    static func fullscreenWindow(pid: pid_t, target: CGRect) -> Bool {
        guard target.width > 0 && target.height > 0,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
            return abs(bounds.minX - target.minX) <= 6 && abs(bounds.minY - target.minY) <= 6 &&
                   abs(bounds.width - target.width) <= 12 && abs(bounds.height - target.height) <= 12
        }
    }
}
