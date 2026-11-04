import AppKit

// Hanmium — 키보드만으로 화면의 UI 요소를 클릭/스크롤하는 메뉴 막대 없는 상주 앱.
//
//   Hanmium                 상주 실행 (단축키 대기)
//   Hanmium --dump [번들ID] 앞 앱(또는 지정 앱)의 클릭 대상·스크롤 영역을 출력하고 종료
//   Hanmium --check [번들ID]
//                           실행 중인 앱(또는 지정 앱)이 Hanmium 과 잘 맞는지 점검. 경고가 있으면 종료 코드 1
//   Hanmium --click | --search | --scroll
//                           실행 1초 뒤 해당 모드를 바로 띄움 (테스트용)
//   Hanmium --settings      실행하면서 설정 창을 띄움

setvbuf(stdout, nil, _IOLBF, 0)  // 파일·파이프로 보내도 로그가 바로 보이게
let args = Array(CommandLine.arguments.dropFirst())

// 모르는 옵션이면 상주 앱으로 뜨지 않고 끝낸다. 뜨면 실행 중인 Hanmium 을 대신해 버린다(단일 실행).
let knownFlags: Set<String> = ["--dump", "--check", "--click", "--search", "--scroll", "--settings"]
if let unknown = args.first(where: { $0.hasPrefix("--") && !knownFlags.contains($0) }) {
    print("알 수 없는 옵션: \(unknown)\n쓸 수 있는 옵션: \(knownFlags.sorted().joined(separator: " "))")
    exit(2)
}

if let i = args.firstIndex(of: "--dump") {
    Dump.run(bundleID: args.count > i + 1 ? args[i + 1] : nil)
    exit(0)
}

if let i = args.firstIndex(of: "--check") {
    exit(Diagnostics.runCLI(bundleID: args.count > i + 1 ? args[i + 1] : nil))
}

let launchMode: ModeKind? =
    args.contains("--click") ? .labels :
    args.contains("--search") ? .search :
    args.contains("--scroll") ? .scroll : nil

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate(launchMode: launchMode, openSettings: args.contains("--settings"))
app.delegate = delegate
app.run()
