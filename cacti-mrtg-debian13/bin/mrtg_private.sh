#!/usr/bin/env bash
# Add an admin-only MRTG interface monitor using SNMPv2c 64-bit counters.
# SNMPv3 recommended: use cfgmaker and edit root-only targets.cfg manually if needed.
set -euo pipefail
umask 077
[[ "$EUID" == 0 ]] || { echo 'Run as root' >&2; exit 1; }
cfg='/etc/mrtg/scripts-tools/targets.cfg'
case "${1:-help}" in
add)
    [[ $# -eq 5 ]] || { echo 'Usage: mrtg_private.sh add NAME ROUTER_IP IFINDEX MAXBYTES' >&2; exit 1; }
    name="$2"; host="$3"; idx="$4"; maxbytes="$5"
    [[ "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,39}$ ]] || { echo 'Invalid name' >&2; exit 1; }
    [[ "$host" =~ ^[a-zA-Z0-9_.:-]+$ ]] || { echo 'Invalid address' >&2; exit 1; }
    [[ "$idx" =~ ^[0-9]+$ && "$maxbytes" =~ ^[0-9]+$ ]] || { echo 'IFINDEX/MAXBYTES must be integers' >&2; exit 1; }
    [[ "$idx" -gt 0 && "$maxbytes" -gt 0 ]] || { echo 'Values must be positive' >&2; exit 1; }
    if [[ -e "$cfg" ]] && grep -q "^Target\[$name\]:" "$cfg"; then
        echo "Duplicate MRTG target $name" >&2; exit 1
    fi
    if [[ -t 0 ]]; then
        read -r -s -p 'SNMPv2c read-only community: ' community; echo >&2
    else
        IFS= read -r community
    fi
    # Deliberately limited character class to avoid MRTG target syntax injection.
    [[ "$community" =~ ^[a-zA-Z0-9_.+-]{8,128}$ ]] || { echo 'Community must be 8-128 chars (A-Z a-z 0-9 _ . + -)' >&2; exit 1; }
    touch "$cfg"; chmod 0600 "$cfg"
    cat >>"$cfg" <<EOF

Target[$name]: $idx:$community@$host:::::2
MaxBytes[$name]: $maxbytes
Title[$name]: Private $name
PageTop[$name]: <h1>Private $name</h1>
EOF
    unset community
    echo "Added private target $name. Test: sudo mrtg /etc/mrtg/scripts-tools/private.cfg"
    ;;
list)
    [[ -f "$cfg" ]] && grep '^Target\[' "$cfg" | sed -E 's/^(Target\[[^]]+\]):.*/\1: [secret omitted]/' || true
    ;;
*)
    echo 'Usage: mrtg_private.sh add NAME ROUTER_IP IFINDEX MAXBYTES | list'
    echo 'Example: sudo mrtg_private.sh add vlan100 192.0.2.1 9 125000000'
    ;;
esac
