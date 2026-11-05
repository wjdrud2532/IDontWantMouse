import AppKit
import WebKit

// 스크롤 영역 회귀 테스트의 시험 창: 키 포커스를 가져가지 않는 WKWebView 창에 페이지 하나를 띄운다.
//   Host <url> [초]   pid 를 출력하고, 정한 시간(기본 6초) 뒤 끝난다.
setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let url = URL(string: CommandLine.arguments[1])!
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 6 : 6
// 다른 창 뒤에 깔고 키 포커스는 가져가지 않는다. 화면 밖으로 보내면 macOS 가 화면 안으로 끌어온다.
let win = NSWindow(contentRect: NSRect(x: 40, y: 80, width: 900, height: 700), styleMask: [.titled], backing: .buffered,
                   defer: false)
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
win.contentView = web
win.orderBack(nil)
web.load(URLRequest(url: url))
print("pid \(getpid())")
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
app.run()
