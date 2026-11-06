import AppKit

/// 화면마다 투명 패널을 하나씩 띄우고, 그리기와 키 입력을 모드에 넘긴다.
/// 패널은 nonactivating 이라 키 입력을 받는 동안에도 원래 앱이 활성 상태로 남는다.
final class Overlay {
    /// AX 좌표계로 그린다. 인자는 그 패널이 덮는 화면 영역(AX 좌표).
    var paint: ((CGRect) -> Void)?
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?

    private var panels: [OverlayPanel] = []
    private var canvases: [CanvasView] = []
    private(set) var keyPanel: OverlayPanel!
    private(set) var keyCanvas: CanvasView!
    /// 유리 라벨이 굴절시킬 화면 사진이 새로 찍히면 받는다
    private var snapshotObserver: NSObjectProtocol?
    /// nil 이면 모든 창 위에 띄운다(라벨 클릭: 메뉴 막대·Dock 위에도 라벨이 필요하다).
    /// 창 번호가 있으면 그 창 바로 위에 끼워 넣어서, 다른 앱 창이 덮으면 같이 가려진다(스크롤 테두리).
    private var stackedAbove: CGWindowID?

    /// fades: 닫을 때 macOS 기본 효과로 서서히 사라진다(약 0.2초). false 면 바로 사라진다.
    init(keyScreen: NSScreen, stackedAbove: CGWindowID? = nil, fades: Bool = true) {
        self.stackedAbove = stackedAbove
        let glass = Config.labelTheme.glass
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            if !fades { panel.animationBehavior = .none }
            if stackedAbove != nil { panel.level = .normal }
            let canvas = CanvasView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                    axOrigin: Screens.axFrame(screen).origin)
            canvas.overlay = self
            if let glass {
                // 흐림 뷰를 라벨 그림 아래에 깐다
                let container = NSView(frame: canvas.frame)
                let blur = GlassBackdrop(glass)
                container.addSubview(blur)
                container.addSubview(canvas)
                canvas.backdrop = blur
                panel.contentView = container
            } else {
                panel.contentView = canvas
            }
            panels.append(panel)
            canvases.append(canvas)
            if screen == keyScreen {
                keyPanel = panel
                keyCanvas = canvas
            }
        }
        if keyPanel == nil, let first = panels.first {
            keyPanel = first
            keyCanvas = canvases.first
        }
        if GlassSnapshots.usesGlass {
            applySnapshots()
            snapshotObserver = NotificationCenter.default.addObserver(
                forName: GlassSnapshots.didChange, object: nil, queue: .main
            ) { [weak self] _ in self?.applySnapshots() }
        }
    }

    /// 화면 사진이 있으면 유리 라벨을 굴절로 그린다. 없으면 흐림 뷰로 그린다.
    private func applySnapshots() {
        for canvas in canvases {
            canvas.glassSource = GlassSnapshots.current.first { $0.axFrame == canvas.axFrame }.map(GlassSource.init)
        }
        redraw()
    }

    /// 다시 찍을 때 빼야 하는 오버레이 창들
    var windowIDs: [CGWindowID] { panels.map { CGWindowID($0.windowNumber) } }

    func show() {
        if let window = stackedAbove {
            stack(above: window)
        } else {
            panels.forEach { $0.orderFrontRegardless() }
        }
        reclaimKey()
    }

    var isStacked: Bool { stackedAbove != nil }

    /// 패널들을 다른 앱의 창 바로 위로 옮긴다
    func stack(above window: CGWindowID) {
        stackedAbove = window
        panels.forEach { $0.order(.above, relativeTo: Int(window)) }
    }

    /// 다른 앱 창을 올리면 그 앱이 키 포커스를 가져갈 수 있어서 다시 가져온다.
    func reclaimKey() {
        if let window = stackedAbove {
            // 맨 앞으로 끌어올리지 않고 키만 받은 뒤 다시 대상 창 바로 위로
            keyPanel.makeKey()
            stack(above: window)
        } else {
            keyPanel.makeKeyAndOrderFront(nil)
        }
        keyPanel.makeFirstResponder(keyCanvas)
    }

    func redraw() {
        canvases.forEach { $0.needsDisplay = true }
    }

    func close() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        canvases.removeAll()
        if let snapshotObserver { NotificationCenter.default.removeObserver(snapshotObserver) }
        snapshotObserver = nil
    }
}

final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // 열린 메뉴(popUpMenu 레벨)보다 위
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.assistiveTechHighWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true  // 합성한 클릭·휠 이벤트가 아래 앱으로 그대로 가도록
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CanvasView: NSView {
    weak var overlay: Overlay?
    /// 유리 라벨이면 그 뒤를 흐리게 하는 뷰 (화면 사진이 없을 때)
    var backdrop: GlassBackdrop?
    /// 유리 라벨이 굴절시킬 이 화면의 사진
    var glassSource: GlassSource?
    private let axOrigin: CGPoint
    var axFrame: CGRect { CGRect(origin: axOrigin, size: bounds.size) }

    init(frame: NSRect, axOrigin: CGPoint) {
        self.axOrigin = axOrigin
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // 뒤집힌 좌표계 + 원점 이동만 하면 AX 좌표를 그대로 쓸 수 있다
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: -axOrigin.x, y: -axOrigin.y)
        Draw.pillFrames = []
        Draw.glassSource = glassSource
        let paintStart = CACurrentMediaTime()
        if let glassSource, GlassGPU.shared != nil {
            // 라벨을 GPU 로 한꺼번에 그려 두려고, 먼저 그리지 않고 라벨 자리만 모은다(빈 그림판에 한 번 그려 본다)
            Draw.collecting = []
            if let scratch = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               let dry = NSGraphicsContext(bitmapImageRep: scratch) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = dry
                overlay?.paint?(CGRect(origin: axOrigin, size: bounds.size))
                NSGraphicsContext.restoreGraphicsState()
            }
            glassSource.prepare(Draw.collecting ?? [])
            Draw.collecting = nil
        }
        overlay?.paint?(CGRect(origin: axOrigin, size: bounds.size))
        Draw.glassSource = nil
        if Timing.running {
            let ms = Int((CACurrentMediaTime() - paintStart) * 1000)
            // 유리 라벨이면 화면 사진으로 굴절까지 그린 때가 끝, 아니면 처음 그린 때가 끝
            if glassSource != nil || !GlassSnapshots.wanted {
                Timing.finish("그리기 끝(그리기 \(ms)ms)")
            } else {
                Timing.mark("굴절 없이 먼저 그림(\(ms)ms)")
            }
        }
        ctx.restoreGState()
        if let backdrop {
            // 그리는 중에는 뷰를 고치지 않고 바로 다음에 흐림 모양을 라벨에 맞춘다
            let frames = Draw.pillFrames.map { $0.offsetBy(dx: -axOrigin.x, dy: -axOrigin.y) }
            let height = bounds.height
            DispatchQueue.main.async { backdrop.cut(to: frames, inFlippedHeight: height) }
        }
    }

    override func keyDown(with event: NSEvent) { overlay?.onKeyDown?(event) }
    override func keyUp(with event: NSEvent) { overlay?.onKeyUp?(event) }
}

/// 유리 라벨 뒤 화면을 흐리게 하는 뷰. 화면마다 하나를 두고 라벨 모양대로 잘라 쓴다
/// (라벨마다 흐림 뷰를 두면 라벨이 수백 개일 때 무겁다).
final class GlassBackdrop: NSVisualEffectView {
    private var frames: [CGRect] = []

    init(_ glass: LabelTheme.Glass) {
        super.init(frame: .zero)
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active  // 키 창이 아니어도 흐림 유지
        // 재질 색이 뒤 색을 덮지 않게 반만 섞는다 (화면 기록 권한이 없을 때만 쓰는 대체 모양)
        alphaValue = 0.55
        appearance = NSAppearance(named: glass == .dark ? .darkAqua : .aqua)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// frames: 캔버스(위에서 아래로 내려가는 좌표) 기준 라벨 사각형. 부모 뷰는 아래에서 위로 올라가는 좌표다.
    func cut(to frames: [CGRect], inFlippedHeight height: CGFloat) {
        guard frames != self.frames else { return }
        self.frames = frames
        guard !frames.isEmpty else {
            isHidden = true
            return
        }
        let union = frames.reduce(CGRect.null) { $0.union($1) }.integral
        frame = CGRect(x: union.minX, y: height - union.maxY, width: union.width, height: union.height)
        maskImage = NSImage(size: union.size, flipped: true) { _ in
            NSColor.black.setFill()
            for f in frames {
                let r = f.offsetBy(dx: -union.minX, dy: -union.minY)
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            return true
        }
        isHidden = false
    }
}

/// 라벨 색 조합. 설정에서 고르며, 스크롤 영역 테두리·검색 강조(accent)도 따라간다.
struct LabelTheme {
    enum Glass { case light, dark }

    let id: String
    let name: String
    let fill: NSColor
    let text: NSColor
    /// 이미 입력한 앞 글자
    let typed: NSColor
    let stroke: NSColor
    let accent: NSColor
    /// 유리 라벨: 뒤 화면을 흐리게 하고(GlassBackdrop) 빛 반사를 그린다. fill 은 흐린 배경 위에 덮는 옅은 색.
    var glass: Glass? = nil

    static let all: [LabelTheme] = [
        LabelTheme(id: "glass", name: "유리", fill: NSColor(white: 1, alpha: 0.3), text: rgb(0x1D1D1F),
                   typed: rgb(0x1D1D1F, 0.35), stroke: NSColor(white: 1, alpha: 0.9), accent: rgb(0x0A84FF),
                   glass: .light),
        LabelTheme(id: "glassDark", name: "유리 다크", fill: NSColor(white: 0, alpha: 0.2), text: .white,
                   typed: NSColor(white: 1, alpha: 0.4), stroke: NSColor(white: 1, alpha: 0.5), accent: rgb(0x0A84FF),
                   glass: .dark),
        LabelTheme(id: "dark", name: "다크", fill: rgb(0x1C1E24, 0.94), text: rgb(0xFFCC40), typed: rgb(0x80808A),
                   stroke: NSColor(white: 1, alpha: 0.2), accent: rgb(0x4D9EFF)),
        LabelTheme(id: "light", name: "라이트", fill: rgb(0xFAFAFA, 0.96), text: rgb(0x1C1E24), typed: rgb(0xA0A0A8),
                   stroke: NSColor(white: 0, alpha: 0.25), accent: rgb(0x2F6FEB)),
        LabelTheme(id: "yellow", name: "노랑", fill: rgb(0xFFD84D), text: rgb(0x1A1A1A), typed: rgb(0x9A8030),
                   stroke: rgb(0xC9A227), accent: rgb(0xF5B700)),
        LabelTheme(id: "blue", name: "파랑", fill: rgb(0x2F6FEB), text: .white, typed: rgb(0xA9C4F7),
                   stroke: rgb(0x1F4FB0), accent: rgb(0x2F6FEB)),
        LabelTheme(id: "green", name: "초록", fill: rgb(0x1F9D55), text: .white, typed: rgb(0xA3DDBB),
                   stroke: rgb(0x167040), accent: rgb(0x1F9D55)),
        LabelTheme(id: "red", name: "빨강", fill: rgb(0xE5484D), text: .white, typed: rgb(0xF5B5B7),
                   stroke: rgb(0xA8282D), accent: rgb(0xE5484D)),
        LabelTheme(id: "purple", name: "보라", fill: rgb(0x7C5CFF), text: .white, typed: rgb(0xC9BDFF),
                   stroke: rgb(0x5536D6), accent: rgb(0x7C5CFF)),
    ]

    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension NSColor {
    /// "#RRGGBB"
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let v = Int(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }
}

enum Draw {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    static var theme: LabelTheme { Config.labelTheme }
    /// 이번에 그린 라벨 사각형(AX 좌표). 유리 라벨이면 이 모양대로 뒤를 흐리게 한다.
    static var pillFrames: [CGRect] = []
    /// 지금 그리는 화면의 사진. 있으면 유리 라벨을 굴절로 그린다.
    static var glassSource: GlassSource?
    /// nil 이 아니면 그리지 않고 유리 라벨 자리만 모은다 (GPU 로 한꺼번에 그리기 전에)
    static var collecting: [(rect: CGRect, forceDark: Bool)]?

    /// center 를 중심으로 라벨을 그리되 화면 밖으로 나가지 않게 민다. 앞 typedCount 글자는 흐리게.
    static func pill(_ text: String, typedCount: Int = 0, center: CGPoint, within bounds: CGRect,
                     font: NSFont = Draw.font) {
        let theme = theme
        let s = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: theme.text])
        if typedCount > 0 {
            s.addAttribute(.foregroundColor, value: theme.typed, range: NSRange(location: 0, length: typedCount))
        }
        // 유리 라벨은 알약 모양이라 양옆을 더 띄운다
        let k = font.pointSize / Draw.font.pointSize
        let pad = theme.glass == nil ? CGSize(width: 4 * k, height: 1 * k) : CGSize(width: 6 * k, height: 2 * k)
        let size = s.size()
        var r = CGRect(x: center.x - size.width / 2 - pad.width, y: center.y - size.height / 2 - pad.height,
                       width: size.width + pad.width * 2, height: size.height + pad.height * 2)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        if collecting != nil {
            if let glass = theme.glass { collecting?.append((r, glass == .dark)) }
            return
        }
        if let glass = theme.glass, let look = glassSource?.look(r, forceDark: glass == .dark) {
            glassShadow(r, dark: look.dark)
            NSImage(cgImage: look.image, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                                                            respectFlipped: true, hints: nil)
            // 뒤 밝기에 맞춰 글자색을 고르고, 굴절된 무늬 위에서도 읽히게 반대색 번짐을 깐다
            let ink: NSColor = look.dark ? .white : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
            let glow = NSShadow()
            glow.shadowBlurRadius = 2
            glow.shadowColor = look.dark ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 1, alpha: 0.6)
            let all = NSRange(location: 0, length: s.length)
            s.addAttributes([.foregroundColor: ink, .shadow: glow], range: all)
            if typedCount > 0 {
                s.addAttribute(.foregroundColor, value: ink.withAlphaComponent(0.4),
                               range: NSRange(location: 0, length: typedCount))
            }
        } else if let glass = theme.glass {
            glassPill(r, fill: theme.fill, dark: glass == .dark)
            pillFrames.append(r)
        } else {
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            theme.fill.setFill()
            path.fill()
            theme.stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        s.draw(at: CGPoint(x: r.minX + pad.width, y: r.minY + pad.height))
    }

    /// 바깥에만 그림자. 유리 속이 비치므로 안쪽까지 어둡게 하지 않는다. radius 가 없으면 알약.
    private static func glassShadow(_ r: CGRect, radius: CGFloat? = nil, dark: Bool, strength: CGFloat = 1) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let corner = min(radius ?? r.height / 2, r.width / 2, r.height / 2)
        let shape = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.saveGState()
        ctx.addRect(r.insetBy(dx: -12, dy: -12))
        ctx.addPath(shape)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 6,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: (dark ? 0.5 : 0.3) * strength))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// 화면 사진이 없을 때: 흐린 배경 위에 유리 느낌을 그린다(바깥 그림자, 옅은 색, 윗부분 광택, 가장자리 빛).
    private static func glassPill(_ r: CGRect, fill: NSColor, dark: Bool) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let radius = r.height / 2
        let shape = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let white = { (a: CGFloat) in CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
        glassShadow(r, dark: dark)

        // 옅은 색을 덮고 위쪽 절반에 광택
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.setFillColor(fill.cgColor)
        ctx.fill(r)
        verticalGradient(ctx, [white(dark ? 0.2 : 0.5), white(0)], from: r.minY, to: r.midY + 1)
        ctx.restoreGState()

        // 가장자리 빛: 위는 밝게, 옆은 거의 없이, 아래는 되비친 빛으로 살짝
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius - 0.5,
                           cornerHeight: radius - 0.5, transform: nil))
        ctx.setLineWidth(1)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        verticalGradient(ctx, [white(dark ? 0.6 : 1), white(dark ? 0.08 : 0.3), white(dark ? 0.3 : 0.7)],
                         from: r.minY, to: r.maxY)
        ctx.restoreGState()

        // 밝은 배경에서도 경계가 보이게 바깥에 아주 옅은 선
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -0.5, dy: -0.5), cornerWidth: radius + 0.5,
                           cornerHeight: radius + 0.5, transform: nil))
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.35 : 0.12))
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private static func verticalGradient(_ ctx: CGContext, _ colors: [CGColor], from top: CGFloat, to bottom: CGFloat) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil) else { return }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// 고르지 않은 영역: 옅게 칠하고 점선으로 두른다. 고른 영역(selected)과 겹치는 곳은 칠하지 않아서
    /// 고른 영역 내용이 물들지 않는다. 단 이 영역이 고른 영역 안에 들어 있으면 그대로 그린다.
    static func inactiveArea(_ rect: CGRect, selected: CGRect, color: NSColor, width: CGFloat,
                             lineOpacity: CGFloat, fillOpacity: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        if !selected.contains(rect) {
            let clip = NSBezierPath(rect: rect.insetBy(dx: -width * 2, dy: -width * 2))
            clip.append(NSBezierPath(rect: selected))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        if fillOpacity > 0 {
            color.withAlphaComponent(fillOpacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
        if lineOpacity > 0 {
            let line = NSBezierPath(roundedRect: rect.insetBy(dx: -width / 2, dy: -width / 2), xRadius: 4, yRadius: 4)
            line.lineWidth = width
            line.setLineDash([width * 4, width * 2.5], count: 2, phase: 0)
            color.withAlphaComponent(lineOpacity).setStroke()
            line.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static let areaCornerRadius: CGFloat = 10

    /// body 에서 그린 것을 alpha 만큼 옅게
    static func faded(_ alpha: CGFloat, _ body: () -> Void) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return body() }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 테두리 두께 설정(1~8)에서 유리 막대 굵기. 기본 3 → 4pt.
    /// 두꺼우면 굴절·광택 띠가 굵은 선처럼 보여서 얇게 둔다.
    static func ringBand(_ width: CGFloat) -> CGFloat { max(2.5, width * 1.4) }

    /// 고르지 않은 영역 유리판의 굴절 가장자리를 지금 화면으로 그린다(사진이 없으면 nil).
    /// 한 번 그린 것을 그 영역이 다시 골라질 때까지 그대로 쓰면, 뒤 화면이 바뀌어도 테두리가 흔들리지 않는다.
    /// 굴절 범위·강도는 설정(slabBezel·slabRefraction)을 따르고, 작은 영역에서는 짧은 변의 절반까지만 휜다.
    static func glassAreaEdge(_ rect: CGRect, color: NSColor, fillOpacity: CGFloat) -> (image: CGImage, frame: CGRect)? {
        guard collecting == nil else { return nil }
        let glass = slabGlass(for: rect)
        return glassSource?.edge(rect, ring: false, width: glass.bezel, cornerRadius: areaCornerRadius, tint: color,
                                 tintAlpha: fillOpacity, specular: 0.6, thickness: glass.thickness, power: glass.power,
                                 rim: glass.rim, dome: glass.dome)
    }

    /// 고르지 않은 영역 유리판의 굴절 모양.
    /// - 영역 전체(기본, dome): 영역을 덮는 볼록렌즈(GlassGPU domeShift). 가운데를 키우고 가장자리는 제자리라 내용이
    ///   잘리지 않는다. 가로·세로 세기 k 는 그 축에서 가장 많이 움직이는 자리(가운데에서 58%)가 8pt 가 되게 정하고
    ///   0.2 를 넘지 않는다(반 365pt: 0.057, 가운데 1.06배 / 반 167pt: 0.124, 1.14배 / 반 34pt: 0.2, 1.25배, 2.6pt).
    ///   돌려주는 thickness·power 가 가로·세로 세기다.
    ///   가장자리 빛은 바깥 24pt 안에만. 움직이는 테두리 가장자리는 40pt 띠(지수 3)로 따로 휜다.
    /// - 가장자리만: 설정한 폭(slabBezel) 안에서 휜다. 지수 3, 두께는 폭의 0.6배(기본 40pt: 가장자리 6pt, 10pt 안쪽 3.2pt).
    static func slabGlass(for rect: CGRect)
        -> (bezel: CGFloat, thickness: CGFloat, power: CGFloat, rim: CGFloat, dome: Bool) {
        let half = max(4, min(rect.width, rect.height) / 2)
        if Config.slabFullRefraction, GlassGPU.shared != nil {
            let k = { (h: CGFloat) in min(min(0.2, 8 / (0.385 * max(h, 1))) * Config.slabRefraction, 0.6) }
            return (half, k(rect.width / 2), k(rect.height / 2), min(24, half), true)
        }
        let bezel = min(Config.slabBezel, half)
        return (bezel, bezel * 0.6 * Config.slabRefraction, 3, bezel, false)
    }

    static func slabBezel(for rect: CGRect) -> CGFloat { slabGlass(for: rect).bezel }

    /// 유리 막대 바깥 가장자리(glassRing 과 같은 계산). 물방울 이동 중이면 stretch·lens 로 모양이 바뀐다.
    static func ringOuter(_ rect: CGRect, band baseBand: CGFloat, stretch: CGFloat, lens: CGFloat)
        -> (rect: CGRect, radius: CGFloat) {
        let radius = blobRadius(rect, stretch: stretch, lens: lens)
        let band = baseBand * (1 + 0.4 * stretch)
        return lens > 0.5 ? (rect, radius) : (rect.insetBy(dx: -band, dy: -band), radius + band)
    }

    /// 테두리 가까이에 있는 고르지 않은 영역 유리판: 영역에서 테두리 모양(hole)을 뺀 유리를 지금 화면으로 굴절시킨다.
    /// 테두리가 빠져나간 자리에는 그 모양대로 유리가 차오르고, 들어가는 영역은 그 모양대로 파이며, 멈춘 뒤에도
    /// 테두리 둘레는 휜 채로 남는다. GPU 를 못 쓰거나 화면 사진이 없으면 nil (그때는 glassArea 로 그린다).
    static func carvedGlassArea(_ rect: CGRect, hole: CGRect, holeRadius: CGFloat, color: NSColor,
                                fillOpacity: CGFloat) -> (frame: CGRect, image: CGImage)? {
        guard collecting == nil else { return nil }
        let glass = slabGlass(for: rect)
        guard let image = glassSource?.carvedSlab(rect, cornerRadius: areaCornerRadius, hole: hole, holeRadius: holeRadius,
                                                  bezel: glass.bezel, thickness: glass.thickness, power: glass.power,
                                                  rim: glass.rim, dome: glass.dome, holeBezel: min(holeBand, glass.bezel),
                                                  holeThickness: min(holeBand, glass.bezel) * 0.6 * Config.slabRefraction,
                                                  tint: color, tintAlpha: fillOpacity, specular: 0.6).first ?? nil
        else { return nil }
        return (rect, image)
    }

    /// 미리 그려 둔 유리 조각들을 제자리에
    static func draw(_ pieces: [(frame: CGRect, image: CGImage)]) {
        for piece in pieces {
            NSImage(cgImage: piece.image, size: piece.frame.size).draw(
                in: piece.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// 테두리 둘레가 휘는 폭: 영역 전체 굴절이면 40pt, 아니면 굴절 범위 설정까지
    static var holeBand: CGFloat { Config.slabFullRefraction && GlassGPU.shared != nil ? 40 : min(40, Config.slabBezel) }

    /// 영역 유리판이 없는 곳(창의 나머지, 다른 창, 배경화면)도 투명한 유리판을 테두리가 파고 지나가듯
    /// 테두리 둘레 띠(holeBand)만큼 휜다. 띠의 세기는 영역 유리판의 테두리 둘레와 같다. 색을 덮지 않고 채도도
    /// 그대로, 빛도 넣지 않아서(넣으면 테두리 바깥에 흰 막이 떠 보였다) 휘는 것 말고는 살아 있는 화면과 같다.
    /// 판은 화면보다 넓게 잡아 화면 가장자리는 휘지 않는다.
    /// 영역 유리판(slabs) 자리는 빼고, 띠가 생길 수 있는 테두리 둘레 네 줄만 GPU 로 그린다(hole 안쪽은 비어 있다).
    static func carvedBackground(_ screen: CGRect, hole: CGRect, holeRadius: CGFloat,
                                 excluding slabs: [CGRect]) -> [(frame: CGRect, image: CGImage)] {
        guard collecting == nil, let glassSource else { return [] }
        let band = holeBand, s = glassSource.snapshot.scale
        // 띠 이음매가 보이지 않게 화면 픽셀에 맞춘다
        let align = { (r: CGRect, outward: Bool) -> CGRect in
            guard !r.isNull else { return .null }
            let lo = { (v: CGFloat) in (v * s).rounded(outward ? .down : .up) / s }
            let hi = { (v: CGFloat) in (v * s).rounded(outward ? .up : .down) / s }
            let x0 = lo(r.minX), y0 = lo(r.minY), x1 = hi(r.maxX), y1 = hi(r.maxY)
            return x1 > x0 && y1 > y0 ? CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .null
        }
        let outer = align(hole.insetBy(dx: -band - 1, dy: -band - 1), true).intersection(screen)
        guard !outer.isNull, outer.width > 0, outer.height > 0 else { return [] }
        // 둥근 hole 안에 들어가는 사각형(모서리 반지름 r 이면 0.3r 안쪽)은 비어 있어서 그리지 않는다
        let r = min(holeRadius, hole.width / 2, hole.height / 2)
        let inner = align(hole.insetBy(dx: r * 0.3 + 1, dy: r * 0.3 + 1), false).intersection(outer)
        var parts = [outer]
        if !inner.isNull, inner.width > 0, inner.height > 0 {
            parts = [CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: inner.minY - outer.minY),
                     CGRect(x: outer.minX, y: inner.maxY, width: outer.width, height: outer.maxY - inner.maxY),
                     CGRect(x: outer.minX, y: inner.minY, width: inner.minX - outer.minX, height: inner.height),
                     CGRect(x: inner.maxX, y: inner.minY, width: outer.maxX - inner.maxX, height: inner.height)]
        }
        let covered = { (part: CGRect) in
            slabs.contains { $0.insetBy(dx: areaCornerRadius, dy: areaCornerRadius).contains(part) }
        }
        parts = parts.filter { $0.width > 0 && $0.height > 0 && !covered($0) }
        guard !parts.isEmpty else { return [] }
        // 영역 유리판 자리는 GPU 에서 비운다(CG 로 잘라 내면 큰 테두리에서 4ms 더 걸렸다)
        let pane = screen.insetBy(dx: -band - 30, dy: -band - 30)
        let images = glassSource.carvedSlab(pane, cornerRadius: 0, hole: hole, holeRadius: holeRadius, bezel: band,
                                            thickness: band * 0.6 * Config.slabRefraction, power: 3, rim: min(24, band),
                                            tint: .black, tintAlpha: 0, saturation: 1, specular: 0, parts: parts,
                                            cuts: Array(slabs.filter { $0.intersects(outer) }.prefix(64)),
                                            cutRadius: areaCornerRadius)
        return zip(parts, images).compactMap { part, image in image.map { (part, $0) } }
    }

    /// 고르지 않은 영역을 유리판으로: 살아 있는 화면 위에 옅은 색을 덮고, 가장자리 띠(edge)는 굴절 + 빛.
    static func glassArea(_ rect: CGRect, selected: CGRect, color: NSColor, fillOpacity: CGFloat,
                          edge: (image: CGImage, frame: CGRect)?) {
        guard collecting == nil else { return }
        let radius = areaCornerRadius
        NSGraphicsContext.saveGraphicsState()
        if !selected.contains(rect) {
            let clip = NSBezierPath(rect: rect.insetBy(dx: -4, dy: -4))
            clip.append(NSBezierPath(rect: selected))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        color.withAlphaComponent(fillOpacity).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        if let edge {
            NSImage(cgImage: edge.image, size: edge.frame.size).draw(
                in: edge.frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            rimLight(rect, radius: radius, strength: 0.8)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 물방울 이동 중 테두리 모양: 빠를수록(stretch) 둥글고, 작은 물방울로 바뀔수록(lens) 원에 가깝다
    static func blobRadius(_ rect: CGRect, stretch: CGFloat, lens: CGFloat) -> CGFloat {
        let minDim = min(rect.width, rect.height)
        return min(minDim / 2, areaCornerRadius + stretch * minDim * 0.2 + lens * minDim)
    }

    /// 고른 영역 둘레 바깥을 유리 막대로 감싼다. 물방울 이동 중이면 stretch·lens 로 모양이 바뀌고,
    /// 매 프레임 모양이 달라서 캐시하지 않는다(moving). 바깥 그림자는 움직이는 정도(shadow, DropletMotion.activity)만큼
    /// 진해서 멈출 때 서서히 사라진다(멈추는 순간 지우면 둘레가 뚝 밝아졌다).
    static func glassRing(_ rect: CGRect, color: NSColor, band baseBand: CGFloat, stretch: CGFloat = 0,
                          lens: CGFloat = 0, moving: Bool = false, shadow: CGFloat = 0) {
        guard collecting == nil else { return }
        let radius = blobRadius(rect, stretch: stretch, lens: lens)
        let band = baseBand * (1 + 0.4 * stretch)
        let outer = rect.insetBy(dx: -band, dy: -band)
        if shadow > 0.01 {
            glassShadow(lens > 0.5 ? rect : outer, radius: lens > 0.5 ? radius : radius + band, dark: true,
                        strength: shadow)
        }
        if lens < 1 {
            // 두께 = 막대 굵기의 절반 × 굴절 강도 설정(100% 면 예전과 같다)
            if let edge = glassSource?.edge(rect, ring: true, width: band, cornerRadius: radius, tint: color,
                                            tintAlpha: 0.3, thickness: band / 2 * Config.borderRefraction,
                                            cached: !moving) {
                NSImage(cgImage: edge.image, size: edge.frame.size).draw(
                    in: edge.frame, from: .zero, operation: .sourceOver, fraction: 1 - lens, respectFlipped: true,
                    hints: nil)
            } else {
                // 사진이 없으면 색을 옅게 칠한 띠 + 안팎 가장자리 빛
                NSGraphicsContext.current?.cgContext.setAlpha(1 - lens)
                let ring = NSBezierPath(roundedRect: outer, xRadius: radius + band, yRadius: radius + band)
                ring.append(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius))
                ring.windingRule = .evenOdd
                color.withAlphaComponent(0.35).setFill()
                ring.fill()
                rimLight(outer, radius: radius + band, strength: 1)
                rimLight(rect, radius: radius, strength: 0.6)
                NSGraphicsContext.current?.cgContext.setAlpha(1)
            }
        }
        if lens > 0 {
            // 속이 찬 작은 물방울: 볼록 렌즈처럼 아래를 키워 보인다
            let half = min(rect.width, rect.height) / 2
            if let drop = glassSource?.edge(rect, ring: false, width: half + 1, cornerRadius: half, tint: color,
                                            tintAlpha: 0.12, cached: false) {
                NSImage(cgImage: drop.image, size: drop.frame.size).draw(
                    in: drop.frame, from: .zero, operation: .sourceOver, fraction: lens, respectFlipped: true,
                    hints: nil)
            } else {
                color.withAlphaComponent(0.35 * lens).setFill()
                NSBezierPath(roundedRect: rect, xRadius: half, yRadius: half).fill()
                rimLight(rect, radius: half, strength: lens)
            }
        }
    }

    /// 둥근 사각형 가장자리에 위는 밝고 아래는 옅은 빛
    private static func rimLight(_ r: CGRect, radius: CGFloat, strength: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let white = { (a: CGFloat) in CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a * strength) }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerWidth: radius, cornerHeight: radius,
                           transform: nil))
        ctx.setLineWidth(1.5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        verticalGradient(ctx, [white(0.9), white(0.15), white(0.45)], from: r.minY, to: r.maxY)
        ctx.restoreGState()
    }

    static func box(_ rect: CGRect, color: NSColor? = nil, width: CGFloat, radius: CGFloat = 4) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: -width / 2, dy: -width / 2), xRadius: radius,
                                yRadius: radius)
        (color ?? theme.accent).setStroke()
        path.lineWidth = width
        path.stroke()
    }
}
