#!/usr/bin/env bash
# Debian 13 QEMU guest: connect to rootless Termux USB multiplexing bridge.
set -euo pipefail

HOST_IP=10.0.2.2
PORT=27015
PROFILE="$HOME/iphone-supervised-security-account-allowed.mobileconfig"
URL='https://raw.githubusercontent.com/tishriclarin/scripts-tools/main/iphone-security/iphone-supervised-security-account-allowed.mobileconfig'

printf '[1/4] Checking Debian tools...\n'
if ! command -v nc >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v pipx >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y netcat-openbsd curl pipx python3-venv
fi
export PATH="$HOME/.local/bin:$PATH"
if ! command -v pymobiledevice3 >/dev/null 2>&1; then
  pipx install pymobiledevice3
fi

printf '[2/4] Testing QEMU/Termux TCP bridge...\n'
if ! nc -z -w 4 "$HOST_IP" "$PORT"; then
  echo 'ERROR: No connection to Termux bridge at 10.0.2.2:27015.' >&2
  echo 'Run the Termux script first. QVM must be using QEMU user-mode networking.' >&2
  exit 1
fi
export PYMOBILEDEVICE3_USBMUX="$HOST_IP:$PORT"
export USBMUXD_SOCKET_ADDRESS="$HOST_IP:$PORT"

printf '[3/4] Querying iPhone through Termux usbmuxd...\n'
DEVICES="$(pymobiledevice3 usbmux list 2>&1)" || {
  echo "$DEVICES" >&2
  exit 1
}
echo "$DEVICES"
if [ -z "$DEVICES" ] || [ "$(printf '%s' "$DEVICES" | tr -d '[:space:]')" = '[]' ]; then
  echo 'ERROR: TCP bridge is reachable, but usbmuxd sees no iPhone.' >&2
  exit 1
fi

printf '[4/4] Checking profiles and downloading the reviewed configuration...\n'
if ! pymobiledevice3 profile list; then
  echo 'Profile access may require pairing. Unlock the iPhone, then run:' >&2
  echo '  PYMOBILEDEVICE3_USBMUX=10.0.2.2:27015 pymobiledevice3 lockdown pair' >&2
  exit 1
fi
curl -fSL --retry 2 -o "$PROFILE" "$URL"
python3 - "$PROFILE" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file:
    data = plistlib.load(file)
assert data['PayloadType'] == 'Configuration'
print('Validated XML/plist:', data['PayloadDisplayName'])
PY

printf '\nProfile saved to: %s\n' "$PROFILE"
echo 'WARNING: This profile can lock management settings and prohibit removal.'
echo 'Only install if you have an authorized supervisor/MDM recovery method.'
read -r -p 'Install the profile on this iPhone now? [y/N] ' answer
if [[ "$answer" =~ ^[yY]$ ]]; then
  pymobiledevice3 profile install "$PROFILE"
  echo 'Profile install requested. Confirm the resulting status on your iPhone.'
else
  echo 'Installation skipped. To install later, rerun this script.'
fi
