import Foundation
import CoreGraphics
import IOKit

// Private IOAVService signatures checked against waydabber/AppleSiliconDDC.
@_silgen_name("IOAVServiceCreateWithService")
private func createAVService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceWriteI2C")
private func avWrite(_ service: CFTypeRef, _ chip: UInt32, _ address: UInt32,
                     _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> IOReturn
@_silgen_name("IOAVServiceReadI2C")
private func avRead(_ service: CFTypeRef, _ chip: UInt32, _ address: UInt32,
                    _ bytes: UnsafeMutableRawPointer, _ count: UInt32) -> IOReturn

enum DisplayError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let text): return text }
    }
}

struct TargetDisplay {
    let id: CGDirectDisplayID
    let bounds: CGRect

    static func connected() -> TargetDisplay? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return nil }
        let matches = ids.prefix(Int(count)).filter {
            CGDisplayVendorNumber($0) == 19501 && CGDisplayModelNumber($0) == 29044
        }
        guard matches.count == 1, let id = matches.first else { return nil }
        return TargetDisplay(id: id, bounds: CGDisplayBounds(id))
    }
}

final class DisplayDDC {
    private func withService<T>(_ action: (CFTypeRef) throws -> T) throws -> T {
        guard TargetDisplay.connected() != nil else {
            throw DisplayError.unavailable("未找到三星 LS27A600U")
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            throw DisplayError.unavailable("无法读取显示器控制服务")
        }
        defer { IOObjectRelease(iterator) }
        var external: [io_service_t] = []
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External" { external.append(entry) }
            else { IOObjectRelease(entry) }
        }
        defer { external.forEach { IOObjectRelease($0) } }
        guard external.count == 1 else {
            throw DisplayError.unavailable("当前需只有一块可控制的外接屏，以免调整错屏幕")
        }
        guard let service = createAVService(kCFAllocatorDefault, external[0])?.takeRetainedValue() else {
            throw DisplayError.unavailable("无法连接显示器的 DDC 服务")
        }
        return try action(service)
    }

    private func checksum(_ bytes: [UInt8], seed: UInt8) -> UInt8 {
        bytes.reduce(seed, ^)
    }

    private func queryBrightness(_ service: CFTypeRef) throws -> Int {
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, 0x10]
            request.append(checksum(request, seed: 0x3f))
            var writeOK = true
            for _ in 0..<2 {
                usleep(20_000)
                let result = request.withUnsafeMutableBytes {
                    avWrite(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
                }
                if result != 0 { writeOK = false; break }
            }
            if !writeOK { continue }
            usleep(60_000)
            var reply = [UInt8](repeating: 0, count: 11)
            let result = reply.withUnsafeMutableBytes {
                avRead(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
            }
            guard result == 0, reply[0] == 0x6e, reply[1] == 0x88,
                  reply[2] == 0x02, reply[3] == 0, reply[4] == 0x10,
                  checksum(reply, seed: 0x50) == 0 else { continue }
            let maximum = Int(reply[6]) * 256 + Int(reply[7])
            let value = Int(reply[8]) * 256 + Int(reply[9])
            guard maximum == 100, (0...100).contains(value) else { continue }
            return value
        }
        throw DisplayError.unavailable("显示器没有返回有效的亮度值")
    }

    func brightness() throws -> Int {
        try withService { try queryBrightness($0) }
    }

    // This is the only hardware-setting write in the application: VCP 0x10.
    // There are no HDR, preset, timing, input, reset or power setters.
    func setBrightness(_ value: Int) throws {
        guard (0...100).contains(value) else {
            throw DisplayError.unavailable("亮度值超出范围")
        }
        try withService { service in
            var request: [UInt8] = [0x84, 0x03, 0x10, 0, UInt8(value)]
            request.append(checksum(request, seed: 0x3f))
            for _ in 0..<2 {
                usleep(30_000)
                let result = request.withUnsafeMutableBytes {
                    avWrite(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
                }
                guard result == 0 else {
                    throw DisplayError.unavailable("亮度指令发送失败")
                }
            }
            usleep(150_000)
            guard try queryBrightness(service) == value else {
                throw DisplayError.unavailable("亮度指令尚未得到显示器确认")
            }
        }
    }
}
