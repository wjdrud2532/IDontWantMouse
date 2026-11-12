import AppKit

// WezTerm 패널 배치 회귀 시험. cases/*.json 마다 CLI 출력·창 틀·화면 배율·설정으로 패널 영역을 계산해
// 기대값(화면에서 확인한 값)과 1pt 안으로 맞는지 본다. 화면이나 WezTerm 을 건드리지 않는다.
// 경계선 찾기(WezTerm.splitLines)도 그려 만든 이미지로 확인한다.
// 잘못 잡은 배치를 새로 만나면 그때의 `wezterm cli list --format json` 과 창 틀을 case 로 남긴다.

struct Case: Decodable {
    let note: String
    let window: [CGFloat]
    let scale: CGFloat
    let tabCount: Int
    let config: String
    let panes: [WezTerm.Pane]
    let expect: [String: [CGFloat]]
}

var failed = 0
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tools/WezTermFixtures/cases"
let files = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()) ?? []
for file in files {
    let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
    guard let data = try? Data(contentsOf: url) else { continue }
    let c: Case
    do { c = try JSONDecoder().decode(Case.self, from: data) } catch {
        print("✗ \(file): 읽지 못함 \(error)")
        failed += 1
        continue
    }
    let window = CGRect(x: c.window[0], y: c.window[1], width: c.window[2], height: c.window[3])
    guard let layout = WezTerm.layout(c.panes, tabCount: c.tabCount, window: window, scale: c.scale,
                                      config: WezTerm.Config(text: c.config)) else {
        print("✗ \(file): 배치를 못 구함")
        failed += 1
        continue
    }
    var bad: [String] = []
    for (frame, pane) in WezTerm.frames(c.panes, layout: layout) {
        guard let e = c.expect[String(pane.pane_id)] else { continue }
        let want = CGRect(x: e[0], y: e[1], width: e[2], height: e[3])
        let off = [frame.minX - want.minX, frame.minY - want.minY, frame.width - want.width, frame.height - want.height]
        if off.contains(where: { abs($0) > 1 }) { bad.append("패널 \(pane.pane_id): \(frame) ≠ 기대 \(want)") }
    }
    func axis(_ d: CGFloat?) -> String { d.map { "÷\(Int($0))" } ?? "추정" }
    let how = "가로 \(axis(layout.divisorX)) 세로 \(axis(layout.divisorY))"
    if bad.isEmpty {
        print("✓ \(file) (\(how))")
    } else {
        print("✗ \(file) (\(how))\n    " + bad.joined(separator: "\n    "))
        failed += 1
    }
}

// 경계선 찾기: 남색 바탕에 1px 노란 세로줄(x=150)·가로줄(y=200, 오른쪽만)과, 길지 않은 노란 글자 덩어리를 그린다
do {
    let w = 400, h = 300
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.12, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 0.4, alpha: 1))
    ctx.fill(CGRect(x: 150, y: 0, width: 1, height: h))           // 세로줄 (CG 는 아래가 0)
    ctx.fill(CGRect(x: 151, y: h - 201, width: w - 151, height: 1)) // 위에서 200 번째 줄
    for i in 0..<6 { ctx.fill(CGRect(x: 20 + i * 18, y: 40, width: 10, height: 14)) }  // 글자처럼 짧은 덩어리
    let found = WezTerm.splitLines(in: ctx.makeImage()!, color: (255, 255, 102))
    if found.xs == [150.5], found.ys == [200.5] {
        print("✓ 경계선 찾기 (세로 \(found.xs), 가로 \(found.ys))")
    } else {
        print("✗ 경계선 찾기: 세로 \(found.xs) 가로 \(found.ys), 기대 [150.5] [200.5]")
        failed += 1
    }
}

print(failed == 0 ? "모두 통과" : "\(failed)개 실패")
exit(failed == 0 ? 0 : 1)
