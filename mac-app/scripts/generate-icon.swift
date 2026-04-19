#!/usr/bin/env swift
import AppKit

// Teale brand color (matching the iOS icon background)
let tealeColor = NSColor(red: 80/255, green: 150/255, blue: 130/255, alpha: 1.0)

let size = CGSize(width: 1024, height: 1024)
let cornerRadius: CGFloat = 180 // macOS icon rounded rect

let image = NSImage(size: size, flipped: false) { rect in
    // White background with rounded rect (macOS icon shape)
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.white.setFill()
    path.fill()

    // Draw the SF Symbol brain.head.profile in teal
    guard let symbol = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: nil) else {
        print("ERROR: Could not load SF Symbol")
        return false
    }

    let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .regular, scale: .large)
        .applying(NSImage.SymbolConfiguration(paletteColors: [tealeColor]))
    let configured = symbol.withSymbolConfiguration(config)!

    // Get the symbol's natural size and center it
    let symbolSize = configured.size
    let scale = min(700 / symbolSize.width, 700 / symbolSize.height)
    let drawSize = CGSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let drawOrigin = CGPoint(
        x: (size.width - drawSize.width) / 2,
        y: (size.height - drawSize.height) / 2
    )

    configured.draw(in: CGRect(origin: drawOrigin, size: drawSize))
    return true
}

// Export as PNG
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    print("ERROR: Could not create PNG")
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let url = URL(fileURLWithPath: outputPath)
try! png.write(to: url)
print("Icon written to \(outputPath)")
