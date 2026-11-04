import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// 메뉴 막대 아이콘 → 설정… 으로 여는 창.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onHotkeysChanged: () -> Void
    private let onRecording: (Bool) -> Void

    /// onRecording: 단축키를 녹화하는 동안 true. 그동안 기존 단축키가 가로채지 않게 풀어둬야 한다.
    init(onHotkeysChanged: @escaping () -> Void, onRecording: @escaping (Bool) -> Void) {
        self.onHotkeysChanged = onHotkeysChanged
        self.onRecording = onRecording
    }

    func show() {
        // 시스템 설정에서 로그인 항목을 지웠을 수도 있으니 실제 상태로 맞춘다
        Config.defaults.set(SMAppService.mainApp.status == .enabled, forKey: "launchAtLogin")
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(onHotkeysChanged: onHotkeysChanged, onRecording: onRecording))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Hanmium 설정"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            // 내용이 길어서 작은 화면에서도 넘치지 않게 높이를 정하고(안은 스크롤된다) 그 크기로 가운데 둔다
            w.setContentSize(NSSize(width: 460, height: 620))
            w.center()
            window = w
        }
        // 메뉴 막대 앱(.accessory)은 창을 클릭해도 활성 앱이 되지 않아 키 입력(단축키 녹화)을 못 받는다.
        // 설정 창이 떠 있는 동안만 일반 앱으로 바꾼다. 그동안 Dock 에 아이콘이 보인다.
        NSApp.mainMenu = Self.mainMenu()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// 일반 앱인 동안 ⌘W·⌘Q 와 텍스트 필드의 복사·붙여넣기가 되도록 최소한의 메뉴
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hanmium 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "윈도우")
        window.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [appMenu, edit, window] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }
}

struct SettingsView: View {
    let onHotkeysChanged: () -> Void
    let onRecording: (Bool) -> Void
    /// 창 높이. 문서 이미지를 만들 때(Tools/DocImages)만 늘려서 모든 항목을 한 장에 담는다.
    static var height: CGFloat = 620

    @AppStorage("enabled", store: Config.defaults) private var enabled = true
    @AppStorage(ModeKind.labels.enabledKey, store: Config.defaults) private var labelsOn = true
    @AppStorage(ModeKind.search.enabledKey, store: Config.defaults) private var searchOn = true
    @AppStorage(ModeKind.scroll.enabledKey, store: Config.defaults) private var scrollOn = true
    @AppStorage(ModeKind.labels.hotkeyKey, store: Config.defaults) private var labelsKey = ModeKind.labels.defaultHotkey
    @AppStorage(ModeKind.search.hotkeyKey, store: Config.defaults) private var searchKey = ModeKind.search.defaultHotkey
    @AppStorage(ModeKind.scroll.hotkeyKey, store: Config.defaults) private var scrollKey = ModeKind.scroll.defaultHotkey
    @AppStorage("labelCharacters", store: Config.defaults) private var labelCharacters = Config.defaultLabelCharacters
    @AppStorage("scrollKeys", store: Config.defaults) private var scrollKeys = Config.defaultScrollKeys
    @AppStorage("scrollPxPerMs", store: Config.defaults) private var scrollSpeed = Config.defaultScrollPxPerMs
    @AppStorage("dashMultiplier", store: Config.defaults) private var dashMultiplier = Config.defaultDashMultiplier
    @AppStorage("useSearchPredicate", store: Config.defaults) private var useSearchPredicate = true
    @AppStorage("labelTheme", store: Config.defaults) private var labelTheme = LabelTheme.all[0].id
    @AppStorage("terminalNotchLines", store: Config.defaults)
    private var terminalNotchLines = Config.defaultTerminalNotchLines
    @AppStorage("animationScale", store: Config.defaults) private var animationScale = 1.0
    @AppStorage("appFilterMode", store: Config.defaults) private var appFilterMode = AppFilterMode.exclude.rawValue
    @AppStorage("appList", store: Config.defaults) private var appList = ""
    @AppStorage("scrollBorderShown", store: Config.defaults) private var scrollBorderShown = true
    @AppStorage("scrollBorderWidth", store: Config.defaults) private var scrollBorderWidth = Config.defaultScrollBorderWidth
    /// 비어 있으면 라벨 색상의 강조색을 따른다
    @AppStorage("scrollBorderColor", store: Config.defaults) private var scrollBorderColor = ""
    @AppStorage("inactiveAreaShown", store: Config.defaults) private var inactiveAreaShown = true
    @AppStorage("scrollBorderStyle", store: Config.defaults) private var scrollBorderStyle = AreaStyle.glass.rawValue
    @AppStorage("focusMotion", store: Config.defaults) private var focusMotion = FocusMotion.none.rawValue
    @AppStorage("focusMotionSpeed", store: Config.defaults) private var focusMotionSpeed = 1.0
    @AppStorage("glassRefraction", store: Config.defaults) private var glassRefraction = 1.0
    @AppStorage("glassSpecular", store: Config.defaults) private var glassSpecular = 1.0
    @AppStorage("glassBlur", store: Config.defaults) private var glassBlur = 1.0
    @AppStorage("glassTint", store: Config.defaults) private var glassTint = 1.0
    @AppStorage("inactiveAreaStyle", store: Config.defaults) private var inactiveAreaStyle = AreaStyle.glass.rawValue
    /// 비어 있으면 스크롤 테두리 색을 따른다
    @AppStorage("inactiveAreaColor", store: Config.defaults) private var inactiveAreaColor = ""
    @AppStorage("inactiveLineOpacity", store: Config.defaults)
    private var inactiveLineOpacity = Config.defaultInactiveLineOpacity
    @AppStorage("inactiveFillOpacity", store: Config.defaults)
    private var inactiveFillOpacity = Config.defaultInactiveFillOpacity

    private var usesGlass: Bool {
        LabelTheme.all.first(where: { $0.id == labelTheme })?.glass != nil
            || (scrollBorderShown && scrollBorderStyle == AreaStyle.glass.rawValue)
            || (inactiveAreaShown && inactiveAreaStyle == AreaStyle.glass.rawValue)
    }

    private var listedIDs: [String] { appList.split(separator: "\n").map(String.init) }
    private var includeMode: Bool { appFilterMode == AppFilterMode.include.rawValue }

    private var borderFollowsTheme: Binding<Bool> {
        Binding(get: { scrollBorderColor.isEmpty },
                set: { scrollBorderColor = $0 ? "" : (Config.labelTheme.accent.hexString ?? "#4D9EFF") })
    }

    private var borderColor: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: scrollBorderColor) ?? Config.labelTheme.accent) },
                set: { scrollBorderColor = NSColor($0).hexString ?? "" })
    }

    private var inactiveFollowsBorder: Binding<Bool> {
        Binding(get: { inactiveAreaColor.isEmpty },
                set: { inactiveAreaColor = $0 ? "" : (Config.scrollBorderColor.hexString ?? "#4D9EFF") })
    }

    private var inactiveColor: Binding<Color> {
        Binding(get: { Color(nsColor: Config.inactiveAreaColor) },
                set: { inactiveAreaColor = NSColor($0).hexString ?? "" })
    }
    // CLT 로 빌드하면 @State 매크로 플러그인이 없어서 AppStorage 로 둔다. 창을 열 때 실제 상태로 맞춘다.
    @AppStorage("launchAtLogin", store: Config.defaults) private var launchAtLogin = false

    /// 로그인 항목 등록은 .app 번들로 실행했을 때만 된다
    private static let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    var body: some View {
        Form {
            Section {
                Toggle("Hanmium 사용", isOn: $enabled)
                Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                    .disabled(!Self.isAppBundle)
                if !Self.isAppBundle {
                    note("Hanmium.app 으로 실행했을 때만 바꿀 수 있습니다.")
                }
                if usesGlass, !CGPreflightScreenCaptureAccess() {
                    note("리퀴드 글래스가 뒤 화면을 굴절시키려면 화면 기록 권한이 필요합니다. "
                        + "없으면 옅은 흐림과 가장자리 빛만 그립니다. 허용한 뒤 Hanmium 을 다시 실행하세요.")
                    HStack {
                        Button("화면 기록 권한 열기", action: openScreenCaptureSettings)
                        Button("Hanmium 다시 실행", action: relaunch).disabled(!Self.isAppBundle)
                    }
                }
            }
            Section("단축키") {
                shortcutRow(.labels, isOn: $labelsOn, spec: $labelsKey)
                shortcutRow(.search, isOn: $searchOn, spec: $searchKey)
                shortcutRow(.scroll, isOn: $scrollOn, spec: $scrollKey)
                note("버튼을 누른 뒤 새 키 조합을 입력하세요. Esc 는 취소입니다.")
            }
            Section("라벨 클릭") {
                TextField("라벨 문자", text: $labelCharacters)
                note("앞쪽 문자가 먼저 쓰입니다. 손이 놓이는 키를 앞에 두세요.")
                VStack(alignment: .leading, spacing: 8) {
                    Text("라벨 색상")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 4)], alignment: .leading, spacing: 6) {
                        ForEach(LabelTheme.all, id: \.id) { theme in
                            Button { labelTheme = theme.id } label: {
                                ThemeSwatch(theme: theme, selected: theme.id == labelTheme)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    note("스크롤 영역 테두리와 검색 결과 강조도 이 색을 따릅니다.")
                }
                if LabelTheme.all.first(where: { $0.id == labelTheme })?.glass != nil {
                    GlassPreview(refraction: glassRefraction, specular: glassSpecular, blur: glassBlur, tint: glassTint,
                                 theme: labelTheme)
                    percentSlider("굴절 강도", value: $glassRefraction, in: 0...2)
                    percentSlider("반사도", value: $glassSpecular, in: 0...2)
                    percentSlider("흐림", value: $glassBlur, in: 0...2)
                    percentSlider("색 진하기", value: $glassTint, in: 0...2)
                    note("굴절 강도는 가장자리가 뒤 화면을 휘는 정도, 반사도는 가장자리에 맺히는 빛, "
                        + "흐림은 글자 뒤를 흐리는 정도, 색 진하기는 밝게(어두운 유리는 어둡게) 덮는 정도입니다. 100% 가 기본.")

                }
            }
            Section("스크롤") {
                TextField("방향 키 (← ↓ ↑ →)", text: $scrollKeys)
                LabeledContent("속도") {
                    Slider(value: $scrollSpeed, in: 0.3...4, step: 0.1)
                    Text(String(format: "%.1f", scrollSpeed)).monospacedDigit().frame(width: 32)
                }
                LabeledContent("Shift 가속 배수") {
                    Slider(value: $dashMultiplier, in: 1.5...6, step: 0.5)
                    Text(String(format: "%.1f", dashMultiplier)).monospacedDigit().frame(width: 32)
                }
                LabeledContent("움직임 애니메이션") {
                    Slider(value: $animationScale, in: 0...2, step: 0.25)
                    Text(animationScale == 0 ? "끔" : "\(Int(animationScale * 100))%")
                        .monospacedDigit().frame(width: 40)
                }
                note("d/u 반 페이지 이동과 누르고 뗄 때의 가속·감속에 걸리는 시간입니다. 끄면 바로 이동합니다.")
                LabeledContent("터미널 휠 한 칸") {
                    HStack(spacing: 4) {
                        NumberField(value: $terminalNotchLines, range: 1...10).frame(width: 36)
                        Text("줄")
                        Stepper("", value: $terminalNotchLines, in: 1...10).labelsHidden()
                    }
                }
                note("WezTerm 에서 Claude Code·vim 같은 전체 화면 앱은 휠 한 칸마다 앱이 정한 만큼 움직입니다. "
                    + "너무 빠르면 늘리고, 뚝뚝 끊겨 보이면 줄이세요.")
            }
            Section("스크롤 영역 테두리") {
                Toggle("테두리 표시", isOn: $scrollBorderShown)
                Picker("모양", selection: $scrollBorderStyle) {
                    Text("리퀴드 글래스").tag(AreaStyle.glass.rawValue)
                    Text("실선").tag(AreaStyle.line.rawValue)
                }
                .disabled(!scrollBorderShown)
                Picker("영역 이동", selection: $focusMotion) {
                    Text("늘어나는 물방울").tag(FocusMotion.stretch.rawValue)
                    Text("날아가는 물방울").tag(FocusMotion.hop.rawValue)
                    Text("없음").tag(FocusMotion.none.rawValue)
                }
                .disabled(!scrollBorderShown)
                percentSlider("영역 이동 속도", value: $focusMotionSpeed, in: 0.25...3)
                    .disabled(!scrollBorderShown || focusMotion == FocusMotion.none.rawValue)
                note("숫자·Tab 으로 다른 영역을 고를 때 테두리가 옮겨가는 모양입니다. 늘어나는 물방울은 가는 쪽이 먼저 "
                    + "늘어났다가 출렁이며 멈추고, 날아가는 물방울은 작은 물방울로 뭉쳐 날아간 뒤 퍼집니다. "
                    + "속도는 100% 가 기본이고 높을수록 빠릅니다.")
                LabeledContent("두께") {
                    Slider(value: $scrollBorderWidth, in: 1...8, step: 1)
                    Text("\(Int(scrollBorderWidth))px").monospacedDigit().frame(width: 32)
                }
                .disabled(!scrollBorderShown)
                Toggle("라벨 색상에 맞추기", isOn: borderFollowsTheme)
                    .disabled(!scrollBorderShown)
                if !scrollBorderColor.isEmpty {
                    ColorPicker("테두리 색", selection: borderColor, supportsOpacity: false)
                        .disabled(!scrollBorderShown)
                }
                note("리퀴드 글래스는 두께에 맞춰 영역 바깥을 얇은 유리 막대로 감쌉니다(기본 3 → 4pt). "
                    + "테두리는 스크롤하는 창 바로 위에만 그려져서, 다른 앱 창이 덮으면 같이 가려집니다.")
            }
            Section("고르지 않은 스크롤 영역") {
                Toggle("표시", isOn: $inactiveAreaShown)
                Picker("모양", selection: $inactiveAreaStyle) {
                    Text("리퀴드 글래스").tag(AreaStyle.glass.rawValue)
                    Text("점선").tag(AreaStyle.line.rawValue)
                }
                .disabled(!inactiveAreaShown)
                Toggle("스크롤 테두리 색에 맞추기", isOn: inactiveFollowsBorder)
                    .disabled(!inactiveAreaShown)
                if !inactiveAreaColor.isEmpty {
                    ColorPicker("색", selection: inactiveColor, supportsOpacity: false)
                        .disabled(!inactiveAreaShown)
                }
                percentSlider("점선 진하기", value: $inactiveLineOpacity, in: 0...1)
                    .disabled(!inactiveAreaShown || inactiveAreaStyle == AreaStyle.glass.rawValue)
                percentSlider(inactiveAreaStyle == AreaStyle.glass.rawValue ? "유리 색 진하기" : "채우기 진하기",
                              value: $inactiveFillOpacity, in: 0...0.6)
                    .disabled(!inactiveAreaShown)
                note("같은 창에서 숫자·Tab 으로 옮겨갈 수 있는 다른 영역(WezTerm·VS Code 분할 창 등)입니다. "
                    + "리퀴드 글래스는 영역 위에 유리판을 얹어 가장자리가 굴절되고 빛나며, 점선은 점선과 옅은 칠로 구분합니다.")
            }
            Section("앱별 사용") {
                Picker("방식", selection: $appFilterMode) {
                    Text("모든 앱에서 사용하고, 목록의 앱에서만 끄기").tag(AppFilterMode.exclude.rawValue)
                    Text("목록의 앱에서만 사용").tag(AppFilterMode.include.rawValue)
                }
                .pickerStyle(.radioGroup)
                ForEach(listedIDs, id: \.self) { id in
                    HStack {
                        Image(nsImage: AppInfo.icon(id)).resizable().frame(width: 18, height: 18)
                        Text(AppInfo.name(id))
                        Spacer()
                        Button { removeApp(id) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("앱 추가…", action: addApps)
                note((includeMode
                    ? "목록의 앱이 앞에 있을 때만 단축키가 동작하고, 다른 앱에서는 키가 그 앱으로 그대로 갑니다. "
                        + "목록이 비어 있으면 어디서도 동작하지 않습니다. "
                    : "목록의 앱이 앞에 있으면 Hanmium 단축키가 꺼지고 키가 그 앱으로 그대로 갑니다. ")
                    + "메뉴 막대 아이콘에서 지금 쓰는 앱을 바로 넣거나 뺄 수도 있습니다.")
            }
            Section("고급") {
                Toggle("웹 페이지에서 빠른 검색 API 사용", isOn: $useSearchPredicate)
                note("끄면 웹 페이지의 요소를 하나씩 훑어서 느리지만 더 많이 찾을 수 있습니다.")
                HStack {
                    Button("설정 내보내기…", action: exportSettings)
                    Button("설정 가져오기…", action: importSettings)
                }
                note("단축키·라벨·스크롤·유리·앱별 사용 설정을 JSON 파일로 저장하거나 불러옵니다. "
                    + "불러오면 파일 속 설정 그대로 맞춥니다(로그인 시 자동 실행은 그대로 둡니다).")
            }
            Section {
                HStack {
                    Spacer()
                    Button("기본값으로 되돌리기", action: resetToDefaults)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: Self.height)
        .onChange(of: enabled) { _ in onHotkeysChanged() }
        .onChange(of: labelsOn) { _ in onHotkeysChanged() }
        .onChange(of: searchOn) { _ in onHotkeysChanged() }
        .onChange(of: scrollOn) { _ in onHotkeysChanged() }
        .onChange(of: labelsKey) { _ in onHotkeysChanged() }
        .onChange(of: searchKey) { _ in onHotkeysChanged() }
        .onChange(of: scrollKey) { _ in onHotkeysChanged() }
        .onChange(of: launchAtLogin, perform: setLaunchAtLogin)
        .onChange(of: appFilterMode) { _ in onHotkeysChanged() }
        .onChange(of: appList) { _ in onHotkeysChanged() }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "추가"
        guard panel.runModal() == .OK else { return }
        var ids = listedIDs
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  !ids.contains(id) else { continue }
            ids.append(id)
        }
        appList = ids.joined(separator: "\n")
    }

    private func removeApp(_ id: String) {
        appList = listedIDs.filter { $0 != id }.joined(separator: "\n")
    }

    private func shortcutRow(_ kind: ModeKind, isOn: Binding<Bool>, spec: Binding<String>) -> some View {
        HStack {
            Text(kind.title)
            Spacer()
            ShortcutRecorder(spec: spec, onRecording: onRecording)
                .frame(width: 140)
                .disabled(!isOn.wrappedValue)
            Toggle(kind.title, isOn: isOn).labelsHidden()
        }
    }

    private func note(_ text: String) -> some View {
        // 긴 설명이 한 줄로 잘리지 않게 줄바꿈한다
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != on { launchAtLogin = actual }
    }

    private func percentSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range, step: 0.05)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").monospacedDigit().frame(width: 40)
        }
    }

    private func openScreenCaptureSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 새로 띄우면 단일 실행 검사로 지금 것이 꺼진다. 권한은 새로 띄운 프로세스부터 적용된다.
    private func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundlePath]
        try? open.run()
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Hanmium 설정.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SettingsTransfer.export().write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let applied = try SettingsTransfer.importSettings(Data(contentsOf: url))
            onHotkeysChanged()
            let alert = NSAlert()
            alert.messageText = "설정을 가져왔습니다"
            alert.informativeText = "\(url.lastPathComponent)에서 설정 \(applied)개를 적용했고, 나머지는 기본값입니다."
            alert.runModal()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func resetToDefaults() {
        enabled = true
        labelsOn = true
        searchOn = true
        scrollOn = true
        labelsKey = ModeKind.labels.defaultHotkey
        searchKey = ModeKind.search.defaultHotkey
        scrollKey = ModeKind.scroll.defaultHotkey
        labelCharacters = Config.defaultLabelCharacters
        scrollKeys = Config.defaultScrollKeys
        scrollSpeed = Config.defaultScrollPxPerMs
        dashMultiplier = Config.defaultDashMultiplier
        useSearchPredicate = true
        labelTheme = LabelTheme.all[0].id
        terminalNotchLines = Config.defaultTerminalNotchLines
        animationScale = 1
        scrollBorderShown = true
        scrollBorderWidth = Config.defaultScrollBorderWidth
        scrollBorderColor = ""
        inactiveAreaShown = true
        scrollBorderStyle = AreaStyle.glass.rawValue
        focusMotion = FocusMotion.none.rawValue
        focusMotionSpeed = 1
        glassRefraction = 1
        glassSpecular = 1
        glassBlur = 1
        glassTint = 1
        inactiveAreaStyle = AreaStyle.glass.rawValue
        inactiveAreaColor = ""
        inactiveLineOpacity = Config.defaultInactiveLineOpacity
        inactiveFillOpacity = Config.defaultInactiveFillOpacity
        // 앱별 사용 목록은 사용자가 고른 것이라 그대로 둔다
    }
}

/// 번들 ID 로 앱 이름·아이콘 찾기
enum AppInfo {
    private static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(_ id: String) -> String {
        guard let url = url(id) else { return id }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage {
        if let url = url(id) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }
}

/// 유리 라벨 미리보기: 밝은·어두운 배경 위 라벨을 지금 설정 그대로(실제 굴절 계산으로) 그린다.
/// 값을 인자로 받아야 슬라이더를 움직일 때마다 다시 그린다.
struct GlassPreview: View {
    let refraction: Double
    let specular: Double
    let blur: Double
    let tint: Double
    let theme: String

    var body: some View {
        Image(nsImage: Self.render())
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private static let size = CGSize(width: 320, height: 64)
    private static let scale: CGFloat = 2

    /// 굴절시킬 배경: 왼쪽은 밝은 문서, 오른쪽은 어두운 코드. 원은 색이 비치는지 보려고 둔다.
    private static let background: CGImage? = {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let half = size.width / 2
        NSColor(srgbRed: 0.97, green: 0.97, blue: 0.95, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: half, height: size.height).fill()
        NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
        CGRect(x: half, y: 0, width: half, height: size.height).fill()
        let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let light: [NSColor] = [.darkGray, .systemBlue]
        let dark: [NSColor] = [.systemPink, .systemGreen, .systemYellow, .systemBlue]
        for i in 0..<5 {
            let y = CGFloat(i) * 13 - 1
            NSAttributedString(string: "let glass = refract(light, n: 1.5)",
                               attributes: [.font: mono, .foregroundColor: light[i % 2]]).draw(at: CGPoint(x: 4, y: y))
            NSAttributedString(string: "func render(_ items: [Item]) -> View",
                               attributes: [.font: mono, .foregroundColor: dark[i % 4]]).draw(at: CGPoint(x: half + 4, y: y))
        }
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: CGRect(x: 96, y: 26, width: 46, height: 46)).fill()
        NSColor.systemPurple.setFill()
        NSBezierPath(ovalIn: CGRect(x: 262, y: -10, width: 46, height: 46)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }()

    private static let snapshot = background.flatMap { ScreenSnapshot(image: $0, axFrame: CGRect(origin: .zero, size: size)) }

    private static func render() -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            guard let background, let snapshot else { return false }
            NSImage(cgImage: background, size: size).draw(in: rect, from: .zero, operation: .copy, fraction: 1,
                                                          respectFlipped: true, hints: nil)
            Draw.glassSource = GlassSource(snapshot)
            let labels = [("FJ", CGPoint(x: 40, y: 22)), ("DK", CGPoint(x: 118, y: 40)),
                          ("SL", CGPoint(x: 210, y: 22)), ("A", CGPoint(x: 268, y: 38))]
            for (label, p) in labels { Draw.pill(label, center: p, within: rect) }
            Draw.glassSource = nil
            return true
        }
    }
}

/// 설정의 라벨 색상 미리보기. 앞 글자는 이미 입력한 상태(흐리게)로 보여준다.
struct ThemeSwatch: View {
    let theme: LabelTheme
    let selected: Bool

    private var glass: Bool { theme.glass != nil }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: glass ? 9 : 4) }
    private var edgeLight: LinearGradient {
        let a: [Double] = theme.glass == .dark ? [0.6, 0.08, 0.3] : [1, 0.3, 0.7]
        return LinearGradient(colors: a.map { Color.white.opacity($0) }, startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Text("F").foregroundColor(Color(nsColor: theme.typed))
                Text("J").foregroundColor(Color(nsColor: theme.text))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.horizontal, glass ? 8 : 6)
            .padding(.vertical, 2)
            .background(shape.fill(Color(nsColor: theme.fill)))
            // 유리 라벨은 흐린 재질을 깔고 가장자리에 빛을 둔다
            .background(shape.fill(.regularMaterial).opacity(glass ? 1 : 0)
                .environment(\.colorScheme, theme.glass == .dark ? .dark : .light))
            .overlay(shape.stroke(glass ? AnyShapeStyle(edgeLight) : AnyShapeStyle(Color(nsColor: theme.stroke)),
                                  lineWidth: 1))
            .shadow(color: .black.opacity(glass ? 0.25 : 0), radius: 2, y: 1)
            Text(theme.name)
                .font(.caption2)
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

/// 정수를 직접 입력하는 칸. 범위 안의 숫자는 치는 대로 바로 저장하고, 입력을 마치면(Return·Tab·다른 곳 클릭)
/// 범위 밖이나 숫자가 아닌 값을 범위 안으로 되돌려 보여준다. SwiftUI TextField 는 저장값이 그대로면 친 글자를 남겨둔다.
struct NumberField: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // 입력 중에는 덮어쓰지 않는다 (Stepper·기본값 복원으로 바뀐 값만 반영)
        if field.currentEditor() == nil { field.stringValue = "\(value)" }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumberField

        init(_ parent: NumberField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField, let v = Int(field.stringValue),
                  parent.range.contains(v) else { return }
            parent.value = v
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? parent.value
            let v = min(max(typed, parent.range.lowerBound), parent.range.upperBound)
            parent.value = v
            field.stringValue = "\(v)"
        }
    }
}

/// 누르면 녹화 상태가 되어 다음 키 조합을 단축키로 받는 버튼
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var spec: String
    let onRecording: (Bool) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onRecordingChange = onRecording
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.spec = spec
        button.onRecord = { spec = $0 }
    }
}

final class RecorderButton: NSButton {
    var spec = "" {
        didSet { refreshTitle() }
    }
    var onRecord: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            refreshTitle()
            onRecordingChange?(recording)
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    private func refreshTitle() {
        title = recording ? "키 조합 입력…" : (KeyCombo(spec)?.display ?? spec)
    }

    @objc private func toggleRecording() {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    // ⌘ 가 들어간 조합은 keyDown 보다 먼저 키 등가물로 온다
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 {  // Esc: 취소
            recording = false
            return
        }
        guard let new = KeyCombo.spec(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            NSSound.beep()  // 수정키 없이 누른 키는 받지 않는다
            return
        }
        recording = false
        onRecord?(new)
    }
}
