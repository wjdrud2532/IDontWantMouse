import AppKit

enum ModeKind: CaseIterable {
    case labels, search, scroll

    var title: String {
        switch self {
        case .labels: "라벨 클릭"
        case .search: "검색"
        case .scroll: "스크롤"
        }
    }

    /// 기본값은 Homerow 에서 쓰던 단축키 그대로
    var defaultHotkey: String {
        switch self {
        case .labels: "opt+space"
        case .search: "opt+/"
        case .scroll: "shift+cmd+j"
        }
    }

    var hotkeyKey: String {
        switch self {
        case .labels: "clickHotkey"
        case .search: "searchHotkey"
        case .scroll: "scrollHotkey"
        }
    }

    var enabledKey: String {
        switch self {
        case .labels: "clickEnabled"
        case .search: "searchEnabled"
        case .scroll: "scrollEnabled"
        }
    }
}

/// 스크롤 영역 테두리·고르지 않은 영역의 모양
enum AreaStyle: String {
    /// 실선(고른 영역) / 점선 + 옅은 칠(고르지 않은 영역)
    case line
    /// 리퀴드 글래스: 고른 영역은 둘레를 감싼 유리 막대, 고르지 않은 영역은 유리판
    case glass
}

/// 스크롤 모드에서 다른 영역을 고를 때 테두리가 옮겨가는 모양
enum FocusMotion: String {
    /// 가는 쪽 변이 먼저 가고 반대쪽이 따라와서 늘어났다가 출렁이며 멈춘다
    case stretch
    /// 작은 물방울로 뭉쳐 날아간 뒤 새 자리에서 테두리로 퍼진다
    case hop
    /// 바로 옮긴다
    case none
}

enum AppFilterMode: String {
    /// 모든 앱에서 쓰고 목록의 앱에서만 끈다
    case exclude
    /// 목록의 앱에서만 쓴다
    case include
}

/// 설정은 메뉴 막대 아이콘 → 설정… 에서 바꾸거나 `defaults write com.local.Hanmium <키> <값>` 으로 바꾼다.
/// 단축키 외에는 매번 읽으므로 바로 적용된다.
enum Config {
    /// 앱 번들로 실행하면 기본 저장소가 곧 com.local.Hanmium 이다(같은 이름으로 suite 를 열면 macOS 가 거부한다).
    /// 빌드한 실행 파일을 바로 실행할 때만 이름을 지정해서 같은 설정을 쓴다.
    static let defaults = Bundle.main.bundleIdentifier == "com.local.Hanmium"
        ? UserDefaults.standard : UserDefaults(suiteName: "com.local.Hanmium") ?? .standard
    /// Vimium 의 기본 라벨 문자(linkHintCharacters)와 같다
    static let defaultLabelCharacters = "sadfjklewcmpgh"
    static let defaultScrollKeys = "hjkl"
    static let defaultScrollPxPerMs = 1.2
    static let defaultDashMultiplier = 3.0

    /// 전체 사용 여부. 끄면 단축키를 모두 놓는다.
    static var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    static var appFilterMode: AppFilterMode {
        AppFilterMode(rawValue: defaults.string(forKey: "appFilterMode") ?? "") ?? .exclude
    }

    /// 앱별 사용 목록(번들 ID, 줄바꿈으로 구분해 저장). appFilterMode 에 따라 끌 앱이거나 쓸 앱이다.
    static var appList: [String] {
        get { (defaults.string(forKey: "appList") ?? "").split(separator: "\n").map(String.init) }
        set { defaults.set(newValue.joined(separator: "\n"), forKey: "appList") }
    }

    static func isListed(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appList.contains(bundleID)
    }

    /// 이 앱이 앞에 있을 때 Hanmium 을 쓸지. 쓰지 않으면 단축키를 놓아서 키가 그 앱으로 그대로 간다.
    static func isAllowed(_ bundleID: String?) -> Bool {
        appFilterMode == .include ? isListed(bundleID) : !isListed(bundleID)
    }

    static func hotkey(for kind: ModeKind) -> String { defaults.string(forKey: kind.hotkeyKey) ?? kind.defaultHotkey }
    static func isEnabled(_ kind: ModeKind) -> Bool { defaults.object(forKey: kind.enabledKey) as? Bool ?? true }

    /// 라벨에 쓸 문자. '/' 는 검색 전환 키라서 뺀다. 두 글자 미만이면 기본값.
    static var labelAlphabet: [Character] {
        let raw = defaults.string(forKey: "labelCharacters") ?? defaultLabelCharacters
        var seen = Set<Character>()
        let chars = Array(raw.lowercased().filter { $0 != "/" && !$0.isWhitespace && seen.insert($0).inserted })
        return chars.count >= 2 ? chars : Array(defaultLabelCharacters)
    }

    /// <왼쪽><아래><위><오른쪽>
    static var scrollKeys: [Character] {
        let keys = Array((defaults.string(forKey: "scrollKeys") ?? defaultScrollKeys).lowercased())
        return keys.count == 4 ? keys : Array(defaultScrollKeys)
    }

    /// 스크롤 움직임 애니메이션 배율. 0 이면 끔(바로 이동), 1 이 기본, 2 는 두 배로 느긋하게.
    /// 라벨이 닫힐 때 서서히 사라지게 할지 (macOS 기본 창 효과, 약 0.2초). 끄면 바로 사라진다.
    static var labelAnimation: Bool { defaults.bool(forKey: "labelAnimation") }

    static var animationScale: Double {
        min(max(defaults.object(forKey: "animationScale") as? Double ?? 1, 0), 2)
    }

    static let defaultScrollBorderWidth = 3.0

    static var scrollBorderShown: Bool { defaults.object(forKey: "scrollBorderShown") as? Bool ?? true }
    static var scrollBorderStyle: AreaStyle {
        AreaStyle(rawValue: defaults.string(forKey: "scrollBorderStyle") ?? "") ?? .glass
    }
    static var focusMotion: FocusMotion {
        FocusMotion(rawValue: defaults.string(forKey: "focusMotion") ?? "") ?? .none
    }

    /// 영역 이동(물방울) 빠르기 배율. 2 면 두 배 빠르게, 0.5 면 두 배 느긋하게.
    static var focusMotionSpeed: CGFloat {
        (defaults.object(forKey: "focusMotionSpeed") as? Double).map { CGFloat(min(max($0, 0.25), 3)) } ?? 1
    }

    /// 유리 라벨 조절(0~2, 1 이 기본): 굴절 강도, 반사도(가장자리 빛), 흐림, 색 진하기
    static var glassRefraction: CGFloat { factor("glassRefraction") }
    static var glassSpecular: CGFloat { factor("glassSpecular") }
    static var glassBlur: CGFloat { factor("glassBlur") }
    static var glassTint: CGFloat { factor("glassTint") }

    private static func factor(_ key: String) -> CGFloat {
        (defaults.object(forKey: key) as? Double).map { CGFloat(min(max($0, 0), 2)) } ?? 1
    }

    static var inactiveAreaStyle: AreaStyle {
        AreaStyle(rawValue: defaults.string(forKey: "inactiveAreaStyle") ?? "") ?? .glass
    }
    static var scrollBorderWidth: CGFloat { CGFloat(positive("scrollBorderWidth") ?? defaultScrollBorderWidth) }
    /// 직접 고른 테두리 색. 없으면 라벨 색상의 강조색.
    static var scrollBorderColor: NSColor {
        NSColor(hex: defaults.string(forKey: "scrollBorderColor") ?? "") ?? labelTheme.accent
    }

    static let defaultInactiveLineOpacity = 0.7
    static let defaultInactiveFillOpacity = 0.12

    /// 같은 창의 고르지 않은 스크롤 영역(숫자·Tab 으로 옮겨갈 곳)을 점선과 옅은 칠로 보일지
    static var inactiveAreaShown: Bool { defaults.object(forKey: "inactiveAreaShown") as? Bool ?? true }
    /// 직접 고른 색. 없으면 스크롤 테두리 색.
    static var inactiveAreaColor: NSColor {
        NSColor(hex: defaults.string(forKey: "inactiveAreaColor") ?? "") ?? scrollBorderColor
    }
    static var inactiveLineOpacity: CGFloat { opacity("inactiveLineOpacity") ?? defaultInactiveLineOpacity }
    static var inactiveFillOpacity: CGFloat { opacity("inactiveFillOpacity") ?? defaultInactiveFillOpacity }

    static let defaultTerminalNotchLines = 3

    /// WezTerm 에 휠 한 칸으로 보낼 줄 수. WezTerm 은 15px 를 한 줄로 치고, 전체 화면 앱에는 크기와 상관없이 한 칸을 넘긴다.
    static var terminalNotchLines: Int {
        let v = defaults.integer(forKey: "terminalNotchLines")
        return (1...10).contains(v) ? v : defaultTerminalNotchLines
    }

    static var labelTheme: LabelTheme {
        let id = defaults.string(forKey: "labelTheme")
        return LabelTheme.all.first { $0.id == id } ?? LabelTheme.all[0]
    }

    static var scrollPxPerMs: Double { positive("scrollPxPerMs") ?? defaultScrollPxPerMs }
    static var dashMultiplier: Double { positive("dashMultiplier") ?? defaultDashMultiplier }

    /// 웹 영역에서 AXUIElementsForSearchPredicate 로 빠르게 찾을지 (끄면 전체 트리를 훑는다)
    static var useSearchPredicate: Bool { defaults.object(forKey: "useSearchPredicate") as? Bool ?? true }

    /// 0~1. 0 도 쓸 수 있는 값이라 positive 와 따로 둔다.
    private static func opacity(_ key: String) -> CGFloat? {
        (defaults.object(forKey: key) as? Double).map { CGFloat(min(max($0, 0), 1)) }
    }

    private static func positive(_ key: String) -> Double? {
        let v = defaults.double(forKey: key)
        return v > 0 ? v : nil
    }
}

/// 설정 내보내기·가져오기 (설정 › 고급). 다른 Mac 으로 옮기거나 되돌릴 때 쓴다.
/// 파일은 {"app": "Hanmium", "version": 1, "settings": {...}} 모양의 JSON 이다.
enum SettingsTransfer {
    /// 옮길 수 있는 설정. 로그인 시 자동 실행은 이 Mac 의 시스템 설정이라 뺀다.
    static let keys: [String] = [
        "enabled", "appFilterMode", "appList",
        "clickHotkey", "searchHotkey", "scrollHotkey", "clickEnabled", "searchEnabled", "scrollEnabled",
        "labelCharacters", "labelAnimation", "labelTheme", "glassRefraction", "glassSpecular", "glassBlur", "glassTint",
        "useSearchPredicate",
        "scrollKeys", "scrollPxPerMs", "dashMultiplier", "animationScale", "terminalNotchLines",
        "scrollBorderShown", "scrollBorderStyle", "scrollBorderWidth", "scrollBorderColor",
        "focusMotion", "focusMotionSpeed",
        "inactiveAreaShown", "inactiveAreaStyle", "inactiveAreaColor", "inactiveLineOpacity", "inactiveFillOpacity",
    ]

    enum Failure: LocalizedError {
        case notHanmium

        var errorDescription: String? { "Hanmium 설정 파일이 아닙니다." }
    }

    /// 기본값과 다르게 바꾼 설정만 담긴다(UserDefaults 에 저장된 것)
    static func export(from defaults: UserDefaults = Config.defaults) throws -> Data {
        var settings: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { settings[key] = value }
        }
        let root: [String: Any] = ["app": "Hanmium", "version": 1, "settings": settings]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// 파일 속 설정으로 맞춘다. 파일에 없는 설정은 기본값으로 돌린다(내보낼 때 기본값이었던 것).
    /// 알 수 없는 키와 문자열·숫자·참거짓이 아닌 값은 무시한다. 적용한 설정 수를 돌려준다.
    @discardableResult
    static func importSettings(_ data: Data, into defaults: UserDefaults = Config.defaults) throws -> Int {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["app"] as? String == "Hanmium",
              let settings = root["settings"] as? [String: Any] else { throw Failure.notHanmium }
        var applied = 0
        for key in keys {
            switch settings[key] {
            case let value as String:
                defaults.set(value, forKey: key)
                applied += 1
            case let value as NSNumber:
                defaults.set(value, forKey: key)
                applied += 1
            default:
                defaults.removeObject(forKey: key)
            }
        }
        return applied
    }
}
