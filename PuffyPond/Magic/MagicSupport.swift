import Foundation
import Metal

/// Magic needs a fast GPU and plenty of memory, so it is only offered on capable devices.
enum MagicSupport {
    static let minimumMemory: UInt64 = 8 * 1024 * 1024 * 1024

    static var isSupported: Bool {
        #if arch(x86_64)
        return false                                   // Apple silicon only
        #else
        #if os(iOS)
        guard ProcessInfo.processInfo.physicalMemory >= minimumMemory else { return false }
        #endif
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)          // M1 or newer
        #endif
    }
}
