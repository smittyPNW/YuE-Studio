import AppKit

// Native typography and the Studio palette; no external artwork dependency.
let size = NSSize(width: 660, height: 460)
let image = NSImage(size: size)
image.lockFocus()
let ivory = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.89, alpha: 1)
let ink = NSColor(srgbRed: 0.14, green: 0.12, blue: 0.10, alpha: 1)
let orange = NSColor(srgbRed: 0.72, green: 0.22, blue: 0.045, alpha: 1)
ivory.setFill()
NSRect(origin: .zero, size: size).fill()

func text(_ value: String, x: CGFloat, top: CGFloat, font: NSFont, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let height = (value as NSString).size(withAttributes: attrs).height
    (value as NSString).draw(at: NSPoint(x: x, y: size.height - top - height), withAttributes: attrs)
}
text("YuE Studio", x: 36, top: 26, font: .systemFont(ofSize: 31, weight: .bold), color: ink)
text("For the love of music.", x: 37, top: 67, font: .systemFont(ofSize: 16), color: ink)
orange.setFill()
NSRect(x: 36, y: 350, width: 588, height: 2).fill()
text("Drag YuE Studio to Applications to install.", x: 36, top: 125,
     font: .systemFont(ofSize: 15, weight: .medium), color: ink)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 296, y: 250))
arrow.line(to: NSPoint(x: 358, y: 250))
arrow.move(to: NSPoint(x: 347, y: 261))
arrow.line(to: NSPoint(x: 358, y: 250))
arrow.line(to: NSPoint(x: 347, y: 239))
arrow.lineWidth = 2.5
arrow.lineCapStyle = .round
orange.setStroke()
arrow.stroke()

text("Mastering included. Song models installed separately.", x: 36, top: 425,
     font: .systemFont(ofSize: 12), color: ink)
image.unlockFocus()
guard CommandLine.arguments.count == 2,
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
