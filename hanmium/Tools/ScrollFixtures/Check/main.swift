import AppKit

// 스크롤 영역 회귀 테스트의 검사 쪽 (Tools/scroll-fixtures.sh 가 Hanmium 소스와 함께 컴파일한다).
//   Check <pid> <기대 id …>   그 프로세스(시험 창)에서 Hanmium 이 찾은 스크롤 영역의 DOM id 를 기대와 비교한다.
//                              id 없는 영역(페이지 전체)은 세지 않는다. 다르면 종료 코드 1.
//   Check <pid> --tree         DOM id 가 있는 요소를 역할·틀·클래스와 함께 출력한다(기대를 정할 때).
setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, let pid = pid_t(first), let app = NSRunningApplication(processIdentifier: pid) else {
    print("사용법: Check <pid> <기대 id …> | Check <pid> --tree")
    exit(2)
}
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
let root = AXUIElementCreateApplication(pid)

/// 웹 내용 트리는 접근성을 켠 뒤 조금 지나야 생긴다: 웹 영역이 보일 때까지 기다린다
func webArea(_ e: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if AX.string(AX.copy(e, kAXRoleAttribute)) == "AXWebArea" { return e }
    guard depth < 8 else { return nil }
    for c in AX.elements(AX.copy(e, kAXChildrenAttribute)) { if let w = webArea(c, depth: depth + 1) { return w } }
    return nil
}
AXEnabler.enable(app: root, pid: pid, bundleID: app.bundleIdentifier)
var web: AXUIElement?
for _ in 0..<40 {
    web = webArea(root)
    if web != nil { break }
    usleep(100_000)
}
guard let web else {
    print("웹 영역을 찾지 못함")
    exit(1)
}
usleep(300_000)

if args.dropFirst().first == "--tree" {
    func walk(_ e: AXUIElement, _ d: Int) {
        let v = AX.multi(e, [kAXRoleAttribute, kAXSubroleAttribute, "AXDOMIdentifier", "AXDOMClassList", kAXVerticalScrollBarAttribute])
        let id = AX.string(v[2]) ?? ""
        if !id.isEmpty || AX.string(v[0]) == "AXScrollArea" {
            let f = AX.point(AX.copy(e, kAXPositionAttribute)).map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"
            let s = AX.size(AX.copy(e, kAXSizeAttribute)).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
            print(String(repeating: "  ", count: d) + "\(AX.string(v[0]) ?? "?")/\(AX.string(v[1]) ?? "-") (\(f) \(s)) id=\(id) "
                  + "\((v[3] as? [String]) ?? []) 세로막대=\(v[4] != nil)")
        }
        for c in AX.elements(AX.copy(e, kAXChildrenAttribute)) { walk(c, d + 1) }
    }
    walk(web, 0)
    exit(0)
}

let expected = Set(args.dropFirst())
let snap = TreeBuilder.forFrontmost(app).scrollSnapshot()
let found = Set(snap.areas.compactMap { AX.string(AX.copy($0.area.ref, "AXDOMIdentifier")) }.filter { !$0.isEmpty })
let wrong = found.subtracting(expected).sorted(), missing = expected.subtracting(found).sorted()
print("찾음 \(found.sorted())" + (wrong.isEmpty ? "" : "  잘못 잡음 \(wrong)") + (missing.isEmpty ? "" : "  놓침 \(missing)"))
exit(wrong.isEmpty && missing.isEmpty ? 0 : 1)
