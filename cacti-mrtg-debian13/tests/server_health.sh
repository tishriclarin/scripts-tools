#!/usr/bin/env bash
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Use sudo/root' >&2; exit 1; }
[[ -f /etc/cacti/debian.php ]] || { echo 'Missing Cacti database config' >&2; exit 1; }
for bin in php mrtg snmpwalk nginx; do command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 1; }; done
php /usr/share/cacti/cli/add_graphs.php --list-hosts >/dev/null
/usr/local/sbin/cacti_account.sh audit-all
nginx -t
[[ -S /run/php/php8.4-fpm.sock ]] || { echo 'PHP-FPM socket unavailable' >&2; exit 1; }
[[ -L /var/lib/scripts-tools/webroot/cacti ]] || { echo 'Cacti NGINX site symlink missing' >&2; exit 1; }
[[ -d /var/lib/mrtg-private ]] || exit 1
[[ $(stat -c %a /var/lib/mrtg-private) == 700 ]] || { echo 'MRTG workdir is not root-only' >&2; exit 1; }
[[ -f /etc/nginx/snippets/scripts-tools-cacti-locations.conf ]] || { echo 'NGINX site rules missing' >&2; exit 1; }
if dpkg -s apache2 2>/dev/null | grep -q '^Status: install ok installed
echo 'PASS: Cacti CLI reachable, account ACL audit clean, NGINX config syntactically valid, MRTG dir private.'
echo 'NEXT: complete manual two-customer HTTP(S) authorization acceptance test in README.md.'
; then echo 'Unexpected Apache installation' >&2; exit 1; fi
echo 'PASS: Cacti CLI reachable, account ACL audit clean, Apache config syntactically valid, MRTG dir private.'
echo 'NEXT: complete manual two-customer HTTP(S) authorization acceptance test in README.md.'
