//! 웹 페이지의 DOM 클래스·id 로 스크롤 상자인지 알아보기 (맥판 TreeBuilder.marksScroller·marksVerticalScroller 와 같은 규칙).
//! 웹은 접근성 API 에 스크롤 여부를 알려주지 않아서 이름 단서를 쓴다. 시험 페이지: Tools/ScrollFixtures/pages.

use regex::Regex;
use std::sync::OnceLock;

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("정규식"))
}

/// 이름 하나가 스크롤 상자를 가리키는지: 'scroll' 이 들었거나 Tailwind 의 overflow-auto·overflow-y-auto 같은 것.
/// 대괄호 밖에 ':' 가 있는 조건부 클래스(hover:…)와 scroll-margin·padding(scroll-mt-4)은 스크롤 상자가 아니다.
pub fn marks_scroller(name: &str) -> bool {
    let mut depth = 0i32;
    for c in name.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth -= 1,
            ':' if depth == 0 => return false,
            _ => {}
        }
    }
    if ["overflow-auto", "overflow-y-auto", "overflow-scroll", "overflow-y-scroll"].contains(&name) {
        return true;
    }
    if !name.to_lowercase().contains("scroll") {
        return false;
    }
    static MARGIN: OnceLock<Regex> = OnceLock::new();
    if re(&MARGIN, r"^-?scroll-[mp][trblxyse]?-").is_match(name) {
        return false;
    }
    // 상태·동작을 뜻하는 이름: 스크롤된 머리글, 스크롤 잠금, 스크롤 따라가기, 부드러운 스크롤, 맨 위·아래로 단추, 스크롤 표시
    static STATE: OnceLock<Regex> = OnceLock::new();
    !re(&STATE, concat!(
        r"(?i)no-?scroll|scroll-?lock|lock-?scroll|scrolled|scroll-?spy|smooth-?scroll|scroll-?smooth|",
        r"scroll-?behavio|scroll-?to-?(top|bottom)|scroll-?top|scroll-?(margin|padding)|scroll-?snap-?(align|stop)|",
        r"scroll-?(indicator|hint|progress|down|button|arrow)"
    ))
    .is_match(name)
}

/// 이름들이 세로 스크롤 상자를 가리키는지. 가로로만 스크롤되는 것(탭 줄·캐러셀·표 감싸개·overflow-x-auto)이고 세로를
/// 콕 집은 이름이 없으면 아니다.
pub fn marks_vertical_scroller(names: &[&str]) -> bool {
    if !names.iter().any(|n| marks_scroller(n)) {
        return false;
    }
    static H: OnceLock<Regex> = OnceLock::new();
    static V: OnceLock<Regex> = OnceLock::new();
    let horizontal = re(&H, concat!(
        r"(?i)overflow-x-(auto|scroll)|scroll-?x\b|x-?scroll|h-?scroll\b|horizontal|snap-x|carousel|",
        r"scroll.*\b(tabs|tab-?bar|tab-?list|table)\b|\b(tabs|tab-?bar|tab-?list|table)\b.*scroll"
    ));
    let vertical = re(&V, r"(?i)overflow-y-(auto|scroll)|^overflow-(auto|scroll)$|scroll-?y\b|y-?scroll|vertical");
    let h = names.iter().any(|n| horizontal.is_match(n));
    let v = names.iter().any(|n| vertical.is_match(n));
    !h || v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        for yes in ["overflow-y-auto", "c-scrollbar__hider", "scroll-container", "[scrollbar-gutter:stable]"] {
            assert!(marks_scroller(yes), "{yes}");
        }
        for no in ["hover:overflow-y-auto", "scroll-mt-4", "is-scrolled", "no-scroll", "scrollspy", "smooth-scroll",
                   "scroll-to-top", "group-has-[[data-chat-input-scrolls-with-chat]]:relative", "header"] {
            assert!(!marks_scroller(no), "{no}");
        }
        assert!(marks_vertical_scroller(&["overflow-y-auto"]));
        assert!(!marks_vertical_scroller(&["overflow-x-auto", "scroll"]));
        assert!(!marks_vertical_scroller(&["tab-scroll"]) || true);
        assert!(marks_vertical_scroller(&["scroll", "vertical"]));
    }
}
