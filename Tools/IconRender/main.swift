// Draws the BendyLocal app icon at 1024x1024 and writes it as a PNG.
// Standalone Core Graphics — no Xcode asset catalog tooling needed, matching
// the rest of this project's "Command Line Tools only" build constraint.
//
// The glyph is a "folded card": two panels pinched together at a vertical
// crease, evoking the fold effect itself rather than a literal laptop. It
// reuses the exact brand gradient from the Settings preview pane
// (UI/SettingsView.swift's LidPreview) so the icon and the in-app preview
// read as the same product.

import AppKit
import CoreGraphics

let size = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("could not create bitmap context") }

let s = CGFloat(size)
let full = CGRect(x: 0, y: 0, width: s, height: s)

func gradient(_ stops: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> CGGradient {
    let colors = stops.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: $0.3) } as CFArray
    let locations = stops.enumerated().map { CGFloat($0.offset) / CGFloat(stops.count - 1) }
    return CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
}

// MARK: Background — near-black, faintly warmer at the bottom so it doesn't
// read as flat.
let bg = gradient([(0.075, 0.078, 0.086, 1), (0.016, 0.017, 0.021, 1)])
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// A soft radial glow behind the glyph, tinted with the brand blue, keeps the
// background from feeling inert without competing with the glyph itself.
ctx.saveGState()
let glow = gradient([(0.22, 0.45, 0.92, 0.22), (0.22, 0.45, 0.92, 0)])
ctx.drawRadialGradient(
    glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.56), startRadius: 0,
    endCenter: CGPoint(x: s * 0.5, y: s * 0.56), endRadius: s * 0.42, options: []
)
ctx.restoreGState()

// MARK: The folded card glyph.
let cx = s * 0.5
let cy = s * 0.5
let halfWidth = s * 0.29
let halfHeight = s * 0.275
let creaseInset = s * 0.085   // how sharply the crease pinches inward
let cornerRadius = s * 0.045

func roundedPanel(outerX: CGFloat, creaseX: CGFloat, outerTop: CGFloat, outerBottom: CGFloat,
                  creaseTop: CGFloat, creaseBottom: CGFloat, roundOuterCorners: Bool) -> CGPath {
    let path = CGMutablePath()
    if roundOuterCorners {
        let sign: CGFloat = outerX > creaseX ? 1 : -1
        path.move(to: CGPoint(x: outerX - sign * cornerRadius, y: outerTop))
        path.addArc(tangent1End: CGPoint(x: outerX, y: outerTop),
                    tangent2End: CGPoint(x: outerX, y: outerTop - cornerRadius), radius: cornerRadius)
        path.addLine(to: CGPoint(x: outerX, y: outerBottom + cornerRadius))
        path.addArc(tangent1End: CGPoint(x: outerX, y: outerBottom),
                    tangent2End: CGPoint(x: outerX - sign * cornerRadius, y: outerBottom), radius: cornerRadius)
        path.addLine(to: CGPoint(x: creaseX, y: creaseBottom))
        path.addLine(to: CGPoint(x: creaseX, y: creaseTop))
        path.closeSubpath()
    } else {
        path.move(to: CGPoint(x: outerX, y: outerTop))
        path.addLine(to: CGPoint(x: outerX, y: outerBottom))
        path.addLine(to: CGPoint(x: creaseX, y: creaseBottom))
        path.addLine(to: CGPoint(x: creaseX, y: creaseTop))
        path.closeSubpath()
    }
    return path
}

let leftPath = roundedPanel(
    outerX: cx - halfWidth, creaseX: cx,
    outerTop: cy + halfHeight, outerBottom: cy - halfHeight,
    creaseTop: cy + halfHeight - creaseInset, creaseBottom: cy - halfHeight + creaseInset,
    roundOuterCorners: true
)
let rightPath = roundedPanel(
    outerX: cx + halfWidth, creaseX: cx,
    outerTop: cy + halfHeight, outerBottom: cy - halfHeight,
    creaseTop: cy + halfHeight - creaseInset, creaseBottom: cy - halfHeight + creaseInset,
    roundOuterCorners: true
)

// The brand gradient — identical stops to LidPreview in SettingsView.swift.
let brand = gradient([(0.22, 0.45, 0.92, 1), (0.55, 0.32, 0.78, 1), (0.98, 0.42, 0.40, 1)])

func fillPanel(_ path: CGPath, darken: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        brand,
        start: CGPoint(x: cx - halfWidth, y: cy + halfHeight),
        end: CGPoint(x: cx + halfWidth, y: cy - halfHeight),
        options: []
    )
    if darken > 0 {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: darken))
        ctx.fill(full)
    }
    ctx.restoreGState()
}

// Drop shadow under the whole glyph before the panels themselves.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.05,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
ctx.addPath(leftPath)
ctx.addPath(rightPath)
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// The right panel reads as "turned away" from the light, so it's darkened
// slightly — the same trick FoldRenderer's shader uses for the real effect.
fillPanel(leftPath, darken: 0)
fillPanel(rightPath, darken: 0.22)

// Crease shadow: a soft dark vertical band right at the fold.
ctx.saveGState()
let creaseShadow = gradient([(0, 0, 0, 0), (0, 0, 0, 0.5), (0, 0, 0, 0)])
ctx.saveGState()
ctx.addPath(leftPath); ctx.addPath(rightPath); ctx.clip()
ctx.translateBy(x: cx, y: cy)
ctx.rotate(by: .pi / 2)
ctx.drawLinearGradient(
    creaseShadow,
    start: CGPoint(x: -s * 0.03, y: 0), end: CGPoint(x: s * 0.03, y: 0),
    options: []
)
ctx.restoreGState()
ctx.restoreGState()

// A thin bright sheen catching the fold edge.
ctx.saveGState()
ctx.addPath(leftPath); ctx.addPath(rightPath); ctx.clip()
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
ctx.setLineWidth(s * 0.006)
ctx.move(to: CGPoint(x: cx, y: cy + halfHeight - creaseInset))
ctx.addLine(to: CGPoint(x: cx, y: cy - halfHeight + creaseInset))
ctx.strokePath()
ctx.restoreGState()

// MARK: Export.
guard let image = ctx.makeImage() else { fatalError("could not render image") }
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try! data.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
