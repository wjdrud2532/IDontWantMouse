import AppKit
import Metal

/// 유리 굴절을 GPU(Metal)로 계산한다. 계산식은 LiquidGlass(CPU)와 같다.
/// Command Line Tools 에는 Metal 컴파일러가 없어서 셰이더 소스를 실행 중에 컴파일한다(처음 한 번, 수십 ms).
/// GPU 를 쓸 수 없으면 shared 가 nil 이고, 그때는 CPU 로 그린다.
///
/// CPU 로는 라벨 250개에 약 125ms, 큰 영역 유리 막대 한 장에 30~70ms 가 들었다.
/// 라벨은 한 장(아틀라스)에 한꺼번에 그려 한 번에 읽어 오고, 영역 유리는 한 번의 실행으로 그린다.
final class GlassGPU {
    static let shared: GlassGPU? = GlassGPU()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let luma: MTLComputePipelineState
    private let pill: MTLComputePipelineState
    private let edge: MTLComputePipelineState
    private let hole: MTLComputePipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let luma = library.makeFunction(name: "pillLuma").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let pill = library.makeFunction(name: "pillGlass").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let edge = library.makeFunction(name: "edgeGlass").flatMap({ try? device.makeComputePipelineState(function: $0) }),
              let hole = library.makeFunction(name: "holeGlass").flatMap({ try? device.makeComputePipelineState(function: $0) })
        else { return nil }
        self.device = device
        self.queue = queue
        self.luma = luma
        self.pill = pill
        self.edge = edge
        self.hole = hole
    }

    /// 화면 사진을 GPU 텍스처로 올린다 (사진마다 한 번, 1920x1080 에 1~2ms)
    func texture(width: Int, height: Int, bgra: Bool, bytes: UnsafeRawPointer) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: bgra ? .bgra8Unorm : .rgba8Unorm,
                                                            width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return tex
    }

    // MARK: 라벨

    /// 셰이더의 Pill 과 같은 배치(float 16개)
    struct PillJob {
        var originX: Float, originY: Float, width: Float, height: Float
        var atlasX: Float, atlasY: Float, radius: Float, bezel: Float
        var thickness: Float, blur: Float, tint: Float, specular: Float
        var saturation: Float, forceDark: Float, power: Float, pad1: Float = 0
    }

    /// 라벨 여러 개를 한 번에 그린다. rects 는 사진 픽셀 좌표. 결과는 rects 와 같은 순서.
    func renderPills(_ rects: [(rect: CGRect, forceDark: Bool)], from source: MTLTexture) -> [LiquidGlass.Look?] {
        guard !rects.isEmpty else { return [] }
        let refraction = Float(Config.glassRefraction), blurAmount = Float(Config.glassBlur)
        let tint = Float(Config.glassTint), specular = Float(Config.glassSpecular)
        // 아틀라스에 왼쪽부터 줄지어 놓는다
        let atlasWidth = 2048
        var x = 0, y = 0, rowHeight = 0
        var jobs: [PillJob] = []
        var places: [CGRect] = []
        for (r, dark) in rects {
            let w = Int(r.width.rounded()), h = Int(r.height.rounded())
            if x + w > atlasWidth {
                x = 0
                y += rowHeight + 1
                rowHeight = 0
            }
            places.append(CGRect(x: x, y: y, width: w, height: h))
            let radius = Float(h) / 2
            jobs.append(PillJob(originX: Float(r.minX), originY: Float(r.minY), width: Float(w), height: Float(h),
                                atlasX: Float(x), atlasY: Float(y), radius: radius,
                                bezel: radius * Float(LiquidGlass.labelBezel),
                                thickness: radius * Float(LiquidGlass.labelThickness) * refraction,
                                blur: (radius * 0.3 * blurAmount).rounded(), tint: tint, specular: specular,
                                saturation: Float(LiquidGlass.saturation), forceDark: dark ? 1 : 0,
                                power: Float(LiquidGlass.labelPower)))
            x += w + 1
            rowHeight = max(rowHeight, h)
        }
        let atlasHeight = y + rowHeight
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: atlasWidth,
                                                            height: max(atlasHeight, 1), mipmapped: false)
        desc.usage = .shaderWrite
        desc.storageMode = .shared
        guard let atlas = device.makeTexture(descriptor: desc),
              let jobBuffer = device.makeBuffer(bytes: jobs, length: MemoryLayout<PillJob>.stride * jobs.count),
              let lumBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride * jobs.count, options: .storageModeShared),
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder()
        else { return rects.map { _ in nil } }

        // 1) 라벨마다 가운데 밝기 → 2) 라벨 그리기
        enc.setComputePipelineState(luma)
        enc.setTexture(source, index: 0)
        enc.setBuffer(jobBuffer, offset: 0, index: 0)
        enc.setBuffer(lumBuffer, offset: 0, index: 1)
        enc.dispatchThreads(MTLSize(width: jobs.count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(64, jobs.count), height: 1, depth: 1))
        enc.setComputePipelineState(pill)
        enc.setTexture(source, index: 0)
        enc.setTexture(atlas, index: 1)
        enc.setBuffer(jobBuffer, offset: 0, index: 0)
        enc.setBuffer(lumBuffer, offset: 0, index: 1)
        for (i, job) in jobs.enumerated() {
            var index = UInt32(i)
            enc.setBytes(&index, length: 4, index: 2)
            enc.dispatchThreads(MTLSize(width: Int(job.width), height: Int(job.height), depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        guard let image = Self.readImage(atlas, width: atlasWidth, height: atlasHeight) else { return rects.map { _ in nil } }
        let lum = lumBuffer.contents().bindMemory(to: Float.self, capacity: jobs.count)
        return places.enumerated().map { i, place in
            image.cropping(to: place).map { LiquidGlass.Look(image: $0, dark: rects[i].forceDark || lum[i] < 0.55) }
        }
    }

    // MARK: 영역 (막대·판)

    /// 셰이더의 Edge 와 같은 배치(float 16개)
    struct EdgeJob {
        var originX: Float, originY: Float, width: Float, height: Float
        var halfX: Float, halfY: Float, radius: Float, bezel: Float
        var ring: Float, tintR: Float, tintG: Float, tintB: Float
        var tintAlpha: Float, saturation: Float, specular: Float, fill: Float
        var thickness: Float, power: Float, rim: Float = 0, dome: Float = 0
    }

    /// LiquidGlass.renderEdge 와 같은 그림을 GPU 로. frame·크기는 사진 픽셀 기준으로 계산해 넘긴다.
    func renderEdge(frameOrigin: CGPoint, size: (Int, Int), half: CGSize, radius: CGFloat, bezel: CGFloat, ring: Bool,
                    tint: (CGFloat, CGFloat, CGFloat), tintAlpha: CGFloat, saturation: CGFloat, specular: CGFloat,
                    fill: CGFloat, thickness: CGFloat, power: CGFloat, rim: CGFloat = 0, dome: Bool = false,
                    from source: MTLTexture) -> CGImage? {
        let (w, h) = size
        var job = EdgeJob(originX: Float(frameOrigin.x), originY: Float(frameOrigin.y), width: Float(w), height: Float(h),
                          halfX: Float(half.width), halfY: Float(half.height), radius: Float(radius), bezel: Float(bezel),
                          ring: ring ? 1 : 0, tintR: Float(tint.0), tintG: Float(tint.1), tintB: Float(tint.2),
                          tintAlpha: Float(tintAlpha), saturation: Float(saturation), specular: Float(specular),
                          fill: Float(fill), thickness: Float(thickness), power: Float(power), rim: Float(rim),
                          dome: dome ? 1 : 0)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderWrite
        desc.storageMode = .shared
        guard let out = device.makeTexture(descriptor: desc), let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(edge)
        enc.setTexture(source, index: 0)
        enc.setTexture(out, index: 1)
        enc.setBytes(&job, length: MemoryLayout<EdgeJob>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Self.readImage(out, width: w, height: h)
    }

    // MARK: 움직이는 테두리 모양을 뺀 유리판

    /// 셰이더의 Hole 과 같은 배치(float 24개)
    struct HoleJob {
        var paneX: Float, paneY: Float, paneW: Float, paneH: Float
        var paneRadius: Float, holeCX: Float, holeCY: Float, holeHX: Float
        var holeHY: Float, holeRadius: Float, bezel: Float, thickness: Float
        var power: Float, smooth: Float, tintAlpha: Float, saturation: Float
        var tintR: Float, tintG: Float, tintB: Float, specular: Float
        /// dome 이면 thickness 는 영역 전체 볼록렌즈 두께이고, hole 가장자리는 holeBezel·holeThickness 띠로 따로 휜다
        var rim: Float = 0, dome: Float = 0, holeBezel: Float = 0, holeThickness: Float = 0
    }

    /// 둥근 사각형(영역)에서 둥근 사각형(hole)을 뺀 모양의 유리판을 그린다. 값은 모두 사진 픽셀 기준이고 hole 은
    /// 영역 왼쪽 위 기준. 띠 안쪽은 굴절 없이 옅은 색(tintAlpha)만 칠해서 한 장에 담는다.
    func renderHole(_ job: HoleJob, from source: MTLTexture) -> CGImage? {
        let w = Int(job.paneW), h = Int(job.paneH)
        var job = job
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderWrite
        desc.storageMode = .shared
        guard w > 4, h > 4, let out = device.makeTexture(descriptor: desc), let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(hole)
        enc.setTexture(source, index: 0)
        enc.setTexture(out, index: 1)
        enc.setBytes(&job, length: MemoryLayout<HoleJob>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Self.readImage(out, width: w, height: h)
    }

    private static func readImage(_ tex: MTLTexture, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        tex.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: 셰이더

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Pill {
        float originX, originY, width, height;
        float atlasX, atlasY, radius, bezel;
        float thickness, blur, tint, specular;
        float saturation, forceDark, power, pad1;
    };

    struct Hole {
        float paneX, paneY, paneW, paneH;
        float paneRadius, holeCX, holeCY, holeHX;
        float holeHY, holeRadius, bezel, thickness;
        float power, smooth, tintAlpha, saturation;
        float tintR, tintG, tintB, specular;
        float rim, dome, holeBezel, holeThickness;
    };

    struct Edge {
        float originX, originY, width, height;
        float halfX, halfY, radius, bezel;
        float ring, tintR, tintG, tintB;
        float tintAlpha, saturation, specular, fill;
        float thickness, power, rim, dome;
    };

    constant float refractiveIndex = 1.5;
    constant float2 toLight = float2(-0.5, -0.866);
    constant float3 lumaWeights = float3(0.2126, 0.7152, 0.0722);
    constexpr sampler linearClamp(coord::pixel, filter::linear, address::clamp_to_edge);

    // 볼록 단면 u^p + (h/thickness)^p = 1 (p = 4 면 스퀘어클) + 스넬 법칙: 가장자리에서 t(0~1) 들어온 자리의 이동 거리
    float refractShift(float t, float bezel, float thickness, float p) {
        float u = 1.0 - t;
        float base = max(1.0 - pow(u, p), 1e-6);
        float height = thickness * pow(base, 1.0 / p);
        float slope = thickness / max(bezel, 1e-3) * pow(u, p - 1.0) * pow(base, 1.0 / p - 1.0);
        float incident = atan(slope);
        return height * tan(incident - asin(sin(incident) / refractiveIndex));
    }

    // 영역 전체를 덮는 볼록렌즈의 이동. d 는 영역 가운데 기준 위치, halfSize 는 영역 반 크기, k 는 가로·세로 세기.
    // 축마다 뒤 화면 자리 = 가운데 + d·(1 − k(1 − a²)), a 는 그 축의 정규화 좌표(가장자리에서 ±1).
    // 가운데는 1/(1−k) 배로 커 보이고 가장자리로 갈수록 줄어 맨 가장자리는 제자리라 영역 안 내용이 하나도 잘리지 않는다.
    // 축을 따로 두어 가로줄은 곧게 남는다.
    // (높이·스넬 법칙으로 휘면 가장자리 몇 pt 안의 내용이 한두 픽셀로 눌려 줄 첫 글자가 사라졌고, 영역 사각형까지의
    // 거리로 면을 만들면 대각선·가운데 줄에서 면이 꺾여 글자가 찢어졌고, 두 축을 섞은 거리로 키우면 줄이 술통처럼 휘었다.)
    float2 domeShift(float2 d, float2 halfSize, float2 k) {
        float2 a = clamp(d / halfSize, -1.0, 1.0);
        return -d * k * (1.0 - a * a);
    }

    // 5x5 가우시안 근사 (CPU 판의 상자 흐림 두 번과 비슷한 폭)
    float3 blurred(texture2d<float> src, float2 p, float r) {
        if (r < 0.5) return src.sample(linearClamp, p).rgb;
        float3 acc = 0.0;
        float wsum = 0.0;
        for (int j = -2; j <= 2; j++) {
            for (int i = -2; i <= 2; i++) {
                float w = exp(-float(i * i + j * j) / 4.5);
                acc += src.sample(linearClamp, p + float2(i, j) * r * 0.5).rgb * w;
                wsum += w;
            }
        }
        return acc / wsum;
    }

    kernel void pillLuma(texture2d<float> src [[texture(0)]], device const Pill *pills [[buffer(0)]],
                         device float *lum [[buffer(1)]], uint id [[thread_position_in_grid]]) {
        Pill p = pills[id];
        float acc = 0.0;
        for (int j = 0; j < 4; j++) {
            for (int i = 0; i < 6; i++) {
                float2 q = float2(p.originX, p.originY)
                    + float2(p.width, p.height) * float2(0.25 + 0.5 * (i + 0.5) / 6.0, 0.25 + 0.5 * (j + 0.5) / 4.0);
                acc += dot(blurred(src, q, p.blur), lumaWeights);
            }
        }
        lum[id] = acc / 24.0;
    }

    kernel void pillGlass(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          device const Pill *pills [[buffer(0)]], device const float *lum [[buffer(1)]],
                          constant uint &index [[buffer(2)]], uint2 gid [[thread_position_in_grid]]) {
        Pill p = pills[index];
        if (gid.x >= uint(p.width) || gid.y >= uint(p.height)) return;
        uint2 out = uint2(uint(p.atlasX), uint(p.atlasY)) + gid;
        float2 px = float2(gid) + 0.5;
        float r = p.radius;
        float2 v = float2(clamp(px.x, r, p.width - r), r) - px;
        float dist = length(v);
        float edge = r - dist;
        float coverage = clamp(edge + 0.5, 0.0, 1.0);
        if (coverage <= 0.0) { dst.write(float4(0.0), out); return; }
        float2 inward = dist > 1e-4 ? v / dist : float2(0.0);
        float shift = 0.0, light = 0.0, crisp = 0.0;
        if (edge < p.bezel) {
            float t = max(edge, 0.0) / p.bezel;
            float u = 1.0 - t;
            shift = refractShift(t, p.bezel, p.thickness, p.power);
            float facing = -dot(inward, toLight);
            light = u * u * u * (facing > 0.0 ? facing * facing : 0.4 * facing * facing);
            crisp = min(1.0, u * 1.6);
        }
        float2 q = float2(p.originX, p.originY) + px + inward * shift;
        float3 c = blurred(src, q, p.blur);
        if (crisp > 0.0) c = mix(c, src.sample(linearClamp, q).rgb, crisp);
        float l = dot(c, lumaWeights);
        c = l + (c - l) * p.saturation;
        bool dark = p.forceDark > 0.5 || lum[index] < 0.55;
        if (dark) {
            c *= max(0.0, 1.0 - 0.38 * p.tint);
        } else {
            float k = min(1.0, 0.2 * p.tint);
            c = c * (1.0 - k) + k;
        }
        c += light * (dark ? 0.7 : 0.95) * p.specular;
        c = clamp(c, 0.0, 1.0);
        dst.write(float4(c * coverage, coverage), out);
    }

    kernel void edgeGlass(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant Edge &e [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(e.width) || gid.y >= uint(e.height)) return;
        float2 px = float2(gid) + 0.5;
        float2 d = px - float2(e.width, e.height) * 0.5;
        float2 q = abs(d) - float2(e.halfX, e.halfY);
        float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - e.radius;
        float2 n;
        if (q.x > 0.0 && q.y > 0.0) {
            n = normalize(float2(d.x < 0.0 ? -q.x : q.x, d.y < 0.0 ? -q.y : q.y));
        } else if (q.x > q.y) {
            n = float2(d.x < 0.0 ? -1.0 : 1.0, 0.0);
        } else {
            n = float2(0.0, d.y < 0.0 ? -1.0 : 1.0);
        }
        float edge;
        float2 inward;
        if (e.ring > 0.5) {
            float off = sd - e.bezel;
            edge = e.bezel - abs(off);
            inward = off > 0.0 ? -n : n;
        } else {
            edge = -sd;
            inward = -n;
            if (e.dome < 0.5 && edge >= e.bezel) { dst.write(float4(0.0), gid); return; }
        }
        float coverage = clamp(edge + 0.5, 0.0, 1.0);
        if (coverage <= 0.0) { dst.write(float4(0.0), gid); return; }
        float t = clamp(max(edge, 0.0) / e.bezel, 0.0, 1.0);
        float u = 1.0 - t;
        // dome 이면 thickness·power 가 가로·세로 세기
        float2 move = e.dome > 0.5 ? domeShift(d, float2(e.width, e.height) * 0.5, float2(e.thickness, e.power))
                                   : inward * refractShift(t, e.bezel, e.thickness, e.power);
        float facing = -dot(inward, toLight);
        // 가장자리 빛은 rim 폭 안에만 (영역 전체가 휘는 판은 굴절 폭이 넓어도 빛은 가장자리에)
        float ur = 1.0 - clamp(max(edge, 0.0) / (e.rim > 0.0 ? e.rim : e.bezel), 0.0, 1.0);
        float light = ur * ur * ur * (facing > 0.0 ? facing * facing : 0.4 * facing * facing);
        float3 c = src.sample(linearClamp, float2(e.originX, e.originY) + px + move).rgb;
        float l = dot(c, lumaWeights);
        c = l + (c - l) * e.saturation;
        c = c * (1.0 - e.tintAlpha) + float3(e.tintR, e.tintG, e.tintB) * e.tintAlpha;
        // 칠하기는 바깥 가장자리 0 에서 안쪽으로 서서히 (경계에 단차가 생기지 않게)
        // (띠 전체에 걸쳐 진해지면 가장자리가 덜 칠해져 액자처럼 보여서 바깥 40% 안에서 다 칠한다)
        c = mix(c, float3(e.tintR, e.tintG, e.tintB), e.fill * smoothstep(0.0, 0.4, t));
        c += light * e.specular;
        c = clamp(c, 0.0, 1.0);
        dst.write(float4(c * coverage, coverage), gid);
    }

    float sdRound(float2 p, float2 c, float2 extent, float r) {
        float2 q = abs(p - c) - extent;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // 두 경계가 만나는 모서리를 둥글게 이어 붙이는 max
    float smoothMax(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (a - b) / k, 0.0, 1.0);
        return mix(b, a, h) + k * h * (1.0 - h);
    }

    // 유리판 = 영역 − hole. 음수면 유리 안, 값은 가장 가까운 경계까지의 거리
    float sdCarved(float2 p, constant Hole &g) {
        float pane = sdRound(p, float2(g.paneW, g.paneH) * 0.5,
                             float2(g.paneW, g.paneH) * 0.5 - g.paneRadius, g.paneRadius);
        float hole = sdRound(p, float2(g.holeCX, g.holeCY), max(float2(g.holeHX, g.holeHY), 0.0), g.holeRadius);
        return smoothMax(pane, -hole, g.smooth);
    }

    // 고르지 않은 영역 유리판에서 움직이는 테두리 모양을 뺀다. 굴절·빛은 edgeGlass 의 판과 같은 식이고,
    // 바깥쪽 법선은 거리의 기울기로 구해서 영역 테두리든 움직이는 테두리든 같은 식으로 휜다.
    kernel void holeGlass(texture2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                          constant Hole &g [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= uint(g.paneW) || gid.y >= uint(g.paneH)) return;
        float2 px = float2(gid) + 0.5;
        float edge = -sdCarved(px, g);
        float coverage = clamp(edge + 0.5, 0.0, 1.0);
        if (coverage <= 0.0) { dst.write(float4(0.0), gid); return; }
        float3 tint = float3(g.tintR, g.tintG, g.tintB);
        // 띠 안쪽은 굴절 없이 옅은 색만 (살아 있는 화면 위에 색을 덮는 자리, Draw.glassArea 의 칠과 같다)
        if (g.dome < 0.5 && edge >= g.bezel) { dst.write(float4(tint * g.tintAlpha, g.tintAlpha) * coverage, gid); return; }
        float2 grad = float2(sdCarved(px + float2(0.5, 0.0), g) - sdCarved(px - float2(0.5, 0.0), g),
                             sdCarved(px + float2(0.0, 0.5), g) - sdCarved(px - float2(0.0, 0.5), g));
        float2 inward = length(grad) > 1e-5 ? -normalize(grad) : float2(0.0);
        float t = clamp(max(edge, 0.0) / g.bezel, 0.0, 1.0);
        float2 move;
        if (g.dome > 0.5) {
            // 영역 전체 볼록렌즈 + 움직이는 테두리 가장자리는 따로 띠로 휜다(테두리 바깥쪽으로 밀려나 보이게)
            float2 center = float2(g.paneW, g.paneH) * 0.5;
            move = domeShift(px - center, center, float2(g.thickness, g.power));  // dome 이면 가로·세로 세기
            float2 hc = float2(g.holeCX, g.holeCY), hext = max(float2(g.holeHX, g.holeHY), 0.0);
            float hd = sdRound(px, hc, hext, g.holeRadius);
            if (hd < g.holeBezel) {
                float2 hg = float2(sdRound(px + float2(0.5, 0.0), hc, hext, g.holeRadius) - sdRound(px - float2(0.5, 0.0), hc, hext, g.holeRadius),
                                   sdRound(px + float2(0.0, 0.5), hc, hext, g.holeRadius) - sdRound(px - float2(0.0, 0.5), hc, hext, g.holeRadius));
                if (length(hg) > 1e-5) {
                    move += normalize(hg) * refractShift(clamp(max(hd, 0.0) / g.holeBezel, 0.0, 1.0), g.holeBezel,
                                                         g.holeThickness, 3.0);
                }
            }
        } else {
            move = inward * refractShift(t, g.bezel, g.thickness, g.power);
        }
        float facing = -dot(inward, toLight);
        float ur = 1.0 - clamp(max(edge, 0.0) / (g.rim > 0.0 ? g.rim : g.bezel), 0.0, 1.0);
        float light = ur * ur * ur * (facing > 0.0 ? facing * facing : 0.4 * facing * facing);
        float3 c = src.sample(linearClamp, float2(g.paneX, g.paneY) + px + move).rgb;
        float l = dot(c, lumaWeights);
        c = l + (c - l) * g.saturation;
        c = c * (1.0 - g.tintAlpha) + tint * g.tintAlpha;
        c += light * g.specular;
        c = clamp(c, 0.0, 1.0);
        dst.write(float4(c * coverage, coverage), gid);
    }
    """
}
