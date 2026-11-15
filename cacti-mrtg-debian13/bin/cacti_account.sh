#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $EUID -eq 0 ]] || { echo 'Run with sudo/root' >&2; exit 1; }
PHP_CLI="${CACTI_ACCOUNT_PHP:-/usr/local/lib/scripts-tools/cacti_account.php}"
[[ -f "$PHP_CLI" ]] || { echo "Missing $PHP_CLI; install scripts-tools first" >&2; exit 1; }
action="${1:-help}"
if [[ "$action" == add ]]; then
    [[ $# -ge 4 ]] || { echo 'Usage: cacti_account.sh add USER PASSWORD DEVICE_ID:ifName:NAME [SELECTOR...]' >&2; exit 1; }
    user="$2"; pass="$3"; shift 3
    if [[ "$pass" == '-' ]]; then
        if [[ -t 0 ]]; then
            read -r -s -p "Password for $user (12+ chars): " pass; echo >&2
        else
            IFS= read -r pass
        fi
    else
        echo 'WARNING: passwords on a command line may appear in shell history or process listings. Use - to enter privately.' >&2
    fi
    printf '%s\n' "$pass" | php "$PHP_CLI" add "$user" --stdin-password "$@"
    unset pass
elif [[ "$action" == reset-admin ]]; then
    if [[ -t 0 ]]; then
        read -r -s -p 'New Cacti admin password (12+ chars): ' pass; echo >&2
    else
        IFS= read -r pass
    fi
    printf '%s\n' "$pass" | php "$PHP_CLI" reset-admin
    unset pass
else
    php "$PHP_CLI" "$@"
fi
