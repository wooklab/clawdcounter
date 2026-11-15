// Renders the ClawdCounter app icon as a 1024x1024 PNG.
// Usage: swift scripts/make_icon.swift <output.png>
import AppKit

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon_1024.png"

let size: CGFloat = 1024
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Paper body with two bars: 5-hour (amber) over weekly (ink), mirroring the menu bar.
let bgTop = rgb(0xF6F2EA), bgBottom = rgb(0xE7E0D3)
let trackTop = rgb(0xD3CBBC), trackBottom = rgb(0xE2DBCF)
let amber = rgb(0xE39F36), ink = rgb(0x1F2731)

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

// CoreGraphics origin is bottom-left: gradients run from bottom (location 0) to top (location 1).
func fillVertical(_ path: CGPath, bottom: CGColor, top: CGColor, from y0: CGFloat, to y1: CGFloat,
                  locations: [CGFloat] = [0, 1]) {
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [bottom, top] as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
    ctx.restoreGState()
}

fillVertical(bodyPath, bottom: bgBottom, top: bgTop, from: body.minY, to: body.maxY)
// Soft top highlight fading out by the middle of the body.
fillVertical(bodyPath, bottom: rgb(0xFFFFFF, 0), top: rgb(0xFFFFFF, 0.10),
             from: body.midY, to: body.maxY)
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(rgb(0x000000, 0.07)); ctx.setLineWidth(2); ctx.strokePath()

func bar(y: CGFloat, fraction: CGFloat, color: CGColor) {
    let track = CGRect(x: 222, y: y, width: 580, height: 128)
    let trackPath = CGPath(roundedRect: track, cornerWidth: 64, cornerHeight: 64, transform: nil)
    // Recessed track: darker at the top edge.
    fillVertical(trackPath, bottom: trackBottom, top: trackTop, from: track.minY, to: track.maxY)
    ctx.addPath(trackPath); ctx.setStrokeColor(rgb(0x000000, 0.06)); ctx.setLineWidth(3); ctx.strokePath()

    let inner = track.insetBy(dx: 16, dy: 16)
    let fill = CGRect(x: inner.minX, y: inner.minY, width: inner.width * fraction, height: inner.height)
    ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 48, cornerHeight: 48, transform: nil))
    ctx.setFillColor(color); ctx.fillPath()
}

bar(y: 534, fraction: 0.74, color: amber)  // 5-hour
bar(y: 362, fraction: 0.42, color: ink)    // weekly

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
