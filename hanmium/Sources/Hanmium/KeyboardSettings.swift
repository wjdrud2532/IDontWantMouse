import AppKit
import SwiftUI

// 설정 창의 키보드 화면들. Karabiner-Elements 설정 창처럼 단순 바꾸기(키 → 키), 복합 규칙(규칙 목록·켜고 끄기·JSON),
// 매개변수로 나눈다. CLT 로 빌드하면 @State 를 쓸 수 없어서 화면 상태는 KeyboardUI 에 둔다.

/// 규칙 편집 시트 등 화면 상태
final class KeyboardUI: ObservableObject {
    static let shared = KeyboardUI()
    @Published var editing = false
    /// 고치는 규칙 번호(nil 이면 새 규칙)
    @Published var editingIndex: Int?
    @Published var text = ""
    @Published var error: String?
    @Published var message: String?
    @Published var karabinerRules = 0
    @Published var karabinerDisabled = 0
    @Published var lastKey = ""
    /// 키보드 그림에서 고른 키(키보드별 설정)
    @Published var layoutDevice: KeyboardIdentity?
    @Published var layoutKey: String?

    func refreshKarabiner() {
        karabinerRules = KeyboardStore.karabinerActiveRules()
        karabinerDisabled = KeyboardStore.karabinerRulesDisabledByHanmium()
    }

    static let template = """
    {
      "description": "새 규칙: Caps Lock 을 Esc 로",
      "manipulators": [
        {
          "type": "basic",
          "from": { "key_code": "caps_lock", "modifiers": { "optional": ["any"] } },
          "to": [{ "key_code": "escape" }]
        }
      ]
    }
    """
}

private func note(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

// MARK: - 복합 규칙

struct KeyboardRulesView: View {
    @ObservedObject var store = KeyboardStore.shared
    @ObservedObject var ui = KeyboardUI.shared

    var body: some View {
        Form {
            Section {
                Toggle("Hanmium 이 키보드 규칙으로 키 바꾸기", isOn: $store.enabled)
                if store.enabled && !KeyboardTap.shared.running {
                    Label("키 입력을 받지 못했습니다. 손쉬운 사용 권한을 확인하세요.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                note("Karabiner-Elements 의 복합 규칙(complex modifications)과 같은 JSON 형식입니다. 위에 있는 규칙부터 보고, "
                    + "처음 맞는 조작 하나만 씁니다. 비밀번호 입력처럼 보안 입력이 켜진 곳에서는 시스템이 키를 보여 주지 않아 바뀌지 않습니다.")
            }
            karabinerSection
            Section("규칙") {
                if store.rules.isEmpty { Text("규칙이 없습니다").foregroundStyle(.secondary) }
                ForEach(Array(store.rules.enumerated()), id: \.element.id) { i, rule in
                    RuleRow(rule: rule, index: i, count: store.rules.count)
                }
                HStack {
                    Button("규칙 추가…") {
                        ui.editingIndex = nil
                        ui.text = KeyboardUI.template
                        ui.error = nil
                        ui.editing = true
                    }
                    Button("Karabiner 에서 다시 가져오기…", action: importKarabiner)
                    Spacer()
                    Button("규칙 파일 보기") { NSWorkspace.shared.activateFileViewerSelecting([KeyboardStore.fileURL]) }
                }
                if let message = ui.message { note(message) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $ui.editing) { RuleEditor() }
        .onAppear { ui.refreshKarabiner() }
    }

    @ViewBuilder private var karabinerSection: some View {
        if ui.karabinerRules > 0 || ui.karabinerDisabled > 0 {
            Section("Karabiner-Elements") {
                if ui.karabinerRules > 0 {
                    Label("Karabiner 에 복합 규칙 \(ui.karabinerRules)개가 켜져 있습니다. Karabiner 가 키를 먼저 바꾸므로 같은 키의 Hanmium 규칙은 동작하지 않습니다.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Karabiner 복합 규칙 모두 끄기") { setKarabiner(enabled: false) }
                    note("Karabiner 설정 파일에서 규칙의 \"enabled\" 만 끕니다. 바꾸기 전 파일은 같은 폴더에 남기고, 아래 버튼으로 다시 켤 수 있습니다.")
                }
                if ui.karabinerDisabled > 0 {
                    HStack {
                        Text("Hanmium 이 끈 Karabiner 규칙 \(ui.karabinerDisabled)개")
                        Spacer()
                        Button("다시 켜기") { setKarabiner(enabled: true) }
                    }
                }
            }
        }
    }

    private func setKarabiner(enabled: Bool) {
        do {
            let n = try KeyboardStore.setKarabinerRules(enabled: enabled)
            ui.message = "Karabiner 복합 규칙 \(n)개를 \(enabled ? "다시 켰습니다" : "껐습니다")."
        } catch {
            ui.message = "Karabiner 설정을 바꾸지 못했습니다: \(error.localizedDescription)"
        }
        ui.refreshKarabiner()
    }

    private func importKarabiner() {
        let alert = NSAlert()
        alert.messageText = "Karabiner 설정에서 다시 가져올까요?"
        alert.informativeText = "지금 Hanmium 의 키보드 규칙·단순 바꾸기·매개변수를 Karabiner 의 선택된 프로필 것으로 바꿉니다."
        alert.addButton(withTitle: "가져오기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let n = try store.importKarabiner()
            ui.message = "Karabiner 에서 규칙 \(n.rules)개, 단순 바꾸기 \(n.simple)개를 가져왔습니다."
        } catch {
            ui.message = "가져오지 못했습니다: \(error.localizedDescription)"
        }
    }
}

private struct RuleRow: View {
    let rule: KeyRule
    let index: Int
    let count: Int
    @ObservedObject var store = KeyboardStore.shared
    @ObservedObject var ui = KeyboardUI.shared

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(rule.manipulators.enumerated()), id: \.offset) { _, m in
                    Text(m?.summary ?? "(읽을 수 없는 조작)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(m?.isSupported == false || m == nil ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        } label: {
            HStack {
                Toggle(rule.description, isOn: Binding(
                    get: { rule.enabled },
                    set: { on in
                        guard store.rules.indices.contains(index) else { return }
                        store.rules[index].enabled = on
                    }))
                .toggleStyle(.checkbox)
                if rule.manipulators.contains(where: { $0 == nil || !$0!.isSupported }) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        .help("지원하지 않는 조작은 건너뜁니다")
                }
                Spacer()
                let only = rule.keyboards
                if !only.isEmpty {
                    Text(only.map(KeyboardDevices.name(for:)).joined(separator: ", ") + " 만")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Menu {
                    Menu("적용할 키보드") {
                        Button { setKeyboards([]) } label: { checkLabel("모든 키보드", only.isEmpty) }
                        Divider()
                        ForEach(KeyboardDevicesView.known(), id: \.identity) { k in
                            Button {
                                setKeyboards(only.contains(k.identity) ? only.filter { $0 != k.identity } : only + [k.identity])
                            } label: { checkLabel(k.name, only.contains(k.identity)) }
                        }
                    }
                    Button("JSON 편집…") {
                        ui.editingIndex = index
                        ui.text = rule.prettyJSON
                        ui.error = nil
                        ui.editing = true
                    }
                    Button("위로") { move(-1) }.disabled(index == 0)
                    Button("아래로") { move(1) }.disabled(index == count - 1)
                    Divider()
                    Button("삭제", role: .destructive) { store.rules.remove(at: index) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private func setKeyboards(_ ids: [KeyboardIdentity]) {
        guard store.rules.indices.contains(index) else { return }
        store.rules[index].setKeyboards(ids)
    }

    private func checkLabel(_ title: String, _ on: Bool) -> some View {
        on ? Label(title, systemImage: "checkmark") : Label(title, systemImage: "")
    }

    private func move(_ by: Int) {
        let to = index + by
        guard store.rules.indices.contains(index), store.rules.indices.contains(to) else { return }
        store.rules.swapAt(index, to)
    }
}

/// 규칙 하나를 JSON 으로 고치는 시트 (Karabiner 의 "Add your own rule" 과 같은 형식)
private struct RuleEditor: View {
    @ObservedObject var ui = KeyboardUI.shared
    @ObservedObject var store = KeyboardStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ui.editingIndex == nil ? "규칙 추가" : "규칙 편집").font(.headline)
            Text("Karabiner-Elements 규칙과 같은 JSON 입니다. {\"hanmium\": \"labels\"} · \"search\" · \"scroll\" 로 Hanmium 모드를 바로 열 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
            CodeEditor(text: $ui.text)
                .frame(minWidth: 620, minHeight: 380)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if let error = ui.error {
                Label(error, systemImage: "xmark.octagon").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("취소") { ui.editing = false }.keyboardShortcut(.cancelAction)
                Button("저장", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func save() {
        do {
            var rule = try KeyRule.parse(ui.text)
            if let i = ui.editingIndex, store.rules.indices.contains(i) {
                rule.enabled = store.rules[i].enabled
                store.rules[i] = rule
            } else {
                store.rules.insert(rule, at: 0)
            }
            ui.editing = false
        } catch {
            ui.error = error.localizedDescription
        }
    }
}

/// JSON 을 고치는 칸. 따옴표가 둥근 따옴표로 바뀌지 않게 자동 바꾸기를 끈다.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isRichText = false
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

// MARK: - 단순 바꾸기

struct KeyboardSimpleView: View {
    @ObservedObject var store = KeyboardStore.shared
    @ObservedObject var ui = KeyboardUI.shared

    var body: some View {
        Form {
            Section {
                if store.simple.isEmpty { Text("바꾸는 키가 없습니다").foregroundStyle(.secondary) }
                ForEach(Array(store.simple.enumerated()), id: \.element.id) { i, item in
                    HStack {
                        KeyPicker(title: "바꿀 키", selection: binding(i, \.from))
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        KeyPicker(title: "바뀐 키", selection: binding(i, \.to))
                        Spacer()
                        Button { store.simple.remove(at: i) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("항목 추가") { store.simple.append(SimpleModification(from: "caps_lock", to: "escape")) }
            } header: {
                Text("키 하나를 다른 키 하나로")
            } footer: {
                note("모든 키보드에 적용합니다(키보드마다 따로 바꾸려면 \"키보드별 설정\"). 키보드 규칙이 먼저 적용되고, 규칙에 걸리지 않은 키만 여기서 바뀝니다. "
                    + "수정키(⇧⌃⌥⌘·Caps Lock)는 바꿀 키로 쓸 수 없습니다. 키보드 규칙의 \"Hanmium 이 키보드 규칙으로 키 바꾸기\" 를 켜야 동작합니다.")
            }
            Section("키 확인") {
                KeyProbe(last: $ui.lastKey)
                    .frame(height: 54)
                note("칸을 누른 뒤 키를 치면 Karabiner 이름(key_code)과 키 코드를 보여 줍니다. 규칙을 쓸 때 참고하세요. "
                    + "Hanmium 키 바꾸기가 켜져 있으면 바뀐 뒤의 키가 보입니다.")
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ i: Int, _ key: WritableKeyPath<SimpleModification, String>) -> Binding<String> {
        Binding(get: { store.simple.indices.contains(i) ? store.simple[i][keyPath: key] : "" },
                set: { v in
                    guard store.simple.indices.contains(i) else { return }
                    store.simple[i][keyPath: key] = v
                })
    }
}

/// Karabiner 처럼 묶음별로 키를 고르는 팝업
struct KeyPicker: View {
    let title: String
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(KeyNames.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.keys, id: \.self) { Text(KeyNames.display($0) + "  (\($0))").tag($0) }
                }
            }
        }
        .labelsHidden()
        .frame(width: 220)
    }
}

/// 누른 키의 이름을 보여 주는 칸 (Karabiner-EventViewer 의 일부)
struct KeyProbe: NSViewRepresentable {
    @Binding var last: String

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onKey = { text in DispatchQueue.main.async { last = text } }
        return v
    }

    func updateNSView(_ v: ProbeView, context: Context) {
        v.text = last.isEmpty ? "여기를 누르고 키를 치세요" : last
        v.needsDisplay = true
    }

    final class ProbeView: NSView {
        var onKey: ((String) -> Void)?
        var text = ""
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

        override func keyDown(with event: NSEvent) { report(event, "누름") }
        override func keyUp(with event: NSEvent) { report(event, "뗌") }
        override func flagsChanged(with event: NSEvent) { report(event, "수정키") }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self, event.type == .keyDown else { return false }
            report(event, "누름")
            return true
        }

        private func report(_ event: NSEvent, _ what: String) {
            let name = KeyNames.names[event.keyCode] ?? "?"
            let flags = KeyboardEngine.pressed(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                                               code: event.keyCode).sorted()
            let mods = flags.isEmpty ? "" : "  수정키: " + flags.joined(separator: ", ")
            onKey?("\(what): \(name)  (키 코드 \(event.keyCode))\(mods)")
        }

        override func draw(_ dirtyRect: NSRect) {
            let focused = window?.firstResponder === self
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.textBackgroundColor.setFill()
            path.fill()
            (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = focused ? 2 : 1
            path.stroke()
            let s = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: focused ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            s.draw(at: CGPoint(x: 12, y: (bounds.height - s.size().height) / 2))
        }
    }
}

// MARK: - 키보드별 설정

/// 연결된 키보드마다: 키보드 규칙을 쓸지, 그 키보드에서만 바꿀 키
struct KeyboardDevicesView: View {
    @ObservedObject var store = KeyboardStore.shared
    @ObservedObject var devices = KeyboardDevices.shared
    @ObservedObject var ui = KeyboardUI.shared

    /// 화면에 보일 키보드: 연결된 것 + 설정만 남은 것
    struct Row {
        let identity: KeyboardIdentity
        let name: String
        let builtIn: Bool
        let connected: Bool
        var kind = KeyboardLayout.Kind(apple: false, iso: false)
    }

    static func known() -> [Row] {
        let connected = KeyboardDevices.shared.connected
        var rows = connected.map {
            Row(identity: $0.identity, name: $0.name, builtIn: $0.builtIn, connected: true,
                kind: KeyboardLayout.Kind(apple: $0.apple, iso: $0.iso))
        }
        for d in KeyboardStore.shared.devices where !rows.contains(where: { $0.identity == d.identity }) {
            rows.append(Row(identity: d.identity, name: d.name, builtIn: false, connected: false))
        }
        return rows
    }

    var body: some View {
        Form {
            Section {
                note("키보드마다 따로 정합니다. 여기서 바꾸는 키는 그 키보드에만 적용되고, 수정키(⌥ ⌘ 등)도 바꿀 수 있습니다. "
                    + "바뀐 키에 키보드 규칙이 걸립니다. 규칙 하나를 어떤 키보드에서만 쓰려면 \"키보드 규칙\" 에서 규칙의 … › 적용할 키보드. "
                    + "\"Hanmium 이 키보드 규칙으로 키 바꾸기\" 를 켜야 동작합니다.")
            }
            ForEach(Self.known(), id: \.identity) { row in
                Section {
                    Toggle("키보드 규칙 적용", isOn: Binding(
                        get: { !(settings(row.identity)?.ignore ?? false) },
                        set: { on in edit(row) { $0.ignore = !on } }))
                    if row.connected { layout(row) }
                    let simple = settings(row.identity)?.simple ?? []
                    ForEach(Array(simple.enumerated()), id: \.element.id) { i, _ in
                        HStack {
                            KeyPicker(title: "바꿀 키", selection: binding(row, i, \.from))
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            KeyPicker(title: "바뀐 키", selection: binding(row, i, \.to))
                            Spacer()
                            Button { edit(row) { $0.simple.remove(at: i) } } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("바꿀 키 추가") { edit(row) { $0.simple.append(SimpleModification(from: "left_option", to: "left_command")) } }
                        Spacer()
                        let rules = store.rules.filter { $0.keyboards.contains(row.identity) }.count
                        if rules > 0 { Text("이 키보드에만 쓰는 규칙 \(rules)개").font(.caption).foregroundStyle(.secondary) }
                    }
                } header: {
                    HStack {
                        Text(row.name)
                        if row.builtIn { Text("내장").foregroundStyle(.secondary) }
                        if !row.connected { Text("연결 안 됨").foregroundStyle(.secondary) }
                        Spacer()
                        Text(String(format: "%04X:%04X", row.identity.vendorID, row.identity.productID))
                            .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        if !row.connected, settings(row.identity) != nil {
                            Button("설정 지우기") { store.devices.removeAll { $0.identity == row.identity } }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices.refresh() }
    }

    /// 키보드 그림 + 고른 키 바꾸기 + 범례
    @ViewBuilder private func layout(_ row: Row) -> some View {
        let s = settings(row.identity)
        let mapped = Dictionary((s?.simple ?? []).map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        KeyboardLayoutView(identity: row.identity, kind: row.kind, mapped: mapped,
                           ruleKeys: ruleKeys(row.identity, ignore: s?.ignore ?? false))
            .padding(.vertical, 4)
        if ui.layoutDevice == row.identity, let key = ui.layoutKey {
            HStack {
                Text(KeyNames.display(key) + " 키를")
                KeyPicker(title: "바뀐 키", selection: Binding(
                    get: { mapped[key] ?? key },
                    set: { to in setMapping(row, key, to) }))
                Text("로")
                Button("원래대로") { setMapping(row, key, key) }.disabled(mapped[key] == nil)
                Spacer()
                Button("닫기") { ui.layoutKey = nil; ui.layoutDevice = nil }
            }
        }
        HStack(spacing: 14) {
            legend(Color.accentColor.opacity(0.22), "이 키보드에서 바꾼 키")
            HStack(spacing: 4) { Circle().fill(Color.orange).frame(width: 7, height: 7); Text("키보드 규칙이 쓰는 키") }
            Text("키를 누르면 바꿀 수 있습니다")
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        if row.kind.iso {
            note("macOS 가 이 키보드를 ISO 배열로 봅니다: 왼쪽 위 키가 §, 왼쪽 ⇧ 옆 키가 ₩(`) 로 들어옵니다.")
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 9)
            Text(text)
        }
    }

    /// 그 키보드에서 키보드 규칙이 쓰는 키 → 규칙 설명들
    private func ruleKeys(_ id: KeyboardIdentity, ignore: Bool) -> [String: [String]] {
        guard !ignore else { return [:] }
        var out: [String: [String]] = [:]
        for rule in store.rules where rule.enabled && (rule.keyboards.isEmpty || rule.keyboards.contains(id)) {
            for m in rule.manipulators.compactMap({ $0 }) where m.isSupported {
                guard let k = m.from.keyCode, !(out[k]?.contains(rule.description) ?? false) else { continue }
                out[k, default: []].append(rule.description)
            }
        }
        return out
    }

    /// key 를 to 로(같으면 바꾸기를 지운다)
    private func setMapping(_ row: Row, _ key: String, _ to: String) {
        edit(row) { s in
            s.simple.removeAll { $0.from == key }
            if to != key { s.simple.append(SimpleModification(from: key, to: to)) }
        }
    }

    private func settings(_ id: KeyboardIdentity) -> KeyboardDeviceSettings? {
        store.devices.first { $0.identity == id }
    }

    /// 그 키보드 설정을 고친다(없으면 만든다). 아무것도 안 남으면 지운다.
    private func edit(_ row: Row, _ change: (inout KeyboardDeviceSettings) -> Void) {
        var list = store.devices
        let i = list.firstIndex { $0.identity == row.identity } ?? {
            list.append(KeyboardDeviceSettings(identity: row.identity, name: row.name))
            return list.count - 1
        }()
        change(&list[i])
        list[i].name = row.name
        if !list[i].ignore && list[i].simple.isEmpty { list.remove(at: i) }
        store.devices = list
    }

    private func binding(_ row: Row, _ i: Int, _ key: WritableKeyPath<SimpleModification, String>) -> Binding<String> {
        Binding(get: {
            let simple = settings(row.identity)?.simple ?? []
            return simple.indices.contains(i) ? simple[i][keyPath: key] : ""
        }, set: { v in
            edit(row) { s in if s.simple.indices.contains(i) { s.simple[i][keyPath: key] = v } }
        })
    }
}

// MARK: - 매개변수

struct KeyboardParamsView: View {
    @ObservedObject var store = KeyboardStore.shared

    var body: some View {
        Form {
            Section("키보드 규칙") {
                LabeledContent("혼자 누르기(to_if_alone) 제한 시간") {
                    NumberField(value: Binding(get: { store.parameters.aloneTimeout },
                                               set: { store.parameters.aloneTimeout = $0 }), range: 50...5000)
                        .frame(width: 70)
                    Text("ms")
                }
                note("키를 누른 뒤 이 시간 안에 다른 키 없이 떼야 to_if_alone 이 나갑니다(Karabiner 의 basic.to_if_alone_timeout_milliseconds, "
                    + "기본 1000). 규칙에 따로 적은 값이 먼저입니다.")
            }
            Section("마우스 키 (mouse_key)") {
                LabeledContent("포인터 속도") {
                    Slider(value: Binding(get: { Double(store.parameters.pointerScale) },
                                          set: { store.parameters.pointerScale = Int($0) }), in: 20...400, step: 5)
                    Text("\(store.parameters.pointerScale)%").monospacedDigit().frame(width: 48)
                }
                LabeledContent("휠 속도") {
                    Slider(value: Binding(get: { Double(store.parameters.wheelScale) },
                                          set: { store.parameters.wheelScale = Int($0) }), in: 20...400, step: 5)
                    Text("\(store.parameters.wheelScale)%").monospacedDigit().frame(width: 48)
                }
                note("100% 일 때 mouse_key 의 x·y 1536 이 초당 1000pt, 휠 48 이 초당 1000pt 입니다. "
                    + "포인터는 처음 0.15초 동안 천천히 출발해 조금씩 옮기기 쉽습니다.")
            }
        }
        .formStyle(.grouped)
    }
}
