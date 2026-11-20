#!/data/data/com.termux/files/usr/bin/bash
# Rootless iPhone -> Termux usbmuxd -> local TCP bridge for QEMU user-mode NAT
set -euo pipefail

PORT=27015
WORK="$HOME/.qvm-iphone"
SOCK="$PREFIX/var/run/usbmuxd"
mkdir -p "$WORK"

echo '[1/4] Checking Termux tools...'
for c in termux-usb usbmuxd idevice_id socat; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo 'Installing missing tools from Termux repositories...'
    pkg install -y termux-api libusb usbmuxd libimobiledevice socat
    break
  fi
done

printf '\n[2/4] Finding iPhone USB device...\n'
DEV="$(termux-usb -l | grep -oE '/dev/bus/usb/[0-9]+/[0-9]+' | head -n1 || true)"
if [ -z "$DEV" ]; then
  echo 'ERROR: No USB device detected. Unlock both phones and reconnect OTG.' >&2
  exit 1
fi
echo "Android USB device: $DEV"

# The Android USB API grants an FD to this child. Standard usbmuxd may still
# fail to change USB configurations / claim interfaces on some Android builds.
cat > "$WORK/usbmuxd-worker.sh" <<'WORKER'
#!/data/data/com.termux/files/usr/bin/bash
if [ -z "${TERMUX_USB_FD:-}" ]; then
  echo 'ERROR: Termux did not pass TERMUX_USB_FD' >> "$HOME/.qvm-iphone/usbmuxd.log"
  exit 1
fi
exec usbmuxd -f -v >> "$HOME/.qvm-iphone/usbmuxd.log" 2>&1
WORKER
chmod 700 "$WORK/usbmuxd-worker.sh"

# Restart stale daemon from an earlier failed test.
pkill -x usbmuxd 2>/dev/null || true
sleep 1
: > "$WORK/usbmuxd.log"
echo '[3/4] Requesting Android USB permission and starting usbmuxd...'
termux-usb -r -E -e "$WORK/usbmuxd-worker.sh" "$DEV"

UDID=''
for _ in 1 2 3 4 5 6 7 8; do
  UDID="$(idevice_id -l 2>/dev/null | head -n1 || true)"
  [ -n "$UDID" ] && break
  sleep 1
done
if [ -z "$UDID" ]; then
  echo 'ERROR: usbmuxd could not communicate with the iPhone.' >&2
  echo 'Latest usbmuxd diagnostics:' >&2
  tail -n 30 "$WORK/usbmuxd.log" >&2
  echo 'If LIBUSB_ERROR_BUSY / NOT_FOUND appears, this is an Android USB interface issue, not a Debian package problem.' >&2
  exit 1
fi

echo "iPhone detected by usbmuxd: $UDID"
echo '[4/4] Starting bridge on Android localhost...'
if [ -f "$WORK/bridge.pid" ] && kill -0 "$(cat "$WORK/bridge.pid")" 2>/dev/null; then
  echo 'Existing bridge process detected.'
else
  nohup socat "TCP4-LISTEN:${PORT},bind=127.0.0.1,reuseaddr,fork" "UNIX-CONNECT:${SOCK}" > "$WORK/bridge.log" 2>&1 < /dev/null &
  echo $! > "$WORK/bridge.pid"
  sleep 1
  if ! kill -0 "$(cat "$WORK/bridge.pid")" 2>/dev/null; then
    echo 'ERROR: TCP bridge failed:' >&2
    cat "$WORK/bridge.log" >&2
    exit 1
  fi
fi
printf '\nREADY: Debian guest using QEMU user networking connects to 10.0.2.2:%s\n' "$PORT"
echo 'Keep Termux alive while accessing the iPhone. Logs: ~/.qvm-iphone/usbmuxd.log'
