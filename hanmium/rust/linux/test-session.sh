#!/bin/bash
# 사용자 세션과 따로 headless GNOME Shell 을 띄워 Hanmium 리눅스판을 시험한다. 설정·런타임 폴더를 따로 써서
# 실제 데스크톱(설정, 창, 입력)에는 아무 영향이 없다. 화면은 가상 모니터 하나(기본 1600x1000).
#   test-session.sh start [WxH]   띄우고 Hanmium 확장을 켠다
#   test-session.sh run CMD…      그 세션 안에서 명령 실행 (WAYLAND_DISPLAY·D-Bus·접근성 버스가 그 세션 것)
#   test-session.sh call METHOD [ARGS…]   확장의 org.hanmium.Shell 메서드 부르기 (gdbus)
#   test-session.sh shot PNG      화면 찍기
#   test-session.sh stop
set -e
DIR=${HANMIUM_TEST_DIR:-/tmp/hanmium-gnome}
EXT_SRC="$(cd "$(dirname "$0")/../gnome-extension" && pwd)/hanmium@hanmium.local"
UNIT=hanmium-test

envs() {
    export XDG_CONFIG_HOME=$DIR/config XDG_DATA_HOME=$DIR/data XDG_CACHE_HOME=$DIR/cache XDG_STATE_HOME=$DIR/state
    export XDG_RUNTIME_DIR=$DIR/runtime WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland
    unset DISPLAY
    export DBUS_SESSION_BUS_ADDRESS=$(cat $DIR/bus 2>/dev/null)
}

case "$1" in
start)
    "$0" stop >/dev/null 2>&1 || true
    size=${2:-1600x1000}
    mkdir -p $DIR/{config,data/gnome-shell/extensions,cache,state,runtime}
    chmod 700 $DIR/runtime
    cp -r "$EXT_SRC" $DIR/data/gnome-shell/extensions/
    # 세션이 띄우는 것(D-Bus, 접근성 버스, 포털, gvfs 등)을 모두 systemd 범위 하나에 넣어 stop 때 한꺼번에 끈다
    uid=$(id -u)
    XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
    nohup systemd-run --user --scope --quiet --unit=$UNIT -- env -u WAYLAND_DISPLAY -u DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
        XDG_CONFIG_HOME=$DIR/config XDG_DATA_HOME=$DIR/data XDG_CACHE_HOME=$DIR/cache XDG_STATE_HOME=$DIR/state \
        XDG_RUNTIME_DIR=$DIR/runtime GVFS_DISABLE_FUSE=1 \
        dbus-run-session -- bash -c "
        echo \"\$DBUS_SESSION_BUS_ADDRESS\" > $DIR/bus
        gsettings set org.gnome.shell disable-user-extensions false
        gsettings set org.gnome.shell enabled-extensions \"['hanmium@hanmium.local']\"
        gsettings set org.gnome.desktop.interface toolkit-accessibility true
        exec gnome-shell --headless --wayland --no-x11 --virtual-monitor $size" > $DIR/shell.log 2>&1 &
    for _ in $(seq 1 60); do
        sleep 0.25
        [ -S $DIR/runtime/wayland-0 ] && [ -s $DIR/bus ] && break
    done
    envs
    for _ in $(seq 1 60); do
        gdbus call --session --dest org.hanmium.Shell --object-path /org/hanmium/Shell \
            --method org.hanmium.Shell.Ping >/dev/null 2>&1 && { echo "시험 세션 준비됨 ($size)"; exit 0; }
        sleep 0.25
    done
    echo "확장이 응답하지 않음:"; grep -i -E 'hanmium|error|JS' $DIR/shell.log | tail -15; exit 1
    ;;
run)
    shift; envs; exec "$@"
    ;;
call)
    shift; envs; m=$1; shift
    exec gdbus call --session --dest org.hanmium.Shell --object-path /org/hanmium/Shell --method org.hanmium.Shell.$m "$@"
    ;;
shot)
    envs
    gdbus call --session --dest org.hanmium.Shell --object-path /org/hanmium/Shell \
        --method org.hanmium.Shell.Screenshot "$2" >/dev/null && echo "$2"
    ;;
stop)
    uid=$(id -u)
    XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
        systemctl --user stop $UNIT.scope 2>/dev/null || true
    sleep 0.3
    for m in $(mount | awk -v d="$DIR" 'index($3, d) == 1 {print $3}'); do fusermount3 -u -z "$m" 2>/dev/null || true; done
    rm -rf $DIR 2>/dev/null || true
    echo "시험 세션 멈춤"
    ;;
*)
    sed -n '2,10p' "$0"; exit 2
    ;;
esac
