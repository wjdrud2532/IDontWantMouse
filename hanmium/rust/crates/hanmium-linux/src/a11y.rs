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

/// 창 기준 좌표를 화면 좌표로 바꿀 때 쓰는 원점. GTK 처럼 그림자를 직접 그리는 창은 버퍼(그림자 포함)와 틀이 다르다.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Origin {
    Frame,
    Buffer,
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

    /// 창 안의 클릭 대상 (보이는 것만)
    pub async fn targets(&self, top: &ObjectRefOwned, window: &Window, origin: Origin) -> (Vec<Target>, usize) {
        let base = match origin {
            Origin::Frame => window.frame,
            Origin::Buffer => window.buffer,
        };
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
