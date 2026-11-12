import AppKit

/// Chrome 이 접근성으로 페이지 요소 위치를 잘못 줄 때 페이지에 직접 물어서 클릭 대상을 얻는다.
///
/// 왜: GeekNews 처럼 html·body 에 `height: 100%` 와 `overflow-x: clip` 이 있는 페이지는 아래로 스크롤하면 Chrome(157)이 모든
/// 요소의 접근성 위치를 body 상자(화면 위로 올라간)에 잘라서 웹 영역 맨 위 높이 1px 로 준다(가로 위치는 맞다). 확대 비율과는
/// 상관없다. 페이지 안의 getBoundingClientRect 는 늘 맞으므로 그것을 쓴다.
///
/// 좌표: 페이지 좌표(CSS px)에 웹 영역 너비 ÷ innerWidth 를 곱하고 웹 영역 위치를 더한다 — 확대 비율이 몇이든 맞는다.
/// 필요한 것: Chrome 의 "보기 › 개발자 정보 › Apple Events 의 JavaScript 허용", 그리고 처음 한 번 macOS 의 "Hanmium 이
/// Chrome 을 제어" 허락.
enum ChromeJS {
    struct Target {
        let rect: CGRect
        let title: String
        let role: String
    }

    enum Failure: Error {
        /// Chrome 의 "Apple Events 의 JavaScript 허용"이 꺼짐
        case disabled
        case failed(String)
    }

    /// 보이는(가려지지 않은) 클릭 대상: 링크·단추·입력칸 등. [x, y, w, h, 글, 태그] 목록과 innerWidth.
    static let script = #"""
    (() => {
      const sel = 'a[href], button, input:not([type=hidden]), select, textarea, summary, label[for], [role=button], [role=link], [role=tab], [role=checkbox], [role=radio], [role=menuitem], [role=switch], [role=option], [onclick], [contenteditable=""], [contenteditable=true], [tabindex]:not([tabindex="-1"])';
      const vw = innerWidth, vh = innerHeight, out = [], seen = new Set();
      for (const el of document.querySelectorAll(sel)) {
        if (seen.has(el)) continue;
        let r = el.getBoundingClientRect();
        const rects = el.getClientRects();
        // 여러 줄로 접힌 인라인 링크는 첫 줄 조각을 누른다
        if (rects.length > 1 && getComputedStyle(el).display === 'inline') r = rects[0];
        if (r.width < 3 || r.height < 3 || r.bottom <= 0 || r.right <= 0 || r.top >= vh || r.left >= vw) continue;
        const st = getComputedStyle(el);
        if (st.visibility === 'hidden' || st.pointerEvents === 'none' || +st.opacity === 0) continue;
        const cx = Math.min(Math.max(r.left + Math.min(r.width, 40) / 2, 1), vw - 1);
        const cy = Math.min(Math.max(r.top + Math.min(r.height, 24) / 2, 1), vh - 1);
        const hit = document.elementFromPoint(cx, cy);
        if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) continue;
        // 링크 안의 단추처럼 겹친 것은 바깥 것만
        for (const inner of el.querySelectorAll(sel)) seen.add(inner);
        const text = (el.innerText || el.value || el.getAttribute('aria-label') || el.title || el.getAttribute('placeholder') || '').trim().replace(/\s+/g, ' ').slice(0, 80);
        out.push([r.left, r.top, r.width, r.height, text, el.tagName, el.getAttribute('role') || '']);
      }
      return JSON.stringify({w: vw, h: vh, t: out});
    })()
    """#

    /// webArea: 웹 영역의 화면 위치(접근성, 이것은 맞다)
    static func targets(pid: pid_t, webArea: CGRect) -> Result<[Target], Failure> {
        let data: Data
        switch run(pid: pid, javascript: script) {
        case .success(let text): data = Data(text.utf8)
        case .failure(let f): return .failure(f)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let width = json["w"] as? Double, width > 0, let list = json["t"] as? [[Any]] else {
            return .failure(.failed("결과를 읽지 못함"))
        }
        let scale = webArea.width / width
        let targets: [Target] = list.compactMap { item in
            guard item.count >= 7, let x = item[0] as? Double, let y = item[1] as? Double, let w = item[2] as? Double,
                  let h = item[3] as? Double else { return nil }
            let rect = CGRect(x: webArea.minX + x * scale, y: webArea.minY + y * scale, width: w * scale, height: h * scale)
                .intersection(webArea)
            guard !rect.isNull, rect.width >= 3, rect.height >= 3 else { return nil }
            let tag = item[5] as? String ?? "", role = item[6] as? String ?? ""
            let axRole = switch (tag, role) {
            case ("A", _), (_, "link"): "AXLink"
            case ("INPUT", _), ("TEXTAREA", _): "AXTextField"
            case ("SELECT", _): "AXPopUpButton"
            case (_, "checkbox"), (_, "switch"): "AXCheckBox"
            case (_, "radio"): "AXRadioButton"
            case (_, "tab"): "AXRadioButton"
            default: "AXButton"
            }
            return Target(rect: rect, title: item[4] as? String ?? "", role: axRole)
        }
        return .success(targets)
    }

    /// 앞 창의 지금 탭에서 자바스크립트를 돌린다. osascript 를 띄우지 않고 Apple Event 를 바로 보낸다(프로세스 띄우기·
    /// AppleScript 컴파일에 200ms 가 들었다). Chrome 사전: execute(CrSu/ExJa) ← active tab(acTa) of window 1, javascript(JvSc).
    /// 프로세스 번호로 보낸다: 같은 브라우저가 둘 떠 있으면(프로필을 따로 쓰는 시험용 Chrome 등) 이름으로는 어느 쪽에 갈지 모른다.
    static func run(pid: pid_t, javascript: String) -> Result<String, Failure> {
        func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }
        func specifier(want: FourCharCode, from: NSAppleEventDescriptor, form: FourCharCode,
                       data: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
            let record = NSAppleEventDescriptor.record()
            record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
            record.setDescriptor(from, forKeyword: AEKeyword(keyAEContainer))
            record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
            record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
            return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
        }
        let window = specifier(want: code("cwin"), from: .null(), form: DescType(formAbsolutePosition),
                               data: NSAppleEventDescriptor(int32: 1))
        let tab = specifier(want: DescType(typeProperty), from: window, form: DescType(formPropertyID),
                            data: NSAppleEventDescriptor(typeCode: code("acTa")))
        let event = NSAppleEventDescriptor(eventClass: code("CrSu"), eventID: code("ExJa"),
                                           targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(tab, forKeyword: AEKeyword(keyDirectObject))
        event.setParam(NSAppleEventDescriptor(string: javascript), forKeyword: code("JvSc"))
        do {
            let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 3)
            if let number = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value, number != 0 {
                let message = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue ?? "\(number)"
                if message.contains("JavaScript") { return .failure(.disabled) }
                return .failure(.failed("\(number) \(message)"))
            }
            guard let text = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else {
                return .failure(.failed("답이 비어 있음"))
            }
            return .success(text)
        } catch {
            // -1743: macOS 의 "Hanmium 이 Chrome 제어" 허락이 없음
            return .failure(.failed("\(error.localizedDescription) (\((error as NSError).code))"))
        }
    }
}
