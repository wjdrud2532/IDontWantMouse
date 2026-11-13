//! AT-SPI 로 클릭 대상 찾기. Wayland 에서는 화면 좌표를 주지 않아서 창 기준 좌표를 받아 확장이 알려 주는 창 위치를 더한다.

use crate::shell::{Rect, Window};
use atspi::proxy::accessible::{AccessibleProxy, ObjectRefExt};
use atspi::proxy::proxy_ext::ProxyExt;
use atspi::zbus;
use atspi::{AccessibilityConnection, CoordType, Interface, ObjectRefOwned, Role, State};
use std::time::Instant;

/// 라벨을 붙일 것
#[derive(Clone, Debug)]
pub struct Target {
    pub role: Role,
    pub name: String,
    /// 화면 좌표
    pub rect: Rect,
    pub object: ObjectRefOwned,
    pub has_action: bool,
}

/// 누를 수 있는 역할
const CLICKABLE: &[Role] = &[
    Role::Button, Role::ToggleButton, Role::CheckBox, Role::RadioButton, Role::Link, Role::MenuItem,
    Role::CheckMenuItem, Role::RadioMenuItem, Role::ComboBox, Role::PageTab, Role::Entry, Role::SpinButton,
    Role::Slider, Role::ListItem, Role::TreeItem,
];

pub struct A11y {
    pub conn: AccessibilityConnection,
}

/// 창 기준 좌표를 화면 좌표로 바꿀 때 쓰는 원점. 앱마다 다르다: GTK 는 창 틀(그림자 뺀 것), Chrome 은 버퍼(그림자 포함)
/// 기준으로 준다. Auto 는 앱의 최상위 창이 알려 주는 크기가 틀·버퍼 중 어느 쪽과 같은지 보고 고른다.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Origin {
    Auto,
    Frame,
    Buffer,
}

/// 스크롤 영역 하나
#[derive(Clone, Debug)]
pub struct Area {
    pub role: Role,
    pub name: String,
    /// 화면 좌표
    pub rect: Rect,
    pub object: ObjectRefOwned,
    /// 창 좌표의 원점(화면 좌표) — 창 좌표로 되돌릴 때
    pub origin: (f64, f64),
}

impl A11y {
    pub async fn new() -> atspi::Result<A11y> {
        Ok(A11y { conn: AccessibilityConnection::new().await? })
    }

    fn bus(&self) -> &zbus::Connection {
        self.conn.connection()
    }

    /// 프로세스 번호가 pid 인 앱
    pub async fn app_for_pid(&self, pid: i32) -> Option<ObjectRefOwned> {
        let root = self.conn.root_accessible_on_registry().await.ok()?;
        let dbus = zbus::fdo::DBusProxy::new(self.bus()).await.ok()?;
        for app in root.get_children().await.ok()? {
            let Some(name) = app.name() else { continue };
            let owner = zbus::names::BusName::from(name.clone());
            if let Ok(p) = dbus.get_connection_unix_process_id(owner).await {
                if p as i32 == pid {
                    return Some(app);
                }
            }
        }
        None
    }

    /// 앱이 쓰는 툴킷 이름 (AT-SPI Application.ToolkitName: "Chromium", "GTK", "Gecko", "Qt" …)
    pub async fn toolkit(&self, app: &ObjectRefOwned) -> String {
        async {
            let p = app.as_accessible_proxy(self.bus()).await.ok()?;
            p.proxies().await.ok()?.application().await.ok()?.toolkit_name().await.ok()
        }
        .await
        .unwrap_or_default()
    }

    /// 앱의 최상위 창들 중 이 창: 제목이 같은 것, 없으면 활성인 것, 없으면 처음 것
    pub async fn window_for(&self, app: &ObjectRefOwned, window: &Window) -> Option<ObjectRefOwned> {
        let proxy = app.as_accessible_proxy(self.bus()).await.ok()?;
        let mut active = None;
        let mut first = None;
        for child in proxy.get_children().await.ok()? {
            let Ok(p) = child.as_accessible_proxy(self.bus()).await else { continue };
            let name = p.name().await.unwrap_or_default();
            if name == window.title {
                return Some(child);
            }
            let states = p.get_state().await.unwrap_or_default();
            if active.is_none() && states.contains(State::Active) {
                active = Some(child.clone());
            }
            if first.is_none() {
                first = Some(child.clone());
            }
        }
        active.or(first)
    }

    /// Chromium·Electron 앱(Chrome, VS Code, Slack 등)은 접근성을 꺼 둔 채 창 아래를 비워 둔다. Orca 처럼 속성·관계를 물으면
    /// 그때 켠다(2026-11-12 jkhan Chrome 에서 확인: --force-renderer-accessibility 없이 페이지 링크까지 나옴). GTK 앱에는 영향 없다.
    pub async fn wake(&self, objects: &[&ObjectRefOwned]) {
        for o in objects {
            if let Ok(p) = o.as_accessible_proxy(self.bus()).await {
                let _ = p.get_attributes().await;
                let _ = p.get_relation_set().await;
            }
        }
    }

    /// 창 좌표의 원점(화면 좌표). Auto 면 최상위 창이 알려 주는 크기로 고른다.
    pub async fn base(&self, top: &ObjectRefOwned, window: &Window, origin: Origin) -> Rect {
        match origin {
            Origin::Frame => window.frame,
            Origin::Buffer => window.buffer,
            Origin::Auto => {
                let size = async {
                    let p = top.as_accessible_proxy(self.bus()).await.ok()?;
                    let c = p.proxies().await.ok()?.component().await.ok()?;
                    c.get_extents(CoordType::Window).await.ok()
                }
                .await;
                match size {
                    Some((_, _, w, h))
                        if (w as f64 - window.buffer.w).abs() < 2.0 && (h as f64 - window.buffer.h).abs() < 2.0
                            && (window.buffer.w - window.frame.w).abs() > 2.0 => window.buffer,
                    _ => window.frame,
                }
            }
        }
    }

    /// 창 안의 클릭 대상 (보이는 것만)
    pub async fn targets(&self, top: &ObjectRefOwned, window: &Window, origin: Origin) -> (Vec<Target>, usize) {
        let base = self.base(top, window, origin).await;
        let screen = window.frame;
        let mut out = vec![];
        let mut stack = vec![(top.clone(), 0usize)];
        let mut visited = 0;
        let started = Instant::now();
        while let Some((obj, depth)) = stack.pop() {
            visited += 1;
            if visited > 6000 || depth > 60 || started.elapsed().as_secs_f64() > 3.0 {
                break;
            }
            let Ok(p) = obj.as_accessible_proxy(self.bus()).await else { continue };
            let states = p.get_state().await.unwrap_or_default();
            if depth > 0 && !states.contains(State::Showing) {
                continue;
            }
            let role = p.get_role().await.unwrap_or(Role::Invalid);
            if CLICKABLE.contains(&role) && states.contains(State::Visible) {
                if let Some(t) = self.target(&p, obj.clone(), role, base, &screen).await {
                    out.push(t);
                }
                // 목록 줄·메뉴 안에도 단추가 있을 수 있어 계속 내려간다(단추 안은 보지 않는다)
                if matches!(role, Role::Button | Role::Link | Role::ToggleButton | Role::CheckBox | Role::RadioButton) {
                    continue;
                }
            }
            if let Ok(children) = p.get_children().await {
                for c in children.into_iter().rev() {
                    stack.push((c, depth + 1));
                }
            }
        }
        (out, visited)
    }

    async fn target(&self, p: &AccessibleProxy<'_>, object: ObjectRefOwned, role: Role, base: Rect, screen: &Rect)
        -> Option<Target> {
        let proxies = p.proxies().await.ok()?;
        let ifaces = p.get_interfaces().await.ok()?;
        if !ifaces.contains(Interface::Component) {
            return None;
        }
        let (x, y, w, h) = proxies.component().await.ok()?.get_extents(CoordType::Window).await.ok()?;
        if w < 2 || h < 2 {
            return None;
        }
        let rect = Rect { x: base.x + x as f64, y: base.y + y as f64, w: w as f64, h: h as f64 };
        if !rect.intersects(screen) {
            return None;
        }
        Some(Target {
            role,
            name: p.name().await.unwrap_or_default(),
            rect,
            object,
            has_action: ifaces.contains(Interface::Action),
        })
    }

    /// 창 안의 스크롤 영역. 역할(스크롤 창·웹 문서·터미널·뷰포트)이나 웹의 DOM 클래스(맥판과 같은 이름 단서)로 찾는다.
    /// 거의 같은 자리는 하나만, 다른 영역 안에서 그 70% 넘게 덮는 것은 바깥 것만 남긴다(휠은 가까운 스크롤 상자로 간다).
    /// 돌려주는 둘째 값은 본 노드 수(막 깨운 Chromium 은 몇 개뿐이다).
    pub async fn scroll_areas(&self, top: &ObjectRefOwned, window: &Window, origin: Origin) -> (Vec<Area>, usize) {
        let base = self.base(top, window, origin).await;
        let screen = window.frame;
        let mut found: Vec<Area> = vec![];
        let mut stack = vec![(top.clone(), 0usize)];
        let mut visited = 0;
        let started = Instant::now();
        let area_roles = [Role::ScrollPane, Role::Viewport, Role::DocumentWeb, Role::Terminal];
        let box_roles = [Role::Section, Role::Landmark, Role::Panel, Role::Grouping, Role::List, Role::Article, Role::Form];
        let leaf_roles = [Role::Paragraph, Role::Link, Role::Label, Role::Static, Role::Button, Role::Image, Role::Heading,
                          Role::ListItem, Role::Entry, Role::PushButtonMenu];
        while let Some((obj, depth)) = stack.pop() {
            visited += 1;
            if visited > 5000 || depth > 60 || started.elapsed().as_secs_f64() > 1.5 {
                break;
            }
            let Ok(p) = obj.as_accessible_proxy(self.bus()).await else { continue };
            let role = p.get_role().await.unwrap_or(Role::Invalid);
            if leaf_roles.contains(&role) {
                continue;
            }
            if depth > 0 && !p.get_state().await.unwrap_or_default().contains(State::Showing) {
                continue;
            }
            if area_roles.contains(&role) || box_roles.contains(&role) {
                if let Some(rect) = self.extents(&p, base).await {
                    let big = rect.w >= 140.0 && rect.h >= 100.0 && rect.intersects(&screen);
                    let mut scroller = area_roles.contains(&role);
                    if big && !scroller {
                        let attrs = p.get_attributes().await.unwrap_or_default();
                        let names: Vec<&str> = attrs
                            .get("class")
                            .map(|c| c.split_whitespace().collect())
                            .unwrap_or_default();
                        let mut all = names.clone();
                        if let Some(id) = attrs.get("id") {
                            all.push(id.as_str());
                        }
                        scroller = hanmium_core::scroll_names::marks_vertical_scroller(&all);
                    }
                    if big && scroller {
                        // 화면(창) 밖으로 나간 부분은 뺀다 — 휠은 보이는 곳에 보내야 한다
                        let rect = rect.clip(&screen);
                        found.push(Area { role, name: p.name().await.unwrap_or_default(), rect, object: obj.clone(),
                                          origin: (base.x, base.y) });
                    }
                }
            }
            if let Ok(children) = p.get_children().await {
                for c in children.into_iter().rev() {
                    stack.push((c, depth + 1));
                }
            }
        }
        // 거의 같은 자리는 하나만
        let close = |a: &Rect, b: &Rect| {
            (a.x - b.x).abs() < 8.0 && (a.y - b.y).abs() < 8.0 && (a.w - b.w).abs() < 8.0 && (a.h - b.h).abs() < 8.0
        };
        let mut unique: Vec<Area> = vec![];
        for a in found {
            if !unique.iter().any(|u| close(&u.rect, &a.rect)) {
                unique.push(a);
            }
        }
        let contains = |o: &Rect, i: &Rect| {
            i.x >= o.x - 4.0 && i.y >= o.y - 4.0 && i.x + i.w <= o.x + o.w + 4.0 && i.y + i.h <= o.y + o.h + 4.0
        };
        let all = unique.clone();
        unique.retain(|inner| {
            !all.iter().any(|outer| {
                !close(&outer.rect, &inner.rect) && contains(&outer.rect, &inner.rect)
                    && inner.rect.w * inner.rect.h >= outer.rect.w * outer.rect.h * 0.7
            })
        });
        unique.sort_by(|a, b| (a.rect.x, a.rect.y).partial_cmp(&(b.rect.x, b.rect.y)).unwrap());
        (unique, visited)
    }

    async fn extents(&self, p: &AccessibleProxy<'_>, base: Rect) -> Option<Rect> {
        let c = p.proxies().await.ok()?.component().await.ok()?;
        let (x, y, w, h) = c.get_extents(CoordType::Window).await.ok()?;
        (w > 0 && h > 0).then(|| Rect { x: base.x + x as f64, y: base.y + y as f64, w: w as f64, h: h as f64 })
    }

    /// 영역이 지금 어디까지 스크롤됐는지 가늠하는 값(시험용, 아래로 갈수록 커짐): 웹은 첫 문단 y 의 음수(px),
    /// 글 상자는 영역 왼쪽 위 근처 글자의 위치(Text 인터페이스, 영역이나 그 안 세 단계까지).
    pub async fn scroll_mark(&self, area: &Area) -> Option<i64> {
        // 웹 영역: 첫 문단의 y 가 스크롤만큼 올라간다 (px)
        let p = area.object.as_accessible_proxy(self.bus()).await.ok()?;
        for c in p.get_children().await.unwrap_or_default().into_iter().take(40) {
            let Ok(cp) = c.as_accessible_proxy(self.bus()).await else { continue };
            if cp.get_role().await.ok() == Some(Role::Paragraph) {
                let (_, y, _, _) = cp.proxies().await.ok()?.component().await.ok()?.get_extents(CoordType::Window).await.ok()?;
                return Some(-(y as i64));
            }
        }
        // 글 상자(GTK 등): 영역 왼쪽 위 근처 글자의 위치
        let (x, y) = (area.rect.x - area.origin.0 + 12.0, area.rect.y - area.origin.1 + 12.0);
        let mut queue = std::collections::VecDeque::from([(area.object.clone(), 0)]);
        while let Some((obj, depth)) = queue.pop_front() {
            let p = obj.as_accessible_proxy(self.bus()).await.ok()?;
            if p.get_interfaces().await.unwrap_or_default().contains(Interface::Text) {
                let text = p.proxies().await.ok()?.text().await.ok()?;
                if let Ok(offset) = text.get_offset_at_point(x as i32, y as i32, CoordType::Window).await {
                    if offset >= 0 {
                        return Some(offset as i64);
                    }
                }
            }
            if depth < 3 {
                for c in p.get_children().await.unwrap_or_default() {
                    queue.push_back((c, depth + 1));
                }
            }
        }
        None
    }

    /// 대상의 첫 동작(누르기·켜기)을 실행한다. 동작이 없으면 false.
    pub async fn activate(&self, t: &Target) -> bool {
        if !t.has_action {
            return false;
        }
        let Ok(p) = t.object.as_accessible_proxy(self.bus()).await else { return false };
        let Ok(proxies) = p.proxies().await else { return false };
        let Ok(action) = proxies.action().await else { return false };
        action.do_action(0).await.unwrap_or(false)
    }
}
