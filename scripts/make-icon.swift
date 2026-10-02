// Renders a simple hand icon into AppIcon.icns. Run with: swift scripts/make-icon.swift
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let tmp = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let bg = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(size) * 0.05, dy: CGFloat(size) * 0.05),
                          xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22)
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.20, alpha: 1).setFill()
    bg.fill()
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.55, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor(calibratedRed: 0.55, green: 0.85, blue: 1.0, alpha: 1).set()
            r.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: (rect.width - tinted.size.width) / 2, y: (rect.height - tinted.size.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    image.unlockFocus()
    return image
}

for size in sizes {
    for scale in [1, 2] where size * scale <= 1024 {
        let px = size * scale
        let image = render(px)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! png.write(to: tmp.appendingPathComponent(name))
    }
}

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"]
task.launch()
task.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print("Wrote AppIcon.icns")
