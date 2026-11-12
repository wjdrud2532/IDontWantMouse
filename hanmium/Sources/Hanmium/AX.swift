import AppKit
import ApplicationServices

/// AX API 결과(CFTypeRef)를 Swift 값으로 꺼내는 헬퍼.
enum AX {
    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success ? value : nil
    }

    /// 여러 속성을 IPC 한 번으로 가져온다. 실패한 속성은 nil.
    static func multi(_ el: AXUIElement, _ attrs: [String]) -> [CFTypeRef?] {
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard err == .success, let values = out as? [AnyObject], values.count == attrs.count else {
            return Array(repeating: nil, count: attrs.count)
        }
        return values.map { v in
            // 가져오지 못한 속성은 kAXValueAXErrorType 인 AXValue 로 채워져 온다
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func string(_ v: CFTypeRef?) -> String? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        return s
    }

    static func bool(_ v: CFTypeRef?) -> Bool? { v as? Bool }

    /// 요소의 화면 위치·크기
    static func frame(_ ref: AXUIElement) -> CGRect? {
        let v = multi(ref, [kAXPositionAttribute, kAXSizeAttribute])
        guard let o = point(v[0]), let s = size(v[1]) else { return nil }
        return CGRect(origin: o, size: s)
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ v: CFTypeRef?) -> [AXUIElement] {
        guard let items = v as? [AnyObject] else { return [] }
        return items.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// AX 창 요소의 CGWindowID (비공개 API).
    static func windowID(_ window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    /// 글자 요소에서 range 글자들이 그려진 사각형 (AX 좌표계). 글자 요소가 아니면 nil.
    static func boundsForRange(_ el: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, value, &out)
                == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(out as! AXValue, .cgRect, &rect) ? rect : nil
    }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 화면 위 UI 요소 하나. 좌표는 모두 AX 좌표계(주 화면 좌상단 원점, y 아래로 증가).
final class Element {
    let ref: AXUIElement
    let role: String
    let subrole: String?
    let frame: CGRect
    /// 창·스크롤 영역에 잘리고 남은, 실제로 보이는 부분
    let visibleFrame: CGRect
    let title: String?
    let desc: String?
    let help: String?
    let placeholder: String?
    let enabled: Bool
    let activationPoint: CGPoint?
    /// 팝업 버튼의 선택값, 하위 정적 텍스트 등 검색에 쓰는 추가 문자열
    var extraText: [String] = []
    /// WezTerm 패널이면 그 번호. 누르면 마우스 대신 wezterm cli 로 옮긴다.
    var wezTermPane: Int?
    /// 여러 줄로 접힌 링크의 첫 글자 자리 (locateTextStart)
    var textStart: CGPoint?

    static let batchAttributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue",
        kAXEnabledAttribute, "AXActivationPoint",
    ]

    static func fetch(_ ref: AXUIElement, clip: CGRect) -> Element? {
        let v = AX.multi(ref, batchAttributes)
        guard let role = AX.string(v[0]) else { return nil }
        var frame = CGRect.zero
        if let origin = AX.point(v[2]), let size = AX.size(v[3]) {
            frame = CGRect(origin: origin, size: size)
        }
        return Element(
            ref: ref, role: role, subrole: AX.string(v[1]), frame: frame,
            visibleFrame: frame.intersection(clip),
            title: AX.string(v[4]), desc: AX.string(v[5]), help: AX.string(v[6]),
            placeholder: AX.string(v[7]), enabled: AX.bool(v[8]) ?? true,
            activationPoint: AX.point(v[9]))
    }

    /// AX 요소가 따로 없는 영역(WezTerm 패널 등). ref 는 그 영역을 품은 창.
    static func region(_ frame: CGRect, in window: Element, role: String, title: String? = nil) -> Element {
        Element(ref: window.ref, role: role, subrole: nil, frame: frame,
                visibleFrame: frame.intersection(window.visibleFrame), title: title, desc: nil, help: nil,
                placeholder: nil, enabled: true, activationPoint: nil)
    }

    private init(ref: AXUIElement, role: String, subrole: String?, frame: CGRect, visibleFrame: CGRect,
                 title: String?, desc: String?, help: String?, placeholder: String?, enabled: Bool,
                 activationPoint: CGPoint?) {
        self.ref = ref
        self.role = role
        self.subrole = subrole
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.title = title
        self.desc = desc
        self.help = help
        self.placeholder = placeholder
        self.enabled = enabled
        self.activationPoint = activationPoint
    }

    var isVisible: Bool { !visibleFrame.isNull && visibleFrame.width >= 3 && visibleFrame.height >= 3 }

    /// 클릭할 위치. 여러 줄로 접힌 링크는 첫 글자, 앱이 알려준 activation point 가 보이는 영역 안이면 그것, 아니면 가운데.
    var clickPoint: CGPoint {
        if let p = textStart, visibleFrame.contains(p) { return p }
        if let p = activationPoint, visibleFrame.insetBy(dx: -1, dy: -1).contains(p) { return p }
        return CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    }

    /// 두 줄 넘게 접힌 링크의 틀은 첫 줄 오른쪽과 마지막 줄 왼쪽을 함께 감싸서, 가운데가 줄 사이 빈 곳이거나
    /// 글자가 없는 쪽이라 눌러도 링크가 아니다(Claude 앱의 긴 URL). 안쪽 글자 요소에 첫 글자 자리를 물어서
    /// 틀이 그 글자보다 1.5배 넘게 높고 글자가 위쪽에 있으면(여백만 있는 한 줄 링크는 글자가 가운데) 첫 글자를 누른다.
    /// 글자 요소는 바로 아래이거나 span 으로 한두 겹 싸여 있다. 보통 AX 두 번.
    func locateTextStart() {
        guard role == "AXLink", frame.height >= 26 else { return }
        var node = ref
        for _ in 0..<3 {
            guard let first = AX.elements(AX.copy(node, kAXChildrenAttribute)).first else { return }
            if let c = AX.boundsForRange(first, location: 0, length: 1), c.height > 0 {
                if frame.height > c.height * 1.5, c.midY < frame.midY - c.height * 0.3 {
                    textStart = CGPoint(x: c.midX, y: c.midY)
                }
                return
            }
            node = first
        }
    }

    var searchTexts: [String] { [title, desc, placeholder, help].compactMap { $0 } + extraText }

    var summary: String {
        let name = String(role.dropFirst(2))
        guard let line = searchTexts.first?.split(whereSeparator: \.isNewline).first else { return name }
        return "\(name) · \(line.prefix(60))"
    }
}

extension CGRect {
    func isClose(to r: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - r.minX) <= tolerance && abs(minY - r.minY) <= tolerance
            && abs(width - r.width) <= tolerance && abs(height - r.height) <= tolerance
    }
}
