import AppKit
import Carbon

// MARK: - 전역 단축키 (Carbon RegisterEventHotKey: 접근성 권한 없이도 동작)

struct KeyCombo {
    let keyCode: UInt32
    let modifiers: UInt32
    /// 메뉴에 보여줄 표기 (예: ⌥Space)
    let display: String

    /// "ctrl+opt+space", "cmd+shift+j" 같은 문자열을 해석한다.
    init?(_ spec: String) {
        var mods: UInt32 = 0
        var key: UInt32?
        var keyName = ""
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "ctrl", "control": mods |= UInt32(controlKey)
            default:
                key = KeyCombo.keyCodes[part]
                keyName = part.count > 1 ? part.prefix(1).uppercased() + part.dropFirst() : part.uppercased()
            }
        }
        guard let key else { return nil }
        keyCode = key
        modifiers = mods
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        display = symbols.filter { mods & UInt32($0.0) != 0 }.map(\.1).joined() + keyName
    }

    /// 설정 창에서 녹화한 키 입력을 "ctrl+opt+space" 형식으로. 수정키가 없거나 모르는 키면 nil.
    static func spec(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        guard !parts.isEmpty,
              let name = keyCodes.first(where: { $0.value == UInt32(keyCode) && $0.key != "esc" })?.key else { return nil }
        return (parts + [name]).joined(separator: "+")
    }

    /// ANSI 배열 기준 가상 키 코드
    static let keyCodes: [String: UInt32] = {
        let letters = "asdfhgzxcv_bqweryt123465=97-80]ou[ip_lj'k;\\,/nm."
        var map: [String: UInt32] = [:]
        for (i, c) in letters.enumerated() where c != "_" { map[String(c)] = UInt32(i) }
        map.merge(["return": 36, "tab": 48, "space": 49, "`": 50, "escape": 53, "esc": 53]) { $1 }
        return map
    }()
}

final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            HotKeys.shared.handlers[id.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    func register(_ combo: KeyCombo, _ handler: @escaping () -> Void) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x484E_4D31), id: nextID)  // 'HNM1'
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[nextID] = handler
        nextID += 1
        return true
    }
}

// MARK: - 키 코드 → 문자

enum KeyTranslator {
    /// 입력기가 한글이어도 ASCII 자판 기준 문자를 돌려준다 ('ㄹ' 대신 'f'). 수정키는 무시하고 소문자로.
    static func character(for keyCode: UInt16) -> Character? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).lowercased().first
    }
}

// MARK: - 마우스 이벤트 합성

enum Mouse {
    enum Button { case left, right }

    static func click(at p: CGPoint, button: Button = .left, flags: CGEventFlags = [], count: Int = 1) {
        let source = CGEventSource(stateID: .hidSystemState)
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) =
            button == .left ? (.leftMouseDown, .leftMouseUp, .left) : (.rightMouseDown, .rightMouseUp, .right)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        for n in 1...max(count, 1) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                      mouseCursorPosition: p, mouseButton: cgButton) else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.flags = flags
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// 휠 이벤트를 커서 위치로 보낸다. 받는 창은 커서 아래 창이므로 호출하는 쪽이 커서를 p 로 옮겨둬야 한다.
    /// by.dy > 0 이면 아래 내용이 보이도록(아래로) 스크롤
    static func scroll(by: CGVector, at p: CGPoint) {
        guard let e = scrollEvent(by) else { return }
        e.location = p
        e.post(tap: .cghidEventTap)
    }

    struct Target {
        let pid: pid_t
        let window: CGWindowID
        let windowOrigin: CGPoint
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    /// 비공개 CGEventSetWindowLocation. 이후 macOS 에서 사라지면 nil 이고 커서를 옮기는 방식으로 돌아간다.
    private static let setWindowLocation: SetWindowLocation? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
            .map { unsafeBitCast($0, to: SetWindowLocation.self) }

    static var canTargetWindows: Bool { setWindowLocation != nil }

    /// 커서를 옮기지 않고 특정 창에 휠 이벤트를 보낸다. 앱은 이벤트에 적힌 창 번호와 창 기준 좌표로 받을 뷰를 찾는다.
    /// 창이 가려져 있어도 되고, 커서가 링크 위에 올라가 미리보기가 뜨는 일도 없다.
    static func scroll(by: CGVector, at p: CGPoint, to target: Target) -> Bool {
        guard let setWindowLocation, let e = scrollEvent(by) else { return false }
        let window = Int64(target.window)
        e.location = p
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: window)
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: window)
        e.setIntegerValueField(CGEventField(rawValue: 51)!, value: window)  // 비공개: 이벤트를 받을 창
        setWindowLocation(e, CGPoint(x: p.x - target.windowOrigin.x, y: p.y - target.windowOrigin.y))
        e.postToPid(target.pid)
        return true
    }

    private static func scrollEvent(_ by: CGVector) -> CGEvent? {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: Int32(-by.dy), wheel2: Int32(-by.dx), wheel3: 0)
    }
}
