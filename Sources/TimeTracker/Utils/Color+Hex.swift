import SwiftUI
import AppKit

extension Color {
    /// Parse a 6-character hex string (RRGGBB) into a SwiftUI Color. Returns nil on
    /// bad input or missing string.
    init?(hex: String?) {
        guard let hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    /// RRGGBB uppercase — suitable for SwiftData persistence.
    var hexString: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}

/// A hash that is the same on every launch, for deriving colours from names.
enum StableHash {
    /// 64-bit FNV-1a over the UTF-8 bytes.
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// A value in 0..<1, e.g. a hue.
    static func unitInterval(_ s: String) -> Double {
        Double(fnv1a(s) % 360) / 360
    }
}
