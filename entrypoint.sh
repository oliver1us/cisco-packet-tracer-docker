#!/usr/bin/env bash
set -u

# Config
: "${DISPLAY_NUM:=1}"
: "${DISPLAY_WIDTH:=1920}"
: "${DISPLAY_HEIGHT:=1080}"
: "${DISPLAY_DEPTH:=24}"
: "${VNC_PORT:=5900}"
: "${NOVNC_PORT:=6080}"
export DISPLAY=":${DISPLAY_NUM}"

mkdir -p "$HOME/.vnc" "$HOME/saves" "$HOME/storage" /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
# Clear the stale X lock and socket: /tmp survives "docker restart" and would break Xvnc
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

# Link the Packet Tracer config paths in $HOME into the storage volume, so the session survives a recreate
STORAGE="$HOME/storage"

persist_dir() {
    src="$1"; dst="$2"
    if [ -d "$src" ] && [ ! -L "$src" ]; then
        mkdir -p "$dst"
        cp -a "$src"/. "$dst"/ 2>/dev/null || true
        rm -rf "$src"
    fi
    mkdir -p "$dst"
    ln -sfn "$dst" "$src"
}

persist_file() {
    src="$1"; dst="$2"
    if [ -f "$src" ] && [ ! -L "$src" ]; then
        mkdir -p "$(dirname "$dst")"
        cp -a "$src" "$dst" 2>/dev/null || true
        rm -f "$src"
    fi
    ln -sfn "$dst" "$src"
}

mkdir -p "$HOME/.local/share"
persist_dir  "$HOME/pt"                                   "$STORAGE/pt"
persist_dir  "$HOME/.local/share/Cisco Packet Tracer"     "$STORAGE/Cisco Packet Tracer"
persist_file "$HOME/.packettracer"                        "$STORAGE/.packettracer"

# Optional VNC password (VNC_PASSWORD)
SECURITY_ARGS="-SecurityTypes None"
if [ -n "${VNC_PASSWORD:-}" ]; then
    printf '%s\n' "$VNC_PASSWORD" | vncpasswd -f > "$HOME/.vnc/passwd"
    chmod 600 "$HOME/.vnc/passwd"
    SECURITY_ARGS="-rfbauth $HOME/.vnc/passwd"
fi

echo "[entrypoint] Xvnc on :${DISPLAY_NUM} (${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}) port ${VNC_PORT}"
Xvnc "$DISPLAY" \
    -geometry "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}" \
    -depth "$DISPLAY_DEPTH" \
    -rfbport "$VNC_PORT" \
    -localhost no \
    $SECURITY_ARGS \
    >/tmp/xvnc.log 2>&1 &
XVNC_PID=$!

# Wait for the display to be ready
for i in $(seq 1 30); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 || {
    echo "[entrypoint] ERROR: Xvnc failed to start"; cat /tmp/xvnc.log; exit 1;
}

dbus-launch --exit-with-session fluxbox >/tmp/fluxbox.log 2>&1 &
FLUX_PID=$!

echo "[entrypoint] noVNC on port ${NOVNC_PORT}"
websockify --web /usr/share/novnc "$NOVNC_PORT" "localhost:${VNC_PORT}" >/tmp/websockify.log 2>&1 &
WS_PID=$!

# ---------------------------------------------------------------------------
# Chromium: no sandbox (container lacks SYS_ADMIN) and small shm; 9.0.1 needs no 8.2.2 polyfill
# ---------------------------------------------------------------------------
export QTWEBENGINE_DISABLE_SANDBOX=1
export QTWEBENGINE_CHROMIUM_FLAGS="--no-sandbox --disable-dev-shm-usage --disable-gpu"

launch_pt() {
    (
        export APPIMAGE=/opt/pt/packettracer.AppImage
        exec /opt/pt/squashfs-root/AppRun
    ) >>/tmp/packettracer.log 2>&1 &
    PT_PID=$!
}

echo "[entrypoint] launching Packet Tracer..."
launch_pt

trap 'kill "$XVNC_PID" "$FLUX_PID" "$WS_PID" "$PT_PID" 2>/dev/null; exit 0' TERM INT

# Supervisor: relaunch PT if it dies, exit the container if Xvnc or websockify dies
while true; do
    sleep 3
    if ! kill -0 "$PT_PID" 2>/dev/null; then
        wait "$PT_PID" 2>/dev/null
        echo "[entrypoint] Packet Tracer exited; restarting in 2s..."
        sleep 2
        launch_pt
    fi
    if ! kill -0 "$XVNC_PID" 2>/dev/null || ! kill -0 "$WS_PID" 2>/dev/null; then
        echo "[entrypoint] critical process exited; shutting down..."
        break
    fi
done

kill "$FLUX_PID" "$PT_PID" 2>/dev/null || true
