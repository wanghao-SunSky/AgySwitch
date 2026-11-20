import AppKit
import CoreGraphics

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func tile() -> CGPath {
    let path = CGMutablePath()
    for i in 0...256 {
        let angle = 2 * Double.pi * Double(i) / 256
        let x = cos(angle), y = sin(angle)
        let point = CGPoint(x: 512 + 424 * copysign(pow(abs(x), 0.46), x),
                            y: 512 + 424 * copysign(pow(abs(y), 0.46), y))
        if i == 0 { path.move(to: point) }
        else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func png(size: Int) -> Data? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let silhouette = tile()
    context.saveGState()
    context.addPath(silhouette)
    context.clip()
    let colors = [CGColor(srgbRed: 0.21, green: 0.23, blue: 0.25, alpha: 1),
                  CGColor(srgbRed: 0.105, green: 0.12, blue: 0.135, alpha: 1)]
    let shading = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shading, start: CGPoint(x: 400, y: 936), end: CGPoint(x: 620, y: 88),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.addPath(silhouette)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.13))
    context.setLineWidth(7)
    context.strokePath()
    context.restoreGState()

    context.setLineWidth(51)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(srgbRed: 0.91, green: 0.94, blue: 0.97, alpha: 1))
    context.move(to: CGPoint(x: 296, y: 616))
    context.addLine(to: CGPoint(x: 728, y: 616))
    context.addLines(between: [CGPoint(x: 646, y: 698), CGPoint(x: 728, y: 616), CGPoint(x: 646, y: 534)])
    context.strokePath()

    context.setStrokeColor(CGColor(srgbRed: 0.69, green: 0.75, blue: 0.81, alpha: 1))
    context.move(to: CGPoint(x: 728, y: 408))
    context.addLine(to: CGPoint(x: 296, y: 408))
    context.addLines(between: [CGPoint(x: 378, y: 490), CGPoint(x: 296, y: 408), CGPoint(x: 378, y: 326)])
    context.strokePath()
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        guard let data = png(size: base * scale) else { exit(1) }
        try data.write(to: destination.appendingPathComponent(filename))
    }
}
