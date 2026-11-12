import CoreGraphics
import Foundation

/// 키 입력 하나를 받아 무엇을 내보낼지 정한다(KeyboardTap 이 실제로 보낸다). 시스템을 건드리지 않아서 따로 시험할 수 있다
/// (Tools/KeyboardFixtures). Karabiner-Elements 의 basic 조작과 같은 순서·뜻으로 동작한다:
/// - 규칙을 위에서부터, 조작을 위에서부터 보고 처음 맞는 것 하나만 쓴다. 맞는 것이 없으면 단순 바꾸기, 그것도 없으면 그대로.
/// - from 의 mandatory 수정키는 내보내는 키에서 뺀다. optional 은 그대로 둔다. 둘 다 없으면 수정키를 누르지 않았을 때만 맞는다.
/// - to 의 마지막 키·버튼은 from 키를 뗄 때까지 누르고 있는다(반복 입력도 그 키로). 그 앞 것은 눌렀다 뗀다.
/// - to_if_alone 은 그 키를 누른 동안 다른 키·버튼을 누르지 않고 제한 시간 안에 뗐을 때 눌렀다 뗀다.
/// - to_after_key_up 은 뗄 때. mouse_key 는 누르고 있는 동안 계속.
final class KeyboardEngine {
    enum Output: Equatable {
        /// 받은 입력을 그대로 보낸다(이것만 있을 때)
        case pass
        case key(UInt16, down: Bool, flags: CGEventFlags, isRepeat: Bool)
        /// 1 왼쪽, 2 오른쪽, 3 가운데, 4 뒤로, 5 앞으로
        case button(Int, down: Bool, flags: CGEventFlags)
        case motionStart(Int, MouseKeyVector, flags: CGEventFlags)
        case motionStop(Int)
        case hanmium(String)
    }

    struct Rules {
        var manipulators: [KeyManipulator] = []
        var simple: [UInt16: UInt16] = [:]
        var aloneTimeout: Double = 1.0
    }

    var rules = Rules()
    var variables: [String: KeyVarValue] = [:]
    /// 조건 frontmost_application_if 에 쓴다
    var frontmost: () -> String? = { nil }
    /// {"hanmium": …} 를 지금 열 수 있는지(Hanmium 이 꺼졌거나 그 앱에서 쓰지 않으면 원래 키가 가게 한다)
    var hanmiumAvailable: (String) -> Bool = { _ in true }

    private struct Active {
        var passthrough = false
        var simpleTo: UInt16?
        /// to 의 마지막 키: from 키를 뗄 때까지 누르고 있는다
        var heldKey: (code: UInt16, flags: CGEventFlags)?
        var heldButton: (number: Int, flags: CGEventFlags)?
        var motions: [Int] = []
        var afterUp: [KeyToEvent] = []
        var alone: [KeyToEvent]?
        var aloneStart: Double = 0
        var aloneTimeout: Double = 1
        var interrupted = false
        /// mandatory 로 쓴 수정키(내보내는 키에서 뺀다)
        var strip: CGEventFlags = []
    }

    private var active: [UInt16: Active] = [:]
    private var nextMotion = 1
    private var lastFlags: CGEventFlags = []

    func reset() {
        active.removeAll()
        variables.removeAll()
    }

    /// 다른 키나 마우스 버튼을 눌렀다: 누르고 있는 키들의 to_if_alone 은 이제 나가지 않는다
    func interrupt() {
        for code in active.keys { active[code]?.interrupted = true }
    }

    func keyDown(_ code: UInt16, flags: CGEventFlags, isRepeat: Bool, time: Double) -> [Output] {
        if isRepeat || active[code] != nil { return repeatKey(code) }
        interrupt()
        for m in rules.manipulators {
            guard let strip = match(m, code: code, flags: flags) else { continue }
            return apply(m, code: code, flags: flags, strip: strip, time: time)
        }
        if let to = rules.simple[code] {
            active[code] = Active(simpleTo: to)
            return [.key(to, down: true, flags: Self.outputFlags(flags, strip: [], adding: [], for: to), isRepeat: false)]
        }
        active[code] = Active(passthrough: true)
        return [.pass]
    }

    func keyUp(_ code: UInt16, flags: CGEventFlags, time: Double) -> [Output] {
        guard let a = active.removeValue(forKey: code) else { return [.pass] }
        if a.passthrough { return [.pass] }
        if let to = a.simpleTo {
            return [.key(to, down: false, flags: Self.outputFlags(flags, strip: [], adding: [], for: to), isRepeat: false)]
        }
        var out: [Output] = []
        if let held = a.heldKey { out.append(.key(held.code, down: false, flags: held.flags, isRepeat: false)) }
        if let b = a.heldButton { out.append(.button(b.number, down: false, flags: b.flags)) }
        out += a.motions.map { .motionStop($0) }
        out += tap(a.afterUp, flags: flags, strip: a.strip)
        if let alone = a.alone, !a.interrupted, time - a.aloneStart < a.aloneTimeout {
            out += tap(alone, flags: flags, strip: a.strip)
        }
        return out
    }

    /// 수정키가 바뀜(flagsChanged). 새로 누른 수정키는 다른 키를 누른 것과 같다.
    func flagsChanged(_ flags: CGEventFlags) -> [Output] {
        let mods: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let before = lastFlags.intersection(mods), now = flags.intersection(mods)
        if !now.subtracting(before).isEmpty { interrupt() }
        lastFlags = flags
        return [.pass]
    }

    private func repeatKey(_ code: UInt16) -> [Output] {
        guard let a = active[code] else { return [.pass] }
        if a.passthrough { return [.pass] }
        if let to = a.simpleTo { return [.key(to, down: true, flags: Self.outputFlags(lastFlags, strip: [], adding: [], for: to), isRepeat: true)] }
        if let held = a.heldKey { return [.key(held.code, down: true, flags: held.flags, isRepeat: true)] }
        return []
    }

    // MARK: 맞추기

    /// 맞으면 mandatory 로 쓴 수정키(뺄 것), 아니면 nil
    private func match(_ m: KeyManipulator, code: UInt16, flags: CGEventFlags) -> CGEventFlags? {
        guard m.isSupported, let from = m.from.keyCode, KeyNames.code(from) == code else { return nil }
        guard let strip = Self.matchModifiers(m.from.modifiers, flags: flags, code: code) else { return nil }
        for c in m.conditions where !condition(c) { return nil }
        // Hanmium 을 지금 열 수 없으면(꺼짐·이 앱에서 쓰지 않음) 이 조작은 없는 것으로 친다
        for e in m.to where e.hanmium != nil && !hanmiumAvailable(e.hanmium!) { return nil }
        return strip
    }

    private func condition(_ c: KeyCondition) -> Bool {
        switch c.type {
        case "variable_if", "variable_unless":
            let value = variables[c.name ?? ""] ?? .int(0)
            let equal = Self.same(value, c.value ?? .int(0))
            return c.type == "variable_if" ? equal : !equal
        case "frontmost_application_if", "frontmost_application_unless":
            let id = frontmost() ?? ""
            let hit = (c.bundleIdentifiers ?? []).contains { pattern in
                id.range(of: pattern, options: .regularExpression) != nil
            }
            return c.type == "frontmost_application_if" ? hit : !hit
        default:
            return false
        }
    }

    /// 정한 적 없는 변수(0)와 false, 1 과 true 는 같다고 본다
    private static func same(_ a: KeyVarValue, _ b: KeyVarValue) -> Bool {
        func normalized(_ v: KeyVarValue) -> KeyVarValue {
            if case .bool(let x) = v { return .int(x ? 1 : 0) }
            return v
        }
        return normalized(a) == normalized(b)
    }

    // MARK: 수정키

    /// 이름 → (일반 플래그, 왼쪽·오른쪽 장치 비트)
    private static let sides: [(name: String, generic: CGEventFlags, left: UInt64, right: UInt64)] = [
        ("shift", .maskShift, 0x02, 0x04),
        ("control", .maskControl, 0x01, 0x2000),
        ("option", .maskAlternate, 0x20, 0x40),
        ("command", .maskCommand, 0x08, 0x10),
    ]

    /// 화살표·Home 등은 fn 없이 눌러도 fn 플래그가 붙어 온다
    private static func inherentFn(_ code: UInt16) -> Bool {
        (114...126).contains(code) || [96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 64, 79, 80, 90].contains(code)
    }

    /// 지금 눌린 수정키 이름들(왼쪽·오른쪽 구분). 장치 비트가 없으면 왼쪽으로 본다.
    static func pressed(_ flags: CGEventFlags, code: UInt16) -> Set<String> {
        var set = Set<String>()
        for s in sides where flags.contains(s.generic) {
            let raw = flags.rawValue
            let l = raw & s.left != 0, r = raw & s.right != 0
            if l || !r { set.insert("left_" + s.name) }
            if r { set.insert("right_" + s.name) }
        }
        if flags.contains(.maskAlphaShift) { set.insert("caps_lock") }
        if flags.contains(.maskSecondaryFn), !inherentFn(code) { set.insert("fn") }
        return set
    }

    /// 맞으면 뺄 수정키 플래그, 아니면 nil
    static func matchModifiers(_ mods: KeyModifiers?, flags: CGEventFlags, code: UInt16) -> CGEventFlags? {
        var remaining = pressed(flags, code: code)
        var stripped = Set<String>()
        for name in mods?.mandatory ?? [] {
            if sides.contains(where: { $0.name == name }) {
                let hit = remaining.filter { $0 == "left_" + name || $0 == "right_" + name }
                guard !hit.isEmpty else { return nil }
                remaining.subtract(hit)
                stripped.formUnion(hit)
            } else {
                guard remaining.contains(name) else { return nil }
                remaining.remove(name)
                stripped.insert(name)
            }
        }
        let optional = Set(mods?.optional ?? [])
        if !optional.contains("any") {
            for m in remaining where !optional.contains(m) && !optional.contains(KeyboardStore.genericModifier(m)) {
                return nil
            }
        }
        return flagsFor(stripped, keepGenericIf: remaining)
    }

    /// 수정키 이름들의 플래그. keepGenericIf 에 같은 종류(반대쪽)가 남아 있으면 일반 플래그는 두고 장치 비트만.
    static func flagsFor(_ names: Set<String>, keepGenericIf remaining: Set<String> = []) -> CGEventFlags {
        var raw: UInt64 = 0
        for name in names {
            if name == "caps_lock" { raw |= CGEventFlags.maskAlphaShift.rawValue; continue }
            if name == "fn" { raw |= CGEventFlags.maskSecondaryFn.rawValue; continue }
            let generic = KeyboardStore.genericModifier(name)
            guard let s = sides.first(where: { $0.name == generic }) else { continue }
            let right = name.hasPrefix("right_")
            raw |= right ? s.right : s.left
            if !remaining.contains("left_" + generic) && !remaining.contains("right_" + generic) {
                raw |= s.generic.rawValue
            }
        }
        return CGEventFlags(rawValue: raw)
    }

    /// to 에 적은 수정키("shift" 는 왼쪽)
    private static func addFlags(_ names: [String]) -> CGEventFlags {
        flagsFor(Set(names.map { n in sides.contains { $0.name == n } ? "left_" + n : n }))
    }

    /// 내보낼 키의 플래그: 지금 플래그에서 뺄 수정키를 빼고 to 의 수정키를 더한다. 화살표처럼 원래 붙는 플래그는 키에 맞춘다.
    static func outputFlags(_ flags: CGEventFlags, strip: CGEventFlags, adding: CGEventFlags, for code: UInt16?) -> CGEventFlags {
        var raw = flags.rawValue & ~strip.rawValue
        raw &= ~(CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue
            | CGEventFlags.maskNonCoalesced.rawValue)
        raw |= adding.rawValue
        if let code {
            if (123...126).contains(code) { raw |= CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue }
            else if inherentFn(code) { raw |= CGEventFlags.maskSecondaryFn.rawValue }
            else if (65...92).contains(code) { raw |= CGEventFlags.maskNumericPad.rawValue }
        }
        return CGEventFlags(rawValue: raw)
    }

    // MARK: 내보내기

    private func apply(_ m: KeyManipulator, code: UInt16, flags: CGEventFlags, strip: CGEventFlags,
                       time: Double) -> [Output] {
        var a = Active(strip: strip)
        a.aloneTimeout = (m.parameters[KeyParameters.aloneKey] ?? rules.aloneTimeout * 1000) / 1000
        var out: [Output] = []
        let last = m.to.lastIndex { $0.keyCode != nil || $0.pointingButton != nil }
        for (i, e) in m.to.enumerated() {
            if let v = e.setVariable { variables[v.name] = v.value }
            if let h = e.hanmium { out.append(.hanmium(h)) }
            if let name = e.keyCode, let kc = KeyNames.code(name) {
                let f = Self.outputFlags(flags, strip: strip, adding: Self.addFlags(e.modifiers), for: kc)
                out.append(.key(kc, down: true, flags: f, isRepeat: false))
                if i == last { a.heldKey = (kc, f) } else { out.append(.key(kc, down: false, flags: f, isRepeat: false)) }
            }
            if let name = e.pointingButton, let n = KeyToEvent.buttonNumber(name) {
                let f = Self.outputFlags(flags, strip: strip, adding: Self.addFlags(e.modifiers), for: nil)
                out.append(.button(n, down: true, flags: f))
                if i == last { a.heldButton = (n, f) } else { out.append(.button(n, down: false, flags: f)) }
            }
            if let v = e.mouseKey {
                let id = nextMotion
                nextMotion += 1
                out.append(.motionStart(id, v, flags: Self.outputFlags(flags, strip: strip, adding: [], for: nil)))
                a.motions.append(id)
            }
        }
        a.afterUp = m.toAfterKeyUp
        if let alone = m.toIfAlone {
            a.alone = alone
            a.aloneStart = time
        }
        active[code] = a
        return out
    }

    /// 눌렀다 바로 떼는 것들(to_after_key_up, to_if_alone)
    private func tap(_ events: [KeyToEvent], flags: CGEventFlags, strip: CGEventFlags) -> [Output] {
        var out: [Output] = []
        for e in events {
            if let v = e.setVariable { variables[v.name] = v.value }
            if let h = e.hanmium { out.append(.hanmium(h)) }
            if let name = e.keyCode, let kc = KeyNames.code(name) {
                let f = Self.outputFlags(flags, strip: strip, adding: Self.addFlags(e.modifiers), for: kc)
                out += [.key(kc, down: true, flags: f, isRepeat: false), .key(kc, down: false, flags: f, isRepeat: false)]
            }
            if let name = e.pointingButton, let n = KeyToEvent.buttonNumber(name) {
                let f = Self.outputFlags(flags, strip: strip, adding: Self.addFlags(e.modifiers), for: nil)
                out += [.button(n, down: true, flags: f), .button(n, down: false, flags: f)]
            }
        }
        return out
    }
}

// MARK: - 사람이 읽는 요약 (설정 창)

extension KeyManipulator {
    var summary: String {
        var parts: [String] = []
        let conds = conditions.compactMap { c -> String? in
            switch c.type {
            case "variable_if": "\(c.name ?? "?") = \(c.value?.description ?? "0")"
            case "variable_unless": "\(c.name ?? "?") ≠ \(c.value?.description ?? "0")"
            case "frontmost_application_if": "앱: " + (c.bundleIdentifiers ?? []).joined(separator: ", ")
            case "frontmost_application_unless": "앱 아님: " + (c.bundleIdentifiers ?? []).joined(separator: ", ")
            default: c.type
            }
        }
        if !conds.isEmpty { parts.append("[" + conds.joined(separator: ", ") + "]") }
        let mandatory = (from.modifiers?.mandatory ?? []).map(Self.symbol).joined()
        parts.append(mandatory + (from.keyCode.map(KeyNames.display) ?? "?"))
        var text = parts.joined(separator: " ") + " → " + Self.describe(to)
        if let alone = toIfAlone { text += " · 혼자 누르면 " + Self.describe(alone) }
        if !toAfterKeyUp.isEmpty { text += " · 뗄 때 " + Self.describe(toAfterKeyUp) }
        if !unsupported.isEmpty { text += "  (지원 안 함: " + unsupported.joined(separator: ", ") + ")" }
        return text
    }

    static func describe(_ events: [KeyToEvent]) -> String {
        if events.isEmpty { return "없음" }
        return events.map { e in
            if let k = e.keyCode { return e.modifiers.map(symbol).joined() + KeyNames.display(k) }
            if let b = e.pointingButton {
                return ["button1": "왼쪽 클릭", "button2": "오른쪽 클릭", "button3": "가운데 클릭",
                        "button4": "뒤로 버튼", "button5": "앞으로 버튼"][b] ?? b
            }
            if let m = e.mouseKey {
                var p: [String] = []
                if let x = m.x { p.append("포인터 \(x < 0 ? "←" : "→")") }
                if let y = m.y { p.append("포인터 \(y < 0 ? "↑" : "↓")") }
                if let v = m.verticalWheel { p.append("휠 \(v < 0 ? "↑" : "↓")") }
                if let h = m.horizontalWheel { p.append("휠 \(h < 0 ? "←" : "→")") }
                return p.joined(separator: " ")
            }
            if let v = e.setVariable { return "\(v.name) = \(v.value)" }
            if let h = e.hanmium {
                return ["labels": "Hanmium 라벨", "search": "Hanmium 검색", "scroll": "Hanmium 스크롤"][h] ?? h
            }
            return e.unsupported.first ?? "?"
        }.joined(separator: ", ")
    }

    static func symbol(_ name: String) -> String {
        let generic = KeyboardStore.genericModifier(name)
        let s = ["shift": "⇧", "control": "⌃", "option": "⌥", "command": "⌘", "caps_lock": "⇪", "fn": "fn ",
                 "any": ""][generic] ?? name
        if name.hasPrefix("left_") { return "왼" + s }
        if name.hasPrefix("right_") { return "오" + s }
        return s
    }
}
