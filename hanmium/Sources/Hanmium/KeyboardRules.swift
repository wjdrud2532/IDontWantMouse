import AppKit
import Combine

// MARK: - 키보드 규칙 (Karabiner-Elements 형식)
//
// Karabiner-Elements 의 complex_modifications 규칙과 simple_modifications 를 같은 JSON 으로 읽어 Hanmium 이 직접 키를 바꾼다
// (KeyboardEngine·KeyboardTap). 규칙은 Karabiner 설정에서 그대로 가져오고 설정 창에서 켜고 끄거나 JSON 으로 고친다.
// 지원하는 것: from.key_code + modifiers(mandatory·optional), conditions(variable_if/unless, frontmost_application_if/unless),
// to·to_if_alone·to_after_key_up 의 key_code(+modifiers)·pointing_button·mouse_key·set_variable, 그리고 Hanmium 모드를 바로
// 여는 {"hanmium": "labels" | "search" | "scroll"}. 그 밖의 것(simultaneous, shell_command 등)이 든 조작은 건너뛴다.

/// Karabiner 의 key_code 이름 ↔ macOS 가상 키 코드 (ANSI 배열)
enum KeyNames {
    static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "non_us_backslash": 10,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "equal_sign": 24, "9": 25, "7": 26, "hyphen": 27, "8": 28, "0": 29, "close_bracket": 30, "o": 31,
        "u": 32, "open_bracket": 33, "i": 34, "p": 35, "return_or_enter": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
        "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47, "tab": 48,
        "spacebar": 49, "grave_accent_and_tilde": 50, "delete_or_backspace": 51, "escape": 53,
        "right_command": 54, "left_command": 55, "left_shift": 56, "caps_lock": 57, "left_option": 58,
        "left_control": 59, "right_shift": 60, "right_option": 61, "right_control": 62, "fn": 63,
        "f17": 64, "keypad_period": 65, "keypad_asterisk": 67, "keypad_plus": 69, "keypad_num_lock": 71,
        "keypad_slash": 75, "keypad_enter": 76, "keypad_hyphen": 78, "f18": 79, "f19": 80, "keypad_equal_sign": 81,
        "keypad_0": 82, "keypad_1": 83, "keypad_2": 84, "keypad_3": 85, "keypad_4": 86, "keypad_5": 87,
        "keypad_6": 88, "keypad_7": 89, "f20": 90, "keypad_8": 91, "keypad_9": 92, "international3": 93,
        "international1": 94, "keypad_comma": 95, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101,
        "lang2": 102, "f11": 103, "lang1": 104, "f13": 105, "f16": 106, "f14": 107, "f10": 109, "application": 110,
        "f12": 111, "f15": 113, "help": 114, "home": 115, "page_up": 116, "delete_forward": 117, "f4": 118,
        "end": 119, "f2": 120, "page_down": 121, "f1": 122, "left_arrow": 123, "right_arrow": 124,
        "down_arrow": 125, "up_arrow": 126,
    ]

    static let names: [UInt16: String] = Dictionary(uniqueKeysWithValues: codes.map { ($1, $0) })

    static func code(_ name: String) -> UInt16? { codes[name] }

    /// 화면에 보일 이름
    static func display(_ name: String) -> String {
        if let special = specials[name] { return special }
        if name.hasPrefix("keypad_") { return "숫자패드 " + display(String(name.dropFirst(7))) }
        if name.count == 1 { return name.uppercased() }
        if name.hasPrefix("f"), Int(name.dropFirst()) != nil { return name.uppercased() }
        return name
    }

    private static let specials: [String: String] = [
        "grave_accent_and_tilde": "₩ (`)", "spacebar": "Space", "tab": "Tab", "return_or_enter": "Return",
        "escape": "Esc", "delete_or_backspace": "⌫", "delete_forward": "⌦", "caps_lock": "Caps Lock",
        "left_arrow": "←", "right_arrow": "→", "up_arrow": "↑", "down_arrow": "↓", "home": "Home", "end": "End",
        "page_up": "Page Up", "page_down": "Page Down", "hyphen": "-", "equal_sign": "=", "open_bracket": "[",
        "close_bracket": "]", "backslash": "\\", "semicolon": ";", "quote": "'", "comma": ",", "period": ".",
        "slash": "/", "num_lock": "NumLock(Clear)", "asterisk": "*", "plus": "+", "enter": "Enter",
        "equal_sign_keypad": "=", "left_shift": "왼쪽 ⇧", "right_shift": "오른쪽 ⇧", "left_control": "왼쪽 ⌃",
        "right_control": "오른쪽 ⌃", "left_option": "왼쪽 ⌥", "right_option": "오른쪽 ⌥",
        "left_command": "왼쪽 ⌘", "right_command": "오른쪽 ⌘", "fn": "fn", "application": "메뉴",
        "lang1": "한/영(lang1)", "lang2": "한자(lang2)", "non_us_backslash": "§", "help": "Help",
    ]

    /// 설정 창 키 고르기 목록: 묶음별
    static let groups: [(title: String, keys: [String])] = [
        ("글자", "abcdefghijklmnopqrstuvwxyz".map(String.init)),
        ("숫자", "1234567890".map(String.init)),
        ("기호", ["grave_accent_and_tilde", "hyphen", "equal_sign", "open_bracket", "close_bracket", "backslash",
                "semicolon", "quote", "comma", "period", "slash", "non_us_backslash"]),
        ("편집·이동", ["escape", "tab", "spacebar", "return_or_enter", "delete_or_backspace", "delete_forward",
                    "left_arrow", "right_arrow", "up_arrow", "down_arrow", "home", "end", "page_up", "page_down"]),
        ("수정키", ["caps_lock", "left_shift", "right_shift", "left_control", "right_control", "left_option",
                 "right_option", "left_command", "right_command", "fn"]),
        ("기능키", (1...20).map { "f\($0)" }),
        ("숫자패드", ["keypad_0", "keypad_1", "keypad_2", "keypad_3", "keypad_4", "keypad_5", "keypad_6", "keypad_7",
                  "keypad_8", "keypad_9", "keypad_period", "keypad_enter", "keypad_plus", "keypad_hyphen",
                  "keypad_asterisk", "keypad_slash", "keypad_equal_sign", "keypad_num_lock"]),
        ("그 밖", ["lang1", "lang2", "application", "help", "international1", "international3"]),
    ]
}

// MARK: - 규칙 JSON (Decodable, Karabiner 이름 그대로)

/// 변수 값: Karabiner 는 정수·참거짓·문자열을 쓴다. 정한 적 없는 변수는 0 이다.
enum KeyVarValue: Decodable, Equatable, CustomStringConvertible {
    case int(Int), bool(Bool), string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else {
            self = .string(try c.decode(String.self))
        }
    }

    var description: String {
        switch self {
        case .int(let i): "\(i)"
        case .bool(let b): b ? "true" : "false"
        case .string(let s): "\"\(s)\""
        }
    }
}

struct KeyModifiers: Decodable, Equatable {
    var mandatory: [String]?
    var optional: [String]?
}

struct KeyFrom: Decodable {
    var keyCode: String?
    var modifiers: KeyModifiers?
    var unsupported: [String] = []

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code", modifiers, simultaneous, pointingButton = "pointing_button",
             consumerKeyCode = "consumer_key_code", any
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(String.self, forKey: .keyCode)
        modifiers = try c.decodeIfPresent(KeyModifiers.self, forKey: .modifiers)
        for key in [CodingKeys.simultaneous, .pointingButton, .consumerKeyCode, .any] where c.contains(key) {
            unsupported.append("from.\(key.stringValue)")
        }
    }
}

struct MouseKeyVector: Decodable, Equatable {
    var x: Double?
    var y: Double?
    var verticalWheel: Double?
    var horizontalWheel: Double?
    var speedMultiplier: Double?

    enum CodingKeys: String, CodingKey {
        case x, y, verticalWheel = "vertical_wheel", horizontalWheel = "horizontal_wheel",
             speedMultiplier = "speed_multiplier"
    }
}

struct KeySetVariable: Decodable {
    var name: String
    var value: KeyVarValue
}

struct KeyToEvent: Decodable {
    var keyCode: String?
    var modifiers: [String] = []
    var pointingButton: String?
    var mouseKey: MouseKeyVector?
    var setVariable: KeySetVariable?
    var hanmium: String?
    var unsupported: [String] = []

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code", modifiers, pointingButton = "pointing_button", mouseKey = "mouse_key",
             setVariable = "set_variable", hanmium, shellCommand = "shell_command",
             consumerKeyCode = "consumer_key_code", selectInputSource = "select_input_source",
             stickyModifier = "sticky_modifier", softwareFunction = "software_function",
             appleVendorKeyboardKeyCode = "apple_vendor_keyboard_key_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try c.decodeIfPresent(String.self, forKey: .keyCode)
        // Karabiner 는 modifiers 를 문자열 하나로도 받는다
        if let list = try? c.decodeIfPresent([String].self, forKey: .modifiers) {
            modifiers = list
        } else if let one = try? c.decodeIfPresent(String.self, forKey: .modifiers) {
            modifiers = [one]
        }
        pointingButton = try c.decodeIfPresent(String.self, forKey: .pointingButton)
        mouseKey = try c.decodeIfPresent(MouseKeyVector.self, forKey: .mouseKey)
        setVariable = try c.decodeIfPresent(KeySetVariable.self, forKey: .setVariable)
        hanmium = try c.decodeIfPresent(String.self, forKey: .hanmium)
        for key in [CodingKeys.shellCommand, .consumerKeyCode, .selectInputSource, .stickyModifier,
                    .softwareFunction, .appleVendorKeyboardKeyCode] where c.contains(key) {
            unsupported.append(key.stringValue)
        }
        if let keyCode, KeyNames.code(keyCode) == nil { unsupported.append("key_code \(keyCode)") }
        if let hanmium, !["labels", "search", "scroll"].contains(hanmium) { unsupported.append("hanmium \(hanmium)") }
        if let pointingButton, KeyToEvent.buttonNumber(pointingButton) == nil {
            unsupported.append("pointing_button \(pointingButton)")
        }
    }

    /// button1 왼쪽, button2 오른쪽, button3 가운데, button4 뒤로, button5 앞으로
    static func buttonNumber(_ name: String) -> Int? {
        guard name.hasPrefix("button"), let n = Int(name.dropFirst(6)), (1...32).contains(n) else { return nil }
        return n
    }
}

struct KeyCondition: Decodable {
    var type: String
    var name: String?
    var value: KeyVarValue?
    var bundleIdentifiers: [String]?
    /// device_if·device_unless 의 키보드들
    var identifiers: [DeviceIdentifier]?

    enum CodingKeys: String, CodingKey {
        case type, name, value, bundleIdentifiers = "bundle_identifiers", identifiers
    }

    static let supported: Set<String> = ["variable_if", "variable_unless", "frontmost_application_if",
                                         "frontmost_application_unless", "device_if", "device_unless"]
}

/// 조건 device_if 의 키보드 하나(Karabiner 의 identifiers). 적힌 것이 모두 맞아야 그 키보드다.
struct DeviceIdentifier: Decodable, Equatable {
    var vendorID: Int?
    var productID: Int?
    var isKeyboard: Bool?
    var isBuiltInKeyboard: Bool?

    enum CodingKeys: String, CodingKey {
        case vendorID = "vendor_id", productID = "product_id", isKeyboard = "is_keyboard",
             isBuiltInKeyboard = "is_built_in_keyboard"
    }

    func matches(_ d: KeyEventSource) -> Bool {
        (vendorID == nil || vendorID == d.identity.vendorID) && (productID == nil || productID == d.identity.productID)
            && isKeyboard != false && (isBuiltInKeyboard == nil || isBuiltInKeyboard == d.builtIn)
    }
}

struct KeyManipulator: Decodable {
    var type: String?
    var from: KeyFrom
    var to: [KeyToEvent] = []
    var toIfAlone: [KeyToEvent]?
    var toAfterKeyUp: [KeyToEvent] = []
    var conditions: [KeyCondition] = []
    var parameters: [String: Double] = [:]
    var unsupported: [String] = []

    enum CodingKeys: String, CodingKey {
        case type, from, to, toIfAlone = "to_if_alone", toAfterKeyUp = "to_after_key_up",
             toIfHeldDown = "to_if_held_down", toDelayedAction = "to_delayed_action", conditions, parameters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        from = try c.decode(KeyFrom.self, forKey: .from)
        to = try c.decodeIfPresent([KeyToEvent].self, forKey: .to) ?? []
        toIfAlone = try c.decodeIfPresent([KeyToEvent].self, forKey: .toIfAlone)
        toAfterKeyUp = try c.decodeIfPresent([KeyToEvent].self, forKey: .toAfterKeyUp) ?? []
        conditions = try c.decodeIfPresent([KeyCondition].self, forKey: .conditions) ?? []
        parameters = (try? c.decodeIfPresent([String: Double].self, forKey: .parameters)) ?? [:]
        unsupported = from.unsupported
        if let type, type != "basic" { unsupported.append("type \(type)") }
        if from.keyCode == nil { unsupported.append("from 키 없음") } else if KeyNames.code(from.keyCode!) == nil {
            unsupported.append("key_code \(from.keyCode!)")
        }
        for key in [CodingKeys.toIfHeldDown, .toDelayedAction] where c.contains(key) {
            unsupported.append(key.stringValue)
        }
        for e in to + (toIfAlone ?? []) + toAfterKeyUp { unsupported += e.unsupported }
        for cond in conditions where !KeyCondition.supported.contains(cond.type) {
            unsupported.append("조건 \(cond.type)")
        }
    }

    var isSupported: Bool { unsupported.isEmpty }
}

// MARK: - 규칙·단순 바꾸기·매개변수

/// 규칙 하나. JSON 을 그대로 들고 있어서(모르는 항목도 지우지 않는다) Karabiner 와 오가도 잃는 것이 없다.
struct KeyRule: Identifiable {
    let id = UUID()
    var json: [String: Any]

    var description: String { json["description"] as? String ?? "(설명 없음)" }

    var enabled: Bool {
        get { json["enabled"] as? Bool ?? true }
        set { json["enabled"] = newValue }
    }

    /// 조작 목록. JSON 이 틀렸으면 그 조작은 nil.
    var manipulators: [KeyManipulator?] {
        let list = json["manipulators"] as? [Any] ?? []
        return list.map { item in
            guard JSONSerialization.isValidJSONObject(item),
                  let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(KeyManipulator.self, from: data)
        }
    }

    /// 이 규칙을 쓰는 키보드(모든 조작에 같은 device_if 를 단다). 비어 있으면 모든 키보드.
    var keyboards: [KeyboardIdentity] {
        let list = json["manipulators"] as? [[String: Any]] ?? []
        guard let conds = list.first?["conditions"] as? [[String: Any]],
              let c = conds.first(where: { $0["type"] as? String == "device_if" }) else { return [] }
        return (c["identifiers"] as? [[String: Any]] ?? []).compactMap { KeyboardIdentity(json: $0) }
    }

    mutating func setKeyboards(_ ids: [KeyboardIdentity]) {
        guard var list = json["manipulators"] as? [[String: Any]] else { return }
        for i in list.indices {
            var conds = (list[i]["conditions"] as? [[String: Any]] ?? []).filter { $0["type"] as? String != "device_if" }
            if !ids.isEmpty { conds.append(["type": "device_if", "identifiers": ids.map(\.json)]) }
            if conds.isEmpty { list[i].removeValue(forKey: "conditions") } else { list[i]["conditions"] = conds }
        }
        json["manipulators"] = list
    }

    static func parse(_ text: String) throws -> KeyRule {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeyRuleError("규칙은 { … } 로 된 JSON 객체여야 합니다")
        }
        guard object["description"] is String else { throw KeyRuleError("\"description\" (설명) 이 없습니다") }
        guard let list = object["manipulators"] as? [Any], !list.isEmpty else {
            throw KeyRuleError("\"manipulators\" (조작 목록) 가 비어 있습니다")
        }
        for (i, item) in list.enumerated() {
            do {
                let data = try JSONSerialization.data(withJSONObject: item)
                _ = try JSONDecoder().decode(KeyManipulator.self, from: data)
            } catch {
                throw KeyRuleError("조작 \(i + 1): \(Self.reason(error))")
            }
        }
        return KeyRule(json: object)
    }

    var prettyJSON: String {
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func reason(_ error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error { return "\"\(key.stringValue)\" 이 없습니다" }
        if case DecodingError.typeMismatch(_, let ctx) = error {
            return "\(ctx.codingPath.map(\.stringValue).joined(separator: ".")) 의 형식이 다릅니다"
        }
        return error.localizedDescription
    }
}

struct KeyRuleError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// 키 하나 → 키 하나. 키보드 규칙에 걸리지 않은 키에만 쓴다(Karabiner 와 같은 순서).
struct SimpleModification: Identifiable, Equatable {
    let id = UUID()
    var from: String
    var to: String
}

struct KeyParameters: Equatable {
    /// 이만큼(ms) 안에 떼야 to_if_alone 이 나간다
    var aloneTimeout = 1000
    /// mouse_key 포인터 속도(%)
    var pointerScale = 100
    /// mouse_key 휠 속도(%)
    var wheelScale = 100

    static let aloneKey = "basic.to_if_alone_timeout_milliseconds"
    static let pointerKey = "mouse_key_xy_scale"
    static let wheelKey = "mouse_key_wheels_scale"
}

// MARK: - 저장소

/// 키보드 규칙을 ~/Library/Application Support/Hanmium/keyboard.json 에 둔다. 바뀔 때마다 저장하고 키 바꾸기에 반영한다.
final class KeyboardStore: ObservableObject {
    static let shared = KeyboardStore()

    @Published var rules: [KeyRule] = [] { didSet { changed() } }
    @Published var simple: [SimpleModification] = [] { didSet { changed() } }
    /// 키보드별 설정(단순 바꾸기·규칙 적용 안 함)
    @Published var devices: [KeyboardDeviceSettings] = [] { didSet { changed() } }
    @Published var parameters = KeyParameters() { didSet { changed() } }
    /// 키 바꾸기 전체 켜기. 처음에는 꺼 둔다(Karabiner 와 겹치지 않게 사용자가 켠다).
    @Published var enabled: Bool = Config.defaults.bool(forKey: "keyboardEnabled") {
        didSet {
            Config.defaults.set(enabled, forKey: "keyboardEnabled")
            apply()
        }
    }

    private var loading = false

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Hanmium/keyboard.json")
    }

    static let karabinerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/karabiner/karabiner.json")

    /// 앱을 켤 때. 저장한 것이 없으면 Karabiner 설정에서 가져온다(켜지는 않는다).
    func load() {
        loading = true
        defer {
            loading = false
            apply()
        }
        if let data = try? Data(contentsOf: Self.fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            read(object)
            return
        }
        if (try? importKarabiner()) != nil {
            Log.write("키보드 규칙을 Karabiner 설정에서 가져옴: 규칙 \(rules.count)개, 단순 바꾸기 \(simple.count)개")
            loading = false
            save()
        }
    }

    private func read(_ object: [String: Any]) {
        rules = (object["rules"] as? [[String: Any]] ?? []).map { KeyRule(json: $0) }
        simple = Self.simpleList(object["simple_modifications"])
        devices = (object["devices"] as? [[String: Any]] ?? []).compactMap(KeyboardDeviceSettings.init(json:))
        let p = object["parameters"] as? [String: Any] ?? [:]
        var params = KeyParameters()
        if let v = p[KeyParameters.aloneKey] as? Int { params.aloneTimeout = v }
        if let v = p[KeyParameters.pointerKey] as? Int { params.pointerScale = v }
        if let v = p[KeyParameters.wheelKey] as? Int { params.wheelScale = v }
        parameters = params
    }

    static func simpleList(_ value: Any?) -> [SimpleModification] {
        (value as? [[String: Any]] ?? []).compactMap { item in
            guard let from = (item["from"] as? [String: Any])?["key_code"] as? String,
                  let to = ((item["to"] as? [[String: Any]])?.first)?["key_code"] as? String else { return nil }
            return SimpleModification(from: from, to: to)
        }
    }

    var jsonObject: [String: Any] {
        [
            "rules": rules.map(\.json),
            "simple_modifications": simple.map { ["from": ["key_code": $0.from], "to": [["key_code": $0.to]]] },
            "devices": devices.map(\.json),
            "parameters": [KeyParameters.aloneKey: parameters.aloneTimeout,
                           KeyParameters.pointerKey: parameters.pointerScale,
                           KeyParameters.wheelKey: parameters.wheelScale],
        ]
    }

    private func changed() {
        guard !loading else { return }
        save()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: jsonObject,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.write("키보드 규칙 저장 실패: \(error.localizedDescription)")
        }
        apply()
    }

    func apply() {
        KeyboardTap.shared.update(rules: rules.filter(\.enabled), simple: simple, parameters: parameters,
                                  devices: devices, enabled: enabled)
        KeyboardDevices.shared.apply(devices, enabled: enabled)
    }

    // MARK: Karabiner 가져오기

    /// Karabiner 설정(선택된 프로필)의 규칙·단순 바꾸기·매개변수로 바꾼다. Hanmium 단축키를 보내는 조작은
    /// {"hanmium": …} 로 바꿔서 Hanmium 이 바로 연다(단축키를 거치지 않으니 Hanmium 이 꺼져 있으면 원래 키가 간다).
    @discardableResult
    func importKarabiner() throws -> (rules: Int, simple: Int) {
        let data = try Data(contentsOf: Self.karabinerURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw KeyRuleError("Karabiner 설정에 프로필이 없습니다")
        }
        let profile = profiles.first { $0["selected"] as? Bool == true } ?? profiles[0]
        let complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        let wasLoading = loading
        loading = true
        rules = (complex["rules"] as? [[String: Any]] ?? []).map { KeyRule(json: Self.convertHotkeys($0)) }
        simple = Self.simpleList(profile["simple_modifications"])
        devices = (profile["devices"] as? [[String: Any]] ?? []).compactMap { d in
            let ids = d["identifiers"] as? [String: Any] ?? [:]
            guard ids["is_keyboard"] as? Bool ?? true, var settings = KeyboardDeviceSettings(json: d) else { return nil }
            settings.name = KeyboardDevices.shared.connected.first { $0.identity == settings.identity }?.name ?? settings.name
            return settings
        }
        var params = KeyParameters()
        let p = complex["parameters"] as? [String: Any] ?? [:]
        if let v = p[KeyParameters.aloneKey] as? Int { params.aloneTimeout = v }
        let virtual = profile["virtual_hid_keyboard"] as? [String: Any] ?? [:]
        if let v = virtual[KeyParameters.pointerKey] as? Int { params.pointerScale = v }
        parameters = params
        loading = wasLoading
        if !loading { save() }
        return (rules.count, simple.count)
    }

    /// 규칙 안에서 Hanmium 단축키(예: ⌥Space)를 보내는 to 를 {"hanmium": "labels"} 로
    private static func convertHotkeys(_ rule: [String: Any]) -> [String: Any] {
        var rule = rule
        let hotkeys: [(String, Set<String>, String)] = ModeKind.allCases.compactMap { kind in
            guard let parsed = parseHotkey(Config.hotkey(for: kind)) else { return nil }
            let action = switch kind {
            case .labels: "labels"
            case .search: "search"
            case .scroll: "scroll"
            }
            return (parsed.key, parsed.mods, action)
        }
        func convert(_ events: Any?) -> Any? {
            guard let list = events as? [[String: Any]] else { return events }
            return list.map { event -> [String: Any] in
                guard let key = event["key_code"] as? String else { return event }
                let mods = Set(((event["modifiers"] as? [String]) ?? (event["modifiers"] as? String).map { [$0] } ?? [])
                    .map(genericModifier))
                if let hit = hotkeys.first(where: { $0.0 == key && $0.1 == mods }) { return ["hanmium": hit.2] }
                return event
            }
        }
        guard var manipulators = rule["manipulators"] as? [[String: Any]] else { return rule }
        for i in manipulators.indices {
            for key in ["to", "to_if_alone", "to_after_key_up"] where manipulators[i][key] != nil {
                manipulators[i][key] = convert(manipulators[i][key])
            }
        }
        rule["manipulators"] = manipulators
        return rule
    }

    /// "opt+space" → (spacebar, [option])
    private static func parseHotkey(_ spec: String) -> (key: String, mods: Set<String>)? {
        var mods = Set<String>()
        var key: String?
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": mods.insert("command")
            case "shift": mods.insert("shift")
            case "opt", "option", "alt": mods.insert("option")
            case "ctrl", "control": mods.insert("control")
            case "space": key = "spacebar"
            case "/": key = "slash"
            case "`": key = "grave_accent_and_tilde"
            case "return": key = "return_or_enter"
            case "esc", "escape": key = "escape"
            default: key = part
            }
        }
        return key.map { ($0, mods) }
    }

    static func genericModifier(_ name: String) -> String {
        for g in ["shift", "control", "option", "command"] where name.hasSuffix(g) { return g }
        return name
    }

    // MARK: Karabiner 쪽 규칙 끄기·켜기

    /// Karabiner 에 켜져 있는 복합 규칙 수 (Karabiner 가 실행 중일 때만)
    static func karabinerActiveRules() -> Int {
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "org.pqrs.Karabiner-Menu" || $0.bundleIdentifier == "org.pqrs.Karabiner-Elements.Settings"
        }) || karabinerServiceRunning(),
            let profile = karabinerProfile() else { return 0 }
        let rules = (profile["complex_modifications"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        return rules.filter { $0["enabled"] as? Bool ?? true }.count
    }

    private static func karabinerServiceRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // 16.x 는 Karabiner-Console-User-Server, 예전 판은 karabiner_console_user_server
        p.arguments = ["-q", "-i", "karabiner[-_]console[-_]user[-_]server"]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func karabinerProfile() -> [String: Any]? {
        guard let data = try? Data(contentsOf: karabinerURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]], !profiles.isEmpty else { return nil }
        return profiles.first { $0["selected"] as? Bool == true } ?? profiles[0]
    }

    /// Karabiner 의 복합 규칙을 모두 끄거나(Hanmium 으로 옮긴 뒤) Hanmium 이 끈 것만 다시 켠다. 끈 규칙(설명)은
    /// Hanmium 설정에 기억한다(Karabiner 파일에는 Karabiner 가 아는 "enabled" 만 쓴다). 바꾸기 전 파일은 옆에 남긴다.
    /// Karabiner 는 파일이 바뀌면 바로 다시 읽는다.
    static func setKarabinerRules(enabled: Bool) throws -> Int {
        let data = try Data(contentsOf: karabinerURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var profiles = root["profiles"] as? [[String: Any]], !profiles.isEmpty else {
            throw KeyRuleError("Karabiner 설정을 읽지 못했습니다")
        }
        let index = profiles.firstIndex { $0["selected"] as? Bool == true } ?? 0
        var complex = profiles[index]["complex_modifications"] as? [String: Any] ?? [:]
        var rules = complex["rules"] as? [[String: Any]] ?? []
        var remembered = Set(Config.defaults.stringArray(forKey: disabledKey) ?? [])
        var count = 0
        for i in rules.indices {
            let name = rules[i]["description"] as? String ?? ""
            if enabled {
                guard remembered.contains(name), rules[i]["enabled"] as? Bool == false else { continue }
                rules[i].removeValue(forKey: "enabled")
                remembered.remove(name)
            } else {
                guard rules[i]["enabled"] as? Bool ?? true else { continue }
                rules[i]["enabled"] = false
                remembered.insert(name)
            }
            count += 1
        }
        if enabled { remembered.removeAll() }
        Config.defaults.set(Array(remembered), forKey: disabledKey)
        guard count > 0 else { return 0 }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backup = karabinerURL.deletingLastPathComponent()
            .appendingPathComponent("karabiner.json.bak-before-hanmium-\(enabled ? "on" : "off")-\(stamp)")
        try data.write(to: backup)
        complex["rules"] = rules
        profiles[index]["complex_modifications"] = complex
        root["profiles"] = profiles
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        try out.write(to: karabinerURL, options: .atomic)
        Log.write("Karabiner 복합 규칙 \(count)개 \(enabled ? "다시 켬" : "끔") (백업 \(backup.lastPathComponent))")
        return count
    }

    private static let disabledKey = "karabinerDisabledRules"

    /// Hanmium 이 꺼 둔 Karabiner 규칙 수
    static func karabinerRulesDisabledByHanmium() -> Int {
        let remembered = Set(Config.defaults.stringArray(forKey: disabledKey) ?? [])
        let rules = (karabinerProfile()?["complex_modifications"] as? [String: Any])?["rules"] as? [[String: Any]] ?? []
        return rules.filter { remembered.contains($0["description"] as? String ?? "") && $0["enabled"] as? Bool == false }
            .count
    }
}
