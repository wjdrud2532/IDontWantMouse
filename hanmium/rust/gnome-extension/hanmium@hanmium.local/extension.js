// Hanmium 의 GNOME Shell 쪽. Wayland 에서는 일반 앱이 다른 창 위치를 알 수도, 모든 창 위에 그릴 수도, 다른 앱에 입력을
// 보낼 수도 없어서 이 확장이 대신 한다. hanmium 데몬(Rust)이 세션 버스의 org.hanmium.Shell 로 부른다.
//
//   Prepare()            시험용: 현황(Overview)을 닫는다
//   State()              시험용: 포커스 창, 키 포커스, 포인터 아래 액터, 현황 여부, 모달(JSON)
//   Activate(id)         그 창을 앞으로
//   Windows()            보이는 창 목록(JSON): id·pid·앱 id·제목·틀·버퍼 사각형·포커스, 앞에서 뒤 순서
//   ShowOverlay(json)    라벨·사각형·번호를 모든 창 위에 그린다. 다시 부르면 바꿔 그린다.
//   HideOverlay()
//   Grab(on)             모드 동안 키보드를 잡아 키를 신호 Key(json) 로 보낸다 (포인터·휠도 잡힌다: 라벨 모드)
//   KeyFocus(on)         키만 받고 포인터·휠은 앱으로 그대로 간다 (스크롤 모드: 가상 휠이 앱에 닿아야 한다).
//                        pushModal 로 잡으면 휠이 셸로 가서 작업 공간이 넘어간다.
//   Click(x, y, button)  가상 포인터로 그 자리를 누른다
//   Scroll(x, y, dx, dy) 포인터를 그 자리로 옮겨 부드러운 휠을 보낸다
//   MovePointer(x, y)
//   Pointer()            지금 포인터 위치
//   ScrollParams·ScrollAim·ScrollHold·ScrollRelease·ScrollPage·ScrollJump·ScrollStop
//                        스크롤 모드: 데몬은 누름·뗌만 알리고 움직임은 여기서 화면 프레임마다 계산해 보낸다(Scroller)
//   SendKeys(json)       [[evdev 코드, 누름], …] 을 차례로 가상 키보드로 (뒤로·앞으로·탭 바꾸기 단축키)
//   TestKey(keycode, pressed)  시험용: 가상 키보드로 키를 보낸다(진짜 키보드처럼 잡기·앱으로 간다)
//   Screenshot(path)     시험용: 화면을 PNG 로
//   단축키(설정 labels·search·scroll, 기본 Alt+Space·Alt+/·Shift+Super+J)는 데몬 메서드 org.hanmium.Daemon.Hotkey(name)
//   를 직접 부른다(데몬이 없으면 D-Bus 활성화로 뜬다. 신호 Hotkey 도 같이). 모드 중 키는 신호 Key(json) 로만 보낸다(순서 보장).
//   스크롤 모드 중 키 포커스를 잃으면 데몬 메서드 Lost() 를 부른다.
import Clutter from 'gi://Clutter';
import Meta from 'gi://Meta';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const VERSION = '0.1.0';

const IFACE = `<node><interface name="org.hanmium.Shell">
  <method name="Ping"><arg type="s" direction="out" name="version"/></method>
  <method name="Prepare"/>
  <method name="State"><arg type="s" direction="out" name="json"/></method>
  <method name="Windows"><arg type="s" direction="out" name="json"/></method>
  <method name="Activate"><arg type="t" direction="in" name="id"/></method>
  <method name="ShowOverlay"><arg type="s" direction="in" name="json"/></method>
  <method name="KeyFocus"><arg type="b" direction="in" name="on"/><arg type="b" direction="out"/></method>
  <method name="HideOverlay"/>
  <method name="Grab"><arg type="b" direction="in" name="on"/><arg type="b" direction="out" name="ok"/></method>
  <method name="Click"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/><arg type="u" direction="in" name="button"/></method>
  <method name="Scroll"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/><arg type="d" direction="in" name="dx"/><arg type="d" direction="in" name="dy"/></method>
  <method name="MovePointer"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/></method>
  <method name="Pointer"><arg type="d" direction="out" name="x"/><arg type="d" direction="out" name="y"/></method>
  <method name="ScrollParams"><arg type="s" direction="in" name="json"/></method>
  <method name="ScrollAim"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/></method>
  <method name="ScrollHold"><arg type="u" direction="in" name="id"/><arg type="d" direction="in" name="dx"/><arg type="d" direction="in" name="dy"/></method>
  <method name="ScrollRelease"><arg type="u" direction="in" name="id"/></method>
  <method name="ScrollPage"><arg type="u" direction="in" name="id"/><arg type="d" direction="in" name="dx"/><arg type="d" direction="in" name="dy"/><arg type="d" direction="in" name="cdx"/><arg type="d" direction="in" name="cdy"/></method>
  <method name="ScrollJump"><arg type="d" direction="in" name="dy"/></method>
  <method name="ScrollStop"/>
  <method name="SendKeys"><arg type="s" direction="in" name="json"/></method>
  <method name="TestKey"><arg type="u" direction="in" name="keycode"/><arg type="b" direction="in" name="pressed"/></method>
  <method name="Screenshot"><arg type="s" direction="in" name="path"/><arg type="b" direction="out" name="ok"/></method>
  <signal name="Key"><arg type="s" name="json"/></signal>
  <signal name="Hotkey"><arg type="s" name="name"/></signal>
</interface></node>`;

const now = () => GLib.get_monotonic_time();

/// 스크롤 모드의 움직임. 맥판 ScrollDriver 와 같은 모형: 누르고 있는 키의 목표 속도로 지수적으로 다가가고(가속·감속 시간 상수),
/// d/u 는 반 페이지를 ease-out 으로 나눠 보내다 누르고 있으면 계속 스크롤로 넘긴다. 화면 프레임(Clutter.Timeline)마다 계산해서
/// 보낸다: 데몬이 D-Bus 로 프레임마다 보내면 도착 시각이 흔들려 덜컹인다. 휠은 연속(CONTINUOUS) 소스로 보내 앱이 손을 뗀 뒤
/// 관성으로 더 움직이지 않게 한다.
class Scroller {
    constructor(pointer) {
        this._pointer = pointer;
        this._held = new Map();
        // unitPx: 휠 한 단위가 그 앱에서 몇 px 인지(데몬이 툴킷으로 정함). 여기 값은 모두 px 로 계산하고 보낼 때 나눈다.
        this._p = {pxPerMs: 1, dash: 3, accelTau: 20, decelTau: 15, glideMs: 120, holdDelayMs: 120, unitPx: 10};
        this._reset();
        this._timeline = null;
    }

    _reset() {
        this._held.clear();
        this._vx = 0; this._vy = 0; this._cx = 0; this._cy = 0;
        this._glide = null;
        this._paging = null;
        this._last = 0;
    }

    params(p) { Object.assign(this._p, p); }

    // 휠을 보낼 자리. 포인터가 그대로인 채 덮개가 생겼다 없어지면(라벨·테두리) Wayland 포인터 포커스가 창으로 돌아오지 않아
    // 휠이 아무 데도 안 간다 → 1px 옆에 갔다 와서 그 자리의 창을 다시 고르게 한다. 스크롤을 시작할 때마다 한 번 더.
    aim(x, y) {
        this._aim = [x, y];
        this._poke();
    }

    _poke() {
        if (!this._aim)
            return;
        const [x, y] = this._aim;
        const t = now();
        this._pointer.notify_absolute_motion(t, x + 1, y);
        this._pointer.notify_absolute_motion(t + 1, x, y);
    }

    hold(id, dx, dy) {
        if (!this._timeline)
            this._poke();
        this._held.set(id, [dx, dy]);
        this._run();
    }

    release(id) {
        this._held.delete(id);
        if (this._paging && this._paging.id === id)
            this._paging = null;
    }

    page(id, dx, dy, cdx, cdy) {
        let tx = dx, ty = dy;
        if (this._glide) {
            tx += this._glide.tx - this._glide.sx;
            ty += this._glide.ty - this._glide.sy;
        }
        if (!this._timeline)
            this._poke();
        this._glide = {tx, ty, sx: 0, sy: 0, start: null};
        this._paging = {id, start: now() / 1000, cdx, cdy};
        this._run();
    }

    jump(dy) {
        this._poke();
        for (let i = 0; i < 20; i++)
            this._send(0, dy > 0 ? 5000 : -5000);
        this._finish();
    }

    stop() {
        this._reset();
        if (this._timeline) {
            this._timeline.stop();
            this._timeline = null;
        }
        this._finish();
    }

    destroy() {
        this.stop();
        this._cancelFinish();
    }

    _run() {
        if (this._timeline)
            return;
        this._last = 0;
        this._timeline = new Clutter.Timeline({actor: global.stage, duration: 1000, repeat_count: -1});
        this._timeline.connect('new-frame', () => this._frame());
        this._timeline.start();
    }

    _shift() {
        const [, , mods] = global.get_pointer();
        return (mods & Clutter.ModifierType.SHIFT_MASK) !== 0;
    }

    _frame() {
        const t = now() / 1000;  // ms
        const frame = 1000 / 60;
        const dt = this._last === 0 ? frame : Math.min(Math.max(t - this._last, 0), 50);
        this._last = t;
        const p = this._p;
        if (this._glide && this._glide.start === null)
            this._glide.start = t - frame;
        const speed = p.pxPerMs * (this._shift() ? p.dash : 1);
        // d/u 를 계속 누르고 있으면 반 페이지 이동의 지금 속도를 이어받아 계속 스크롤로
        if (this._paging) {
            const g = this._glide;
            let gvx = 0, gvy = 0, slowing = false;
            if (g && g.start !== null && p.glideMs > 0) {
                const prog = Math.min(1, (t - g.start) / p.glideMs);
                const k = 2 * (1 - prog) / p.glideMs;
                gvx = g.tx * k; gvy = g.ty * k;
                slowing = prog >= 0.5 && Math.hypot(gvx, gvy) <= Math.hypot(this._paging.cdx, this._paging.cdy) * speed;
            }
            if (slowing || t - this._paging.start >= p.holdDelayMs) {
                this._vx += gvx; this._vy += gvy;
                this._held.set(this._paging.id, [this._paging.cdx, this._paging.cdy]);
                this._glide = null;
                this._paging = null;
            }
        }
        let tx = 0, ty = 0;
        for (const [dx, dy] of this._held.values()) { tx += dx; ty += dy; }
        tx *= speed; ty *= speed;
        const speeding = Math.hypot(tx, ty) >= Math.hypot(this._vx, this._vy);
        const tau = speeding ? p.accelTau : p.decelTau;
        const k = tau > 0 ? 1 - Math.exp(-dt / tau) : 1;
        this._vx += (tx - this._vx) * k;
        this._vy += (ty - this._vy) * k;
        if (this._held.size === 0 && Math.hypot(this._vx, this._vy) < 0.02) { this._vx = 0; this._vy = 0; }
        this._cx += this._vx * dt;
        this._cy += this._vy * dt;
        let sx = Math.trunc(this._cx), sy = Math.trunc(this._cy);
        this._cx -= sx; this._cy -= sy;
        if (this._glide && this._glide.start !== null) {
            const g = this._glide;
            const prog = p.glideMs > 0 ? Math.min(1, (t - g.start) / p.glideMs) : 1;
            const eased = 1 - (1 - prog) ** 2;
            const dx = Math.trunc(g.tx * eased), dy = Math.trunc(g.ty * eased);
            sx += dx - g.sx; sy += dy - g.sy;
            g.sx = dx; g.sy = dy;
            if (prog >= 1)
                this._glide = null;
        }
        if (sx !== 0 || sy !== 0)
            this._send(sx, sy);
        const idle = this._held.size === 0 && !this._glide && !this._paging && this._vx === 0 && this._vy === 0;
        if (idle) {
            this._finish();
            this._timeline?.stop();
            this._timeline = null;
        }
    }

    _send(dx, dy) {
        this._cancelFinish();
        const u = this._p.unitPx || 10;
        this._pointer.notify_scroll_continuous(now(), dx / u, dy / u, Clutter.ScrollSource.CONTINUOUS, Clutter.ScrollFinishFlags.NONE);
        this._sent = true;
        if (dx || dy)
            this._lastDir = [Math.sign(dx), Math.sign(dy)];
    }

    // 멈췄다고 알린다(앱이 스크롤이 끝난 것을 안다). 끝 신호를 받은 GTK 등은 직전 150ms 의 휠 양으로 속도를 재서 관성 스크롤을
    // 이어 가므로(놓은 뒤에도 미끄러짐), 200ms 조용히 기다린 뒤 반대·같은 방향으로 1px 씩(합 0) 보내 잰 속도를 0 으로 만들고 끝낸다.
    // 그 사이 다시 스크롤하면 취소(같은 스크롤로 이어짐).
    _finish() {
        if (!this._sent || this._finishTimer)
            return;
        this._finishTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
            this._finishTimer = 0;
            const u = this._p.unitPx || 10;
            const [sx, sy] = (this._lastDir ?? [0, 1]).map(v => v / u);
            const t = now();
            const p = this._pointer;
            p.notify_scroll_continuous(t, -sx, -sy, Clutter.ScrollSource.CONTINUOUS, Clutter.ScrollFinishFlags.NONE);
            p.notify_scroll_continuous(t + 1000, sx, sy, Clutter.ScrollSource.CONTINUOUS, Clutter.ScrollFinishFlags.NONE);
            p.notify_scroll_continuous(t + 2000, 0, 0, Clutter.ScrollSource.CONTINUOUS,
                Clutter.ScrollFinishFlags.HORIZONTAL | Clutter.ScrollFinishFlags.VERTICAL);
            this._sent = false;
            return GLib.SOURCE_REMOVE;
        });
    }

    _cancelFinish() {
        if (this._finishTimer) {
            GLib.source_remove(this._finishTimer);
            this._finishTimer = 0;
        }
    }
}

// 단축키·모드 중 키는 hanmium 데몬(org.hanmium.Daemon)의 메서드를 직접 부른다. 신호만 뿌리면 데몬이 막 떠서 아직 듣지 않을 때
// 사라진다. 데몬이 없으면 세션 버스가 D-Bus 활성화로 띄워 전달한다. 실패하면 로그에 남긴다.
function callDaemon(method, arg) {
    Gio.DBus.session.call('org.hanmium.Daemon', '/org/hanmium/Daemon', 'org.hanmium.Daemon', method,
        arg === null ? null : new GLib.Variant('(s)', [arg]), null, Gio.DBusCallFlags.NONE, 5000, null,
        (conn, res) => {
            try {
                conn.call_finish(res);
            } catch (e) {
                console.warn(`hanmium: 데몬 ${method} 실패: ${e.message}`);
            }
        });
}

class Service {
    constructor() {
        this._overlay = null;
        this._grab = null;
        const seat = Clutter.get_default_backend().get_default_seat();
        this._pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this._keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        this._scroller = new Scroller(this._pointer);
    }

    destroy() {
        this._scroller?.destroy();
        this.HideOverlay();
        this._pointer = null;
        this._keyboard = null;
    }

    State() {
        const [x, y] = global.get_pointer();
        const under = global.stage.get_actor_at_pos(Clutter.PickMode.REACTIVE, x, y);
        const kf = global.stage.get_key_focus();
        return JSON.stringify({
            focus: global.display.focus_window?.get_title() ?? null,
            keyFocus: kf === global.stage ? 'stage' : (kf?.name || kf?.constructor?.name || null),
            under: under?.constructor?.name ?? null,
            pointer: [x, y],
            overview: Main.overview.visible,
            modal: Main.modalCount,
        });
    }

    Ping() {
        return VERSION;
    }

    // 시험 세션: 처음 뜨는 현황(Overview)을 닫는다
    // 시험 세션(가상 모니터)은 포인터 장벽이 없어 왼쪽 위 모서리에 포인터가 '들어가기'만 해도 현황이 열린다. 시작 때 포인터가
    // (0,0) 이라 덮개가 생겼다 없어질 때마다 현황이 열리므로 화면 가운데로 옮겨 둔다.
    Prepare() {
        Main.overview.hide();
        // (0,0) 에서 처음 움직일 때는 모서리 장벽에 한 축이 걸려 남으므로 두 번
        for (let i = 0; i < 2; i++)
            this._pointer.notify_absolute_motion(now() + i, global.stage.width / 2, global.stage.height / 2);
    }

    Windows() {
        const metas = global.get_window_actors().map(a => a.meta_window)
            .filter(w => w && !w.minimized && w.showing_on_its_workspace());
        const sorted = global.display.sort_windows_by_stacking(metas).reverse();
        const rect = r => ({x: r.x, y: r.y, w: r.width, h: r.height});
        return JSON.stringify(sorted.map(w => ({
            id: w.get_id(),
            pid: w.get_pid(),
            app: w.get_gtk_application_id() ?? w.get_sandboxed_app_id() ?? null,
            wmClass: w.get_wm_class(),
            title: w.get_title(),
            frame: rect(w.get_frame_rect()),
            buffer: rect(w.get_buffer_rect()),
            focused: w.has_focus(),
            type: w.get_window_type(),
        })));
    }

    // 창 하나를 앞으로(포커스)
    Activate(id) {
        const w = global.get_window_actors().map(a => a.meta_window).find(m => m && m.get_id() === Number(id));
        if (w)
            Main.activateWindow(w);
    }

    _ensureOverlay() {
        if (this._overlay)
            return this._overlay;
        this._overlay = new St.Widget({
            name: 'hanmium-overlay', reactive: true, can_focus: true, x: 0, y: 0,
            width: global.stage.width, height: global.stage.height,
        });
        this._overlay.connect('key-press-event', (_a, e) => this._key(e, true));
        this._overlay.connect('key-release-event', (_a, e) => this._key(e, false));
        Main.uiGroup.add_child(this._overlay);
        return this._overlay;
    }

    // spec: {labels:[{x,y,text,typed}], rects:[{x,y,w,h,kind}], badges:[{x,y,text,dim}]}
    ShowOverlay(json) {
        const spec = JSON.parse(json);
        const o = this._ensureOverlay();
        o.destroy_all_children();
        for (const r of spec.rects ?? []) {
            const style = r.kind === 'slab'
                ? 'background-color: rgba(255,255,255,0.06); border-radius: 10px;'
                : 'border: 3px solid rgba(64,156,255,0.95); border-radius: 10px;';
            o.add_child(new St.Widget({x: r.x, y: r.y, width: r.w, height: r.h, style}));
        }
        for (const l of spec.labels ?? []) {
            const typed = l.typed ?? 0;
            const text = typed > 0
                ? `<span alpha="45%">${GLib.markup_escape_text(l.text.slice(0, typed), -1)}</span>${GLib.markup_escape_text(l.text.slice(typed), -1)}`
                : GLib.markup_escape_text(l.text, -1);
            const label = new St.Label({
                style: 'background-color: rgba(255,214,10,0.95); color: #1c1c1e; font-weight: 800; font-size: 13px;'
                    + ' padding: 1px 5px; border-radius: 5px; border: 1px solid rgba(0,0,0,0.35);',
            });
            label.clutter_text.set_markup(text.toUpperCase());
            label.set_position(Math.round(l.x), Math.round(l.y));
            o.add_child(label);
        }
        for (const b of spec.badges ?? []) {
            const badge = new St.Label({
                text: b.text,
                style: `background-color: rgba(255,107,0,${b.dim ? 0.45 : 1}); color: white; font-weight: 900;`
                    + ' font-size: 14px; padding: 1px 7px; border-radius: 10px; border: 2px solid white;',
            });
            badge.set_position(Math.round(b.x), Math.round(b.y));
            o.add_child(badge);
        }
    }

    HideOverlay() {
        this.Grab(false);
        this.KeyFocus(false);
        this._overlay?.destroy();
        this._overlay = null;
    }

    Grab(on) {
        if (on) {
            if (this._grab)
                return true;
            this.KeyFocus(false);
            const o = this._ensureOverlay();
            o.reactive = true;
            this._grab = Main.pushModal(o, {actionMode: Shell.ActionMode.NORMAL});
            o.grab_key_focus();
            return true;
        }
        if (this._grab) {
            Main.popModal(this._grab);
            this._grab = null;
        }
        return true;
    }

    // 키보드 포커스만 가져온다(패널 키보드 이동과 같은 방식): 키는 앱(Wayland)으로 가지 않고 1x1 받는 곳(sink)이 받는다.
    // Clutter 는 반응하는(reactive) 액터에만 키를 주므로 덮개 대신 화면 밖의 작은 액터를 쓰고, 덮개는 반응하지 않게 해서
    // 포인터·휠이 그 아래 창으로 가게 한다. 셸 단축키(Alt+Tab 등)는 그대로 먹는다.
    KeyFocus(on) {
        if (on) {
            if (this._grab) {
                Main.popModal(this._grab);
                this._grab = null;
            }
            this._ensureOverlay().reactive = false;
            if (!this._sink) {
                this._sink = new St.Widget({name: 'hanmium-keys', reactive: true, can_focus: true, x: -4, y: -4, width: 1, height: 1});
                this._sink.connect('key-press-event', (_a, e) => this._key(e, true));
                this._sink.connect('key-release-event', (_a, e) => this._key(e, false));
                Main.uiGroup.add_child(this._sink);
            }
            global.stage.set_key_focus(this._sink);
            // 다른 데로 포커스가 가면(창을 누름, 현황이 닫히며 포커스를 돌려줌 등) 키가 앱으로 새므로 데몬에 알려 모드를 끝낸다
            this._sinkWatch ??= global.stage.connect('notify::key-focus', () => {
                if (this._sink && global.stage.get_key_focus() !== this._sink) {
                    console.log('hanmium: 스크롤 모드 키 포커스를 잃음');
                    this.KeyFocus(false);
                    callDaemon('Lost', null);
                }
            });
            return global.stage.get_key_focus() === this._sink;
        }
        if (this._sinkWatch) {
            global.stage.disconnect(this._sinkWatch);
            this._sinkWatch = null;
        }
        if (this._sink) {
            const sink = this._sink;
            this._sink = null;
            if (global.stage.get_key_focus() === sink)
                global.stage.set_key_focus(null);
            sink.destroy();
        }
        return true;
    }

    _key(event, pressed) {
        const info = {
            pressed,
            repeat: (event.get_flags() & Clutter.EventFlags.FLAG_REPEATED) !== 0,
            keycode: event.get_key_code(),          // 하드웨어 키 코드 = evdev + 8
            keyval: event.get_key_symbol(),
            unicode: event.get_key_unicode(),
            state: event.get_state(),
            time: event.get_time(),
        };
        // 모드 중 키는 신호로만 보낸다: 데몬(zbus)은 메서드 호출을 동시에 처리해서 누름·뗌 순서가 뒤바뀔 수 있다(떼기가
        // 먼저 오면 스크롤이 멈추지 않는다). 신호는 순서대로 온다. 모드가 열려 있으면 데몬은 이미 떠서 듣고 있다.
        this.emit('Key', JSON.stringify(info));
        return Clutter.EVENT_STOP;
    }

    Click(x, y, button) {
        const t = now();
        this._pointer.notify_absolute_motion(t, x, y);
        this._pointer.notify_button(t + 1, button, Clutter.ButtonState.PRESSED);
        this._pointer.notify_button(t + 2, button, Clutter.ButtonState.RELEASED);
    }

    Scroll(x, y, dx, dy) {
        const t = now();
        this._pointer.notify_absolute_motion(t, x, y);
        this._pointer.notify_scroll_continuous(t + 1, dx, dy, Clutter.ScrollSource.FINGER, Clutter.ScrollFinishFlags.NONE);
    }

    MovePointer(x, y) {
        this._pointer.notify_absolute_motion(now(), x, y);
    }

    Pointer() {
        const [x, y] = global.get_pointer();
        return [x, y];
    }

    ScrollParams(json) { this._scroller.params(JSON.parse(json)); }
    ScrollAim(x, y) { this._scroller.aim(x, y); }
    ScrollHold(id, dx, dy) { this._scroller.hold(id, dx, dy); }
    ScrollRelease(id) { this._scroller.release(id); }
    ScrollPage(id, dx, dy, cdx, cdy) { this._scroller.page(id, dx, dy, cdx, cdy); }
    ScrollJump(dy) { this._scroller.jump(dy); }
    ScrollStop() { this._scroller.stop(); }

    // [[evdev 코드, 누름], …]
    SendKeys(json) {
        let t = now();
        for (const [code, pressed] of JSON.parse(json))
            this._keyboard.notify_key(t++, code, pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
    }

    TestKey(keycode, pressed) {
        // notify_key 는 evdev 키 코드를 받는다
        this._keyboard.notify_key(now(), keycode, pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
    }

    ScreenshotAsync([path], invocation) {
        try {
            const shooter = new Shell.Screenshot();
            const stream = Gio.File.new_for_path(path).replace(null, false, Gio.FileCreateFlags.NONE, null);
            shooter.screenshot(false, stream, (_o, res) => {
                try {
                    shooter.screenshot_finish(res);
                    stream.close(null);
                    invocation.return_value(new GLib.Variant('(b)', [true]));
                } catch (e) {
                    invocation.return_value(new GLib.Variant('(b)', [false]));
                }
            });
        } catch (e) {
            invocation.return_value(new GLib.Variant('(b)', [false]));
        }
    }
}

const HOTKEYS = ['labels', 'search', 'scroll'];

export default class HanmiumExtension extends Extension {
    enable() {
        this._service = new Service();
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this._service);
        this._service.emit = (name, json) => this._dbus.emit_signal(name, new GLib.Variant('(s)', [json]));
        this._dbus.export(Gio.DBus.session, '/org/hanmium/Shell');
        this._owner = Gio.bus_own_name(Gio.BusType.SESSION, 'org.hanmium.Shell', Gio.BusNameOwnerFlags.REPLACE, null, null, null);
        // 단축키: 창이 앞에 있을 때(NORMAL)와 현황 화면에서. 모드 중(키보드를 잡은 동안)에는 확장이 키를 Key 신호로 보낸다.
        this._settings = this.getSettings();
        for (const name of HOTKEYS) {
            Main.wm.addKeybinding(name, this._settings, Meta.KeyBindingFlags.IGNORE_AUTOREPEAT,
                Shell.ActionMode.NORMAL | Shell.ActionMode.OVERVIEW,
                () => {
                    callDaemon('Hotkey', name);
                    this._dbus.emit_signal('Hotkey', new GLib.Variant('(s)', [name]));
                });
        }
    }

    disable() {
        for (const name of HOTKEYS)
            Main.wm.removeKeybinding(name);
        this._settings = null;
        if (this._owner)
            Gio.bus_unown_name(this._owner);
        this._dbus?.unexport();
        this._service?.destroy();
        this._owner = null;
        this._dbus = null;
        this._service = null;
    }
}
