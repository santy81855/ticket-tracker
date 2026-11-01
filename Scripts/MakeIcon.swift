import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Pass the iconset output directory.") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    guard let graphics = NSGraphicsContext.current else {
      fatalError("Cannot create icon graphics context.")
    }
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let rectangle = NSRect(x: 70, y: 70, width: 884, height: 884)
    let shape = NSBezierPath(roundedRect: rectangle, xRadius: 205, yRadius: 205)
    guard
      let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.47, green: 0.40, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.25, green: 0.30, blue: 0.74, alpha: 1))
    else {
      fatalError("Cannot create icon gradient.")
    }
    gradient.draw(in: shape, angle: -45)
    NSColor.white.withAlphaComponent(0.13).setFill()
    NSBezierPath(ovalIn: NSRect(x: 430, y: 560, width: 600, height: 600)).fill()
    let ticket = NSBezierPath(
      roundedRect: NSRect(x: 270, y: 315, width: 484, height: 395), xRadius: 65, yRadius: 65)
    NSColor.white.withAlphaComponent(0.96).setFill()
    ticket.fill()
    NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.87, alpha: 1).setStroke()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 360, y: 512))
    check.line(to: NSPoint(x: 460, y: 420))
    check.line(to: NSPoint(x: 655, y: 605))
    check.lineWidth = 47
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { fatalError("Cannot render app icon.") }
    let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    try png.write(to: directory.appendingPathComponent(name))
  }
}
