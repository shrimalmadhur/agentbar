// Draws AppIcon.icns. Run from the repo root: swift icon/make-icon.swift
// Follows Apple's macOS icon grid: an 824-point rounded square, centered on a
// 1024-point canvas, with a drop shadow.
import AppKit
import SwiftUI

struct Tile: View {
    let colors: [Color]
    var body: some View {
        RoundedRectangle(cornerRadius: 64, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: 64, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 3))
            .frame(width: 250, height: 250)
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.17, blue: 0.27),
                                              Color(red: 0.07, green: 0.07, blue: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 4))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
            VStack(spacing: 44) {
                HStack(spacing: 44) {
                    Tile(colors: [Color(red: 0.96, green: 0.58, blue: 0.43), Color(red: 0.80, green: 0.40, blue: 0.28)])
                    Tile(colors: [Color(red: 0.45, green: 0.70, blue: 1.00), Color(red: 0.22, green: 0.46, blue: 0.94)])
                }
                HStack(spacing: 44) {
                    Tile(colors: [Color(red: 0.36, green: 0.88, blue: 0.64), Color(red: 0.13, green: 0.64, blue: 0.45)])
                    Tile(colors: [Color(red: 1.00, green: 0.78, blue: 0.35), Color(red: 0.96, green: 0.55, blue: 0.18)])
                        .overlay(alignment: .topTrailing) {
                            // The "needs you" tile carries a notification dot.
                            Circle().fill(.white).frame(width: 74, height: 74)
                                .overlay(Circle().fill(Color(red: 0.95, green: 0.30, blue: 0.28)).padding(12))
                                .offset(x: 22, y: -22)
                                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        }
                }
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func make() throws {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let cg = r.cgImage else { throw CocoaError(.fileWriteUnknown) }
    let set = URL(fileURLWithPath: "icon/AppIcon.iconset")
    try? FileManager.default.removeItem(at: set)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: cg, size: NSSize(width: 1024, height: 1024))
                .draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
        }
    }
}

try MainActor.assumeIsolated { try make() }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", "icon/AppIcon.iconset", "-o", "icon/AppIcon.icns"]
try p.run()
p.waitUntilExit()
try FileManager.default.removeItem(atPath: "icon/AppIcon.iconset")
print("wrote icon/AppIcon.icns")
