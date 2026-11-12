// Hanmium 의 GNOME Shell 쪽. Wayland 에서는 일반 앱이 다른 창 위치를 알 수도, 모든 창 위에 그릴 수도, 다른 앱에 입력을
// 보낼 수도 없어서 이 확장이 대신 한다. hanmium 데몬(Rust)이 세션 버스의 org.hanmium.Shell 로 부른다.
//
//   Prepare()            시험용: 현황(Overview)을 닫는다
//   Windows()            보이는 창 목록(JSON): id·pid·앱 id·제목·틀·버퍼 사각형·포커스, 앞에서 뒤 순서
//   ShowOverlay(json)    라벨·사각형·번호를 모든 창 위에 그린다. 다시 부르면 바꿔 그린다.
//   HideOverlay()
//   Grab(on)             모드 동안 키보드를 잡아 키를 신호 Key(json) 로 보낸다
//   Click(x, y, button)  가상 포인터로 그 자리를 누른다
//   Scroll(x, y, dx, dy) 포인터를 그 자리로 옮겨 부드러운 휠을 보낸다
//   MovePointer(x, y)
//   TestKey(keycode, pressed)  시험용: 가상 키보드로 키를 보낸다(진짜 키보드처럼 잡기·앱으로 간다)
//   Screenshot(path)     시험용: 화면을 PNG 로
import Clutter from 'gi://Clutter';
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
  <method name="Windows"><arg type="s" direction="out" name="json"/></method>
  <method name="ShowOverlay"><arg type="s" direction="in" name="json"/></method>
  <method name="HideOverlay"/>
  <method name="Grab"><arg type="b" direction="in" name="on"/><arg type="b" direction="out" name="ok"/></method>
  <method name="Click"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/><arg type="u" direction="in" name="button"/></method>
  <method name="Scroll"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/><arg type="d" direction="in" name="dx"/><arg type="d" direction="in" name="dy"/></method>
  <method name="MovePointer"><arg type="d" direction="in" name="x"/><arg type="d" direction="in" name="y"/></method>
  <method name="TestKey"><arg type="u" direction="in" name="keycode"/><arg type="b" direction="in" name="pressed"/></method>
  <method name="Screenshot"><arg type="s" direction="in" name="path"/><arg type="b" direction="out" name="ok"/></method>
  <signal name="Key"><arg type="s" name="json"/></signal>
</interface></node>`;

const now = () => GLib.get_monotonic_time();

class Service {
    constructor() {
        this._overlay = null;
        this._grab = null;
        const seat = Clutter.get_default_backend().get_default_seat();
        this._pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        this._keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
    }

    destroy() {
        this.HideOverlay();
        this._pointer = null;
        this._keyboard = null;
    }

    Ping() {
        return VERSION;
    }

    // 시험 세션: 처음 뜨는 현황(Overview)을 닫는다
    Prepare() {
        Main.overview.hide();
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
        this._overlay?.destroy();
        this._overlay = null;
    }

    Grab(on) {
        if (on) {
            if (this._grab)
                return true;
            const o = this._ensureOverlay();
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

    _key(event, pressed) {
        const info = {
            pressed,
            keycode: event.get_key_code(),          // 하드웨어 키 코드 = evdev + 8
            keyval: event.get_key_symbol(),
            unicode: event.get_key_unicode(),
            state: event.get_state(),
            time: event.get_time(),
        };
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

export default class HanmiumExtension extends Extension {
    enable() {
        this._service = new Service();
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this._service);
        this._service.emit = (name, json) => this._dbus.emit_signal(name, new GLib.Variant('(s)', [json]));
        this._dbus.export(Gio.DBus.session, '/org/hanmium/Shell');
        this._owner = Gio.bus_own_name(Gio.BusType.SESSION, 'org.hanmium.Shell', Gio.BusNameOwnerFlags.REPLACE, null, null, null);
    }

    disable() {
        if (this._owner)
            Gio.bus_unown_name(this._owner);
        this._dbus?.unexport();
        this._service?.destroy();
        this._owner = null;
        this._dbus = null;
        this._service = null;
    }
}
