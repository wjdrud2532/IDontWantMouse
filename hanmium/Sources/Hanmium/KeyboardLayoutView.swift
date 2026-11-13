import SwiftUI

// 키보드별 설정 화면의 키보드 그림. 키마다 macOS 가 받는 키(키 코드 이름)로 그리고, 그 키보드에서 바꾼 키는 파랗게 "원래 → 바뀐 키"로,
// 키보드 규칙이 쓰는 키는 주황 점으로 보인다. 키를 누르면 아래에서 바꿀 키를 고른다.
// 실제 키캡 배치는 키보드마다 달라서 두 가지로만 그린다: Apple(fn ⌃ ⌥ ⌘) 과 PC(⌃ Fn ⌘ ⌥, 숫자 패드 있음). ISO 로 보이는
// 키보드는 왼쪽 위가 §(키 코드 10), 왼쪽 ⇧ 옆에 `(키 코드 50) 이 있다.

/// 그림 속 키 하나. 칸 단위 좌표(1 = 보통 키 하나).
struct LayoutKey: Identifiable {
    let id: Int
    /// Karabiner 키 이름. nil 이면 Mac 에 신호를 보내지 않는 키(PC 키보드의 Fn)
    let name: String?
    let rects: [CGRect]

    var frame: CGRect { rects.dropFirst().reduce(rects[0]) { $0.union($1) } }
}

enum KeyboardLayout {
    struct Kind: Hashable {
        var apple: Bool
        var iso: Bool
        var numpad: Bool { !apple }
    }

    static func size(_ kind: Kind) -> CGSize { CGSize(width: kind.numpad ? 19.5 : 15, height: 6.3) }

    static func keys(_ kind: Kind) -> [LayoutKey] {
        var out: [LayoutKey] = []
        func add(_ name: String?, _ rects: [CGRect]) { out.append(LayoutKey(id: out.count, name: name, rects: rects)) }
        /// 한 줄을 왼쪽부터. "" 는 빈칸.
        func row(_ y: Double, _ items: [(String?, Double)]) {
            var x = 0.0
            for (name, w) in items {
                if name != "" { add(name, [CGRect(x: x, y: y, width: w, height: 1)]) }
                x += w
            }
        }
        let letters = { (s: String) in s.map { (Optional(String($0)), 1.0) } }
        // 기능키 줄
        row(0, [("escape", 1), ("", 0.5)] + (1...4).map { ("f\($0)", 1.0) } + [("", 0.25)]
            + (5...8).map { ("f\($0)", 1.0) } + [("", 0.25)] + (9...12).map { ("f\($0)", 1.0) })
        let y1 = 1.3, y2 = 2.3, y3 = 3.3, y4 = 4.3, y5 = 5.3
        row(y1, [(kind.iso ? "non_us_backslash" : "grave_accent_and_tilde", 1)] + letters("1234567890")
            + [("hyphen", 1), ("equal_sign", 1), ("delete_or_backspace", 2)])
        if kind.iso {
            row(y2, [("tab", 1.5)] + letters("qwertyuiop") + [("open_bracket", 1), ("close_bracket", 1)])
            row(y3, [("caps_lock", 1.75)] + letters("asdfghjkl") + [("semicolon", 1), ("quote", 1), ("backslash", 1)])
            // ISO Enter 는 두 줄에 걸친 ㄱ 모양
            add("return_or_enter", [CGRect(x: 13.5, y: y2, width: 1.5, height: 1.1), CGRect(x: 13.75, y: y2, width: 1.25, height: 2)])
            row(y4, [("left_shift", 1.25), ("grave_accent_and_tilde", 1)] + letters("zxcvbnm")
                + [("comma", 1), ("period", 1), ("slash", 1), ("right_shift", 2.75)])
        } else {
            row(y2, [("tab", 1.5)] + letters("qwertyuiop") + [("open_bracket", 1), ("close_bracket", 1), ("backslash", 1.5)])
            row(y3, [("caps_lock", 1.75)] + letters("asdfghjkl") + [("semicolon", 1), ("quote", 1), ("return_or_enter", 2.25)])
            row(y4, [("left_shift", 2.25)] + letters("zxcvbnm")
                + [("comma", 1), ("period", 1), ("slash", 1), ("right_shift", 2.75)])
        }
        let bottom: [(String?, Double)] = kind.apple
            ? [("fn", 1), ("left_control", 1), ("left_option", 1), ("left_command", 1.25), ("spacebar", 5.5),
               ("right_command", 1.25), ("right_option", 1)]
            : [("left_control", 1.25), (nil, 1), ("left_command", 1.25), ("left_option", 1.25), ("spacebar", 4.75),
               ("right_option", 1.25), ("right_control", 1.25)]
        row(y5, bottom)
        // 화살표: ← (↑ 위 ↓ 아래) →
        add("left_arrow", [CGRect(x: 12, y: y5 + 0.5, width: 1, height: 0.5)])
        add("up_arrow", [CGRect(x: 13, y: y5, width: 1, height: 0.5)])
        add("down_arrow", [CGRect(x: 13, y: y5 + 0.5, width: 1, height: 0.5)])
        add("right_arrow", [CGRect(x: 14, y: y5 + 0.5, width: 1, height: 0.5)])
        if kind.numpad {
            let x = 15.5
            func pad(_ name: String, _ c: Double, _ y: Double, w: Double = 1, h: Double = 1) {
                add(name, [CGRect(x: x + c, y: y, width: w, height: h)])
            }
            for (i, n) in ["keypad_num_lock", "keypad_slash", "keypad_asterisk", "keypad_hyphen"].enumerated() { pad(n, Double(i), y1) }
            for (i, n) in ["7", "8", "9"].enumerated() { pad("keypad_" + n, Double(i), y2) }
            for (i, n) in ["4", "5", "6"].enumerated() { pad("keypad_" + n, Double(i), y3) }
            for (i, n) in ["1", "2", "3"].enumerated() { pad("keypad_" + n, Double(i), y4) }
            pad("keypad_plus", 3, y2, h: 2)
            pad("keypad_enter", 3, y4, h: 2)
            pad("keypad_0", 0, y5, w: 2)
            pad("keypad_period", 2, y5)
        }
        return out
    }

    /// 키캡에 쓸 짧은 글자
    static func label(_ name: String) -> String {
        if let s = short[name] { return s }
        if name.hasPrefix("keypad_") { return label(String(name.dropFirst(7))) }
        return KeyNames.display(name)
    }

    private static let short: [String: String] = [
        "grave_accent_and_tilde": "₩", "non_us_backslash": "§", "escape": "esc", "tab": "⇥", "caps_lock": "⇪",
        "left_shift": "⇧", "right_shift": "⇧", "left_control": "⌃", "right_control": "⌃", "left_option": "⌥",
        "right_option": "⌥", "left_command": "⌘", "right_command": "⌘", "fn": "fn", "spacebar": "space",
        "return_or_enter": "↩", "delete_or_backspace": "⌫", "delete_forward": "⌦", "left_arrow": "←",
        "right_arrow": "→", "up_arrow": "↑", "down_arrow": "↓", "enter": "⌤", "num_lock": "num", "asterisk": "*",
        "plus": "+", "hyphen": "-", "slash": "/", "period": ".", "equal_sign": "=", "home": "home", "end": "end",
        "page_up": "pgup", "page_down": "pgdn", "lang1": "한/영", "lang2": "한자", "application": "≣",
    ]
}

/// 키보드 하나의 그림
struct KeyboardLayoutView: View {
    let identity: KeyboardIdentity
    let kind: KeyboardLayout.Kind
    /// 이 키보드에서 바꾼 키: 원래 → 바뀐 키
    let mapped: [String: String]
    /// 키보드 규칙이 쓰는 키 → 규칙 설명들
    let ruleKeys: [String: [String]]
    @ObservedObject var ui = KeyboardUI.shared

    var body: some View {
        let size = KeyboardLayout.size(kind)
        GeometryReader { g in
            let u = g.size.width / size.width
            ZStack(alignment: .topLeading) {
                ForEach(KeyboardLayout.keys(kind)) { key in
                    cap(key, u: u)
                }
            }
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
    }

    private func cap(_ key: LayoutKey, u: CGFloat) -> some View {
        let gap = 0.07 * u
        let frame = key.frame
        let to = key.name.flatMap { mapped[$0] }
        // 규칙은 바뀐 뒤의 키로 맞춘다
        let rules = (to ?? key.name).flatMap { ruleKeys[$0] } ?? []
        let selected = ui.layoutDevice == identity && ui.layoutKey == key.name && key.name != nil
        func shape(_ inset: CGFloat) -> Path {
            var p = Path()
            for r in key.rects {
                let rect = CGRect(x: (r.minX - frame.minX) * u + inset, y: (r.minY - frame.minY) * u + inset,
                                  width: r.width * u - inset * 2, height: r.height * u - inset * 2)
                p.addRoundedRect(in: rect, cornerSize: CGSize(width: 0.12 * u, height: 0.12 * u))
            }
            return p
        }
        let fill: Color = to != nil ? Color.accentColor.opacity(0.3) : Color(nsColor: .controlBackgroundColor)
        let edge: Color = selected ? .accentColor : to != nil ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35)
        return ZStack(alignment: .topLeading) {
            shape(gap).fill(edge)
            shape(gap + (selected ? 2 : 1)).fill(fill)
            Group {
                if let name = key.name, let to {
                    VStack(spacing: 0) {
                        Text(KeyboardLayout.label(name)).font(.system(size: u * 0.24)).foregroundStyle(.secondary)
                        Text(KeyboardLayout.label(to)).font(.system(size: u * 0.36, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                } else if let name = key.name {
                    Text(KeyboardLayout.label(name)).font(.system(size: u * 0.32))
                } else {
                    Text("Fn").font(.system(size: u * 0.3)).foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: frame.width * u, height: min(frame.height, 1) * u)
            if !rules.isEmpty {
                Circle().fill(Color.orange).frame(width: u * 0.16, height: u * 0.16)
                    .offset(x: frame.width * u - gap - u * 0.24, y: gap + u * 0.08)
            }
        }
        .frame(width: frame.width * u, height: frame.height * u, alignment: .topLeading)
        .contentShape(Rectangle())
        .help(help(key, to: to, rules: rules))
        .onTapGesture {
            guard let name = key.name else { return }
            let same = ui.layoutDevice == identity && ui.layoutKey == name
            ui.layoutDevice = same ? nil : identity
            ui.layoutKey = same ? nil : name
        }
        .offset(x: frame.minX * u, y: frame.minY * u)
    }

    private func help(_ key: LayoutKey, to: String?, rules: [String]) -> String {
        guard let name = key.name else { return "Mac 에 신호를 보내지 않는 키(키보드 안에서만 쓰는 Fn)라 바꿀 수 없습니다" }
        var first = KeyNames.display(name) + " (" + name + ")"
        if let to { first += " → " + KeyNames.display(to) }
        let lines: [String] = [first] + rules.map { "규칙: " + $0 }
        return lines.joined(separator: "\n")
    }
}
