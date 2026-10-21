import SwiftUI
import AppKit

/// Colours modelled on the Dreamehome app, with dark-mode counterparts.
enum Theme {
    static let backgroundTop = dynamic(0xF4EADF, 0x2B2622)
    static let backgroundBottom = dynamic(0xF6F6F7, 0x161617)
    static let card = dynamic(0xFFFFFF, 0x232325)
    static let secondary = dynamic(0x9B9BA0, 0x8E8E93)
    static let segmentTrack = dynamic(0xE9E9EC, 0x2E2E31)
    static let segmentThumb = dynamic(0xFFFFFF, 0x48484C)
    static let accent = Color(hex: 0x3F7CF6)
    static let accentDeep = Color(hex: 0x2B61E8)
    static let charge = Color(hex: 0x3CC46B)
    static let chip = Color(white: 0.36).opacity(0.88)

    /// Room fills: yellow, blue, light blue, green.
    static let roomRGB: [(UInt8, UInt8, UInt8)] = [(0xF6, 0xDB, 0x7F), (0xA9, 0xC2, 0xF5), (0xB8, 0xDC, 0xF7), (0xBA, 0xD9, 0x90)]
    static func dimmedRGB(dark: Bool) -> (UInt8, UInt8, UInt8) { dark ? (0x3C, 0x3C, 0x40) : (0xE4, 0xE4, 0xE6) }
    static func floorRGB(dark: Bool) -> (UInt8, UInt8, UInt8) { dark ? (0x44, 0x44, 0x48) : (0xE9, 0xE9, 0xEB) }
    static let wallRGB: (UInt8, UInt8, UInt8) = (0x8C, 0x8C, 0x92)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension VacuumMap {
    /// Renders one pixel per map cell; the view scales it up without smoothing for the app's blocky look.
    func image(selected: Set<Int>, dimUnselected: Bool, dark: Bool) -> CGImage? {
        let colorByRoom = Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, $0.colorIndex) })
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = cells[i]
            let rgb: (UInt8, UInt8, UInt8)
            switch v {
            case VacuumMap.outside: continue
            case VacuumMap.wall: rgb = Theme.wallRGB
            case VacuumMap.floor: rgb = Theme.floorRGB(dark: dark)
            default:
                let id = Int(v)
                rgb = dimUnselected && !selected.contains(id) ? Theme.dimmedRGB(dark: dark) : Theme.roomRGB[(colorByRoom[id] ?? id) % 4]
            }
            pixels[i * 4] = rgb.0
            pixels[i * 4 + 1] = rgb.1
            pixels[i * 4 + 2] = rgb.2
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
