//! hanmium (리눅스).
//!   hanmium run                     데몬: 확장의 단축키(Hotkey 신호)를 기다려 모드를 연다
//!   hanmium windows                 확장이 아는 창 목록
//!   hanmium dump                    앞 창의 클릭 대상 (AT-SPI)
//!   hanmium areas                   앞 창의 스크롤 영역과 지금 스크롤 위치 표시값(시험용)
//!   hanmium labels                  라벨 모드 한 번(시험용)
//!   창 좌표 원점은 앱이 알려 주는 창 크기로 고른다(--frame·--buffer 로 고정).
//! 확장(org.hanmium.Shell)이 켜진 GNOME 세션에서 돌린다. 시험은 rust/linux/test-session.sh.

mod a11y;
mod evdev_keys;
mod label_mode;
mod scroll_mode;
mod shell;

use a11y::{A11y, Origin};
use futures_util::StreamExt;
use label_mode::{find_targets, front_window, LabelMode, Res, Step};
use scroll_mode::{ScrollMode, ScrollStep};
use shell::ShellProxy;
use std::time::{Duration, Instant};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let origin = if args.iter().any(|a| a == "--buffer") {
        Origin::Buffer
    } else if args.iter().any(|a| a == "--frame") {
        Origin::Frame
    } else {
        Origin::Auto
    };
    let result = match args.first().map(String::as_str) {
        Some("run") => run(origin).await,
        Some("windows") => windows().await,
        Some("dump") => dump(origin).await,
        Some("areas") => areas(origin).await,
        Some("labels") => labels_once(origin).await,
        _ => {
            eprintln!("사용법: hanmium run | windows | dump | areas | labels  [--frame|--buffer]");
            std::process::exit(2);
        }
    };
    if let Err(e) = result {
        eprintln!("오류: {e}");
        std::process::exit(1);
    }
}

async fn connect() -> Res<(zbus::Connection, ShellProxy<'static>)> {
    let session = zbus::Connection::session().await?;
    let shell = ShellProxy::new(&session).await?;
    Ok((session, shell))
}

async fn windows() -> Res<()> {
    let (_s, shell) = connect().await?;
    for w in shell::parse_windows(&shell.windows().await?) {
        println!("{}{} pid {} {:?} 틀 {:?} 버퍼 {:?} {}", if w.focused { "* " } else { "  " }, w.id, w.pid,
                 w.app.unwrap_or_default(), w.frame, w.buffer, w.title);
    }
    Ok(())
}

async fn dump(origin: Origin) -> Res<()> {
    let (_s, shell) = connect().await?;
    let a = A11y::new().await?;
    let started = Instant::now();
    let (window, targets, visited) = find_targets(&shell, &a, origin).await?;
    println!("창 {} 틀 {:?} — 대상 {}개 (노드 {visited}개, {}ms)", window.title, window.frame, targets.len(),
             started.elapsed().as_millis());
    for t in &targets {
        println!("  {:?} {:?} ({:.0},{:.0} {:.0}x{:.0}){}", t.role, t.name, t.rect.x, t.rect.y, t.rect.w, t.rect.h,
                 if t.has_action { "" } else { " (동작 없음)" });
    }
    Ok(())
}

async fn areas(origin: Origin) -> Res<()> {
    let (_s, shell) = connect().await?;
    let a = A11y::new().await?;
    let started = Instant::now();
    let window = front_window(&shell).await?;
    let app = a.app_for_pid(window.pid).await.ok_or("앱을 접근성 버스에서 찾지 못함")?;
    let top = a.window_for(&app, &window).await.ok_or("창을 접근성 트리에서 찾지 못함")?;
    a.wake(&[&app, &top]).await;
    let (found, _) = a.scroll_areas(&top, &window, origin).await;
    println!("창 {} 틀 {:?} — 스크롤 영역 {}개 ({}ms)", window.title, window.frame, found.len(), started.elapsed().as_millis());
    for (i, area) in found.iter().enumerate() {
        let mark = a.scroll_mark(area).await;
        println!("  {} {:?} {:?} ({:.0},{:.0} {:.0}x{:.0}) 위치 {}", i + 1, area.role, area.name, area.rect.x, area.rect.y,
                 area.rect.w, area.rect.h, mark.map(|m| m.to_string()).unwrap_or("-".into()));
    }
    Ok(())
}

async fn labels_once(origin: Origin) -> Res<()> {
    let (_s, shell) = connect().await?;
    let a = A11y::new().await?;
    let mut keys = shell.receive_key().await?;
    let mut mode = LabelMode::open(&shell, &a, origin, Instant::now()).await?;
    while let Some(k) = keys.next().await {
        if let Step::Done = mode.key(&shell, &a, &k.args()?.json).await? {
            break;
        }
    }
    Ok(())
}

/// 확장이 부르는 데몬 쪽 D-Bus (org.hanmium.Daemon). 단축키는 신호를 뿌리면 데몬이 아직 듣고 있지 않을 때(막 켰을 때)
/// 사라지므로 확장이 메서드를 직접 부른다. 데몬이 없으면 세션 버스가 D-Bus 활성화로 띄워서 전달한다
/// (rust/linux/org.hanmium.Daemon.service). 모드 중 키는 확장의 Key 신호로 받는다: zbus 는 메서드 호출을 동시에 처리해서
/// 누름·뗌 순서가 뒤바뀔 수 있지만 신호 흐름은 순서대로다.
enum Event {
    Hotkey(String),
    Key(String),
    /// 단축키를 앱에 보낸 뒤 그 모드를 다시 연다
    Reopen(Kind),
    /// 확장이 키 포커스를 잃었다(스크롤 모드 중 창을 누름 등) — 키가 앱으로 가므로 모드를 끝낸다
    Lost,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Kind {
    Labels,
    Scroll,
}

enum Mode {
    Labels(LabelMode),
    Scroll(ScrollMode),
}

impl Mode {
    fn kind(&self) -> Kind {
        match self {
            Mode::Labels(_) => Kind::Labels,
            Mode::Scroll(_) => Kind::Scroll,
        }
    }

    async fn close(&mut self, shell: &ShellProxy<'_>) {
        let r = match self {
            Mode::Labels(m) => m.close(shell).await.map(|_| ()),
            Mode::Scroll(m) => m.close(shell).await,
        };
        if let Err(e) = r {
            eprintln!("모드를 닫다가 오류: {e}");
        }
    }
}

async fn open(kind: Kind, shell: &ShellProxy<'_>, a: &A11y, origin: Origin, started: Instant) -> Option<Mode> {
    let r = match kind {
        Kind::Labels => LabelMode::open(shell, a, origin, started).await.map(Mode::Labels),
        Kind::Scroll => ScrollMode::open(shell, a, origin, started).await.map(Mode::Scroll),
    };
    match r {
        Ok(m) => Some(m),
        Err(e) => {
            eprintln!("{kind:?} 모드를 열지 못함: {e}");
            let _ = shell.hide_overlay().await;
            None
        }
    }
}

struct DaemonIface {
    tx: tokio::sync::mpsc::UnboundedSender<Event>,
}

#[zbus::interface(name = "org.hanmium.Daemon")]
impl DaemonIface {
    /// 단축키(labels·search·scroll)
    fn hotkey(&self, name: String) {
        let _ = self.tx.send(Event::Hotkey(name));
    }
    /// 스크롤 모드 중 확장이 키 포커스를 잃음
    fn lost(&self) {
        let _ = self.tx.send(Event::Lost);
    }
}

/// 키 JSON 이 codes 중 하나를 뗀 것인가
fn released(json: &str, codes: &[u16]) -> bool {
    let info: serde_json::Value = serde_json::from_str(json).unwrap_or_default();
    let code = info["keycode"].as_u64().unwrap_or(0).saturating_sub(8) as u16;
    info["pressed"] == serde_json::Value::Bool(false) && codes.contains(&code)
}

/// 데몬: 단축키를 받아 모드를 열고, 모드 중에는 확장이 보내는 키를 그 모드에 넘긴다
async fn run(origin: Origin) -> Res<()> {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let conn = zbus::connection::Builder::session()?
        .serve_at("/org/hanmium/Daemon", DaemonIface { tx: tx.clone() })?
        .build()
        .await?;
    // 이름은 받은 메서드를 처리할 준비가 된 뒤에 갖는다(활성화로 떴을 때 기다리던 호출이 바로 들어온다)
    let flags = zbus::fdo::RequestNameFlags::DoNotQueue.into();
    match conn.request_name_with_flags("org.hanmium.Daemon", flags).await {
        Ok(zbus::fdo::RequestNameReply::PrimaryOwner) => {}
        _ => return Err("hanmium 데몬이 이미 실행 중입니다".into()),
    }
    let shell = ShellProxy::new(&conn).await?;
    let mut keys = shell.receive_key().await?;
    let a = A11y::new().await?;
    let mut mode: Option<Mode> = None;
    // 앱에 보낼 단축키와 그것을 보낼 때(이 키 중 하나를 뗄 때): Shift+h·l·j·k 는 Shift 를 뗄 때(누르고 있는 Shift 가
    // 섞이지 않게), 넘기는 Ctrl·Alt 단축키는 그 키를 뗄 때. 보내면 모드를 닫고 조금 뒤 다시 연다.
    let mut pending: Vec<(u16, bool)> = vec![];
    let mut send_on: Vec<u16> = vec![];
    println!("hanmium 데몬 시작 (확장 {})", shell.ping().await.unwrap_or_else(|_| "없음".into()));
    let debug = std::env::var_os("HANMIUM_DEBUG").is_some();
    loop {
        let event = tokio::select! {
            e = rx.recv() => match e { Some(e) => e, None => break },
            k = keys.next() => match k {
                Some(k) => Event::Key(k.args()?.json.to_string()),
                None => break,
            },
        };
        if debug {
            match &event {
                Event::Key(j) => eprintln!("[키] {} 모드 {:?} 보낼 것 {}", j, mode.as_ref().map(|m| m.kind()), pending.len()),
                Event::Hotkey(n) => eprintln!("[단축키] {n}"),
                Event::Reopen(k) => eprintln!("[다시 열기] {k:?}"),
                Event::Lost => eprintln!("[포커스 잃음]"),
            }
        }
        if mode.is_none() {
            pending.clear();
        }
        match event {
            Event::Hotkey(name) => {
                let started = Instant::now();
                let kind = match name.as_str() {
                    "labels" => Kind::Labels,
                    "scroll" => Kind::Scroll,
                    other => {
                        eprintln!("아직 없는 모드: {other}");
                        continue;
                    }
                };
                // 같은 모드 단축키는 닫기, 라벨 단축키는 어느 모드든 닫기, 그 밖에는 바꾸기
                if let Some(mut m) = mode.take() {
                    let was = m.kind();
                    m.close(&shell).await;
                    if was == kind || kind == Kind::Labels {
                        continue;
                    }
                }
                mode = open(kind, &shell, &a, origin, started).await;
            }
            Event::Lost => {
                if let Some(mut m) = mode.take() {
                    eprintln!("키 포커스를 잃어 {:?} 모드를 끝냄", m.kind());
                    m.close(&shell).await;
                }
            }
            Event::Reopen(kind) => {
                if mode.is_none() {
                    mode = open(kind, &shell, &a, origin, Instant::now()).await;
                }
            }
            Event::Key(json) => {
                let Some(m) = mode.as_mut() else { continue };
                if !pending.is_empty() && released(&json, &send_on) {
                    let kind = m.kind();
                    m.close(&shell).await;
                    mode = None;
                    let keys: Vec<[serde_json::Value; 2]> =
                        pending.drain(..).map(|(c, p)| [c.into(), p.into()]).collect();
                    if let Err(e) = shell.send_keys(&serde_json::to_string(&keys)?).await {
                        eprintln!("단축키를 보내지 못함: {e}");
                    }
                    // 앱이 단축키를 처리한 뒤(새 페이지·탭) 다시 연다. 라벨은 새 페이지가 그려질 시간을 더 준다.
                    let tx = tx.clone();
                    let wait = if kind == Kind::Labels { 300 } else { 150 };
                    tokio::spawn(async move {
                        tokio::time::sleep(Duration::from_millis(wait)).await;
                        let _ = tx.send(Event::Reopen(kind));
                    });
                    continue;
                }
                let next = match m {
                    Mode::Labels(l) => match l.key(&shell, &a, &json).await {
                        Ok(Step::Continue) => Ok(None),
                        Ok(Step::Done) => Ok(Some(None)),
                        Ok(Step::Send(keys)) => {
                            pending.extend(keys);
                            send_on = vec![42, 54];
                            Ok(None)
                        }
                        Ok(Step::ToScroll(code)) => {
                            // 라벨에서 j·k: 스크롤 모드를 열고 그 키를 누른 것으로
                            let mut s = open(Kind::Scroll, &shell, &a, origin, Instant::now()).await;
                            if let Some(Mode::Scroll(sm)) = s.as_mut() {
                                let press = serde_json::json!({"pressed": true, "keycode": code + 8, "state": 0}).to_string();
                                let _ = sm.key(&shell, &press).await;
                            }
                            Ok(Some(s))
                        }
                        Err(e) => Err(e),
                    },
                    Mode::Scroll(sm) => match sm.key(&shell, &json).await {
                        Ok(ScrollStep::Continue) => Ok(None),
                        Ok(ScrollStep::Done) => Ok(Some(None)),
                        Ok(ScrollStep::Send(keys)) => {
                            pending.extend(keys);
                            send_on = vec![42, 54];
                            Ok(None)
                        }
                        Ok(ScrollStep::Pass(keys, code)) => {
                            pending.extend(keys);
                            send_on = vec![code];
                            Ok(None)
                        }
                        Ok(ScrollStep::ToLabels) => Ok(Some(open(Kind::Labels, &shell, &a, origin, Instant::now()).await)),
                        Err(e) => Err(e),
                    },
                };
                match next {
                    Ok(None) => {}
                    Ok(Some(new)) => mode = new,
                    Err(e) => {
                        eprintln!("모드 오류: {e}");
                        let _ = shell.scroll_stop().await;
                        let _ = shell.hide_overlay().await;
                        mode = None;
                    }
                }
            }
        }
    }
    Ok(())
}
