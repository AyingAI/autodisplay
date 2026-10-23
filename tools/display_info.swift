// Read-only display model information. Omit serial numbers and UUIDs.
import Foundation
import CoreGraphics

var ids = [CGDirectDisplayID](repeating: 0, count: 32)
var count: UInt32 = 0
guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
    fputs("Cannot enumerate online displays\n", stderr)
    exit(1)
}
let displays: [[String: Any]] = ids.prefix(Int(count)).map { id in
    let bounds = CGDisplayBounds(id)
    return ["builtIn": CGDisplayIsBuiltin(id) != 0,
            "vendor": CGDisplayVendorNumber(id), "model": CGDisplayModelNumber(id),
            "width": Int(bounds.width), "height": Int(bounds.height)]
}
let data = try JSONSerialization.data(withJSONObject: displays, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
