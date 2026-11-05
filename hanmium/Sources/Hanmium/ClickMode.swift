import AppKit

/// 라벨을 입력하거나(labels) 텍스트로 검색해서(search) 요소를 골라 클릭한다.
///
/// 라벨 모드: 라벨 입력 → 왼쪽 클릭. 마지막 글자를 Shift 와 함께 → 오른쪽 클릭,
///           Cmd → Cmd-클릭(새 탭), Option → 더블클릭. Backspace 로 지우기, '/' 로 검색 전환.
/// 검색 모드: 제목·설명·값으로 찾기. Tab/↓ 다음, Shift-Tab/↑ 이전, Return 클릭
///           (Shift-Return 오른쪽, Cmd-Return Cmd-클릭, Option-Return 더블클릭).
final class ClickMode: NSObject, Mode, NSTextFieldDelegate {
    enum Kind { case labels, search }

    var onExit: (() -> Void)?
    /// 눌러서 닫혔으면 누른 대상 (Esc 로 닫았으면 nil)
    private(set) var clicked: Element?
    private let targets: [Element]
    private let labels: [String]
    private let alphabet: Set<Character>
    private let overlay: Overlay
    private var kind: Kind
    private var typed = ""
    private var results: [Int] = []
    private var focused = 0
    private var field: SearchField?
    private var status: NSTextField?
    private var stopped = false

    init(targets: [Element], kind: Kind, screen: NSScreen) {
        let alphabet = Config.labelAlphabet
        self.targets = targets
        self.labels = LabelMaker.make(count: targets.count, alphabet: alphabet)
        self.alphabet = Set(alphabet)
        self.kind = kind
        self.overlay = Overlay(keyScreen: screen, fades: Config.labelAnimation)
    }

    func start() {
        overlay.paint = { [unowned self] rect in paint(rect) }
        overlay.onKeyDown = { [unowned self] event in keyDown(event) }
        overlay.show()
        if kind == .search { showSearchField() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        overlay.close()
        onExit?()
    }

    // MARK: 그리기

    private func paint(_ rect: CGRect) {
        switch kind {
        case .labels:
            for (i, t) in targets.enumerated() where labels[i].hasPrefix(typed) {
                let p = t.clickPoint
                guard rect.contains(p) else { continue }
                Draw.pill(labels[i].uppercased(), typedCount: typed.count, center: p, within: rect)
            }
        case .search:
            for (n, i) in results.enumerated() {
                let t = targets[i]
                guard rect.intersects(t.visibleFrame) else { continue }
                let accent = Draw.theme.accent
                Draw.box(t.visibleFrame, color: n == focused ? accent : accent.withAlphaComponent(0.45),
                         width: n == focused ? 3 : 1.5)
            }
        }
    }

    // MARK: 라벨 모드

    private func keyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc
            stop()
            return
        case 51:  // Backspace
            if !typed.isEmpty {
                typed.removeLast()
                overlay.redraw()
            }
            return
        default:
            break
        }
        guard let c = KeyTranslator.character(for: event.keyCode) else { return }
        if c == "/" {
            switchToSearch()
            return
        }
        guard alphabet.contains(c) else {
            NSSound.beep()
            return
        }
        let next = typed + String(c)
        let matches = labels.indices.filter { labels[$0].hasPrefix(next) }
        guard !matches.isEmpty else {
            NSSound.beep()
            return
        }
        typed = next
        // 어느 라벨도 다른 라벨의 접두사가 아니어서 완전히 일치하면 후보는 하나뿐이다
        if matches.count == 1, labels[matches[0]] == next {
            click(targets[matches[0]], modifiers: event.modifierFlags)
            return
        }
        overlay.redraw()
    }

    private func click(_ target: Element, modifiers: NSEvent.ModifierFlags) {
        clicked = target
        if let pane = target.wezTermPane {
            stop()
            WezTerm.activate(pane: pane)
            return
        }
        let point = target.clickPoint
        let button: Mouse.Button = modifiers.contains(.shift) ? .right : .left
        let flags: CGEventFlags = modifiers.contains(.command) ? .maskCommand : []
        let count = modifiers.contains(.option) ? 2 : 1
        stop()
        // 오버레이가 사라진 뒤에 클릭해야 포커스가 꼬이지 않는다
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            Mouse.click(at: point, button: button, flags: flags, count: count)
        }
    }

    // MARK: 검색 모드

    private func switchToSearch() {
        kind = .search
        typed = ""
        showSearchField()
        overlay.redraw()
    }

    private func showSearchField() {
        let canvas = overlay.keyCanvas!
        let width: CGFloat = 520
        let x = (canvas.bounds.width - width) / 2
        let y = canvas.bounds.height - 180

        let field = SearchField(frame: NSRect(x: x, y: y, width: width, height: 30))
        field.font = .systemFont(ofSize: 17)
        field.placeholderString = "검색 · Return 클릭 · Tab 다음 · Esc 닫기"
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.delegate = self
        field.onCommandReturn = { [unowned self] in clickFocused(modifiers: .command) }

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: x + 4, y: y + 34, width: width - 8, height: 18)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .white
        status.drawsBackground = true
        status.backgroundColor = NSColor(white: 0.1, alpha: 0.92)
        status.lineBreakMode = .byTruncatingTail

        canvas.addSubview(field)
        canvas.addSubview(status)
        overlay.keyPanel.makeFirstResponder(field)
        self.field = field
        self.status = status
        updateResults()
    }

    func controlTextDidChange(_ notification: Notification) {
        updateResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            stop()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            clickFocused(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
            moveFocus(1)
        case #selector(NSResponder.insertBacktab(_:)), #selector(NSResponder.moveUp(_:)):
            moveFocus(-1)
        default:
            return false
        }
        return true
    }

    private func clickFocused(modifiers: NSEvent.ModifierFlags) {
        guard results.indices.contains(focused) else {
            NSSound.beep()
            return
        }
        click(targets[results[focused]], modifiers: modifiers)
    }

    private func moveFocus(_ delta: Int) {
        guard !results.isEmpty else { return }
        focused = (focused + delta + results.count) % results.count
        updateStatus()
        overlay.redraw()
    }

    private func updateResults() {
        let query = (field?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            results = []
        } else {
            let scored = targets.indices.compactMap { i in Self.score(targets[i], query).map { (i, $0) } }
            results = scored.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                let fa = targets[a.0].visibleFrame, fb = targets[b.0].visibleFrame
                return (fa.minY, fa.minX) < (fb.minY, fb.minX)
            }.map(\.0)
        }
        focused = 0
        updateStatus()
        overlay.redraw()
    }

    private func updateStatus() {
        guard let status else { return }
        if results.isEmpty {
            status.stringValue = field?.stringValue.isEmpty ?? true ? " 대상 \(targets.count)개" : " 일치 없음"
        } else {
            status.stringValue = " \(focused + 1)/\(results.count)  \(targets[results[focused]].summary)"
        }
    }

    /// 완전 일치 3, 접두 일치 2, 포함 1. 비교는 대소문자·NFC/NFD 차이를 무시한다.
    private static func score(_ e: Element, _ query: String) -> Int? {
        var best = 0
        for text in e.searchTexts {
            if text.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 3 }
            if text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
                best = max(best, 2)
            } else if text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                best = max(best, 1)
            }
        }
        return best > 0 ? best : nil
    }
}

/// Cmd-Return 은 필드 에디터의 명령으로 오지 않아서 키 등가물 단계에서 가로챈다.
final class SearchField: NSTextField {
    var onCommandReturn: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

enum LabelMaker {
    /// Vimium 과 같은 방식으로 라벨 n 개를 만든다. 라벨이 적으면 모두 한 글자이고, 모자라면 앞 글자부터
    /// 두 글자(더 모자라면 세 글자)로 늘린다. 늘린 글자는 한 글자 라벨로 쓰지 않으므로 어느 라벨도
    /// 다른 라벨의 접두사가 아니다 — 완전히 일치하면 곧 하나뿐이다.
    static func make(count n: Int, alphabet: [Character]) -> [String] {
        guard n > 0, alphabet.count > 1 else { return [] }
        var hints = [""]
        var offset = 0
        while hints.count - offset < n || hints.count == 1 {
            let hint = hints[offset]
            offset += 1
            for c in alphabet { hints.append(String(c) + hint) }
        }
        return hints[offset..<offset + n].sorted().map { String($0.reversed()) }
    }
}
