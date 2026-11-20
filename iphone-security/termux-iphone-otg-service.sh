#!/data/data/com.termux/files/usr/bin/bash
# iPhone OTG monitor + local usbmuxd bridge for Debian running in QEMU.
# Install: bash termux-iphone-otg-service.sh install
# Controls: bash termux-iphone-otg-service.sh status|logs|restart|stop|start|uninstall
set -euo pipefail

NAME=iphone-otg
BASE="$HOME/.local/share/iphone-otg"
STATE="$HOME/.local/state/iphone-otg"
SERVICE="$PREFIX/var/service/$NAME"
# termux-services normally sets these in a login shell. Scripts launched
# without that shell must provide them explicitly for sv and service-daemon.
export SVDIR="$PREFIX/var/service"
export LOGDIR="$PREFIX/var/log"
mkdir -p "$SVDIR" "$LOGDIR"
MODE=install
if [ "$#" -gt 0 ]; then MODE="$1"; fi

case "$MODE" in
  install)
    echo "[1/3] Installing Termux background-service dependencies..."
    pkg install -y termux-services termux-api libusb usbmuxd libimobiledevice socat
    mkdir -p "$BASE" "$STATE" "$SERVICE/log"
    cat > "$BASE/worker.sh" <<'WORKER'
#!/data/data/com.termux/files/usr/bin/bash
STATE="$HOME/.local/state/iphone-otg"
mkdir -p "$STATE"
echo "$$" > "$STATE/mux.pid"
if [ -z "$TERMUX_USB_FD" ]; then
  echo "Termux:API did not provide TERMUX_USB_FD" >> "$STATE/mux.log"
  exit 1
fi
# Note: Termux's stock usbmuxd/libusb can still fail to claim an Android USB interface.
exec "$PREFIX/bin/usbmuxd" -f -v >> "$STATE/mux.log" 2>&1
WORKER
    cat > "$BASE/monitor.sh" <<'MONITOR'
#!/data/data/com.termux/files/usr/bin/bash
set -u
STATE="$HOME/.local/state/iphone-otg"
WORKER="$HOME/.local/share/iphone-otg/worker.sh"
SOCKET="$PREFIX/var/run/usbmuxd"
mkdir -p "$STATE" "$PREFIX/var/run"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$STATE/service.log"; }
USB_PATH=""
MUX_PID=""
BRIDGE_PID=""
LINK_UP=no
cleanup() {
  log "Service stopped; cleaning up child processes"
  if [ -n "$MUX_PID" ]; then kill "$MUX_PID" 2>/dev/null || true; fi
  if [ -n "$BRIDGE_PID" ]; then kill "$BRIDGE_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM
log "Starting local-only TCP bridge at 127.0.0.1:27015"
socat "TCP4-LISTEN:27015,bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:$SOCKET" >> "$STATE/bridge.log" 2>&1 &
BRIDGE_PID=$!
sleep 1
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
  log "ERROR: TCP port 27015 unavailable; check $STATE/bridge.log"
  exit 1
fi
log "Monitoring USB OTG every 5 seconds. Android may ask for USB permission."
while :; do
  if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    log "ERROR: TCP bridge exited"
    exit 1
  fi
  NEW_PATH="$(termux-usb -l 2>/dev/null | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' | head -n1 || true)"
  if [ -z "$NEW_PATH" ]; then
    if [ -n "$USB_PATH" ]; then
      log "USB device disconnected: $USB_PATH"
      if [ -n "$MUX_PID" ]; then kill "$MUX_PID" 2>/dev/null || true; fi
      USB_PATH=""
      MUX_PID=""
      LINK_UP=no
    fi
  elif [ "$NEW_PATH" != "$USB_PATH" ]; then
    if [ -n "$MUX_PID" ]; then kill "$MUX_PID" 2>/dev/null || true; fi
    USB_PATH="$NEW_PATH"
    MUX_PID=""
    LINK_UP=no
    : > "$STATE/mux.log"
    rm -f "$STATE/mux.pid"
    log "OTG device attached: $USB_PATH; requesting Android USB permission"
    if termux-usb -r -E -e "$WORKER" "$USB_PATH" >> "$STATE/service.log" 2>&1; then
      sleep 2
      MUX_PID="$(cat "$STATE/mux.pid" 2>/dev/null || true)"
      if [ -z "$MUX_PID" ] || ! kill -0 "$MUX_PID" 2>/dev/null; then
        log "usbmuxd did not stay running. Check $STATE/mux.log"
      else
        log "usbmuxd launched, checking iPhone connectivity..."
      fi
    else
      log "USB permission denied, timed out, or device disconnected."
    fi
  fi
  if [ -n "$USB_PATH" ]; then
    UDID="$(idevice_id -l 2>/dev/null | head -n1 || true)"
    if [ -n "$UDID" ] && [ "$LINK_UP" != yes ]; then
      LINK_UP=yes
      log "iPhone available to Termux (UDID present). Debian endpoint: 10.0.2.2:27015"
    elif [ -z "$UDID" ] && [ "$LINK_UP" = yes ]; then
      LINK_UP=no
      log "iPhone no longer listed by usbmuxd."
    fi
  fi
  sleep 5
done
MONITOR
    chmod 700 "$BASE/worker.sh" "$BASE/monitor.sh"
    cat > "$SERVICE/run" <<'RUN'
#!/data/data/com.termux/files/usr/bin/sh
exec "$HOME/.local/share/iphone-otg/monitor.sh"
RUN
    chmod 700 "$SERVICE/run"
    ln -sfn "$PREFIX/share/termux-services/svlogger" "$SERVICE/log/run"
    echo "[2/3] Starting runit service manager..."
    service-daemon start >/dev/null 2>&1 || true
    sleep 2
    echo "[3/3] Enabling USB hotplug monitor..."
    sv-enable "$NAME"
    sv up "$NAME"
    sv status "$NAME" || true
    echo "Installed: monitor handles device attach/detach without restarting the terminal."
    echo "Android USB permission may still require tapping Allow for every reconnection."
    echo "Check: bash $HOME/termux-iphone-otg-service.sh status"
    ;;
  start)
    if [ ! -f "$SERVICE/run" ]; then
      echo "Service directory not installed; running setup first."
      exec bash "$0" install
    fi
    service-daemon start >/dev/null 2>&1 || true
    sleep 2
    sv-enable "$NAME"; sv up "$NAME"; sv status "$NAME"
    ;;
  stop)
    sv-disable "$NAME"; sv down "$NAME"; sv status "$NAME" || true
    ;;
  restart)
    if [ ! -f "$SERVICE/run" ]; then
      echo "Service directory not installed; running setup first."
      exec bash "$0" install
    fi
    service-daemon start >/dev/null 2>&1 || true
    sleep 2
    sv restart "$NAME"; sv status "$NAME"
    ;;
  status)
    sv status "$NAME" || true
    echo "--- Android USB devices ---"
    termux-usb -l || true
    echo "--- Monitor ---"
    tail -n 15 "$STATE/service.log" 2>/dev/null || true
    echo "--- Latest usbmuxd diagnostic ---"
    tail -n 15 "$STATE/mux.log" 2>/dev/null || true
    ;;
  logs)
    tail -n 50 -f "$STATE/service.log" "$STATE/mux.log" "$STATE/bridge.log"
    ;;
  uninstall)
    sv-disable "$NAME" 2>/dev/null || true
    sv down "$NAME" 2>/dev/null || true
    rm -rf "$SERVICE" "$BASE"
    echo "Removed USB service. Logs remain at $STATE"
    ;;
  *)
    echo "Usage: $0 {install|start|stop|restart|status|logs|uninstall}" >&2
    exit 2
    ;;
esac
