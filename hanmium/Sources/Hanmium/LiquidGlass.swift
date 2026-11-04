import AppKit
import CoreMedia
import Metal
import ScreenCaptureKit

/// 유리 라벨을 실제 유리처럼 그린다. https://kube.io/blog/liquid-glass-css-svg/ 의 모델을 따른다:
///
/// - 표면 높이: 볼록 스퀘어클 `y = (1 - (1 - x)^4)^(1/4)`. x 는 가장자리(0)에서 베젤 끝(1)까지,
///   베젤 안쪽은 평평하다.
/// - 굴절: 빛이 위에서 수직으로 들어온다고 보고 스넬 법칙(공기 1 → 유리 1.5)으로 꺾인 각을 구한다.
///   바닥(뒤 화면)에 닿는 자리는 `높이 × tan(입사각 - 굴절각)` 만큼 안쪽으로 밀린다.
///   그래서 가장자리에는 더 안쪽 화면이 끌려와 렌즈처럼 보인다.
/// - 가장자리 빛: 표면이 빛 쪽(왼쪽 위 -60°)을 향할수록 밝고, 맞은편 가장자리는 되비친 빛으로 약하게.
///
/// 뒤 화면 픽셀이 있어야 굴절을 계산할 수 있어서, 모드를 열 때 화면을 찍는다(화면 기록 권한).
/// 권한이 없으면 흐림 뷰(GlassBackdrop)만 깐다.
enum LiquidGlass {
    static let refractiveIndex: CGFloat = 1.5
    /// 빛이 오는 쪽(화면 좌표, 아래가 +y): -60° 왼쪽 위
    static let toLight = CGVector(dx: -0.5, dy: -0.866)
    static let saturation: CGFloat = 1.4
    /// 라벨 유리 두께(반지름 배수, 굴절 강도 100% 기준)와 굽은 가장자리 폭.
    /// 두꺼울수록 가장자리가 안쪽 화면을 더 끌어와 경계가 또렷하다.
    static let labelThickness: CGFloat = 1.6
    static let labelBezel: CGFloat = 0.95

    /// 가장자리에서 t(0~1) 만큼 들어온 자리의 굴절 이동 거리. 픽셀마다 삼각함수를 풀지 않게 미리 계산해 둔다.
    struct Profile {
        private let table: [CGFloat]

        init(bezel: CGFloat, thickness: CGFloat, samples: Int = 128) {
            table = (0..<samples).map { i in
                let u = 1 - CGFloat(i) / CGFloat(samples - 1)
                let base = max(1 - u * u * u * u, 1e-6)
                let height = thickness * pow(base, 0.25)
                let slope = thickness / max(bezel, 1e-3) * u * u * u * pow(base, -0.75)
                let incident = atan(slope)
                return height * tan(incident - asin(sin(incident) / refractiveIndex))
            }
        }

        func shift(_ t: CGFloat) -> CGFloat {
            let x = min(max(t, 0), 1) * CGFloat(table.count - 1)
            let i = Int(x)
            guard i + 1 < table.count else { return table[i] }
            let f = x - CGFloat(i)
            return table[i] * (1 - f) + table[i + 1] * f
        }
    }

    struct Look {
        let image: CGImage
        /// 뒤가 어두워서 글자를 밝게 써야 하는지
        let dark: Bool
    }

    /// rect(AX 좌표)의 알약 모양 유리를 snapshot 으로 그린 이미지. forceDark 면 배경과 상관없이 어둡게.
    static func render(_ rect: CGRect, from snap: ScreenSnapshot, forceDark: Bool) -> Look? {
        let s = snap.scale
        let w = Int((rect.width * s).rounded()), h = Int((rect.height * s).rounded())
        guard w > 4, h > 4 else { return nil }
        let radius = CGFloat(h) / 2
        let bezel = radius * labelBezel
        let refraction = Config.glassRefraction
        let profile = Profile(bezel: bezel, thickness: radius * labelThickness * refraction)
        let blur = Int((radius * 0.3 * Config.glassBlur).rounded())
        let tintAmount = Config.glassTint
        let specular = Config.glassSpecular

        // 1. 알약 + 여백(굴절로 바깥 픽셀까지 끌려오므로)만큼 잘라서 흐리게
        let margin = Int((radius * (1 + refraction)).rounded(.up)) + blur * 2 + 2
        let ox = Int(((rect.minX - snap.axFrame.minX) * s).rounded()) - margin
        let oy = Int(((rect.minY - snap.axFrame.minY) * s).rounded()) - margin
        let cw = w + margin * 2, ch = h + margin * 2
        // 굽은 가장자리는 선명한 화면을 굴절시켜야 휘어진 게 보인다. 흐린 화면을 휘면 티가 나지 않는다.
        let sharp = snap.crop(x: ox, y: oy, width: cw, height: ch)
        var crop = sharp
        if blur > 0 {
            boxBlur(&crop, cw, ch, radius: blur)
            boxBlur(&crop, cw, ch, radius: blur)
        }

        // 2. 밝기를 보고 글자·색조를 정한다 (가운데 평평한 부분)
        var lum: CGFloat = 0
        var n: CGFloat = 0
        for y in (margin + h / 4)..<(margin + h * 3 / 4) {
            for x in (margin + w / 4)..<(margin + w * 3 / 4) {
                let i = (y * cw + x) * 3
                lum += 0.2126 * CGFloat(crop[i]) + 0.7152 * CGFloat(crop[i + 1]) + 0.0722 * CGFloat(crop[i + 2])
                n += 1
            }
        }
        let dark = forceDark || (n > 0 && lum / n < 0.55)

        // 3. 픽셀마다 굴절·빛
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let px = CGFloat(x) + 0.5, py = CGFloat(y) + 0.5
                // 알약 = 가운데 가로 선분에서 radius 안쪽. 가장 가까운 선분 위 점 쪽이 안쪽 방향이다.
                let spineX = min(max(px, radius), CGFloat(w) - radius)
                let vx = spineX - px, vy = radius - py
                let dist = (vx * vx + vy * vy).squareRoot()
                let edge = radius - dist  // 가장자리에서 안쪽으로 떨어진 거리
                let coverage = min(max(edge + 0.5, 0), 1)
                guard coverage > 0 else { continue }
                let inward = dist > 1e-4 ? CGVector(dx: vx / dist, dy: vy / dist) : .zero

                var shift: CGFloat = 0
                var light: CGFloat = 0
                var crisp: CGFloat = 0  // 1 이면 선명한 화면, 0 이면 흐린 화면
                if edge < bezel {
                    let t = max(edge, 0) / bezel
                    let u = 1 - t
                    shift = profile.shift(t)
                    // 바깥을 향하는 면이 빛 쪽이면 밝게, 반대쪽은 되비친 빛으로 약하게
                    let facing = -(inward.dx * toLight.dx + inward.dy * toLight.dy)
                    light = u * u * u * (facing > 0 ? facing * facing : 0.4 * facing * facing)
                    crisp = min(1, u * 1.6)
                }

                let sx = CGFloat(margin) + px + inward.dx * shift, sy = CGFloat(margin) + py + inward.dy * shift
                var (r, g, b) = sample(crop, cw, ch, sx, sy)
                if crisp > 0 {
                    let (cr, cg, cb) = sample(sharp, cw, ch, sx, sy)
                    r += (cr - r) * crisp
                    g += (cg - g) * crisp
                    b += (cb - b) * crisp
                }
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r = l + (r - l) * saturation
                g = l + (g - l) * saturation
                b = l + (b - l) * saturation
                // 색 진하기: 밝은 유리는 흰빛을, 어두운 유리는 그늘을 덮는다
                if dark {
                    let k = max(0, 1 - 0.38 * tintAmount)
                    r *= k; g *= k; b *= k
                } else {
                    let k = min(1, 0.2 * tintAmount)
                    r = r * (1 - k) + k; g = g * (1 - k) + k; b = b * (1 - k) + k
                }
                let spec = light * (dark ? 0.7 : 0.95) * specular
                r += spec; g += spec; b += spec

                let i = (y * w + x) * 4
                out[i] = UInt8(min(max(r, 0), 1) * coverage * 255)
                out[i + 1] = UInt8(min(max(g, 0), 1) * coverage * 255)
                out[i + 2] = UInt8(min(max(b, 0), 1) * coverage * 255)
                out[i + 3] = UInt8(coverage * 255)
            }
        }
        guard let image = makeImage(out, w, h) else { return nil }
        return Look(image: image, dark: dark)
    }

    /// 스크롤 영역용 유리. rect(AX 좌표)는 영역이고, 돌려주는 이미지는 frame 에 그린다.
    /// - ring == false (판): 영역 위에 얹은 유리판. 가장자리 width 폭만 굴절시켜 그리고 안쪽은 비워 둔다.
    ///   안쪽은 살아 있는 화면 위에 색만 덮어서(Draw.glassArea) 지난 사진이 보이지 않게 한다.
    /// - ring == true (막대): 영역 둘레 바깥을 감싸는 width 굵기의 둥근 유리 막대. 바깥에만 있어서
    ///   스크롤하는 내용이 막대에 비치지 않는다.
    static func renderEdge(_ rect: CGRect, ring: Bool, width: CGFloat, cornerRadius: CGFloat, tint: NSColor,
                           tintAlpha: CGFloat, saturation: CGFloat = saturation, specular: CGFloat? = nil,
                           fill: CGFloat = 0, thickness: CGFloat? = nil,
                           from snap: ScreenSnapshot) -> (image: CGImage, frame: CGRect)? {
        let s = snap.scale
        let frame = ring ? rect.insetBy(dx: -width, dy: -width) : rect
        let w = Int((frame.width * s).rounded()), h = Int((frame.height * s).rounded())
        guard w > 4, h > 4, let tc = tint.usingColorSpace(.sRGB) else { return nil }
        let tr = tc.redComponent, tg = tc.greenComponent, tb = tc.blueComponent
        // 영역 사각형(픽셀, frame 기준)
        let inset = ring ? width * s : 0
        let cx = CGFloat(w) / 2, cy = CGFloat(h) / 2
        let radius = cornerRadius * s
        let hx = CGFloat(w) / 2 - inset - radius, hy = CGFloat(h) / 2 - inset - radius
        let bezel = ring ? width * s / 2 : width * s
        let profile = Profile(bezel: bezel, thickness: thickness.map { $0 * s } ?? bezel)
        // 사진에서 frame 왼쪽 위 픽셀
        let gx = (frame.minX - snap.axFrame.minX) * s, gy = (frame.minY - snap.axFrame.minY) * s
        // 가장자리 띠 바깥은 계산하지 않는다
        let m = Int((radius + (ring ? width * s : bezel)).rounded(.up)) + 2

        var out = [UInt8](repeating: 0, count: w * h * 4)
        snap.withPixels { src in
            func shade(_ x: Int, _ y: Int) {
                let px = CGFloat(x) + 0.5, py = CGFloat(y) + 0.5
                let dx = px - cx, dy = py - cy
                let qx = abs(dx) - hx, qy = abs(dy) - hy
                let ox = max(qx, 0), oy = max(qy, 0)
                let sd = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - radius
                // 바깥쪽 법선
                var nx: CGFloat = 0, ny: CGFloat = 0
                if qx > 0, qy > 0 {
                    let l = (qx * qx + qy * qy).squareRoot()
                    nx = (dx < 0 ? -qx : qx) / l
                    ny = (dy < 0 ? -qy : qy) / l
                } else if qx > qy {
                    nx = dx < 0 ? -1 : 1
                } else {
                    ny = dy < 0 ? -1 : 1
                }
                let edge: CGFloat
                var ix: CGFloat, iy: CGFloat  // 안쪽(유리가 두꺼워지는 쪽) 방향
                if ring {
                    let off = sd - bezel  // 막대 가운데 선에서 떨어진 거리
                    edge = bezel - abs(off)
                    (ix, iy) = off > 0 ? (-nx, -ny) : (nx, ny)
                } else {
                    edge = -sd
                    (ix, iy) = (-nx, -ny)
                    if edge >= bezel { return }
                }
                let coverage = min(max(edge + 0.5, 0), 1)
                guard coverage > 0 else { return }
                let t = min(max(edge, 0) / bezel, 1)
                let u = 1 - t
                let shift = profile.shift(t)
                let facing = -(ix * toLight.dx + iy * toLight.dy)
                let light = u * u * u * (facing > 0 ? facing * facing : 0.4 * facing * facing)

                var (r, g, b) = snap.sample(src, gx + px + ix * shift, gy + py + iy * shift)
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r = l + (r - l) * saturation
                g = l + (g - l) * saturation
                b = l + (b - l) * saturation
                r = r * (1 - tintAlpha) + tr * tintAlpha
                g = g * (1 - tintAlpha) + tg * tintAlpha
                b = b * (1 - tintAlpha) + tb * tintAlpha
                // 칠하기는 바깥 가장자리 0 에서 안쪽으로 서서히 (경계에 단차가 생기지 않게)
                let tt = min(1, t / 0.4)
                let k = fill * tt * tt * (3 - 2 * tt)
                r = r * (1 - k) + tr * k; g = g * (1 - k) + tg * k; b = b * (1 - k) + tb * k
                let spec = light * (specular ?? (ring ? 0.9 : 0.75))
                r += spec; g += spec; b += spec
                let i = (y * w + x) * 4
                out[i] = UInt8(min(max(r, 0), 1) * coverage * 255)
                out[i + 1] = UInt8(min(max(g, 0), 1) * coverage * 255)
                out[i + 2] = UInt8(min(max(b, 0), 1) * coverage * 255)
                out[i + 3] = UInt8(coverage * 255)
            }
            for y in 0..<h {
                if y < m || y >= h - m {
                    for x in 0..<w { shade(x, y) }
                } else {
                    for x in 0..<min(m, w) { shade(x, y) }
                    for x in max(w - m, m)..<w { shade(x, y) }
                }
            }
        }
        guard let image = makeImage(out, w, h) else { return nil }
        return (image, frame)
    }

    private static func makeImage(_ rgba: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func sample(_ p: [Float], _ w: Int, _ h: Int, _ x: CGFloat, _ y: CGFloat)
        -> (CGFloat, CGFloat, CGFloat) {
        let fx = min(max(x - 0.5, 0), CGFloat(w - 1)), fy = min(max(y - 0.5, 0), CGFloat(h - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
        let ax = Float(fx - CGFloat(x0)), ay = Float(fy - CGFloat(y0))
        func at(_ x: Int, _ y: Int, _ c: Int) -> Float { p[(y * w + x) * 3 + c] }
        func mix(_ c: Int) -> CGFloat {
            let top = at(x0, y0, c) * (1 - ax) + at(x1, y0, c) * ax
            let bottom = at(x0, y1, c) * (1 - ax) + at(x1, y1, c) * ax
            return CGFloat(top * (1 - ay) + bottom * ay)
        }
        return (mix(0), mix(1), mix(2))
    }

    /// RGB float 버퍼를 가로·세로로 한 번씩 평균낸다 (두 번 돌리면 가우시안에 가깝다)
    private static func boxBlur(_ p: inout [Float], _ w: Int, _ h: Int, radius: Int) {
        var tmp = p
        let span = Float(radius * 2 + 1)
        for y in 0..<h {
            for c in 0..<3 {
                var sum: Float = 0
                for k in -radius...radius { sum += p[(y * w + min(max(k, 0), w - 1)) * 3 + c] }
                for x in 0..<w {
                    tmp[(y * w + x) * 3 + c] = sum / span
                    sum += p[(y * w + min(x + radius + 1, w - 1)) * 3 + c] - p[(y * w + max(x - radius, 0)) * 3 + c]
                }
            }
        }
        for x in 0..<w {
            for c in 0..<3 {
                var sum: Float = 0
                for k in -radius...radius { sum += tmp[(min(max(k, 0), h - 1) * w + x) * 3 + c] }
                for y in 0..<h {
                    p[(y * w + x) * 3 + c] = sum / span
                    sum += tmp[(min(y + radius + 1, h - 1) * w + x) * 3 + c] - tmp[(max(y - radius, 0) * w + x) * 3 + c]
                }
            }
        }
    }
}

/// 한 화면을 찍은 픽셀 (8비트 4채널, 위에서 아래로). 연속 캡처 프레임은 BGRA 순서 그대로 둔다.
final class ScreenSnapshot {
    let axFrame: CGRect
    /// 픽셀 / 포인트
    let scale: CGFloat
    let width: Int
    let height: Int
    let bgra: Bool
    private let pixels: [UInt8]
    private var red: Int { bgra ? 2 : 0 }
    private var blue: Int { bgra ? 0 : 2 }

    /// 연속 캡처(SCStream) 프레임에서. 다음 프레임에 버퍼가 다시 쓰이므로 복사해 둔다(1920x1080 에 1~2ms).
    init?(pixelBuffer pb: CVPixelBuffer, axFrame: CGRect) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { dst in
            for row in 0..<height {
                memcpy(dst.baseAddress! + row * width * 4, base + row * rowBytes, width * 4)
            }
        }
        self.width = width
        self.height = height
        self.axFrame = axFrame
        scale = CGFloat(width) / axFrame.width
        bgra = true
        pixels = buffer
    }

    init?(image: CGImage, axFrame: CGRect) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        self.axFrame = axFrame
        scale = CGFloat(width) / axFrame.width
        bgra = false
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        pixels = buffer
    }

    func withPixels<T>(_ body: (UnsafeBufferPointer<UInt8>) -> T) -> T { pixels.withUnsafeBufferPointer(body) }

    /// GPU 로 그릴 때 쓰는 텍스처 (처음 쓸 때 한 번 올린다)
    private(set) lazy var gpuTexture: MTLTexture? = pixels.withUnsafeBytes { raw in
        raw.baseAddress.flatMap { GlassGPU.shared?.texture(width: width, height: height, bgra: bgra, bytes: $0) }
    }

    /// 사진 픽셀 좌표(가운데가 +0.5)에서 RGB 0~1 를 선형 보간으로. 화면 밖은 가장자리 픽셀.
    func sample(_ src: UnsafeBufferPointer<UInt8>, _ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let fx = min(max(x - 0.5, 0), CGFloat(width - 1)), fy = min(max(y - 0.5, 0), CGFloat(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let ax = fx - CGFloat(x0), ay = fy - CGFloat(y0)
        func mix(_ c: Int) -> CGFloat {
            let a = CGFloat(src[(y0 * width + x0) * 4 + c]), b = CGFloat(src[(y0 * width + x1) * 4 + c])
            let d = CGFloat(src[(y1 * width + x0) * 4 + c]), e = CGFloat(src[(y1 * width + x1) * 4 + c])
            return ((a * (1 - ax) + b * ax) * (1 - ay) + (d * (1 - ax) + e * ax) * ay) / 255
        }
        return (mix(red), mix(1), mix(blue))
    }

    /// 픽셀 좌표 사각형을 RGB 0~1 float 로. 화면 밖은 가장자리 픽셀로 채운다.
    func crop(x: Int, y: Int, width w: Int, height h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h * 3)
        pixels.withUnsafeBufferPointer { src in
            for row in 0..<h {
                let sy = min(max(y + row, 0), height - 1)
                for col in 0..<w {
                    let sx = min(max(x + col, 0), width - 1)
                    let i = (sy * width + sx) * 4, o = (row * w + col) * 3
                    out[o] = Float(src[i + red]) / 255
                    out[o + 1] = Float(src[i + 1]) / 255
                    out[o + 2] = Float(src[i + blue]) / 255
                }
            }
        }
        return out
    }
}

/// 유리 라벨이 굴절시킬 화면 사진. 모드를 열 때마다 새로 찍고, 다 찍히면 알린다.
enum GlassSnapshots {
    static let didChange = Notification.Name("HanmiumGlassSnapshotsDidChange")
    private(set) static var current: [ScreenSnapshot] = []
    private static var generation = 0

    /// 유리 라벨이나 유리 스크롤 테두리·영역을 쓰는지
    static var usesGlass: Bool {
        Config.labelTheme.glass != nil || Config.scrollBorderStyle == .glass
            || (Config.inactiveAreaShown && Config.inactiveAreaStyle == .glass)
    }

    static var wanted: Bool { usesGlass && CGPreflightScreenCaptureAccess() }

    /// 새 모드를 열 때: 지난 사진은 버리고 찍는다. 오버레이가 뜨기 전이라 Hanmium 창은 찍히지 않는다.
    static func retake() {
        current = []
        capture(excluding: [])
    }

    /// 떠 있는 오버레이 창은 빼고 다시 찍는다 (스크롤해서 뒤 화면이 바뀌었을 때)
    static func refresh(excluding windows: [CGWindowID]) {
        capture(excluding: windows)
    }

    private static var following = false

    // MARK: 연속 캡처 (스크롤 모드 동안)

    private static var stream: ScreenStream?

    /// 스크롤 모드를 열 때: 오버레이 창은 빼고 화면을 계속 받는다. 프레임은 wantLive 로 바란 동안만 사진으로 바꾼다.
    static func startStream(excluding windows: [CGWindowID]) {
        guard wanted, stream == nil else { return }
        let s = ScreenStream()
        stream = s
        s.start(screens: screenInfo(), excluding: windows)
    }

    static func stopStream() {
        stream?.stop()
        stream = nil
    }

    /// 지금부터 seconds 동안 들어오는 프레임을 굴절에 바로 쓴다 (물방울이 움직이거나 스크롤하는 동안).
    /// 연속 캡처가 없으면 false — 그때는 한 장씩 찍는 쪽을 쓴다.
    @discardableResult
    static func wantLive(for seconds: Double) -> Bool {
        guard let stream, stream.isRunning else { return false }
        stream.wantFrames(until: CACurrentMediaTime() + seconds)
        return true
    }

    /// 연속 캡처에서 새 사진이 왔을 때 (메인 스레드)
    fileprivate static func receive(_ snap: ScreenSnapshot) {
        generation += 1
        current = current.filter { $0.axFrame != snap.axFrame } + [snap]
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// 물방울이 움직이는 동안 뒤 화면을 쉬지 않고 다시 찍어서 굴절이 실시간으로 바뀌게 한다.
    /// 창 목록은 처음에 한 번만 받아 두고(오버레이 창을 빼는 필터), 찍기만 되풀이한다. keepGoing 이 false 면 멈춘다.
    static func follow(excluding windows: [CGWindowID], while keepGoing: @escaping () -> Bool) {
        guard wanted, !following, #available(macOS 14.0, *) else { return }
        following = true
        let screens = screenInfo()
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            let shots = screens.compactMap { id, axFrame, scale -> (SCContentFilter, SCStreamConfiguration, CGRect)? in
                guard let content, let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
                let config = SCStreamConfiguration()
                config.width = Int(axFrame.width * scale)
                config.height = Int(axFrame.height * scale)
                config.showsCursor = false
                return (excludingHanmium(display, in: content, windows: windows), config, axFrame)
            }
            DispatchQueue.main.async {
                func loop() {
                    guard keepGoing(), !shots.isEmpty else {
                        following = false
                        return
                    }
                    generation += 1
                    let gen = generation
                    let group = DispatchGroup()
                    let lock = NSLock()
                    var snaps: [ScreenSnapshot] = []
                    for (filter, config, axFrame) in shots {
                        group.enter()
                        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                            if let image, let snap = ScreenSnapshot(image: image, axFrame: axFrame) {
                                lock.lock()
                                snaps.append(snap)
                                lock.unlock()
                            }
                            group.leave()
                        }
                    }
                    group.notify(queue: .main) {
                        if gen == generation, !snaps.isEmpty {
                            current = snaps
                            NotificationCenter.default.post(name: didChange, object: nil)
                        }
                        loop()
                    }
                }
                loop()
            }
        }
    }

    /// Hanmium 자기 창(오버레이·설정 창)을 뺀 화면 필터. 오버레이를 찍으면 유리가 자기 자신을 다시 굴절시켜
    /// 덮은 색·채도 보정이 쌓이고(보라색으로 수렴) 화면이 흔들린다. 막 띄운 오버레이 창은 창 목록에 아직 없을 수 있어서
    /// 창 번호가 아니라 앱으로 뺀다. 앱은 메뉴 막대 아이콘 때문에 늘 목록에 있다.
    static func excludingHanmium(_ display: SCDisplay, in content: SCShareableContent,
                                 windows: [CGWindowID]) -> SCContentFilter {
        if let me = content.applications.first(where: { $0.processID == getpid() }) {
            return SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: content.windows.filter { windows.contains($0.windowID) })
    }

    private static func screenInfo() -> [(CGDirectDisplayID, CGRect, CGFloat)] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (id, Screens.axFrame(screen), screen.backingScaleFactor)
        }
    }

    private static func capture(excluding windows: [CGWindowID]) {
        guard wanted, #available(macOS 14.0, *) else { return }
        generation += 1
        let gen = generation
        let screens = screenInfo()
        let finish = { (snaps: [ScreenSnapshot]) in
            guard gen == generation, !snaps.isEmpty else { return }
            Timing.mark("화면 캡처 도착")
            current = snaps
            NotificationCenter.default.post(name: didChange, object: nil)
        }
        // 뺄 창이 없으면 화면 영역을 바로 찍는다 (창 목록을 받는 단계가 없어서 빠르다)
        if windows.isEmpty, #available(macOS 15.2, *) {
            let group = DispatchGroup()
            let lock = NSLock()
            var snaps: [ScreenSnapshot] = []
            for (_, axFrame, _) in screens {
                group.enter()
                SCScreenshotManager.captureImage(in: axFrame) { image, _ in
                    if let image, let snap = ScreenSnapshot(image: image, axFrame: axFrame) {
                        _ = snap.gpuTexture  // GPU 로 올리는 것도 여기(백그라운드)서 끝내 둔다
                        lock.lock()
                        snaps.append(snap)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { finish(snaps) }
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, _ in
            guard let content else { return }
            let group = DispatchGroup()
            let lock = NSLock()
            var snaps: [ScreenSnapshot] = []
            for (id, axFrame, scale) in screens {
                guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(axFrame.width * scale)
                config.height = Int(axFrame.height * scale)
                config.showsCursor = false
                group.enter()
                SCScreenshotManager.captureImage(
                    contentFilter: excludingHanmium(display, in: content, windows: windows), configuration: config
                ) { image, _ in
                    if let image, let snap = ScreenSnapshot(image: image, axFrame: axFrame) {
                        _ = snap.gpuTexture  // GPU 로 올리는 것도 여기(백그라운드)서 끝내 둔다
                        lock.lock()
                        snaps.append(snap)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) { finish(snaps) }
        }
    }
}

/// 한 화면 캔버스가 쓰는 사진과, 알약 모양별로 그려둔 유리 (글자를 칠 때마다 다시 계산하지 않게)
final class GlassSource {
    let snapshot: ScreenSnapshot
    private var cache: [String: LiquidGlass.Look] = [:]

    init(_ snapshot: ScreenSnapshot) { self.snapshot = snapshot }

    private var edgeCache: [String: (image: CGImage, frame: CGRect)] = [:]

    private func key(_ rect: CGRect, _ forceDark: Bool) -> String {
        "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height),\(forceDark)"
    }

    func look(_ rect: CGRect, forceDark: Bool) -> LiquidGlass.Look? {
        let key = key(rect, forceDark)
        if let hit = cache[key] { return hit }
        prepare([(rect, forceDark)])
        if let hit = cache[key] { return hit }
        let look = LiquidGlass.render(rect, from: snapshot, forceDark: forceDark)
        cache[key] = look
        return look
    }

    /// 아직 그리지 않은 라벨들을 GPU 로 한꺼번에 그려 둔다 (GPU 를 못 쓰면 아무것도 안 한다)
    func prepare(_ jobs: [(rect: CGRect, forceDark: Bool)]) {
        guard let gpu = GlassGPU.shared, let texture = snapshot.gpuTexture else { return }
        let missing = jobs.filter { cache[key($0.rect, $0.forceDark)] == nil }
        guard !missing.isEmpty else { return }
        let s = snapshot.scale, origin = snapshot.axFrame.origin
        let pixelRects = missing.map { job in
            (rect: CGRect(x: ((job.rect.minX - origin.x) * s).rounded(), y: ((job.rect.minY - origin.y) * s).rounded(),
                          width: (job.rect.width * s).rounded(), height: (job.rect.height * s).rounded()),
             forceDark: job.forceDark)
        }
        for (job, look) in zip(missing, gpu.renderPills(pixelRects, from: texture)) {
            if let look { cache[key(job.rect, job.forceDark)] = look }
        }
    }

    /// saturation: 굴절된 뒤 화면의 채도 배율. 1 이면 뒤 색 그대로(고르지 않은 영역 — 색이 바뀌어 보이지 않게).
    func edge(_ rect: CGRect, ring: Bool, width: CGFloat, cornerRadius: CGFloat, tint: NSColor,
              tintAlpha: CGFloat, saturation: CGFloat = LiquidGlass.saturation, specular: CGFloat? = nil,
              fill: CGFloat = 0, thickness: CGFloat? = nil,
              cached: Bool = true) -> (image: CGImage, frame: CGRect)? {
        let spec = specular ?? (ring ? 0.9 : 0.75)
        let make = {
            self.gpuEdge(rect, ring: ring, width: width, cornerRadius: cornerRadius, tint: tint, tintAlpha: tintAlpha,
                         saturation: saturation, specular: spec, fill: fill, thickness: thickness)
                ?? LiquidGlass.renderEdge(rect, ring: ring, width: width, cornerRadius: cornerRadius, tint: tint,
                                          tintAlpha: tintAlpha, saturation: saturation, specular: spec, fill: fill,
                                          thickness: thickness, from: self.snapshot)
        }
        guard cached else { return make() }
        let key = "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height),\(ring),\(width),\(cornerRadius),"
            + "\(tint.hexString ?? ""),\(tintAlpha),\(saturation),\(spec),\(fill),\(thickness ?? -1)"
        if let hit = edgeCache[key] { return hit }
        let made = make()
        edgeCache[key] = made
        return made
    }

    /// LiquidGlass.renderEdge 와 같은 값을 사진 픽셀 기준으로 계산해 GPU 로 그린다
    private func gpuEdge(_ rect: CGRect, ring: Bool, width: CGFloat, cornerRadius: CGFloat, tint: NSColor,
                         tintAlpha: CGFloat, saturation: CGFloat, specular: CGFloat, fill: CGFloat,
                         thickness: CGFloat?) -> (image: CGImage, frame: CGRect)? {
        guard let gpu = GlassGPU.shared, let texture = snapshot.gpuTexture, let tc = tint.usingColorSpace(.sRGB)
        else { return nil }
        let s = snapshot.scale
        let frame = ring ? rect.insetBy(dx: -width, dy: -width) : rect
        let w = Int((frame.width * s).rounded()), h = Int((frame.height * s).rounded())
        guard w > 4, h > 4 else { return nil }
        let inset = ring ? width * s : 0
        let radius = cornerRadius * s
        let half = CGSize(width: CGFloat(w) / 2 - inset - radius, height: CGFloat(h) / 2 - inset - radius)
        let origin = CGPoint(x: (frame.minX - snapshot.axFrame.minX) * s, y: (frame.minY - snapshot.axFrame.minY) * s)
        return gpu.renderEdge(frameOrigin: origin, size: (w, h), half: half, radius: radius,
                              bezel: ring ? width * s / 2 : width * s, ring: ring,
                              tint: (tc.redComponent, tc.greenComponent, tc.blueComponent), tintAlpha: tintAlpha,
                              saturation: saturation, specular: specular, fill: fill,
                              thickness: (thickness ?? (ring ? width / 2 : width)) * s, from: texture).map { ($0, frame) }
    }
}

/// 화면을 계속 받는다(SCStream, 초당 최대 30장). 프레임은 바랄 때만 사진으로 바꾸고, 그 일은 받는 큐에서 해서
/// 메인 스레드를 막지 않는다. 한 장씩 찍기(창 목록 받기 + 캡처 40~60ms)보다 훨씬 빠르게 뒤 화면이 바뀐다.
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "Hanmium.stream", qos: .userInteractive)
    private let lock = NSLock()
    private var streams: [SCStream] = []
    private var frames: [ObjectIdentifier: CGRect] = [:]
    private var until: CFTimeInterval = 0
    private var latest: [ObjectIdentifier: CVPixelBuffer] = [:]
    private(set) var isRunning = false

    func start(screens: [(CGDirectDisplayID, CGRect, CGFloat)], excluding windows: [CGWindowID], attempt: Int = 0) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self, let content else { return }
            let byApp = content.applications.contains { $0.processID == getpid() }
            let byWindow = content.windows.contains { windows.contains($0.windowID) }
            // Hanmium 창을 뺄 수 없으면 찍지 않는다(자기 자신을 굴절시킨다). 잠깐 뒤에 한 번 더 해 본다.
            guard byApp || byWindow else {
                if attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.start(screens: screens, excluding: windows, attempt: attempt + 1)
                    }
                } else {
                    DispatchQueue.main.async { Log.write("연속 캡처 안 함: Hanmium 창을 화면 목록에서 찾지 못함") }
                }
                return
            }
            DispatchQueue.main.async {
                Log.write("연속 캡처 시작: Hanmium 창 빼기 \(byApp ? "앱 단위" : "창 번호 단위(앱을 목록에서 못 찾음)")")
            }
            for (id, axFrame, scale) in screens {
                guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }
                let config = SCStreamConfiguration()
                config.width = Int(axFrame.width * scale)
                config.height = Int(axFrame.height * scale)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.queueDepth = 3
                config.showsCursor = false
                let stream = SCStream(filter: GlassSnapshots.excludingHanmium(display, in: content, windows: windows),
                                      configuration: config, delegate: self)
                guard (try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)) != nil else { continue }
                lock.lock()
                streams.append(stream)
                frames[ObjectIdentifier(stream)] = axFrame
                lock.unlock()
                stream.startCapture { [weak self] error in
                    if error == nil { self?.isRunning = true }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let all = streams
        streams.removeAll()
        latest.removeAll()
        lock.unlock()
        isRunning = false
        for s in all { s.stopCapture(completionHandler: nil) }
    }

    /// 그때까지 들어오는 프레임을 사진으로 바꾼다. 막 바라기 시작했으면 마지막으로 받은 프레임부터 바로 쓴다.
    func wantFrames(until time: CFTimeInterval) {
        lock.lock()
        let wasIdle = until < CACurrentMediaTime()
        until = max(until, time)
        let pending = wasIdle ? latest : [:]
        lock.unlock()
        for (id, pb) in pending { queue.async { self.deliver(pb, from: id) } }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                  as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let id = ObjectIdentifier(stream)
        lock.lock()
        latest[id] = pb
        let live = until >= CACurrentMediaTime()
        lock.unlock()
        if live { deliver(pb, from: id) }
    }

    private func deliver(_ pb: CVPixelBuffer, from id: ObjectIdentifier) {
        lock.lock()
        let axFrame = frames[id]
        lock.unlock()
        guard let axFrame, let snap = ScreenSnapshot(pixelBuffer: pb, axFrame: axFrame) else { return }
        _ = snap.gpuTexture  // GPU 로 올리는 것도 여기서 끝내 둔다
        DispatchQueue.main.async { GlassSnapshots.receive(snap) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        isRunning = false
    }
}
