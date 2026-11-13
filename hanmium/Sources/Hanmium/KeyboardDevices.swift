import AppKit
import Carbon
import IOKit
import IOKit.hid

// MARK: - 키보드별 설정
//
// 연결된 키보드마다 따로 정한다(Karabiner-Elements 의 devices 와 같은 모양):
// - 단순 바꾸기: 그 키보드의 HID 서비스에 UserKeyMapping 으로 건다(macOS 의 "보조 키" 설정과 같은 단계). 그래서 수정키(⌥⌘ 등)도
//   바꿀 수 있고, 바뀐 키에 키보드 규칙이 걸린다(Karabiner 처럼 단순 바꾸기 → 복합 규칙 순서). 원래 걸려 있던 전체 바꾸기
//   (hidutil property --set, 예: Caps Lock → F18)는 그대로 두고 그 위에 더한다.
// - 규칙 적용 안 함(ignore): 그 키보드의 키는 Hanmium 이 건드리지 않는다.
// - 규칙마다 "적용할 키보드"(조건 device_if): 키 이벤트가 어느 키보드에서 왔는지는 이벤트의 서비스 ID 로 안다(KeyboardTap).

/// 키보드를 알아보는 값(Karabiner 의 identifiers). 같은 제품 두 개는 구분하지 않는다.
struct KeyboardIdentity: Hashable {
    var vendorID: Int
    var productID: Int

    var json: [String: Any] { ["vendor_id": vendorID, "product_id": productID, "is_keyboard": true] }

    init(vendorID: Int, productID: Int) {
        self.vendorID = vendorID
        self.productID = productID
    }

    init?(json: [String: Any]?) {
        guard let json, let v = json["vendor_id"] as? Int, let p = json["product_id"] as? Int else { return nil }
        self.init(vendorID: v, productID: p)
    }
}

/// 키보드 하나의 설정 (keyboard.json 의 "devices" 항목)
struct KeyboardDeviceSettings: Identifiable {
    let id = UUID()
    var identity: KeyboardIdentity
    /// 마지막으로 본 이름(연결이 끊겨도 목록에 보이게)
    var name: String
    var ignore = false
    var simple: [SimpleModification] = []

    var json: [String: Any] {
        var out: [String: Any] = ["identifiers": identity.json, "name": name]
        if ignore { out["ignore"] = true }
        if !simple.isEmpty {
            out["simple_modifications"] = simple.map { ["from": ["key_code": $0.from], "to": [["key_code": $0.to]]] }
        }
        return out
    }

    init(identity: KeyboardIdentity, name: String) {
        self.identity = identity
        self.name = name
    }

    /// 수정키(Caps Lock·fn 포함)가 낀 바꾸기는 HID 단계(UserKeyMapping)에서, 나머지는 Hanmium 키 탭에서 키 코드로 바꾼다
    static let modifierKeys: Set<String> = ["caps_lock", "left_shift", "right_shift", "left_control", "right_control",
                                            "left_option", "right_option", "left_command", "right_command", "fn"]

    var hidPairs: [SimpleModification] {
        simple.filter { Self.modifierKeys.contains($0.from) || Self.modifierKeys.contains($0.to) }
    }

    var keyMap: [UInt16: UInt16] {
        var map: [UInt16: UInt16] = [:]
        for m in simple where !Self.modifierKeys.contains(m.from) && !Self.modifierKeys.contains(m.to) {
            if let from = KeyNames.code(m.from), let to = KeyNames.code(m.to), from != to { map[from] = to }
        }
        return map
    }

    init?(json: [String: Any]) {
        guard let identity = KeyboardIdentity(json: json["identifiers"] as? [String: Any]) else { return nil }
        self.identity = identity
        name = json["name"] as? String ?? "키보드 \(identity.vendorID):\(identity.productID)"
        ignore = json["ignore"] as? Bool ?? false
        simple = KeyboardStore.simpleList(json["simple_modifications"])
    }
}

/// 연결된 키보드
struct ConnectedKeyboard: Identifiable, Equatable {
    var id: KeyboardIdentity { identity }
    let identity: KeyboardIdentity
    let name: String
    let builtIn: Bool
    /// macOS 가 ISO 배열로 보는지(왼쪽 위가 §)
    let iso: Bool
    /// 이 키보드의 HID 서비스들(키 이벤트의 서비스 ID 와 같다)
    let services: [UInt64]

    var apple: Bool { builtIn || identity.vendorID == 0x5AC }
}

/// 연결된 키보드 목록과 키보드별 단순 바꾸기(UserKeyMapping). 메인 스레드에서 쓴다. 서비스 ID → 키보드 표는 키 탭 스레드에서도
/// 읽으므로 잠금을 둔다.
final class KeyboardDevices: ObservableObject {
    static let shared = KeyboardDevices()

    @Published private(set) var connected: [ConnectedKeyboard] = []

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private let lock = NSLock()
    private var byService: [UInt64: KeyEventSource] = [:]
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var pending: DispatchWorkItem?
    /// 지금 건 설정(새 키보드가 붙으면 다시 건다)
    private var settings: [KeyboardDeviceSettings] = []
    private var active = false
    /// Hanmium 이 UserKeyMapping 을 건 키보드("제조사:제품"). 앱이 죽었다 켜져도 걷을 수 있게 설정에 남긴다.
    private var touched: Set<String> {
        get { Set(Config.defaults.stringArray(forKey: "keyboardMappedDevices") ?? []) }
        set { Config.defaults.set(Array(newValue).sorted(), forKey: "keyboardMappedDevices") }
    }

    private init() {
        refresh()
        watch()
    }

    /// 키 이벤트의 서비스 ID 가 어느 키보드인지 (키 탭 스레드)
    func source(service: UInt64) -> KeyEventSource? {
        lock.lock()
        defer { lock.unlock() }
        return byService[service]
    }

    /// 화면에 보일 이름: 연결된 것, 저장한 설정, 그것도 없으면 번호
    static func name(for id: KeyboardIdentity) -> String {
        if let k = shared.connected.first(where: { $0.identity == id }) { return k.name }
        if let d = KeyboardStore.shared.devices.first(where: { $0.identity == id }) { return d.name }
        return "키보드 \(id.vendorID):\(id.productID)"
    }

    func refresh() {
        var found: [KeyboardIdentity: (name: String, builtIn: Bool, services: [UInt64])] = [:]
        var order: [KeyboardIdentity] = []
        for s in services() {
            let v = Self.int(s, kIOHIDVendorIDKey), p = Self.int(s, kIOHIDProductIDKey)
            guard v != 0 || p != 0 else { continue }
            let name = IOHIDServiceClientCopyProperty(s, kIOHIDProductKey as CFString) as? String ?? "키보드"
            // Karabiner 가상 키보드 같은 소프트웨어 장치는 뺀다
            if name.localizedCaseInsensitiveContains("Karabiner") { continue }
            let id = KeyboardIdentity(vendorID: v, productID: p)
            let builtIn = IOHIDServiceClientCopyProperty(s, "Built-In" as CFString) as? Bool ?? false
            let service = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value ?? 0
            if found[id] == nil { order.append(id) }
            found[id, default: (name, builtIn, [])].services.append(service)
        }
        let list = order.map { id in
            ConnectedKeyboard(identity: id, name: found[id]!.name, builtIn: found[id]!.builtIn,
                              iso: found[id]!.services.contains(where: Self.isISO), services: found[id]!.services)
        }.sorted { ($0.builtIn ? 0 : 1, $0.name) < ($1.builtIn ? 0 : 1, $1.name) }
        lock.lock()
        byService = Dictionary(list.flatMap { k in k.services.map { ($0, KeyEventSource(identity: k.identity, builtIn: k.builtIn)) } },
                               uniquingKeysWith: { a, _ in a })
        lock.unlock()
        if list != connected { connected = list }
    }

    /// 키보드 HID 서비스들(Generic Desktop · Keyboard)
    private func services() -> [IOHIDServiceClient] {
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return all.filter { IOHIDServiceClientConformsTo($0, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0 }
    }

    private static func int(_ s: IOHIDServiceClient, _ key: String) -> Int {
        (IOHIDServiceClientCopyProperty(s, key as CFString) as? NSNumber)?.intValue ?? 0
    }

    // MARK: 단순 바꾸기 걸기

    /// 키보드별 단순 바꾸기를 건다. enabled 가 false 면 Hanmium 이 건 것을 모두 걷는다. wait 가 true 면 다 걸 때까지 기다린다(앱을 끌 때).
    ///
    /// 거는 것은 /usr/bin/hidutil 로 한다. Hanmium 이 IOHIDServiceClientSetProperty 로 걸면 값은 들어간 것처럼 읽히지만
    /// 키보드 드라이버(레지스트리의 HIDEventServiceProperties)에는 가지 않아 바뀌지 않았다(2026-11-13, 외장 키보드의 ⌘↔⌥). hidutil 은
    /// 그럴 권한이 있다. 지금 걸린 값도 드라이버 쪽에서 읽는다.
    func apply(_ settings: [KeyboardDeviceSettings], enabled: Bool, wait: Bool = false) {
        self.settings = settings
        active = enabled
        let base = baseMapping()
        let before = touched
        var after = before
        var jobs: [(id: KeyboardIdentity, name: String, mapping: [[String: Any]], count: Int)] = []
        var seen = Set<KeyboardIdentity>()
        for s in services() {
            let id = KeyboardIdentity(vendorID: Self.int(s, kIOHIDVendorIDKey), productID: Self.int(s, kIOHIDProductIDKey))
            guard seen.insert(id).inserted else { continue }
            let key = "\(id.vendorID):\(id.productID)"
            let service = (IOHIDServiceClientGetRegistryID(s) as? NSNumber)?.uint64Value ?? 0
            let mine = enabled ? settings.first { $0.identity == id && !$0.ignore }?.hidPairs ?? [] : []
            let pairs = Self.pairs(mine, iso: Self.isISO(service: service))
            // 떨어져 있는 키보드는 after 에 남아 다시 붙을 때 걷힌다
            if pairs.isEmpty { after.remove(key) } else { after.insert(key) }
            guard !pairs.isEmpty || before.contains(key) else { continue }
            // 같은 키를 Hanmium 이 바꾸면 전체 바꾸기보다 Hanmium 것
            let sources = Set(pairs.map { ($0[Self.srcKey] as? NSNumber)?.uint64Value ?? 0 })
            let merged = base.filter { !sources.contains(($0[Self.srcKey] as? NSNumber)?.uint64Value ?? 0) } + pairs
            if !Self.same(Self.driverMapping(service: service), merged) {
                let name = IOHIDServiceClientCopyProperty(s, kIOHIDProductKey as CFString) as? String ?? "?"
                jobs.append((id, name, merged, pairs.count))
            }
        }
        if after != before { touched = after }
        guard !jobs.isEmpty else { return }
        let run = {
            for job in jobs {
                let ok = Self.hidutil(job.id, job.mapping)
                Log.write("키보드별 바꾸기: \(job.name) \(job.count)개 (전체 바꾸기 \(base.count)개 위에)\(ok ? "" : " — hidutil 실패")")
            }
        }
        if wait { run() } else { Self.queue.async(execute: run) }
    }

    /// 앱을 끌 때: Hanmium 이 건 것을 걷는다
    func restore() { apply(settings, enabled: false, wait: true) }

    private static let queue = DispatchQueue(label: "Hanmium.hidutil", qos: .userInitiated)

    /// hidutil property --matching '{"VendorID":…,"ProductID":…}' --set '{"UserKeyMapping":[…]}'
    @discardableResult
    private static func hidutil(_ id: KeyboardIdentity, _ mapping: [[String: Any]]) -> Bool {
        guard let matching = try? JSONSerialization.data(withJSONObject: ["VendorID": id.vendorID, "ProductID": id.productID]),
              let value = try? JSONSerialization.data(withJSONObject: [mappingKey: mapping]) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--matching", String(decoding: matching, as: UTF8.self),
                       "--set", String(decoding: value, as: UTF8.self)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// 키보드 드라이버에 지금 걸린 UserKeyMapping (레지스트리)
    private static func driverMapping(service: UInt64) -> [[String: Any]] {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(service))
        defer { IOObjectRelease(entry) }
        let props = IORegistryEntryCreateCFProperty(entry, "HIDEventServiceProperties" as CFString, nil, 0)?
            .takeRetainedValue() as? [String: Any]
        return props?[mappingKey] as? [[String: Any]] ?? []
    }

    private static let mappingKey = "UserKeyMapping"
    private static let srcKey = "HIDKeyboardModifierMappingSrc"
    private static let dstKey = "HIDKeyboardModifierMappingDst"

    /// hidutil property --set 으로 건 전체 바꾸기(키보드마다 따로 건 것이 아님)
    private func baseMapping() -> [[String: Any]] {
        IOHIDEventSystemClientCopyProperty(client, Self.mappingKey as CFString) as? [[String: Any]] ?? []
    }

    /// macOS 가 ISO 배열로 보는 키보드인지(그러면 §·` 의 키 코드와 HID 값이 맞바뀐다). 이벤트의 키보드 종류와 같은 값이
    /// 레지스트리의 HIDEventServiceProperties.HIDSubinterfaceID 에 있다(예: ISO 로 보이는 외장 키보드 41, ANSI 외장 키보드 40, 맥북 내장 91).
    static func isISO(service: UInt64) -> Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(service))
        defer { IOObjectRelease(entry) }
        let props = IORegistryEntryCreateCFProperty(entry, "HIDEventServiceProperties" as CFString, nil, 0)?
            .takeRetainedValue() as? [String: Any]
        guard let type = props?["HIDSubinterfaceID"] as? Int else { return false }
        return KBGetLayoutType(Int16(type)) == UInt32(kKeyboardISO)
    }

    private static func pairs(_ list: [SimpleModification], iso: Bool) -> [[String: Any]] {
        list.compactMap { m in
            guard let src = HIDUsage.value(m.from, iso: iso), let dst = HIDUsage.value(m.to, iso: iso), m.from != m.to
            else { return nil }
            return [srcKey: NSNumber(value: src), dstKey: NSNumber(value: dst)]
        }
    }

    private static func same(_ a: [[String: Any]], _ b: [[String: Any]]) -> Bool {
        func key(_ list: [[String: Any]]) -> [String] {
            list.map { "\(($0[srcKey] as? NSNumber)?.uint64Value ?? 0)>\(($0[dstKey] as? NSNumber)?.uint64Value ?? 0)" }.sorted()
        }
        return key(a) == key(b)
    }

    // MARK: 붙고 떨어짐

    /// 키보드가 붙거나 떨어지면(블루투스 재연결·잠자기 뒤 포함) 목록을 다시 읽고 바꾸기를 다시 건다. 새 서비스에는 시스템이 전체
    /// 바꾸기를 먼저 걸므로 조금 기다린다.
    private func watch() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            guard let refcon else { return }
            Unmanaged<KeyboardDevices>.fromOpaque(refcon).takeUnretainedValue().changed()
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOHIDEventService"), callback, me, &it)
            while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
            iterators.append(it)
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            refresh()
            apply(settings, enabled: active)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

/// Karabiner key_code 이름 → HID 사용 값 ((페이지 << 32) | 사용, UserKeyMapping 형식)
enum HIDUsage {
    /// iso: macOS 가 ISO 로 보는 키보드면 키 코드 10(§)·50(`)이 HID 0x35·0x64 와 맞바뀐다
    static func value(_ name: String, iso: Bool = false) -> UInt64? {
        if name == "fn" { return 0xFF_0000_0003 }  // Apple 벤더 페이지의 fn(지구본)
        if iso, name == "non_us_backslash" { return 0x7_0000_0035 }
        if iso, name == "grave_accent_and_tilde" { return 0x7_0000_0064 }
        guard let usage = keyboard[name] else { return nil }
        return 0x7_0000_0000 | UInt64(usage)
    }

    private static let keyboard: [String: UInt32] = {
        var t: [String: UInt32] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[String(c)] = 0x04 + UInt32(i) }
        for (i, c) in "1234567890".enumerated() { t[String(c)] = 0x1E + UInt32(i) }
        for i in 1...12 { t["f\(i)"] = 0x3A + UInt32(i - 1) }
        for i in 13...24 { t["f\(i)"] = 0x68 + UInt32(i - 13) }
        for i in 1...9 { t["keypad_\(i)"] = 0x59 + UInt32(i - 1) }
        let named: [String: UInt32] = [
            "return_or_enter": 0x28, "escape": 0x29, "delete_or_backspace": 0x2A, "tab": 0x2B, "spacebar": 0x2C,
            "hyphen": 0x2D, "equal_sign": 0x2E, "open_bracket": 0x2F, "close_bracket": 0x30, "backslash": 0x31,
            "non_us_pound": 0x32, "semicolon": 0x33, "quote": 0x34, "grave_accent_and_tilde": 0x35, "comma": 0x36,
            "period": 0x37, "slash": 0x38, "caps_lock": 0x39, "print_screen": 0x46, "scroll_lock": 0x47,
            "pause": 0x48, "insert": 0x49, "home": 0x4A, "page_up": 0x4B, "delete_forward": 0x4C, "end": 0x4D,
            "page_down": 0x4E, "right_arrow": 0x4F, "left_arrow": 0x50, "down_arrow": 0x51, "up_arrow": 0x52,
            "keypad_num_lock": 0x53, "keypad_slash": 0x54, "keypad_asterisk": 0x55, "keypad_hyphen": 0x56,
            "keypad_plus": 0x57, "keypad_enter": 0x58, "keypad_0": 0x62, "keypad_period": 0x63,
            "non_us_backslash": 0x64, "application": 0x65, "keypad_equal_sign": 0x67, "help": 0x75,
            "keypad_comma": 0x85, "international1": 0x87, "international3": 0x89, "lang1": 0x90, "lang2": 0x91,
            "left_control": 0xE0, "left_shift": 0xE1, "left_option": 0xE2, "left_command": 0xE3,
            "right_control": 0xE4, "right_shift": 0xE5, "right_option": 0xE6, "right_command": 0xE7,
        ]
        t.merge(named) { a, _ in a }
        return t
    }()
}
