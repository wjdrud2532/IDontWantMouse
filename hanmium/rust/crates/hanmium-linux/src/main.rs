//! hanmium (리눅스).
//!   hanmium run                     데몬: 확장의 단축키(Hotkey 신호)를 기다려 모드를 연다
//!   hanmium windows                 확장이 아는 창 목록
//!   hanmium dump [--buffer]         앞 창의 클릭 대상 (AT-SPI)
//!   hanmium labels [--buffer]       라벨 모드 한 번(시험용)
//! 확장(org.hanmium.Shell)이 켜진 GNOME 세션에서 돌린다. 시험은 rust/linux/test-session.sh.

mod a11y;
mod evdev_keys;
mod label_mode;
mod shell;

use a11y::{A11y, Origin};
use futures_util::StreamExt;
use label_mode::{find_targets, LabelMode, Res, Step};
use shell::ShellProxy;
use std::time::Instant;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let origin = if args.iter().any(|a| a == "--buffer") { Origin::Buffer } else { Origin::Frame };
    let result = match args.first().map(String::as_str) {
        Some("run") => run(origin).await,
        Some("windows") => windows().await,
        Some("dump") => dump(origin).await,
        Some("labels") => labels_once(origin).await,
        _ => {
            eprintln!("사용법: hanmium run | windows | dump [--buffer] | labels [--buffer]");
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

/// 확장이 부르는 데몬 쪽 D-Bus (org.hanmium.Daemon). 신호를 뿌리면 데몬이 아직 듣고 있지 않을 때(막 켰을 때) 사라지므로
/// 확장이 메서드를 직접 부른다. 데몬이 없으면 세션 버스가 D-Bus 활성화로 띄워서 전달한다(rust/linux/org.hanmium.Daemon.service).
enum Event {
    Hotkey(String),
    Key(String),
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
    /// 모드 중 키 (확장이 잡은 키, JSON)
    fn key(&self, json: String) {
        let _ = self.tx.send(Event::Key(json));
    }
}

/// 데몬: 단축키를 받아 모드를 열고, 모드 중에는 확장이 보내는 키를 그 모드에 넘긴다
async fn run(origin: Origin) -> Res<()> {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let conn = zbus::connection::Builder::session()?
        .serve_at("/org/hanmium/Daemon", DaemonIface { tx })?
        .build()
        .await?;
    // 이름은 받은 메서드를 처리할 준비가 된 뒤에 갖는다(활성화로 떴을 때 기다리던 호출이 바로 들어온다)
    let flags = zbus::fdo::RequestNameFlags::DoNotQueue.into();
    match conn.request_name_with_flags("org.hanmium.Daemon", flags).await {
        Ok(zbus::fdo::RequestNameReply::PrimaryOwner) => {}
        _ => return Err("hanmium 데몬이 이미 실행 중입니다".into()),
    }
    let shell = ShellProxy::new(&conn).await?;
    let a = A11y::new().await?;
    let mut mode: Option<LabelMode> = None;
    println!("hanmium 데몬 시작 (확장 {})", shell.ping().await.unwrap_or_else(|_| "없음".into()));
    while let Some(event) = rx.recv().await {
        match event {
            Event::Hotkey(name) => {
                let started = Instant::now();
                match name.as_str() {
                    "labels" => {
                        if let Some(mut m) = mode.take() {
                            m.close(&shell).await?;
                            continue;
                        }
                        match LabelMode::open(&shell, &a, origin, started).await {
                            Ok(m) => mode = Some(m),
                            Err(e) => eprintln!("라벨 모드를 열지 못함: {e}"),
                        }
                    }
                    other => eprintln!("아직 없는 모드: {other}"),
                }
            }
            Event::Key(json) => {
                if let Some(m) = mode.as_mut() {
                    match m.key(&shell, &a, &json).await {
                        Ok(Step::Continue) => {}
                        Ok(Step::Done) => mode = None,
                        Err(e) => {
                            eprintln!("라벨 모드 오류: {e}");
                            let _ = shell.hide_overlay().await;
                            mode = None;
                        }
                    }
                }
            }
        }
    }
    Ok(())
}
