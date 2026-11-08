// Renders the ClawdCounter app icon as a 1024x1024 PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon_1024.png"

let size: CGFloat = 1024
func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Background matches the Claude desktop app icon (top -> bottom).
let bgTop = rgb(0xD97656), bgBottom = rgb(0xDB6945)
let green = rgb(0x34C759), yellow = rgb(0xFFCC00), orange = rgb(0xFF9500), red = rgb(0xFF3B30)
let cream = rgb(0xFAF6F0)

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt body centered on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(bodyPath); ctx.setFillColor(bgBottom); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [bgBottom, bgTop] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY), options: [])
ctx.restoreGState()

let cx: CGFloat = 512, cy: CGFloat = 512

// Eyes (CoreGraphics origin is bottom-left): active = filled green, idle = empty ring.
let eyeR: CGFloat = 62, eyeY = cy + 95, eyeDX: CGFloat = 125
ctx.addEllipse(in: CGRect(x: cx - eyeDX - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2))
ctx.setFillColor(green); ctx.fillPath()

let ringW: CGFloat = 22
let rr = eyeR - ringW / 2
ctx.addEllipse(in: CGRect(x: cx + eyeDX - rr, y: eyeY - rr, width: rr * 2, height: rr * 2))
ctx.setStrokeColor(cream); ctx.setLineWidth(ringW); ctx.strokePath()

// Smile: arc stroked, then filled with a left-to-right gradient.
let smile = CGMutablePath()
smile.addArc(center: CGPoint(x: cx, y: cy + 40), radius: 215,
             startAngle: .pi * 1.18, endAngle: .pi * 1.82, clockwise: false)
let stroked = smile.copy(strokingWithWidth: 58, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.saveGState()
ctx.addPath(stroked); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [green, yellow, orange, red] as CFArray,
                      locations: [0, 0.35, 0.65, 1])!
let box = stroked.boundingBox
ctx.drawLinearGradient(grad, start: CGPoint(x: box.minX, y: 0), end: CGPoint(x: box.maxX, y: 0), options: [])
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
