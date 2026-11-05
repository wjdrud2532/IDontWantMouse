import AppKit

// Hanmium 앱 아이콘을 그린다: 어두운 바탕 위의 창 하나와, 그 위에 붙은 글자 라벨(누를 곳마다 붙는 그것).
// 화면을 찍지 않고 코드로만 그린다. 사용법: AppIcon <출력 폴더> → <폴더>/AppIcon.iconset/*.png
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
/// 그림자는 좌표 변환(크기 줄이기)을 따르지 않아서 픽셀 크기에 맞춰 직접 줄인다
var shadowScale: CGFloat = 1

func shadow(_ alpha: CGFloat, y: CGFloat, blur: CGFloat) {
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.shadowOffset = NSSize(width: 0, height: y * shadowScale)
    s.shadowBlurRadius = blur * shadowScale
    s.set()
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}

/// 노란 라벨 하나 (가운데 글자)
func pill(_ text: String, center: CGPoint, height: CGFloat) {
    let font = roundedFont(height * 0.66)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(0x1B1F2A)]
    let size = (text as NSString).size(withAttributes: attrs)
    let rect = CGRect(x: center.x - (size.width + height * 0.62) / 2, y: center.y - height / 2,
                      width: size.width + height * 0.62, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: height * 0.3, yRadius: height * 0.3)
    NSGraphicsContext.saveGraphicsState()
    shadow(0.35, y: -height * 0.08, blur: height * 0.18)
    color(0xF5B700).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xFFE27A), ending: color(0xF5B300))!.draw(in: path, angle: -90)
    color(0xC98F00, 0.6).setStroke()
    path.lineWidth = max(1, height * 0.025)
    path.stroke()
    (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - height * 0.02),
                            withAttributes: attrs)
}

/// 1024 기준 좌표로 그린다
func drawIcon() {
    // 바탕: macOS 아이콘 격자(824pt 몸체, 둥근 모서리)와 아래 그림자
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    shadow(0.3, y: -10, blur: 24)
    color(0x18213D).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x34477E), ending: color(0x121931))!.draw(in: bodyPath, angle: -90)

    // 창: 밝은 카드, 위쪽 막대와 신호등 점, 글줄
    let card = CGRect(x: 196, y: 250, width: 632, height: 520)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 46, yRadius: 46)
    NSGraphicsContext.saveGraphicsState()
    shadow(0.35, y: -8, blur: 22)
    color(0xF4F6FA).setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    cardPath.addClip()
    color(0xE2E6EF).setFill()
    CGRect(x: card.minX, y: card.maxY - 78, width: card.width, height: 78).fill()
    NSGraphicsContext.restoreGraphicsState()
    for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        color(UInt32(hex)).setFill()
        NSBezierPath(ovalIn: CGRect(x: card.minX + 40 + CGFloat(i) * 46, y: card.maxY - 53, width: 28, height: 28)).fill()
    }
    let lines: [(CGFloat, CGFloat)] = [(612, 330), (540, 420), (468, 260), (396, 380), (324, 300)]
    for (y, w) in lines {
        color(0xC7CEDC).setFill()
        NSBezierPath(roundedRect: CGRect(x: card.minX + 132, y: y, width: w, height: 30), xRadius: 15, yRadius: 15).fill()
    }

    // 글자 라벨: 줄마다 하나씩 작은 것, 앞쪽에 크게 하나
    pill("s", center: CGPoint(x: card.minX + 78, y: 627), height: 58)
    pill("d", center: CGPoint(x: card.minX + 78, y: 483), height: 58)
    pill("f", center: CGPoint(x: card.minX + 78, y: 339), height: 58)
    pill("jk", center: CGPoint(x: 676, y: 236), height: 200)
}

let sizes: [(String, Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
    ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024),
]
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    shadowScale = CGFloat(px) / 1024
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print(iconset.path)
